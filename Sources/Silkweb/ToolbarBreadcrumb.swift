import AppKit
import SilkwebCore
import SwiftUI

/// Toolbar geometry for the empty middle of the compact bar (silkweb-1.65; #91 moved the path to the status bar).
/// Only the gap observes it.
@MainActor @Observable
final class ToolbarMetrics {
    /// The gap item's width. It fills the bar between Filter by Tag and the trailing items, which keeps those items
    /// at the trailing edge now that the title is removed (macOS 15 has no SwiftUI flexible toolbar spacer).
    var gapWidth: CGFloat = 320
    @ObservationIgnored let controller = CompactToolbarController()
    init() { controller.metrics = self }
}

/// Keeps the compact bar laid out: sizes the empty gap to the room the other items leave, sets overflow
/// priorities, and slides the leading items into the traffic-light area only while no window button shows
/// (hidden buttons, or the concealed full-screen titlebar; AppKit doesn't reflow for them) and AppKit lets the
/// row take the freed room.
@MainActor final class CompactToolbarController: NSObject {
    weak var metrics: ToolbarMetrics?
    private(set) weak var window: NSWindow?
    private weak var anchor: NSView?
    private var observers: [NSObjectProtocol] = []
    private var buttonObservations: [NSKeyValueObservation] = []
    private var scheduled = false
    /// The last width each item took in the bar, viewer padding included, so items in the » menu still count.
    private var slotWidths: [ObjectIdentifier: CGFloat] = [:]
    /// The gap viewer's padding, last seen while it was placed.
    private var gapPadding: CGFloat?
    /// AppKit's own toolbar-view frame while the leading items are shifted; nil when nothing is shifted.
    private var naturalFrame: NSRect?
    private var shiftedFrame: NSRect?
    private var animating = false
    /// AppKit refused the shifted row the freed room; the items stay put until a window button shows again.
    private(set) var shiftGrowthFailed = false
    private var nudges = 0
    /// Whether the last leading move slid (false: placed at once, as under Reduce Motion).
    private(set) var lastMoveAnimated: Bool?
    static var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static let leadingInset = Spacing.small
    /// From the Info glyph to the bar's edge or the inspector's titlebar area, mirroring the leading inset (#68).
    static let trailingInset = Spacing.small
    /// How far the Info button's bezel overhangs its item into the viewer's 4 pt trailing padding. AppKit keeps the
    /// row 4 pt from the bar's edge, which alone would leave the glyph 14 pt from it.
    static let trailingOverhang: CGFloat = 3
    /// What the last item keeps after its glyph: the 6 pt a toolbar button leaves around its 13 pt glyph and the
    /// viewer's 4 pt padding, less the overhang.
    static let trailingGlyphInset: CGFloat = 10 - trailingOverhang
    /// Room after the last item's viewer.
    static let rowEndInset = trailingInset - trailingGlyphInset
    /// 16 pt between the library and view groups at the least, the design system's gap between groups.
    static let minimumGapWidth = Spacing.medium
    static let nudgeLimit = 3
    /// AppKit starts the row about 10 pt after the zoom button; a row starting further in follows a section.
    static let sectionSlack: CGFloat = 24
    /// Tests turn this off to make the controller try the slide after a section and hit AppKit's refusal.
    static var predictsSections = true
    /// How far short of its end the shifted row may stop before it counts as refused (rounding, viewer padding).
    static let rowEndSlack: CGFloat = 12
    /// The gap gives way first: it shrinks to its minimum, and only below that does it go into the » menu. The
    /// buttons follow in this order, Filter by Tag first; the sidebar toggle and mode control never do.
    static let gapPriority = -2000
    static let overflowPriorities: [String: Int] = [
        "Filter by Tag": -1000, "Sort By": -800, "Show Outline": -600, "Show Document Info": -400, "New Document": -200,
    ]

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    func attach(anchor: NSView) {
        self.anchor = anchor
        // In full screen the toolbar moves to a separate window; keep observing the document window.
        if let window = anchor.window, window.toolbar != nil, window !== self.window {
            self.window = window
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            let center = NotificationCenter.default
            // Resize updates at once, so the gap shrinks with the window instead of after it.
            observers =
                [
                    center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) {
                        [weak self] _ in
                        MainActor.assumeIsolated { self?.update() }
                    }
                ]
                + [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification].map { name in
                    center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated { self?.scheduleUpdate() }
                    }
                } + [
                    // Sidebar and Outline columns move the toolbar's sections without resizing the window.
                    center.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: nil, queue: .main) {
                        [weak self] note in
                        let view = note.object as? NSView
                        MainActor.assumeIsolated {
                            guard let self, let window = self.window, view?.window === window else { return }
                            self.scheduleUpdate()
                        }
                    }
                ]
            // macOS shows the buttons again when the full-screen titlebar is revealed (hover at the top edge), so
            // follow the buttons themselves, and their titlebar view, rather than the window's full-screen state.
            let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap {
                window.standardWindowButton($0)
            }
            let changed: (NSView) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.scheduleUpdate() } }
            buttonObservations =
                buttons.flatMap { button in
                    [
                        button.observe(\.isHidden) { view, _ in changed(view) },
                        button.observe(\.alphaValue) { view, _ in changed(view) },
                        button.observe(\.superview) { view, _ in changed(view) },
                    ]
                }
                + Set(buttons.compactMap(\.superview)).map { titlebar in
                    titlebar.observe(\.isHidden) { view, _ in changed(view) }
                }
        }
        scheduleUpdate()
    }

    /// Coalesces bursts (three buttons hiding, a divider drag) into one pass after AppKit's toolbar layout.
    func scheduleUpdate() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scheduled = false
            nudges = 0
            update()
        }
    }

    /// The buttons are absent only when none of them shows. Full screen alone isn't evidence: macOS reveals the
    /// titlebar with its buttons on hover while the window stays full screen. A visible traffic light always
    /// keeps the items where AppKit put them.
    static func windowButtonsAbsent(buttonsShown: [Bool]) -> Bool {
        !buttonsShown.contains(true)
    }

    /// Shown: in a window, not hidden (itself or its titlebar), and not faded out.
    static func isShown(_ button: NSButton?) -> Bool {
        guard let button else { return false }
        return button.window != nil && !button.isHiddenOrHasHiddenAncestor && button.alphaValue > 0.01
    }

    var windowButtonsAbsent: Bool {
        guard let window else { return false }
        return Self.windowButtonsAbsent(
            buttonsShown: [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map {
                Self.isShown(window.standardWindowButton($0))
            })
    }

    func update() {
        guard let window, let anchor, let toolbar = window.toolbar,
            let gapItem = toolbar.items.first(where: { $0.view.map { anchor.isDescendant(of: $0) } == true }),
            let gap = gapItem.view
        else { return }
        for item in toolbar.items {
            let priority =
                item === gapItem
                ? Self.gapPriority
                : Self.overflowPriorities[item.label] ?? NSToolbarItem.VisibilityPriority.user.rawValue
            if item.visibilityPriority.rawValue != priority {
                item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: priority)
            }
        }
        // Items in the » menu have no window; the sidebar toggle never overflows, so something is always placed.
        let views = toolbar.items.compactMap(\.view)
        let placed = views.filter {
            $0.window != nil && !$0.isHiddenOrHasHiddenAncestor && $0.superview?.superview?.superview != nil
        }
        guard let toolbarView = placed.first?.superview?.superview, let bar = toolbarView.superview,
            placed.allSatisfy({ $0.superview?.superview === toolbarView })
        else { return }
        for view in placed { slotWidths[ObjectIdentifier(view)] = view.superview!.frame.width }
        let padding = placed.first.map { $0.superview!.frame.width - $0.frame.width } ?? 8
        // The gap's viewer may pad it differently from the buttons'; the row's end depends on its own.
        if placed.contains(where: { $0 === gap }) { gapPadding = gap.superview!.frame.width - gap.frame.width }
        func slot(_ view: NSView) -> CGFloat { slotWidths[ObjectIdentifier(view)] ?? view.fittingSize.width + padding }

        // Leading edge. AppKit lays the row out itself (after the traffic lights, or after the sidebar column);
        // its frame for the toolbar view is never overridden unless the window buttons are absent.
        if animating { return }
        if let shifted = shiftedFrame, toolbarView.frame != shifted {
            // AppKit laid the toolbar view out again; its frame is the natural one now.
            naturalFrame = nil
            shiftedFrame = nil
        }
        let natural = naturalFrame ?? toolbarView.frame
        let firstViewer = placed.map { $0.superview!.frame.minX }.min() ?? 0
        let firstItem = placed.map { $0.frame.minX + $0.superview!.frame.minX }.min() ?? 0
        let naturalLeading = natural.minX + firstViewer
        let regions = Self.reservedRegions(in: bar)
        let buttonsAbsent = windowButtonsAbsent
        // The slide is worth it only while the row also takes the freed room; otherwise the trailing items would
        // leave the edge (#54). AppKit never grows the row into a section it keeps for the sidebar column, so
        // after one the items stay where AppKit put them, as they do once AppKit refuses the wider row.
        if !buttonsAbsent { shiftGrowthFailed = false }
        let buttonsEnd = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton]
            .compactMap { window.standardWindowButton($0) }.filter { $0.window === bar.window }
            .map { $0.convert($0.bounds, to: bar).maxX }.max()
        let slides =
            buttonsAbsent && !shiftGrowthFailed
            && !(Self.predictsSections
                && Self.rowFollowsSection(naturalLeading: naturalLeading, regions: regions, buttonsEnd: buttonsEnd))
        var target = natural
        if slides {
            let shift = min(0, Self.leadingInset - (natural.minX + firstItem))
            target = NSRect(
                x: natural.minX + shift, y: natural.minY, width: natural.width - shift, height: natural.height)
        }
        if target != toolbarView.frame {
            if target == natural {
                naturalFrame = nil
                shiftedFrame = nil
            } else {
                naturalFrame = natural
                shiftedFrame = target
            }
            move(toolbarView, to: target, in: window)
        }

        // The gap takes the room the other items leave, so the trailing items stay at the trailing edge.
        // The row ends at the bar's edge or where AppKit reserves the titlebar over the Outline inspector.
        // While shifted, the gap also takes the freed space.
        let grows = shiftedFrame != nil
        let leading = grows ? target.minX + firstViewer : naturalLeading
        var limit = grows ? target.maxX : natural.maxX
        for region in regions where region.minX > naturalLeading + 1 {
            limit = min(limit, region.minX)
        }
        let others = views.filter { $0 !== gap }.reduce(CGFloat(0)) { $0 + slot($1) }
        let available = floor(limit - Self.rowEndInset - leading - others - (gapPadding ?? padding))
        let width = max(Self.minimumGapWidth, available)
        let changed = metrics.map { abs($0.gapWidth - width) > 0.5 } ?? false
        if changed {
            metrics?.gapWidth = width
            nudges = 0
        }
        // Once the gap has its width, a row that still stops short of its end wasn't given the room.
        let rowEnd = toolbarView.frame.minX + (placed.map { $0.superview!.frame.maxX }.max() ?? 0)
        let rowShort =
            grows && !animating && toolbarView.frame == target && !changed && placed.count == views.count
            && available >= Self.minimumGapWidth
            && abs(gap.frame.width - width) < 1 && rowEnd < limit - Self.rowEndInset - Self.rowEndSlack
        if grows, rowShort || (placed.count < views.count && nudges >= Self.nudgeLimit) {
            // AppKit didn't give the shifted row the freed space after all: keep AppKit's placement instead, so
            // the trailing items keep their edge.
            shiftGrowthFailed = true
            scheduleUpdate()
        } else if placed.count < views.count, available >= Self.minimumGapWidth {
            nudge(toolbar, toolbarView: toolbarView)
        } else if changed {
            // Confirm the row once SwiftUI applies the width.
            DispatchQueue.main.async { [weak self] in self?.update() }
        }
    }

    /// Whether AppKit starts the row after a section it keeps for the sidebar column (a blocking view before the
    /// row, or a start well past the traffic lights). The row never grows into that section.
    static func rowFollowsSection(naturalLeading: CGFloat, regions: [NSRect], buttonsEnd: CGFloat?) -> Bool {
        regions.contains { $0.maxX <= naturalLeading + 1 }
            || buttonsEnd.map { naturalLeading > $0 + sectionSlack } == true
    }

    /// Where AppKit keeps the titlebar clear for a split view's trailing column (the Outline inspector). AppKit
    /// marks the sidebar and inspector dividers with blocking views in the titlebar container (zero-width ones,
    /// for plain dividers, don't stop items); without them the row runs to the bar's edge.
    static func reservedRegions(in bar: NSView) -> [NSRect] {
        guard let container = bar.superview else { return [] }
        return container.subviews.filter {
            $0 !== bar && NSStringFromClass(type(of: $0)).contains("Blocking") && !$0.isHidden
        }
        .map { $0.convert($0.bounds, to: bar) }.filter { $0.width > 0 }
    }

    private func move(_ toolbarView: NSView, to target: NSRect, in window: NSWindow) {
        if Self.reduceMotion() || window.inLiveResize {
            lastMoveAnimated = false
            toolbarView.frame = target
            return
        }
        lastMoveAnimated = true
        animating = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            toolbarView.animator().frame = target
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.animating = false
                toolbarView.frame = target
                self.scheduleUpdate()
            }
        }
    }

    /// NSToolbar doesn't re-measure items already in the » menu, so once the gap fits again, ask it to
    /// lay the row out (after SwiftUI applies the new width). Bounded: a window narrower than the fixed items
    /// legitimately keeps the » menu.
    private func nudge(_ toolbar: NSToolbar, toolbarView: NSView) {
        guard nudges < Self.nudgeLimit else { return }
        nudges += 1
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for item in toolbar.items where item.view?.window == nil {
                item.view?.invalidateIntrinsicContentSize()
                // Re-assigning a priority makes the toolbar re-evaluate which items fit.
                let priority = item.visibilityPriority
                item.visibilityPriority = .user
                item.visibilityPriority = priority
            }
            toolbarView.needsLayout = true
            toolbarView.layoutSubtreeIfNeeded()
            update()
        }
    }
}

/// The empty middle of the compact bar (#91): library group · gap · view group. No path, no title.
struct ToolbarGap: View {
    let workspace: LibraryWorkspace

    var body: some View {
        ToolbarAnchor(controller: workspace.toolbarMetrics.controller)
            .frame(width: workspace.toolbarMetrics.gapWidth, height: 22)
            .accessibilityHidden(true)
    }
}

/// Hands the window to the controller and marks the gap's item, which the controller sizes.
private struct ToolbarAnchor: NSViewRepresentable {
    let controller: CompactToolbarController
    func makeNSView(context: Context) -> ToolbarAnchorView { ToolbarAnchorView(controller: controller) }
    func updateNSView(_ view: ToolbarAnchorView, context: Context) {}
}

final class ToolbarAnchorView: NSView {
    let controller: CompactToolbarController
    init(controller: CompactToolbarController) {
        self.controller = controller
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { controller.attach(anchor: self) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// `Library › Vanlife › Settling In`, leading in the status bar (#91): the document's real folder. Reads no text.
struct StatusBarPath: NSViewRepresentable {
    let workspace: LibraryWorkspace
    func makeNSView(context: Context) -> BreadcrumbView {
        BreadcrumbView { [weak workspace] in workspace?.selectFolder($0) }
    }
    func updateNSView(_ view: BreadcrumbView, context: Context) {
        view.update(path: workspace.breadcrumb)
    }
    /// Unspecified: the whole path; zero: the folded path; otherwise the offered width up to the whole path. Below
    /// the folded path's width the view clips rather than overlap the trailing cluster.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: BreadcrumbView, context: Context) -> CGSize? {
        let width =
            switch proposal.width {
            case nil: view.idealWidth
            case 0: view.minimumWidth
            case let offered?: min(view.idealWidth, offered)
            }
        return CGSize(width: width, height: CrumbButton.height)
    }
}

/// Native buttons, so Full Keyboard Access, VoiceOver and the pointer all reach each crumb.
final class BreadcrumbView: NSView {
    let select: (String) -> Void
    private(set) var path = Breadcrumb(crumbs: [], current: "")
    private(set) var crumbButtons: [CrumbButton] = []
    private(set) var ellipsis: CrumbButton?
    private var separators: [NSImageView] = []
    let currentLabel = NSTextField(labelWithString: "")
    private(set) var fit: Breadcrumb.Fit?
    /// The whole path and the fully folded one, measured once per path.
    private(set) var idealWidth: CGFloat = 0
    private(set) var minimumWidth: CGFloat = 0

    static let crumbFont = NSFont.systemFont(ofSize: 11)
    static let currentFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    /// Hover padding on each side of a crumb; it also spaces the text from the chevrons (4 pt).
    static let padding: CGFloat = 4
    static let separatorWidth: CGFloat = 8
    static let ellipsisWidth = textWidth("…", crumbFont) + 2 * padding
    static let metrics = Breadcrumb.Metrics(separator: Double(separatorWidth), ellipsis: Double(ellipsisWidth))

    init(select: @escaping (String) -> Void) {
        self.select = select
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: CrumbButton.height))
        currentLabel.font = Self.currentFont
        currentLabel.textColor = .labelColor
        currentLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(currentLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Path")
        setAccessibilityIdentifier("statusPath")
        // At its folded minimum the title can still be wider than a very narrow bar; it never spills over.
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Each crumb's and the document title's width, hover padding included.
    private var measured: (crumbs: [Double], current: Double) {
        (
            path.crumbs.map { Double(Self.textWidth($0.title, Self.crumbFont) + 2 * Self.padding) },
            Double(Self.textWidth(path.current, Self.currentFont) + 2 * Self.padding)
        )
    }

    func update(path: Breadcrumb) {
        guard path != self.path else { return }
        self.path = path
        for view in crumbButtons + separators { view.removeFromSuperview() }
        crumbButtons = path.crumbs.map { crumb in
            let button = CrumbButton(title: crumb.title, link: crumb.folderPath != nil)
            if let folder = crumb.folderPath {
                button.activate = { [weak self] in self?.select(folder) }
                button.setAccessibilityLabel("\(crumb.title), folder")
                button.setAccessibilityHelp("Shows this folder")
            } else {
                button.setAccessibilityLabel(crumb.title)
            }
            addSubview(button)
            return button
        }
        separators = (0...path.crumbs.count).map { _ in
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
            image.contentTintColor = .tertiaryLabelColor
            image.setAccessibilityElement(false)
            addSubview(image)
            return image
        }
        currentLabel.stringValue = path.current
        currentLabel.toolTip = path.current
        setAccessibilityValue(path.accessibilityValue)
        let (crumbs, current) = measured
        idealWidth = ceil(
            Breadcrumb.fit(crumbs: crumbs, current: current, available: .infinity, metrics: Self.metrics).width)
        minimumWidth = ceil(
            Breadcrumb.fit(crumbs: crumbs, current: current, available: 0, metrics: Self.metrics).width)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let ellipsisWidth = Self.ellipsisWidth
        let (crumbs, current) = measured
        let fit = Breadcrumb.fit(
            // Half a point of slack, so a frame rounded to the pixel grid doesn't fold a path that fits.
            crumbs: crumbs, current: current, available: Double(bounds.width) + 0.5, metrics: Self.metrics)
        self.fit = fit
        // The `…` pull-down exists only while ancestors are folded.
        if fit.collapsed.isEmpty {
            ellipsis?.removeFromSuperview()
            ellipsis = nil
        } else {
            let hidden = Array(path.crumbs[fit.collapsed])
            let button = ellipsis ?? CrumbButton(title: "…", link: true)
            if ellipsis == nil { addSubview(button); ellipsis = button }
            button.setAccessibilityLabel("More folders: " + hidden.map(\.title).joined(separator: ", "))
            button.activate = { [weak self, weak button] in
                guard let self, let button else { return }
                let menu = NSMenu()
                for crumb in hidden {
                    let item = NSMenuItem(
                        title: crumb.title, action: crumb.folderPath == nil ? nil : #selector(self.chooseHidden(_:)),
                        keyEquivalent: "")
                    item.target = self
                    item.representedObject = crumb.folderPath
                    item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                    menu.addItem(item)
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
            }
        }
        // Crumbs and the current crumb share one text baseline.
        let height = bounds.height
        let baseline = floor(
            (height - Self.crumbFont.ascender + Self.crumbFont.descender) / 2 - Self.crumbFont.descender)
        func place(_ view: NSView, x: CGFloat, width: CGFloat) {
            let size = view.fittingSize
            view.frame = NSRect(
                x: x, y: baseline + view.firstBaselineOffsetFromTop - size.height, width: max(0, width),
                height: size.height)
        }
        var x: CGFloat = 0
        var separatorIndex = 0
        func separator() {
            let image = separators[separatorIndex]
            separatorIndex += 1
            image.isHidden = false
            image.frame = NSRect(x: x, y: 0, width: Self.separatorWidth, height: height)
            x += Self.separatorWidth
        }
        for (index, button) in crumbButtons.enumerated() {
            if index == fit.collapsed.lowerBound, let ellipsis {
                place(ellipsis, x: x, width: ellipsisWidth)
                x += ellipsisWidth
                separator()
            }
            button.isHidden = fit.collapsed.contains(index)
            guard !button.isHidden else { continue }
            place(button, x: x, width: CGFloat(fit.crumbWidths[index]))
            x += CGFloat(fit.crumbWidths[index])
            separator()
        }
        for image in separators[separatorIndex...] { image.isHidden = true }
        // Labels inset their text by 2 pt on each side; widen the frames so measured text isn't truncated.
        place(currentLabel, x: x + Self.padding - 2, width: CGFloat(fit.currentWidth) - 2 * Self.padding + 4)
        setAccessibilityChildren((ellipsis.map { [$0] } ?? []) + crumbButtons.filter { !$0.isHidden } + [currentLabel])
    }

    @objc private func chooseHidden(_ sender: NSMenuItem) {
        if let folder = sender.representedObject as? String { select(folder) }
    }
}

/// A plain text crumb: hover fill, pointing hand, Space under Full Keyboard Access.
final class CrumbButton: NSButton {
    var activate: (() -> Void)?
    let isLink: Bool
    private var hovered = false { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?
    static let height: CGFloat = 20

    init(title: String, link: Bool) {
        isLink = link
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(
            string: title, attributes: [.font: BreadcrumbView.crumbFont, .foregroundColor: NSColor.secondaryLabelColor])
        toolTip = title
        target = self
        action = #selector(activateCrumb)
        if !link {
            isEnabled = false
            setAccessibilityRole(.staticText)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func activateCrumb() { activate?() }

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: BreadcrumbView.textWidth(attributedTitle.string, BreadcrumbView.crumbFont) + 2
                * BreadcrumbView.padding, height: Self.height)
    }
    override var fittingSize: NSSize { intrinsicContentSize }
    override var firstBaselineOffsetFromTop: CGFloat {
        let font = BreadcrumbView.crumbFont
        return (Self.height - font.ascender + font.descender) / 2 + font.ascender
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered && isLink {
            NSColor.quaternarySystemFill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
        }
        // Tail truncation inside the 6 pt padding; the colour stays secondary even when not a link.
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let font = BreadcrumbView.crumbFont
        let text = NSAttributedString(
            string: attributedTitle.string,
            attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
        let lineHeight = ceil(font.ascender - font.descender)
        text.draw(
            with: NSRect(
                x: BreadcrumbView.padding, y: (bounds.height - lineHeight) / 2,
                width: max(0, bounds.width - 2 * BreadcrumbView.padding), height: lineHeight),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
    override var isFlipped: Bool { false }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill() }

    override func resetCursorRects() {
        if isLink { addCursorRect(bounds, cursor: .pointingHand) }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

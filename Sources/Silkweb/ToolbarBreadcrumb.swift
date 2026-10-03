import AppKit
import SwiftUI
import SilkwebCore

/// Toolbar geometry for the one-line breadcrumb (silkweb-1.65). Only the breadcrumb observes it.
@MainActor @Observable
final class ToolbarMetrics {
    /// The breadcrumb item's width, including its leading gap. It fills the bar between Filter by Tag and the
    /// trailing items, which also keeps those items at the trailing edge now that the title is removed.
    var breadcrumbWidth: CGFloat = 320
    @ObservationIgnored let controller = CompactToolbarController()
    init() { controller.metrics = self }
}

/// Keeps the compact bar laid out: sizes the breadcrumb, sets overflow priorities, and slides the leading
/// items into the traffic-light area when the window buttons are absent (AppKit doesn't reflow for them).
@MainActor final class CompactToolbarController: NSObject {
    weak var metrics: ToolbarMetrics?
    private(set) weak var window: NSWindow?
    private weak var anchor: NSView?
    private var observers: [NSObjectProtocol] = []
    private var buttonObservations: [NSKeyValueObservation] = []
    private var scheduled = false
    private var relayoutPending = false
    private var relayoutAttempts = 0
    static let leadingInset = Spacing.small
    static let trailingInset = Spacing.small
    static let minimumBreadcrumbWidth: CGFloat = 120
    static let overflowAllowance: CGFloat = 32
    static let relayoutLimit = 3
    /// Items that overflow into the » menu first have the lowest priority; the rest never overflow.
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
            // Resize updates at once, so a shrinking window never flashes items into the » menu.
            observers = [NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.relayoutAttempts = 0
                    self?.update()
                }
            }] + [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification].map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scheduleUpdate() }
                }
            }
            buttonObservations = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { kind in
                window.standardWindowButton(kind)?.observe(\.isHidden) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.scheduleUpdate() }
                }
            }
        }
        scheduleUpdate()
    }

    /// Coalesces bursts (live resize, three buttons hiding) into one pass after AppKit's toolbar layout.
    func scheduleUpdate() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            scheduled = false
            update()
        }
    }

    /// The traffic lights are present when the zoom button is visible in the toolbar's row.
    var windowButtonsShown: Bool {
        guard let zoom = window?.standardWindowButton(.zoomButton) else { return false }
        return zoom.window != nil && !zoom.isHiddenOrHasHiddenAncestor && zoom.alphaValue > 0.01
    }

    func update() {
        // Measure through any placed item: the breadcrumb itself may be in the » menu after a shrink.
        guard let window, let anchor, let toolbar = window.toolbar,
              let crumb = toolbar.items.first(where: { $0.view.map { anchor.isDescendant(of: $0) } == true })?.view,
              let sample = toolbar.items.compactMap(\.view).first(where: { $0.superview?.superview?.superview != nil }),
              let viewer = sample.superview, let toolbarView = viewer.superview, let bar = toolbarView.superview else { return }
        for item in toolbar.items {
            let priority = item.view === crumb ? NSToolbarItem.VisibilityPriority.user.rawValue
                : Self.overflowPriorities[item.label] ?? NSToolbarItem.VisibilityPriority.user.rawValue
            if item.visibilityPriority.rawValue != priority { item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: priority) }
        }
        let views = toolbar.items.compactMap(\.view).filter { $0.isDescendant(of: toolbarView) && !$0.isHiddenOrHasHiddenAncestor }
        func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: bar) }

        // Leading edge: only move items when the system leaves the empty traffic-light area in place.
        if let natural = views.map({ frame($0).minX }).min().map({ $0 - toolbarView.frame.minX }) {
            let shift = windowButtonsShown ? 0 : min(0, Self.leadingInset - natural)
            let target = NSRect(x: shift, y: toolbarView.frame.minY, width: bar.bounds.width - shift, height: toolbarView.frame.height)
            if toolbarView.frame != target {
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || window.inLiveResize {
                    toolbarView.frame = target
                } else {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.2
                        context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                        toolbarView.animator().frame = target
                    } completionHandler: { [weak self] in
                        MainActor.assumeIsolated { self?.scheduleUpdate() }
                    }
                }
            }
        }

        // The breadcrumb takes whatever the other items leave, so the row ends at the trailing inset. Every item
        // counts, including any already in the » menu, so a too-wide breadcrumb can't hide what measures it.
        guard let start = views.map({ frame($0).minX }).min() else { return }
        let spacing = max(0, viewer.frame.width - sample.frame.width)
        let others = toolbar.items.compactMap(\.view).filter { $0 !== crumb }
        // An item in the » menu keeps its last toolbar frame; its fitting size there is its menu form.
        let othersWidth = others.reduce(CGFloat(0)) { $0 + ($1.frame.width > 0 ? $1.frame.width : $1.fittingSize.width) + spacing }
        // While anything is in the » menu the toolbar keeps room for its chevron, so leave that room until every
        // item is back, then return to the exact width. A little slack keeps rounding from overflowing an item.
        let overflowing = views.count < toolbar.items.compactMap(\.view).count
        let allowance = overflowing && relayoutAttempts < Self.relayoutLimit ? Self.overflowAllowance : 0
        let width = max(Self.minimumBreadcrumbWidth, floor(bar.bounds.width - Self.trailingInset - start - othersWidth) - 2 - allowance)
        let changed = metrics.map { abs($0.breadcrumbWidth - width) > 0.5 } ?? false
        if changed { metrics?.breadcrumbWidth = width }
        if overflowing {
            relayout(toolbar, toolbarView: toolbarView, crumb: crumb)
        } else if changed, relayoutAttempts > 0 {
            // Confirm the row still fits once SwiftUI applies the exact width.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.update() }
        }
    }

    /// NSToolbar doesn't re-measure items already in the » menu, so once the breadcrumb has shrunk to fit,
    /// ask it to lay the row out again (after SwiftUI applies the new width).
    private func relayout(_ toolbar: NSToolbar, toolbarView: NSView, crumb: NSView) {
        guard !relayoutPending, relayoutAttempts < Self.relayoutLimit else { return }
        relayoutPending = true
        relayoutAttempts += 1
        DispatchQueue.main.async { [weak self] in
            self?.relayoutPending = false
            for view in toolbar.items.compactMap(\.view) where view.window == nil {
                view.invalidateIntrinsicContentSize()
                if view === crumb { view.setFrameSize(NSSize(width: view.fittingSize.width, height: view.frame.height)) }
            }
            if let item = toolbar.items.first(where: { $0.view === crumb }) {
                // Re-assigning a priority makes the toolbar re-evaluate which items fit.
                item.visibilityPriority = .high
                item.visibilityPriority = .user
            }
            toolbarView.needsLayout = true
            toolbarView.layoutSubtreeIfNeeded()
            // Bounded: a window narrower than the fixed items legitimately keeps the » menu.
            self?.scheduleUpdate()
        }
    }
}

/// `Library › Vanlife › Settling In` with a quiet count suffix, in one line of the compact bar.
struct ToolbarBreadcrumb: View {
    let workspace: LibraryWorkspace

    var body: some View {
        BreadcrumbRepresentable(workspace: workspace)
            .frame(width: workspace.toolbarMetrics.breadcrumbWidth, height: 22)
    }
}

private struct BreadcrumbRepresentable: NSViewRepresentable {
    let workspace: LibraryWorkspace
    func makeNSView(context: Context) -> BreadcrumbView {
        BreadcrumbView(controller: workspace.toolbarMetrics.controller) { [weak workspace] in workspace?.selectFolder($0) }
    }
    func updateNSView(_ view: BreadcrumbView, context: Context) {
        // Observes navigation and counts only; the path never depends on document text.
        view.update(path: workspace.breadcrumb, count: workspace.subtitle)
    }
}

/// Native buttons, so Full Keyboard Access, VoiceOver and the pointer all reach each crumb.
final class BreadcrumbView: NSView {
    let controller: CompactToolbarController
    let select: (String) -> Void
    private(set) var path = Breadcrumb(crumbs: [], current: "")
    private(set) var count = ""
    private(set) var crumbButtons: [CrumbButton] = []
    private(set) var ellipsis: CrumbButton?
    private var separators: [NSImageView] = []
    let currentLabel = NSTextField(labelWithString: "")
    let countLabel = NSTextField(labelWithString: "")
    private(set) var fit: Breadcrumb.Fit?

    static let crumbFont = NSFont.systemFont(ofSize: 13)
    static let currentFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    /// Hover padding on each side of a crumb; it also spaces the text from the chevrons (6 pt).
    static let padding: CGFloat = 6
    static let separatorWidth: CGFloat = 8
    /// 16 pt from Filter by Tag to the first crumb's text.
    static let leadingGap = Spacing.medium - padding
    static let countGap = Spacing.xSmall

    init(controller: CompactToolbarController, select: @escaping (String) -> Void) {
        self.controller = controller
        self.select = select
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        currentLabel.font = Self.currentFont
        currentLabel.textColor = .labelColor
        currentLabel.lineBreakMode = .byTruncatingMiddle
        countLabel.font = Self.countFont
        countLabel.textColor = .tertiaryLabelColor
        countLabel.setAccessibilityElement(false)
        addSubview(currentLabel)
        addSubview(countLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Path")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { controller.attach(anchor: self) }
    }

    static func textWidth(_ text: String, _ font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    func update(path: Breadcrumb, count: String) {
        guard path != self.path || count != self.count else { return }
        self.path = path
        self.count = count
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
                .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
            image.contentTintColor = .tertiaryLabelColor
            image.setAccessibilityElement(false)
            addSubview(image)
            return image
        }
        currentLabel.stringValue = path.current
        currentLabel.toolTip = path.current
        countLabel.stringValue = count
        setAccessibilityValue(path.accessibilityValue(count: count))
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let ellipsisWidth = Self.textWidth("…", Self.crumbFont) + 2 * Self.padding
        let fit = Breadcrumb.fit(crumbs: path.crumbs.map { Double(Self.textWidth($0.title, Self.crumbFont) + 2 * Self.padding) },
                                 current: Double(Self.textWidth(path.current, Self.currentFont) + 2 * Self.padding),
                                 count: count.isEmpty ? 0 : Double(Self.countGap - Self.padding + Self.textWidth(count, Self.countFont)),
                                 available: Double(bounds.width - Self.leadingGap),
                                 metrics: .init(separator: Double(Self.separatorWidth), ellipsis: Double(ellipsisWidth)))
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
                    let item = NSMenuItem(title: crumb.title, action: crumb.folderPath == nil ? nil : #selector(self.chooseHidden(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = crumb.folderPath
                    item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                    menu.addItem(item)
                }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
            }
        }
        // Crumbs, the current crumb and the count share one text baseline.
        let height = bounds.height
        let baseline = floor((height - Self.crumbFont.ascender + Self.crumbFont.descender) / 2 - Self.crumbFont.descender)
        func place(_ view: NSView, x: CGFloat, width: CGFloat) {
            let size = view.fittingSize
            view.frame = NSRect(x: x, y: baseline + view.firstBaselineOffsetFromTop - size.height, width: max(0, width), height: size.height)
        }
        var x = Self.leadingGap
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
        x += CGFloat(fit.currentWidth)
        countLabel.isHidden = !fit.showsCount
        place(countLabel, x: x + Self.countGap - Self.padding - 2, width: Self.textWidth(count, Self.countFont) + 4)
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
        attributedTitle = NSAttributedString(string: title, attributes: [.font: BreadcrumbView.crumbFont, .foregroundColor: NSColor.secondaryLabelColor])
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
        NSSize(width: BreadcrumbView.textWidth(attributedTitle.string, BreadcrumbView.crumbFont) + 2 * BreadcrumbView.padding, height: Self.height)
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
        let text = NSAttributedString(string: attributedTitle.string,
                                      attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style])
        let lineHeight = ceil(font.ascender - font.descender)
        text.draw(with: NSRect(x: BreadcrumbView.padding, y: (bounds.height - lineHeight) / 2,
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
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

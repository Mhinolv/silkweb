import AppKit
import SwiftUI

struct EditorTabBar: NSViewRepresentable {
    let workspace: LibraryWorkspace
    func makeNSView(context: Context) -> EditorTabBarView { EditorTabBarView(workspace: workspace) }
    func updateNSView(_ view: EditorTabBarView, context: Context) {
        // Register observation of per-tab chrome, without observing document text.
        for tab in workspace.tabs { _ = tab.isPreview; _ = tab.editor.state; _ = tab.editor.url }
        _ = workspace.activeTabID
        view.reload()
    }
}

/// Native accessibility and event tracking; drag frames never publish workspace state.
final class EditorTabBarView: NSView {
    let workspace: LibraryWorkspace
    let scroll = NSScrollView()
    let strip = TabStripView()
    let overflow = NSPopUpButton(frame: .zero, pullsDown: true)
    private(set) var buttons: [EditorTabButton] = []
    private var insertionGap: Int?
    private let indicator = NSView()
    private var shownActiveID: UUID?

    init(workspace: LibraryWorkspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = strip
        addSubview(scroll)
        overflow.isBordered = false
        overflow.setAccessibilityLabel("All document tabs")
        overflow.toolTip = "All document tabs"
        addSubview(overflow)
        indicator.wantsLayer = true
        indicator.layer?.backgroundColor = NSColor.silkwebAccent.cgColor
        indicator.isHidden = true
        strip.addSubview(indicator)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Document tabs")
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        // Tolerates a duplicate tab ID instead of trapping (silkweb-1.79).
        let existing = Dictionary(buttons.map { ($0.tab.id, $0) }, uniquingKeysWith: { first, _ in first })
        for button in buttons { button.removeFromSuperview() }
        buttons = workspace.tabs.map { tab in
            let button = existing[tab.id] ?? EditorTabButton(tab: tab, bar: self)
            strip.addSubview(button)
            button.refresh()
            return button
        }
        setAccessibilityChildren(buttons)
        let menu = NSMenu()
        menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
        for tab in workspace.tabs {
            let item = NSMenuItem(title: tab.editor.name, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = tab.id
            item.state = tab.id == workspace.activeTabID ? .on : .off
            menu.addItem(item)
        }
        overflow.menu = menu
        needsLayout = true
    }

    /// Folder tabs are 28 pt, bottom-aligned under a 4 pt gap, so the active tab opens into the editor.
    static let tabHeight: CGFloat = 28

    override func layout() {
        super.layout()
        let available = max(0, bounds.width - 28)
        scroll.frame = NSRect(x: 0, y: 0, width: available, height: bounds.height)
        overflow.frame = NSRect(x: available, y: 0, width: 28, height: bounds.height)
        let height = min(bounds.height, Self.tabHeight)
        let width = min(220, max(110, available / CGFloat(max(1, buttons.count))))
        strip.frame = NSRect(x: 0, y: 0, width: max(available, width * CGFloat(buttons.count)), height: bounds.height)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: height)
        }
        strip.activeFrame = buttons.first { $0.tab.id == workspace.activeTabID }?.frame
        if shownActiveID != workspace.activeTabID {
            shownActiveID = workspace.activeTabID
            buttons.first { $0.tab.id == shownActiveID }?.scrollToVisible(NSRect(x: 0, y: 0, width: width, height: height))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.silkwebPaneBackground.setFill()
        bounds.fill()
        // The strip draws the hairline under the tabs; this part runs under the overflow control.
        NSColor.silkwebHairline.setFill()
        NSRect(x: overflow.frame.minX, y: 0, width: bounds.width - overflow.frame.minX, height: 1).fill()
    }

    func trackInsertion(at point: NSPoint) {
        guard let first = buttons.first else { return }
        let location = strip.convert(point, from: nil)
        let gap = min(buttons.count, max(0, Int((location.x / max(1, first.frame.width) + 0.5).rounded(.down))))
        insertionGap = gap
        indicator.frame = NSRect(x: min(strip.bounds.width - 2, CGFloat(gap) * first.frame.width), y: 0, width: 2, height: strip.bounds.height)
        // Resolved when shown, so it follows the appearance and the Accent chosen in Settings.
        effectiveAppearance.performAsCurrentDrawingAppearance { indicator.layer?.backgroundColor = NSColor.silkwebAccent.cgColor }
        indicator.isHidden = false
        strip.addSubview(indicator, positioned: .above, relativeTo: nil)
    }
    func finishDrag(_ id: UUID, at point: NSPoint) {
        defer { insertionGap = nil; indicator.isHidden = true }
        guard bounds.contains(convert(point, from: nil)), let gap = insertionGap else { return }
        workspace.reorderTab(id, to: gap)
    }
    @objc private func choose(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? UUID { workspace.activateTab(id) }
    }
}

/// Draws the strip's bottom hairline everywhere except under the active tab.
final class TabStripView: NSView {
    var activeFrame: NSRect? { didSet { if activeFrame != oldValue { needsDisplay = true } } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.silkwebHairline.setFill()
        guard let active = activeFrame else { return NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill() }
        NSRect(x: 0, y: 0, width: max(0, active.minX), height: 1).fill()
        NSRect(x: active.maxX, y: 0, width: max(0, bounds.width - active.maxX), height: 1).fill()
    }
}

final class EditorTabButton: NSView {
    let tab: DocumentTab
    private weak var bar: EditorTabBarView?
    let close = NSButton()
    private let title = NSTextField(labelWithString: "")
    private var hovered = false
    private var tracking: NSTrackingArea?
    private var down: NSPoint?
    private var dragged = false

    init(tab: DocumentTab, bar: EditorTabBarView) {
        self.tab = tab; self.bar = bar
        super.init(frame: .zero)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingMiddle
        title.setAccessibilityElement(false)
        addSubview(title)
        close.isBordered = false
        close.target = self; close.action = #selector(closeTab)
        addSubview(close)
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === title ? self : hit
    }
    var isActive: Bool { bar?.workspace.activeTabID == tab.id }
    /// The coral dot marks unsaved text only; it is state, not a control, so it stays on hover.
    var showsDirtyDot: Bool { tab.editor.state.isDirty }

    func refresh() {
        let active = isActive
        title.stringValue = tab.editor.name
        let font = NSFont.systemFont(ofSize: 12)
        title.font = tab.isPreview ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        title.textColor = active ? .labelColor : .secondaryLabelColor
        close.title = "×"
        // × on hover and on the active tab.
        close.isHidden = !hovered && !active
        close.setAccessibilityLabel("Close \(tab.editor.name)")
        close.toolTip = "Close \(tab.editor.name)"
        toolTip = tab.isPreview ? "Preview — edit or double-click to keep this tab open" : tab.editor.name
        setAccessibilityLabel(tab.editor.name + (tab.editor.state.isDirty ? ", edited" : "") + (tab.isPreview ? ", preview" : ""))
        setAccessibilityValue(active ? 1 : 0)
        setAccessibilityChildren([close])
        needsLayout = true
        needsDisplay = true
    }

    static let dotSize: CGFloat = 6
    static let cornerRadius: CGFloat = 6

    /// The dot sits 6 pt after the title, which gives up 12 pt of its budget while the dot shows.
    var dotRect: NSRect? {
        guard showsDirtyDot else { return nil }
        return NSRect(x: title.frame.maxX + 6, y: (bounds.height - Self.dotSize) / 2, width: Self.dotSize, height: Self.dotSize)
    }

    override func layout() {
        super.layout()
        close.frame = NSRect(x: 6, y: (bounds.height - 16) / 2, width: 16, height: 16)
        let dot: CGFloat = showsDirtyDot ? 12 : 0
        let budget = max(0, bounds.width - 52 - dot)
        let width = min(budget, ceil(title.cell?.cellSize.width ?? budget))
        // Centre the title and its dot together within the slot between the close button and the trailing edge.
        let x = max(26, (bounds.width - width - dot) / 2)
        title.frame = NSRect(x: x, y: (bounds.height - 16) / 2, width: width, height: 16)
    }

    /// Top, left and right edges with rounded top corners; the bottom stays open onto the editor.
    private func outline(_ rect: NSRect) -> NSBezierPath {
        let r = min(Self.cornerRadius, rect.width / 2, rect.height)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY - r))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.maxY - r), radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.maxY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.maxY - r), radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        if isActive {
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            let path = outline(bounds.insetBy(dx: 0.5, dy: 0).offsetBy(dx: 0, dy: -0.5))
            path.lineWidth = 1
            (contrast ? NSColor.labelColor.withAlphaComponent(0.4) : NSColor.silkwebHairline).setStroke()
            path.stroke()
        } else if hovered {
            NSColor.quaternarySystemFill.setFill()
            let fill = outline(bounds)
            fill.close()
            fill.fill()
        }
        if let dotRect {
            NSColor.silkwebCoral.setFill()
            NSBezierPath(ovalIn: dotRect).fill()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    override func mouseDown(with event: NSEvent) {
        guard let bar, !bar.workspace.mutating else { return }
        down = event.locationInWindow; dragged = false
        bar.workspace.activateTab(tab.id)
        if event.clickCount == 2 { bar.workspace.keepTab(tab.id) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let down, hypot(event.locationInWindow.x - down.x, event.locationInWindow.y - down.y) >= 4 else { return }
        dragged = true; bar?.trackInsertion(at: event.locationInWindow)
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { bar?.finishDrag(tab.id, at: event.locationInWindow) }
        down = nil; dragged = false
    }
    override func otherMouseUp(with event: NSEvent) { if event.buttonNumber == 2 { closeTab() } }
    override func accessibilityPerformPress() -> Bool { bar?.workspace.activateTab(tab.id); return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { bar?.workspace.activateTab(tab.id) }
        else { super.keyDown(with: event) }
    }
    @objc private func closeTab() {
        guard let workspace = bar?.workspace else { return }
        Task { await workspace.closeTab(tab.id) }
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let workspace = bar?.workspace else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; menu.addItem(item)
        }
        add("Close Tab", #selector(closeTab))
        add("Close Other Tabs", #selector(closeOthers))
        add("Close Tabs to the Right", #selector(closeRight))
        menu.addItem(.separator())
        if tab.isPreview { add("Keep Open", #selector(keepOpen)) }
        add("Reveal in Library", #selector(revealInLibrary))
        add("Reveal in Finder", #selector(revealInFinder))
        menu.autoenablesItems = false
        for item in menu.items where !item.isSeparatorItem { item.isEnabled = !workspace.mutating }
        return menu
    }
    @objc private func closeOthers() {
        guard let workspace = bar?.workspace else { return }
        Task { await workspace.closeTabs(otherThan: tab.id) }
    }
    @objc private func closeRight() {
        guard let workspace = bar?.workspace else { return }
        Task { await workspace.closeTabs(otherThan: tab.id, toRight: true) }
    }
    @objc private func keepOpen() { bar?.workspace.keepTab(tab.id) }
    @objc private func revealInLibrary() {
        guard let workspace = bar?.workspace else { return }
        workspace.search.text = ""
        workspace.activateTab(tab.id)
    }
    @objc private func revealInFinder() {
        if let url = tab.editor.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

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
    let strip = NSView()
    let overflow = NSPopUpButton(frame: .zero, pullsDown: true)
    private let material = NSVisualEffectView()
    private(set) var buttons: [EditorTabButton] = []
    private var insertionGap: Int?
    private let indicator = NSView()
    private var shownActiveID: UUID?

    init(workspace: LibraryWorkspace) {
        self.workspace = workspace
        super.init(frame: .zero)
        material.material = .headerView
        material.blendingMode = .withinWindow
        material.state = .followsWindowActiveState
        addSubview(material)
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
        indicator.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        indicator.isHidden = true
        strip.addSubview(indicator)
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Document tabs")
        reload()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reload() {
        let existing = Dictionary(uniqueKeysWithValues: buttons.map { ($0.tab.id, $0) })
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

    override func layout() {
        super.layout()
        material.frame = bounds
        let available = max(0, bounds.width - 28)
        scroll.frame = NSRect(x: 0, y: 1, width: available, height: max(0, bounds.height - 1))
        overflow.frame = NSRect(x: available, y: 0, width: 28, height: bounds.height)
        let width = min(220, max(110, available / CGFloat(max(1, buttons.count))))
        strip.frame = NSRect(x: 0, y: 0, width: max(available, width * CGFloat(buttons.count)), height: 27)
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: 27)
        }
        if shownActiveID != workspace.activeTabID {
            shownActiveID = workspace.activeTabID
            buttons.first { $0.tab.id == shownActiveID }?.scrollToVisible(NSRect(x: 0, y: 0, width: width, height: 27))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    func trackInsertion(at point: NSPoint) {
        guard let first = buttons.first else { return }
        let location = strip.convert(point, from: nil)
        let gap = min(buttons.count, max(0, Int((location.x / max(1, first.frame.width) + 0.5).rounded(.down))))
        insertionGap = gap
        indicator.frame = NSRect(x: min(strip.bounds.width - 2, CGFloat(gap) * first.frame.width), y: 0, width: 2, height: 27)
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
    func refresh() {
        let active = bar?.workspace.activeTabID == tab.id
        title.stringValue = tab.editor.name
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        title.font = tab.isPreview ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) : font
        title.textColor = active ? .labelColor : .secondaryLabelColor
        close.title = tab.editor.state.isDirty && !hovered ? "•" : "×"
        close.isHidden = !active && !hovered && !tab.editor.state.isDirty
        close.setAccessibilityLabel("Close \(tab.editor.name)")
        close.toolTip = "Close \(tab.editor.name)"
        toolTip = tab.isPreview ? "Preview — edit or double-click to keep this tab open" : tab.editor.name
        setAccessibilityLabel(tab.editor.name + (tab.editor.state.isDirty ? ", edited" : "") + (tab.isPreview ? ", preview" : ""))
        setAccessibilityValue(active ? 1 : 0)
        setAccessibilityChildren([close])
        needsDisplay = true
    }
    override func layout() {
        super.layout()
        close.frame = NSRect(x: 6, y: 5, width: 16, height: 16)
        title.frame = NSRect(x: 26, y: 5, width: max(0, bounds.width - 52), height: 18)
    }
    override func draw(_ dirtyRect: NSRect) {
        if bar?.workspace.activeTabID == tab.id {
            NSColor.controlBackgroundColor.setFill(); bounds.fill()
        } else if hovered { NSColor.quaternaryLabelColor.setFill(); bounds.fill() }
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

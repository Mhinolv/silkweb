import AppKit
import SilkwebCore
import SwiftUI

/// The library window's sidebar (#195, Finder-style): each open Library is a section, a group-row header with its
/// folder name, and under it the rows a lone Library shows (All Documents, Agent Activity, the root and its
/// folders, Tags). One outline holds every section; each Library's rows come from its own
/// `FolderSidebar.Coordinator`.
struct LibrarySectionsSidebar: NSViewRepresentable {
    let registry: LibraryWindowRegistry
    let current: LibraryWorkspace

    func makeCoordinator() -> SidebarSections { SidebarSections(registry: registry) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.makeScrollView() }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(view, sections: registry.sections, current: current)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: SidebarSections) {
        for header in coordinator.headers { header.coordinator?.finishDrag(accepted: false) }
    }
}

@MainActor final class SidebarSections: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// A Library section's header row.
    @MainActor final class Header: NSObject {
        let workspace: LibraryWorkspace
        var title: String
        /// Built once the Library has loaded; a loading section shows only its header.
        var coordinator: FolderSidebar.Coordinator?
        init(workspace: LibraryWorkspace) {
            self.workspace = workspace
            title = workspace.root?.lastPathComponent ?? ""
        }
    }

    static let headerSpacing: CGFloat = 12

    let registry: LibraryWindowRegistry
    private(set) var headers: [Header] = []
    /// The current Library: its section holds the outline's selection.
    private(set) weak var current: LibraryWorkspace?
    weak var outline: SidebarOutlineView?
    private weak var scroll: NSScrollView?
    private var restoringDepth = 0
    private var revealRequests: [ObjectIdentifier: Int] = [:]

    init(registry: LibraryWindowRegistry) {
        self.registry = registry
    }

    /// Selection changes made by reloads and restores never navigate.
    var restoring: Bool { restoringDepth > 0 || headers.contains { $0.coordinator?.restoring == true } }

    private var currentCoordinator: FolderSidebar.Coordinator? {
        headers.first { $0.workspace === current }?.coordinator
    }

    private func owner(ofRow row: Int) -> FolderSidebar.Coordinator? {
        (outline?.item(atRow: row) as? FolderSidebar.Item)?.owner
    }

    private var selectedOwner: FolderSidebar.Coordinator? { outline.flatMap { owner(ofRow: $0.selectedRow) } }

    func makeScrollView() -> NSScrollView {
        // A source list doesn't indent rows under group rows: every Library's rows sit where a lone Library's do.
        let (scroll, outline) = FolderSidebar.makeOutline()
        outline.floatsGroupRows = false
        outline.delegate = self
        outline.dataSource = self
        outline.renameSelected = { [weak self] in self?.selectedOwner?.renameSelection() }
        outline.toggleDisclosure = { [weak self] row in self?.owner(ofRow: row)?.toggleDisclosure(at: row) ?? false }
        outline.toggleGroup = { [weak self] in self?.selectedOwner?.toggleSelectedGroup() ?? false }
        outline.tagArrow = { [weak self] key in self?.selectedOwner?.navigateTags(key) ?? false }
        outline.didFocus = { [weak self] in
            guard let current = self?.current else { return }
            current.focusColumn = 0
            current.libraryFocusChanged()
        }
        outline.didResign = { [weak self] in self?.current?.libraryFocusChanged() }
        outline.contextMenu = { [weak self] event in self?.menu(event) }
        outline.moveFocus = { [weak self] backwards in self?.current?.focus(backwards ? 2 : 1) }
        outline.expandHovered = { [weak self] in
            guard let hovered = self?.headers.compactMap(\.coordinator).first(where: { $0.hovered != nil }) else {
                return false
            }
            hovered.expandHover()
            return true
        }
        outline.dragEnded = { [weak self] in
            for header in self?.headers ?? [] { header.coordinator?.finishDrag(accepted: false) }
        }
        outline.setAccessibilityLabel("Libraries")
        self.outline = outline
        self.scroll = scroll
        return scroll
    }

    // MARK: Updates

    func update(_ view: NSScrollView, sections: [LibraryWorkspace], current: LibraryWorkspace) {
        guard let outline else { return }
        let currentChanged = self.current !== current
        self.current = current
        var rebuilt = false
        if sections.map(ObjectIdentifier.init) != headers.map({ ObjectIdentifier($0.workspace) }) {
            let existing = Dictionary(uniqueKeysWithValues: headers.map { (ObjectIdentifier($0.workspace), $0) })
            headers = sections.map { existing[ObjectIdentifier($0)] ?? Header(workspace: $0) }
            rebuilt = true
        }
        for header in headers {
            let title = header.workspace.root?.lastPathComponent ?? ""
            if header.title != title {
                header.title = title
                rebuilt = true
            }
            // A replaced Library (Settings ▸ Choose Library…) builds a new tree once it has loaded.
            if let coordinator = header.coordinator, header.workspace.snapshot == nil {
                coordinator.finishDrag(accepted: false)
                header.coordinator = nil
                rebuilt = true
            } else if header.coordinator == nil, let snapshot = header.workspace.snapshot {
                let coordinator = FolderSidebar.Coordinator(workspace: header.workspace, snapshot: snapshot)
                coordinator.sections = self
                coordinator.header = header
                coordinator.outline = outline
                coordinator.revision = header.workspace.revision
                header.coordinator = coordinator
                rebuilt = true
            }
        }
        restoringDepth += 1
        if rebuilt {
            outline.reloadData()
            for header in headers {
                if !header.workspace.sectionCollapsed { outline.expandItem(header) }
                header.coordinator?.restore()
            }
        } else {
            for header in headers {
                syncCollapse(header)
                guard let coordinator = header.coordinator, let snapshot = header.workspace.snapshot else { continue }
                FolderSidebar.update(
                    view, coordinator: coordinator, snapshot: snapshot, isCurrent: header.workspace === current)
            }
        }
        restoringDepth -= 1
        if rebuilt || currentChanged { applyCurrent() }
        let id = ObjectIdentifier(current)
        if revealRequests[id] != current.sectionRevealRequest {
            revealRequests[id] = current.sectionRevealRequest
            reveal()
        }
    }

    /// Reloads one Library's rows; the other sections keep theirs.
    func reload(_ header: Header) {
        guard let outline else { return }
        restoringDepth += 1
        outline.reloadItem(header, reloadChildren: true)
        if !header.workspace.sectionCollapsed { outline.expandItem(header) }
        restoringDepth -= 1
    }

    /// Another section's reload can move the outline's rows; the current Library's scope stays selected.
    func didRestore(_ coordinator: FolderSidebar.Coordinator) {
        guard coordinator.workspace !== current else { return }
        restoringDepth += 1
        currentCoordinator?.selectScope()
        restoringDepth -= 1
    }

    private func syncCollapse(_ header: Header) {
        guard let outline else { return }
        let collapsed = header.workspace.sectionCollapsed
        guard outline.isItemExpanded(header) == collapsed else { return }
        restoringDepth += 1
        if collapsed {
            outline.collapseItem(header)
        } else {
            outline.expandItem(header)
            header.coordinator?.applyExpansion()
            if header.workspace === current { currentCoordinator?.selectScope() }
        }
        restoringDepth -= 1
    }

    /// The current Library's header is in `labelColor` and its sidebar takes focus commands.
    private func applyCurrentHeaders() {
        guard let outline else { return }
        for header in headers {
            header.workspace.sidebarOutline = header.workspace === current ? outline : nil
            let row = outline.row(forItem: header)
            if row >= 0, let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SectionHeaderCell {
                configure(cell, header: header)
            }
        }
    }

    /// … and its scope is selected.
    private func applyCurrent() {
        guard let outline else { return }
        applyCurrentHeaders()
        restoringDepth += 1
        if let coordinator = currentCoordinator {
            coordinator.selectScope()
            coordinator.updateCurrentScope()
        } else {
            outline.deselectAll(nil)
        }
        restoringDepth -= 1
    }

    /// Focusing an open Library: its section expands, its remembered scope is selected and scrolled into view.
    private func reveal() {
        guard let outline, let header = headers.first(where: { $0.workspace === current }) else { return }
        restoringDepth += 1
        syncCollapse(header)
        currentCoordinator?.selectScope()
        restoringDepth -= 1
        let headerRow = outline.row(forItem: header)
        if headerRow >= 0 { outline.scrollRowToVisible(headerRow) }
        if outline.selectedRow >= 0 { outline.scrollRowToVisible(outline.selectedRow) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch item {
        case nil: headers.count
        case let header as Header: header.coordinator?.roots.count ?? 0
        case let item as FolderSidebar.Item: item.children.count
        default: 0
        }
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch item {
        case let header as Header: header.coordinator!.roots[index]
        case let item as FolderSidebar.Item: item.children[index]
        default: headers[index]
        }
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if item is Header { return true }
        return (item as? FolderSidebar.Item)?.owner?.outlineView(outlineView, isItemExpandable: item) ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?)
        -> Any?
    {
        (item as? Header)?.title ?? (item as? FolderSidebar.Item)?.title
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        (item as? FolderSidebar.Item)?.owner?.outlineView(outlineView, pasteboardWriterForItem: item)
    }

    func outlineView(
        _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
        proposedChildIndex index: Int
    ) -> NSDragOperation {
        let owner = (item as? FolderSidebar.Item)?.owner
        // Cross-Library moves are a follow-up (#193): another Library's folders refuse the drop.
        for header in headers where header.coordinator !== owner { header.coordinator?.setHover(nil) }
        return owner?.outlineView(outlineView, validateDrop: info, proposedItem: item, proposedChildIndex: index) ?? []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int)
        -> Bool
    {
        (item as? FolderSidebar.Item)?.owner?.outlineView(
            outlineView, acceptDrop: info, item: item, childIndex: childIndex) ?? false
    }

    // MARK: Delegate

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { item is Header }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { !(item is Header) }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let header = item as? Header, header !== headers.first else { return Spacing.sidebarRowHeight }
        return Spacing.sidebarRowHeight + Self.headerSpacing
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        item is Header ? SectionHeaderRowView() : ThreadRowView()
    }

    func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
        owner(ofRow: row)?.outlineView(outlineView, didAdd: rowView, forRow: row)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let header = item as? Header else {
            return (item as? FolderSidebar.Item)?.owner?.outlineView(outlineView, viewFor: tableColumn, item: item)
        }
        let identifier = NSUserInterfaceItemIdentifier("sectionHeader")
        let cell =
            outlineView.makeView(withIdentifier: identifier, owner: self) as? SectionHeaderCell
            ?? SectionHeaderCell(identifier: identifier)
        configure(cell, header: header)
        return cell
    }

    private func configure(_ cell: SectionHeaderCell, header: Header) {
        let isCurrent = header.workspace === current
        cell.textField?.stringValue = header.title
        cell.textField?.textColor = isCurrent ? .labelColor : .secondaryLabelColor
        cell.setAccessibilityLabel("\(header.title) library")
        cell.setAccessibilityValue(isCurrent ? "current" : nil)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !restoring, let owner = selectedOwner else { return }
        if owner.workspace !== current {
            // A row in another section: that Library becomes current, then the row's scope is shown as usual.
            registry.focus(owner.workspace)
            current = owner.workspace
            applyCurrentHeaders()
        }
        owner.outlineViewSelectionDidChange(notification)
    }

    func outlineViewItemDidExpand(_ notification: Notification) { expansion(notification, expanded: true) }
    func outlineViewItemDidCollapse(_ notification: Notification) { expansion(notification, expanded: false) }

    private func expansion(_ notification: Notification, expanded: Bool) {
        let item = notification.userInfo?["NSObject"]
        if let header = item as? Header {
            guard !restoring else { return }
            // The Show/Hide chevron: a collapsed section keeps its selection and its Library stays open.
            header.workspace.sectionCollapsed = !expanded
            guard expanded else { return }
            // After AppKit has inserted the section's rows: inside this notification they can't be selected yet.
            DispatchQueue.main.async { [weak self] in
                guard let self, header.workspace.sectionCollapsed == false else { return }
                restoringDepth += 1
                header.coordinator?.applyExpansion()
                if header.workspace === current { currentCoordinator?.selectScope() }
                restoringDepth -= 1
            }
            return
        }
        guard let owner = (item as? FolderSidebar.Item)?.owner else { return }
        if expanded {
            owner.outlineViewItemDidExpand(notification)
        } else {
            owner.outlineViewItemDidCollapse(notification)
        }
    }

    // MARK: Header menu

    private func menu(_ event: NSEvent) -> NSMenu? {
        guard let outline else { return nil }
        let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
        guard let header = outline.item(atRow: row) as? Header else { return owner(ofRow: row)?.menu(event) }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let reveal = menu.addItem(
            withTitle: "Reveal in Finder", action: #selector(revealLibrary(_:)), keyEquivalent: "")
        reveal.target = self
        reveal.representedObject = header.workspace
        menu.addItem(.separator())
        let close = menu.addItem(withTitle: "Close Library", action: #selector(closeLibrary(_:)), keyEquivalent: "")
        close.target = self
        close.representedObject = header.workspace
        return menu
    }

    @objc private func revealLibrary(_ sender: NSMenuItem) {
        if let root = (sender.representedObject as? LibraryWorkspace)?.root {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        }
    }

    @objc private func closeLibrary(_ sender: NSMenuItem) {
        guard let workspace = sender.representedObject as? LibraryWorkspace else { return }
        Task { await registry.closeLibrary(workspace) }
    }
}

/// A Library section's header: the folder name, 11 pt semibold, under 12 pt of space (none above the first).
final class SectionHeaderCell: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 11, weight: .semibold)
        text.lineBreakMode = .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setAccessibilityElement(false)
        addSubview(text)
        textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            text.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.sidebarRowHeight / 2),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// No capsule and no thread guide on a section header.
final class SectionHeaderRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
}

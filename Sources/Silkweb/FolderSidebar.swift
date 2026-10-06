import AppKit
import SilkwebCore
import SwiftUI
import UniformTypeIdentifiers

struct FolderSidebar: NSViewRepresentable {
    let snapshot: LibrarySnapshot
    let workspace: LibraryWorkspace

    final class Item: NSObject {
        let folder: LibraryFolder?
        let title: String
        var tag: LibraryTag?
        var isTagsGroup = false
        var children: [Item] = [] { didSet { for child in children { child.parent = self } } }
        /// Thread guides walk up through parents (silkweb-1.63).
        weak var parent: Item?
        init(folder: LibraryFolder?, title: String) { self.folder = folder; self.title = title }
    }

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace, snapshot: snapshot) }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator)
    }

    static func makeScrollView(coordinator: Coordinator) -> NSScrollView {
        let workspace = coordinator.workspace
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        // With legacy scroll bars (a mouse attached) a short folder list shows no empty track (1.81).
        scroll.autohidesScrollers = true
        // Paint over the sidebar item's wallpaper-tinted material (1.56).
        scroll.drawsBackground = true
        scroll.backgroundColor = .silkwebPaneBackground
        let outline = SidebarOutlineView()
        outline.renameSelected = { [weak coordinator] in coordinator?.renameSelection() }
        outline.toggleDisclosure = { [weak coordinator] row in coordinator?.toggleDisclosure(at: row) ?? false }
        outline.toggleGroup = { [weak coordinator] in coordinator?.toggleSelectedGroup() ?? false }
        outline.tagArrow = { [weak coordinator] key in coordinator?.navigateTags(key) ?? false }
        outline.didFocus = { workspace.focusColumn = 0 }
        outline.contextMenu = { [weak coordinator = coordinator] event in coordinator?.menu(event) }
        outline.moveFocus = { backwards in workspace.focus(backwards ? 2 : 1) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folders"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .silkwebPaneBackground
        outline.rowHeight = Spacing.sidebarRowHeight
        outline.indentationPerLevel = ThreadRowView.indentation
        outline.delegate = coordinator
        outline.dataSource = coordinator
        outline.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.silkwebMove.identifier)])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)
        outline.expandHovered = { [weak coordinator] in
            guard coordinator?.hovered != nil else { return false }
            coordinator?.expandHover(); return true
        }
        outline.dragEnded = { [weak coordinator] in coordinator?.finishDrag(accepted: false) }
        outline.allowsEmptySelection = true
        outline.autosaveExpandedItems = false
        outline.setAccessibilityLabel("Folders")
        scroll.documentView = outline
        coordinator.outline = outline
        coordinator.restore()
        return scroll
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.finishDrag(accepted: false)
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        Self.update(view, coordinator: context.coordinator, snapshot: snapshot)
    }

    static func update(_ view: NSScrollView, coordinator: Coordinator, snapshot: LibrarySnapshot) {
        let workspace = coordinator.workspace
        if coordinator.rootURL != snapshot.rootURL || coordinator.revision != workspace.revision {
            coordinator.revision = workspace.revision
            if coordinator.configure(snapshot) { coordinator.restore() } else { coordinator.updateVisibleCounts() }
        }
        if coordinator.selectedTagID != workspace.session.selectedTagID
            || coordinator.tagsExpanded != workspace.tagsExpanded
        {
            coordinator.restore()
        }
        if coordinator.tagRenameID != workspace.tagRenameID {
            coordinator.tagRenameID = workspace.tagRenameID
            coordinator.restore()
        }
        if coordinator.rename != workspace.rename {
            coordinator.rename = workspace.rename
            coordinator.restore()
        }
        // Scope changes made outside the sidebar (the toolbar breadcrumb, 1.65) move the selected row too.
        if coordinator.selectedFolder != .some(workspace.session.selectedFolder) {
            coordinator.selectScope()
        }
        coordinator.updateCurrentScope()
        if coordinator.lastFocusRequest != workspace.focusRequest {
            coordinator.lastFocusRequest = workspace.focusRequest
            if workspace.focusColumn == 0, workspace.rename == nil {
                view.window?.makeFirstResponder(coordinator.outline)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let workspace: LibraryWorkspace
        var roots: [Item] = []
        var itemsByPath: [String: Item] = [:]
        var rootURL: URL?
        var tagsGroup: Item?
        var itemsByTag: [UUID: Item] = [:]
        var tagsExpanded = true
        var selectedTagID: UUID?
        var tagRenameID: UUID?
        private var tags: [LibraryTag] = []
        private var tagCounts: [UUID: Int] = [:]
        private var folders: [LibraryFolder] = []
        private var counts: [UUID: FolderDocumentCount] = [:]
        private var totalCount = 0
        weak var outline: NSOutlineView?
        var restoring = false
        /// The folder scope the selected row last followed.
        var selectedFolder: String??
        var lastFocusRequest = 0
        var revision = 0
        var rename: LibraryRename?
        var hovered: Item?
        var springTask: Task<Void, Never>?
        var springExpanded: [Item] = []
        /// The scope the list shows; its row's accessibility value says “current folder”.
        private(set) var currentItem: Item?
        private var hoverMonitor: Any?
        private var dragCache: (name: NSPasteboard.Name, count: Int, revision: Int, library: UUID, paths: [String]?)?

        private let readDragData: (NSPasteboard) -> Data?

        init(
            workspace: LibraryWorkspace, snapshot: LibrarySnapshot,
            readDragData: @escaping (NSPasteboard) -> Data? = {
                $0.data(forType: NSPasteboard.PasteboardType(UTType.silkwebMove.identifier))
            }
        ) {
            self.readDragData = readDragData
            self.workspace = workspace
            super.init()
            configure(snapshot)
        }

        @discardableResult
        func configure(_ snapshot: LibrarySnapshot) -> Bool {
            counts = snapshot.presentation.counts
            totalCount = snapshot.documents.count
            tagCounts = workspace.tagCounts
            guard rootURL != snapshot.rootURL || folders != snapshot.folders || tags != workspace.tags else {
                return false
            }
            tags = workspace.tags
            rootURL = snapshot.rootURL
            folders = snapshot.folders
            itemsByPath = [:]
            let all = Item(folder: nil, title: "All Documents")
            roots = [all]
            var byID: [UUID: Item] = [:]
            for folder in snapshot.folders {
                let item = Item(folder: folder, title: folder.name)
                byID[folder.id] = item
                itemsByPath[folder.relativePath] = item
            }
            for folder in snapshot.folders {
                guard let item = byID[folder.id] else { continue }
                item.children = (snapshot.presentation.children[folder.id] ?? []).compactMap { byID[$0.id] }
                if folder.parentID == nil { roots.append(item) }
            }
            itemsByTag = [:]
            tagsGroup = nil
            do {
                let group = Item(folder: nil, title: "Tags")
                group.isTagsGroup = true
                group.children = tags.map { tag in
                    let item = Item(folder: nil, title: tag.name)
                    item.tag = tag
                    itemsByTag[tag.id] = item
                    return item
                }
                tagsGroup = group
                roots.append(group)
            }
            return true
        }

        func updateVisibleCounts() {
            guard let outline else { return }
            for row in 0..<outline.numberOfRows {
                if let item = outline.item(atRow: row) as? Item,
                    let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarFolderCell
                {
                    applyCount(to: cell, item: item)
                }
            }
        }
        private func applyCount(to cell: SidebarFolderCell, item: Item) {
            if item.isTagsGroup || item.tag != nil {
                let count = item.tag.map { tagCounts[$0.id] ?? 0 } ?? tags.count
                cell.countBadge.stringValue = FolderDocumentCount(direct: count, recursive: count).inlineSuffix
                cell.setAccessibilityValue("\(count) \(item.isTagsGroup ? "tags" : "documents")" + currentSuffix(item))
                cell.toolTip = nil
                return
            }
            let count =
                item.folder.flatMap { counts[$0.id] } ?? FolderDocumentCount(direct: totalCount, recursive: totalCount)
            cell.countBadge.stringValue = count.inlineSuffix
            cell.setAccessibilityValue(count.accessibilityValue + currentSuffix(item))
            cell.toolTip =
                item.folder?.isUnreadable == true ? "You don't have permission to view this folder." : count.tooltip
        }

        private func currentSuffix(_ item: Item) -> String { item === currentItem ? ", current folder" : "" }

        /// The list's scope: a selected tag, else the selected folder, else All Documents.
        func scopeItem() -> Item? {
            workspace.session.selectedTagID.flatMap { itemsByTag[$0] }
                ?? (workspace.session.selectedFolder.flatMap { itemsByPath[$0] } ?? roots.first)
        }

        /// Moves the “current folder” suffix by updating only the old and new rows' cells. The selection capsule
        /// is the only visual mark (owner decision, 1.65: no coral node).
        func updateCurrentScope() {
            let next = scopeItem()
            guard next !== currentItem else { return }
            let previous = currentItem
            currentItem = next
            guard let outline else { return }
            for item in [previous, next].compactMap({ $0 }) {
                let row = outline.row(forItem: item)
                guard row >= 0 else { continue }
                if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarFolderCell {
                    applyCount(to: cell, item: item)
                }
            }
        }

        /// O(depth): the row's level and which guides pass through it.
        func thread(for item: Item) -> ThreadRowView.Thread {
            var chain = [item]
            while let parent = chain.last?.parent { chain.append(parent) }
            chain.reverse()
            func isLast(_ item: Item) -> Bool { (item.parent?.children ?? roots).last === item }
            return ThreadRowView.Thread(
                level: chain.count - 1, isLastChild: isLast(item),
                ancestorContinues: chain.dropFirst().dropLast().map { !isLast($0) },
                hasChildren: item.isTagsGroup || !item.children.isEmpty)
        }

        func restore() {
            guard let outline else { return }
            restoring = true
            outline.reloadData()
            for path in workspace.session.expandedFolders.sorted(by: { $0.count < $1.count }) {
                if let item = itemsByPath[path] { outline.expandItem(item) }
            }
            selectedTagID = workspace.session.selectedTagID
            if let group = tagsGroup {
                if workspace.session.selectedTagID != nil { workspace.tagsExpanded = true }
                if workspace.tagsExpanded { outline.expandItem(group) }
            }
            tagsExpanded = workspace.tagsExpanded
            let item = scopeItem()
            if let item { select(item) }
            if item == nil { outline.deselectAll(nil) }
            selectedFolder = .some(workspace.session.selectedFolder)
            restoring = false
            updateCurrentScope()
        }

        /// Selects the scope's row without reloading; a no-op when it is already selected.
        func selectScope() {
            selectedFolder = .some(workspace.session.selectedFolder)
            guard let outline, let item = scopeItem(), outline.item(atRow: outline.selectedRow) as? Item !== item else {
                return
            }
            restoring = true
            select(item)
            restoring = false
        }

        private func select(_ item: Item) {
            guard let outline else { return }
            var parent = outline.parent(forItem: item)
            while let ancestor = parent {
                outline.expandItem(ancestor)
                parent = outline.parent(forItem: ancestor)
            }
            let row = outline.row(forItem: item)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false);
                outline.scrollRowToVisible(row)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? Item)?.children ?? roots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            (item as? Item)?.isTagsGroup == true || !((item as? Item)?.children.isEmpty ?? true)
        }
        func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?)
            -> Any?
        {
            (item as? Item)?.title
        }
        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            ThreadRowView()
        }
        /// Guides are set per added row only: expand/collapse never redraws the rest of the tree.
        func outlineView(_ outlineView: NSOutlineView, didAdd rowView: NSTableRowView, forRow row: Int) {
            guard let rowView = rowView as? ThreadRowView, let item = outlineView.item(atRow: row) as? Item else {
                return
            }
            rowView.thread = thread(for: item)
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("folderCell")
            let cell =
                outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarFolderCell
                ?? SidebarFolderCell()
            if cell.textField == nil {
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingTail
                text.font = .systemFont(ofSize: 13)
                text.setContentHuggingPriority(NSLayoutConstraint.Priority(251), for: .horizontal)
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                let image = NSImageView()
                let count = cell.countBadge
                count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
                count.textColor = .secondaryLabelColor
                count.setContentCompressionResistancePriority(.required, for: .horizontal)
                count.translatesAutoresizingMaskIntoConstraints = false
                count.setAccessibilityElement(false)
                let badge = cell.lockBadge
                badge.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
                badge.contentTintColor = .secondaryLabelColor
                badge.setAccessibilityElement(false)
                text.translatesAutoresizingMaskIntoConstraints = false
                image.translatesAutoresizingMaskIntoConstraints = false
                badge.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.addSubview(text)
                cell.addSubview(badge)
                cell.addSubview(count)
                cell.textField = text
                cell.imageView = image
                cell.titleToLock = text.trailingAnchor.constraint(equalTo: badge.leadingAnchor)
                cell.lockToCount = badge.trailingAnchor.constraint(equalTo: count.leadingAnchor)
                cell.lockWidth = badge.widthAnchor.constraint(equalToConstant: 0)
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    cell.titleToLock!,
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    cell.lockToCount!,
                    count.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                    count.firstBaselineAnchor.constraint(equalTo: text.firstBaselineAnchor),
                    badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    cell.lockWidth!, badge.heightAnchor.constraint(equalToConstant: 12),
                ])
            }
            cell.renameField?.removeFromSuperview()
            cell.renameField = nil
            cell.textField?.isHidden = false
            if let rename = workspace.rename, rename.isFolder, rename.path == item.folder?.relativePath {
                let field = RenameNameField(name: rename.name)
                field.validate = { [weak workspace] in await workspace?.validateRename(rename, value: $0) }
                field.finish = { [weak workspace] in workspace?.finishRename(rename, value: $0) }
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                if let text = cell.textField {
                    text.isHidden = true
                    NSLayoutConstraint.activate([
                        field.leadingAnchor.constraint(equalTo: text.leadingAnchor),
                        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        field.heightAnchor.constraint(equalToConstant: 22),
                    ])
                }
                cell.renameField = field
            }
            if let tag = item.tag, workspace.tagRenameID == tag.id {
                let field = RenameNameField(name: workspace.tagRenameName)
                field.validate = { TagEditor.normalize($0) == nil ? "Use 1–64 characters without commas." : nil }
                field.finish = { [weak workspace] value in
                    if let value { workspace?.renameTag(tag, to: value) }
                    workspace?.tagRenameID = nil
                }
                field.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(field)
                if let text = cell.textField {
                    text.isHidden = true
                    NSLayoutConstraint.activate([
                        field.leadingAnchor.constraint(equalTo: text.leadingAnchor),
                        field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                        field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                        field.heightAnchor.constraint(equalToConstant: 22),
                    ])
                }
                cell.renameField = field
            }
            cell.textField?.stringValue = item.title
            let symbol =
                item.tag != nil || item.isTagsGroup
                ? "tag" : item.folder.map { $0.parentID == nil ? "books.vertical" : "folder" } ?? "doc.on.doc"
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.configureCluster(unreadable: item.folder?.isUnreadable == true, renaming: cell.renameField != nil)
            let label = item.folder.map { "\(item.title), \($0.parentID == nil ? "library" : "folder")" } ?? item.title
            cell.setAccessibilityElement(true)
            cell.setAccessibilityLabel(
                item.folder?.isUnreadable == true ? "\(label), unreadable, permission denied" : label)
            if item.isTagsGroup { cell.setAccessibilityLabel("Tags") }
            if let tag = item.tag {
                cell.setAccessibilityLabel("\(tag.name), tag, \(tagCounts[tag.id] ?? 0) documents")
            }
            applyCount(to: cell, item: item)
            return cell
        }
        func menu(_ event: NSEvent) -> NSMenu? {
            guard let outline else { return nil }
            let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
            guard let item = outline.item(atRow: row) as? Item else { return nil }
            if let tag = item.tag { return tagMenu(tag) }
            guard let folder = item.folder else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (title, action) in [
                ("New Document", #selector(newDocument(_:))), ("New Folder", #selector(newFolder(_:))),
            ] {
                let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                entry.target = self; entry.representedObject = folder.relativePath;
                entry.isEnabled = workspace.canMutate
            }
            menu.addItem(.separator())
            let rename = menu.addItem(withTitle: "Rename…", action: #selector(renameFolder(_:)), keyEquivalent: "")
            rename.target = self; rename.representedObject = folder.relativePath
            rename.isEnabled = workspace.canMutate && !folder.relativePath.isEmpty
            let move = menu.addItem(withTitle: "Move To…", action: #selector(moveFolder(_:)), keyEquivalent: "")
            move.target = self; move.representedObject = folder.relativePath
            move.isEnabled = workspace.canMutate && !folder.relativePath.isEmpty
            let reveal = menu.addItem(
                withTitle: "Reveal in Finder", action: #selector(revealFolder(_:)), keyEquivalent: "")
            reveal.target = self; reveal.representedObject = folder.relativePath
            menu.addItem(.separator())
            let trash = menu.addItem(withTitle: "Move to Trash", action: #selector(trashFolder(_:)), keyEquivalent: "")
            trash.target = self; trash.representedObject = folder.relativePath
            trash.isEnabled = workspace.canMutate && !folder.relativePath.isEmpty
            return menu
        }
        func tagMenu(_ tag: LibraryTag) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (title, action) in [
                ("Rename Tag…", #selector(renameTag(_:))), ("Delete Tag…", #selector(deleteTag(_:))),
            ] {
                let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                entry.target = self; entry.representedObject = tag; entry.isEnabled = workspace.canMutate
            }
            return menu
        }
        @objc private func renameTag(_ sender: NSMenuItem) {
            guard let tag = sender.representedObject as? LibraryTag else { return }
            workspace.tagRenameName = tag.name; workspace.tagRenameID = tag.id
        }
        @objc private func deleteTag(_ sender: NSMenuItem) {
            if let tag = sender.representedObject as? LibraryTag { workspace.deleteTag(tag) }
        }
        func renameSelection() {
            guard let outline, let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
            workspace.focusColumn = 0
            if let tag = item.tag {
                guard workspace.canMutate else { return }
                workspace.tagRenameName = tag.name; workspace.tagRenameID = tag.id
            } else if !item.isTagsGroup {
                workspace.beginRename()
            }
        }
        private func setGroupExpanded(_ expanded: Bool) {
            guard let outline, let group = tagsGroup else { return }
            let target =
                restoring || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? outline : outline.animator()
            if expanded { target.expandItem(group) } else { target.collapseItem(group) }
        }
        func toggleDisclosure(at row: Int) -> Bool {
            guard let outline, let group = tagsGroup, outline.item(atRow: row) as? Item === group else { return false }
            setGroupExpanded(!outline.isItemExpanded(group))
            return true
        }
        func toggleSelectedGroup() -> Bool {
            guard let outline, let group = tagsGroup, outline.item(atRow: outline.selectedRow) as? Item === group else {
                return false
            }
            setGroupExpanded(!outline.isItemExpanded(group))
            return true
        }
        func navigateTags(_ key: UInt16) -> Bool {
            guard let outline, let item = outline.item(atRow: outline.selectedRow) as? Item, let group = tagsGroup
            else { return false }
            if item.isTagsGroup {
                if key == 123 {
                    setGroupExpanded(false)
                } else if !outline.isItemExpanded(group) {
                    setGroupExpanded(true)
                } else {
                    return false
                }
                return true
            }
            if key == 123, item.tag != nil {
                outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: group)), byExtendingSelection: false)
                return true
            }
            return false
        }

        @objc private func newDocument(_ sender: NSMenuItem) {
            workspace.create(folder: false, parent: sender.representedObject as? String)
        }
        @objc private func newFolder(_ sender: NSMenuItem) {
            workspace.create(folder: true, parent: sender.representedObject as? String)
        }
        @objc private func renameFolder(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            workspace.beginRename(LibraryRename(path: path, isFolder: true))
        }
        @objc private func moveFolder(_ sender: NSMenuItem) {
            if let path = sender.representedObject as? String { workspace.requestMove([path]) }
        }
        @objc private func trashFolder(_ sender: NSMenuItem) {
            if let path = sender.representedObject as? String { workspace.requestTrash([path], pane: 0) }
        }
        @objc private func revealFolder(_ sender: NSMenuItem) { workspace.reveal(sender.representedObject as? String) }

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
            guard workspace.canMutate, let path = (item as? Item)?.folder?.relativePath, !path.isEmpty,
                let id = workspace.snapshot?.metadata.IDsByPath[path]
            else { return nil }
            let writer = NSPasteboardItem()
            writer.setData(
                try! JSONEncoder().encode(InternalMove(library: workspace.dragIdentity, ids: [id])),
                forType: NSPasteboard.PasteboardType(UTType.silkwebMove.identifier))
            return writer
        }
        func dragPaths(_ pasteboard: NSPasteboard) -> [String]? {
            let count = pasteboard.changeCount
            if let cached = dragCache, cached.name == pasteboard.name, cached.count == count,
                cached.revision == workspace.revision, cached.library == workspace.dragIdentity
            {
                return cached.paths
            }
            let paths = readDragData(pasteboard).flatMap { workspace.pathsForDrag($0) }
            dragCache = (pasteboard.name, count, workspace.revision, workspace.dragIdentity, paths)
            return paths
        }
        func allowsDrop(_ paths: [String], item: Any?) -> Bool {
            guard workspace.canMutate, let folder = (item as? Item)?.folder, !folder.isUnreadable else { return false }
            return MoveSelection.permits(paths, destination: folder.relativePath)
        }
        func outlineView(
            _ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard let paths = dragPaths(info.draggingPasteboard), allowsDrop(paths, item: item) else {
                setHover(nil); return []
            }
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            setHover(item as? Item)
            return .move
        }
        func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex: Int)
            -> Bool
        {
            guard let paths = dragPaths(info.draggingPasteboard), allowsDrop(paths, item: item),
                let destination = (item as? Item)?.folder?.relativePath
            else { return false }
            finishDrag(accepted: true)
            workspace.move(paths, to: destination)
            return true
        }
        func setHover(_ item: Item?) {
            guard hovered !== item else { return }
            springTask?.cancel()
            hovered = item
            if item == nil {
                if let hoverMonitor { NSEvent.removeMonitor(hoverMonitor); self.hoverMonitor = nil }
            } else if hoverMonitor == nil {
                hoverMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 49, self?.hovered != nil else { return event }
                    self?.expandHover()
                    return nil
                }
            }
            if UserDefaults.standard.object(forKey: "com.apple.springing.enabled") != nil,
                !UserDefaults.standard.bool(forKey: "com.apple.springing.enabled")
            {
                return
            }
            guard let item, !item.children.isEmpty, outline?.isItemExpanded(item) == false else { return }
            let configured = UserDefaults.standard.double(forKey: "com.apple.springing.delay")
            let delay = configured > 0 ? configured : 0.6
            springTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                self?.expandHover()
            }
        }
        func expandHover() {
            guard let item = hovered, let outline, !outline.isItemExpanded(item), !item.children.isEmpty else { return }
            springTask?.cancel()
            restoring = true
            outline.expandItem(item)
            restoring = false
            springExpanded.append(item)
        }
        func finishDrag(accepted: Bool) {
            springTask?.cancel()
            for item in springExpanded.reversed() {
                if accepted, let target = hovered?.folder?.relativePath, let path = item.folder?.relativePath,
                    target == path || target.hasPrefix(path.isEmpty ? "" : path + "/")
                {
                    workspace.session.expandedFolders.insert(path)
                } else {
                    restoring = true; outline?.collapseItem(item); restoring = false
                }
            }
            springExpanded = []; setHover(nil)
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !restoring, let outline, let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
            if item.isTagsGroup { return }
            let generation = workspace.navigationGeneration
            if let tag = item.tag {
                workspace.selectTag(tag.id)
            } else {
                workspace.selectFolder(item.folder?.relativePath)
            }
            // An accepted scope switch never rolls back, so its completion leaves the outline alone (#88).
            guard workspace.navigationGeneration == generation else { return }
            Task {
                // Refused: once pending navigation drains, the row moves back to the scope the list shows.
                await workspace.waitForNavigation()
                selectScope()
            }
        }
        func outlineViewItemDidExpand(_ notification: Notification) { expansion(notification, expanded: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { expansion(notification, expanded: false) }
        private func expansion(_ notification: Notification, expanded: Bool) {
            guard !restoring, let item = notification.userInfo?["NSObject"] as? Item else { return }
            if item.isTagsGroup {
                workspace.tagsExpanded = expanded
                tagsExpanded = expanded
                workspace.persistSession()
                return
            }
            guard let path = item.folder?.relativePath else { return }
            if hovered != nil {
                if expanded, !springExpanded.contains(where: { $0 === item }) { springExpanded.append(item) }
                return
            }
            if expanded {
                workspace.session.expandedFolders.insert(path)
            } else {
                workspace.session.expandedFolders.remove(path)
            }
        }
    }
}

final class SidebarFolderCell: NSTableCellView, CapsuleAccessories {
    let lockBadge = NSImageView()
    let countBadge = NSTextField(labelWithString: "")
    var renameField: RenameNameField?
    var titleToLock: NSLayoutConstraint?
    var lockToCount: NSLayoutConstraint?
    var lockWidth: NSLayoutConstraint?

    func configureCluster(unreadable: Bool, renaming: Bool) {
        countBadge.isHidden = renaming
        lockBadge.isHidden = renaming || !unreadable
        lockWidth?.constant = unreadable ? 12 : 0
        titleToLock?.constant = unreadable ? -4 : 0
        // The suffix already starts with a space; retain four points around the lock.
        lockToCount?.constant = unreadable ? -4 : 0
        updateSecondaryColor()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateSecondaryColor() }
    }

    /// Set by `CapsuleRowView`: the folder icon and `(N)` suffix tint sage on a focused capsule.
    var capsuleFocused = false {
        didSet { if capsuleFocused != oldValue { updateSecondaryColor() } }
    }

    func updateSecondaryColor() {
        let color: NSColor =
            capsuleFocused
            ? .silkwebAccent
            : backgroundStyle == .emphasized
                ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75)
                : .secondaryLabelColor
        countBadge.textColor = color
        lockBadge.contentTintColor = color
        imageView?.contentTintColor = color
    }
}

/// A sidebar row hanging from 1.5 pt thread guides with rounded elbows (silkweb-1.63). Drawn per row after the
/// capsule: no layers and no whole-tree pass. No coral node: the selection capsule marks the scope (1.65).
final class ThreadRowView: CapsuleRowView {
    struct Thread: Equatable {
        var level: Int
        var isLastChild: Bool
        var ancestorContinues: [Bool]
        var hasChildren: Bool
    }

    static let indentation: CGFloat = 16
    /// AppKit's disclosure slot width in a source list.
    static let slotWidth: CGFloat = 13
    static let lineWidth: CGFloat = 1.5

    var thread: Thread? { didSet { if thread != oldValue { needsDisplay = true } } }

    init() { super.init(cornerRadius: 6) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Measured from the real outline so guides follow AppKit's own indentation.
    var metrics: ThreadGuides.Metrics? {
        guard let outline = superview as? NSOutlineView, let thread else { return nil }
        let row = outline.row(for: self)
        guard row >= 0 else { return nil }
        let cellX = outline.frameOfCell(atColumn: 0, row: row).minX
        return ThreadGuides.Metrics(
            leadingInset: cellX - CGFloat(thread.level) * outline.indentationPerLevel - Self.slotWidth,
            indentation: outline.indentationPerLevel, slotWidth: Self.slotWidth, rowHeight: bounds.height)
    }

    /// Row-local y from a distance below the top edge.
    private func y(_ distance: CGFloat) -> CGFloat { isFlipped ? bounds.minY + distance : bounds.maxY - distance }

    var threadPath: NSBezierPath? {
        guard let thread, let metrics else { return nil }
        let dx = -frame.minX
        let path = NSBezierPath()
        path.lineWidth = Self.lineWidth
        path.lineCapStyle = .butt
        path.lineJoinStyle = .round
        for segment in ThreadGuides.segments(
            level: thread.level, isLastChild: thread.isLastChild,
            ancestorContinues: thread.ancestorContinues, hasChildren: thread.hasChildren, metrics: metrics)
        {
            switch segment {
            case .rail(let x):
                path.move(to: NSPoint(x: x + dx, y: bounds.minY))
                path.line(to: NSPoint(x: x + dx, y: bounds.maxY))
            case .elbow(let x, let cornerY, let radius, let endX):
                let k = 0.5523 * radius // Quarter-circle control distance.
                path.move(to: NSPoint(x: x + dx, y: y(0)))
                path.line(to: NSPoint(x: x + dx, y: y(cornerY - radius)))
                path.curve(
                    to: NSPoint(x: x + dx + radius, y: y(cornerY)),
                    controlPoint1: NSPoint(x: x + dx, y: y(cornerY - radius + k)),
                    controlPoint2: NSPoint(x: x + dx + radius - k, y: y(cornerY)))
                path.line(to: NSPoint(x: endX + dx, y: y(cornerY)))
            }
        }
        return path
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.silkwebThread.setStroke()
        threadPath?.stroke()
    }

    /// Drop-on target: the focused capsule with a 1.5 pt sage outline; threads still draw on top.
    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        NSColor.silkwebSelection.setFill()
        NSBezierPath(roundedRect: capsuleRect, xRadius: cornerRadius, yRadius: cornerRadius).fill()
        let outline = NSBezierPath(
            roundedRect: capsuleRect.insetBy(dx: 0.75, dy: 0.75), xRadius: cornerRadius, yRadius: cornerRadius)
        outline.lineWidth = 1.5
        NSColor.silkwebAccent.setStroke()
        outline.stroke()
    }

    override var isTargetForDropOperation: Bool { didSet { needsDisplay = true } }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let button = subview as? NSButton, button.identifier == NSOutlineView.disclosureButtonIdentifier {
            button.contentTintColor = .tertiaryLabelColor
        }
    }
}

/// Arrow navigation and type-selection remain AppKit's native outline behavior.
final class SidebarOutlineView: NSOutlineView {
    var toggleDisclosure: ((Int) -> Bool)?
    var toggleGroup: (() -> Bool)?
    var tagArrow: ((UInt16) -> Bool)?
    var moveFocus: ((Bool) -> Void)?
    var renameSelected: (() -> Void)?
    var didFocus: (() -> Void)?
    var contextMenu: ((NSEvent) -> NSMenu?)?
    var expandHovered: (() -> Bool)?
    var dragEnded: (() -> Void)?
    private var lastClick: (Int, TimeInterval)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { didFocus?() }
        return result
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?(event) }
    override func mouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        if clicked >= 0, frameOfOutlineCell(atRow: clicked).contains(convert(event.locationInWindow, from: nil)),
            toggleDisclosure?(clicked) == true
        {
            return
        }
        let wasSelected = clicked == selectedRow
        // Like the list (#70, #88): a plain press selects an unselected row at once. AppKit commits a draggable
        // row on release, and the press has already focused the outline, so the old row's capsule would light up.
        if clicked >= 0, !wasSelected, event.clickCount == 1,
            event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        {
            selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
        }
        super.mouseDown(with: event)
        if event.clickCount == 2, toggleGroup?() == true { return }
        if wasSelected, let lastClick, lastClick.0 == clicked, (0.5...1.5).contains(event.timestamp - lastClick.1) {
            renameSelected?()
        }
        lastClick = (clicked, event.timestamp)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        super.draggingExited(sender); dragEnded?()
    }
    override func draggingEnded(_ sender: NSDraggingInfo) {
        super.draggingEnded(sender); dragEnded?()
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let point = convert(sender.draggingLocation, from: nil)
        let visible = visibleRect
        if point.y < visible.minY + 24 || point.y > visible.maxY - 24, let event = NSApp.currentEvent {
            autoscroll(with: event)
        }
        return super.draggingUpdated(sender)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 123 || event.keyCode == 124, tagArrow?(event.keyCode) == true {
            return
        } else if event.keyCode == 49, expandHovered?() == true {
            return
        } else if event.keyCode == 36 || event.keyCode == 76 {
            renameSelected?()
        } else if event.keyCode == 48, !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
            moveFocus?(event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }
}

import AppKit
import SwiftUI
import SilkwebCore

struct FolderSidebar: NSViewRepresentable {
    let snapshot: LibrarySnapshot
    let workspace: LibraryWorkspace

    final class Item: NSObject {
        let folder: LibraryFolder?
        let title: String
        var children: [Item] = []
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
        scroll.drawsBackground = false
        let outline = SidebarOutlineView()
        outline.renameSelected = { workspace.focusColumn = 0; workspace.beginRename() }
        outline.didFocus = { workspace.focusColumn = 0 }
        outline.contextMenu = { [weak coordinator = coordinator] event in coordinator?.menu(event) }
        outline.moveFocus = { backwards in workspace.focus(backwards ? 2 : 1) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folders"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 24
        outline.delegate = coordinator
        outline.dataSource = coordinator
        outline.allowsEmptySelection = false
        outline.autosaveExpandedItems = false
        outline.setAccessibilityLabel("Folders")
        scroll.documentView = outline
        coordinator.outline = outline
        coordinator.restore()
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        Self.update(view, coordinator: context.coordinator, snapshot: snapshot)
    }

    static func update(_ view: NSScrollView, coordinator: Coordinator, snapshot: LibrarySnapshot) {
        let workspace = coordinator.workspace
        if coordinator.rootURL != snapshot.rootURL || coordinator.revision != workspace.revision {
            coordinator.revision = workspace.revision
            coordinator.configure(snapshot)
            coordinator.restore()
        }
        if coordinator.rename != workspace.rename {
            coordinator.rename = workspace.rename
            coordinator.restore()
        }
        if coordinator.lastFocusRequest != workspace.focusRequest {
            coordinator.lastFocusRequest = workspace.focusRequest
            if workspace.focusColumn == 0 {
                view.window?.makeFirstResponder(coordinator.outline)
            }
        }
    }

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let workspace: LibraryWorkspace
        var roots: [Item] = []
        var itemsByPath: [String: Item] = [:]
        var rootURL: URL?
        weak var outline: NSOutlineView?
        var restoring = false
        var lastFocusRequest = 0
        var revision = 0
        var rename: LibraryRename?

        init(workspace: LibraryWorkspace, snapshot: LibrarySnapshot) {
            self.workspace = workspace
            super.init()
            configure(snapshot)
        }

        func configure(_ snapshot: LibrarySnapshot) {
            rootURL = snapshot.rootURL
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
                if let parent = folder.parentID { byID[parent]?.children.append(item) }
                else { roots.append(item) }
            }
            for item in byID.values {
                item.children.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            }
        }

        func restore() {
            guard let outline else { return }
            restoring = true
            outline.reloadData()
            for path in workspace.session.expandedFolders.sorted(by: { $0.count < $1.count }) {
                if let item = itemsByPath[path] { outline.expandItem(item) }
            }
            let item = workspace.session.selectedFolder.flatMap { itemsByPath[$0] } ?? roots.first
            if let item {
                var parent = outline.parent(forItem: item)
                while let ancestor = parent {
                    outline.expandItem(ancestor)
                    parent = outline.parent(forItem: ancestor)
                }
                let row = outline.row(forItem: item)
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); outline.scrollRowToVisible(row) }
            }
            restoring = false
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? Item)?.children.count ?? roots.count
        }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            ((item as? Item)?.children ?? roots)[index]
        }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? Item)?.children.isEmpty ?? true)
        }
        func outlineView(_ outlineView: NSOutlineView, objectValueFor tableColumn: NSTableColumn?, byItem item: Any?) -> Any? {
            (item as? Item)?.title
        }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let item = item as? Item else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("folderCell")
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarFolderCell ?? SidebarFolderCell()
            if cell.textField == nil {
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingTail
                let image = NSImageView()
                let badge = cell.lockBadge
                badge.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)
                badge.contentTintColor = .secondaryLabelColor
                text.translatesAutoresizingMaskIntoConstraints = false
                image.translatesAutoresizingMaskIntoConstraints = false
                badge.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.addSubview(text)
                cell.addSubview(badge)
                cell.textField = text
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: badge.leadingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    badge.widthAnchor.constraint(equalToConstant: 12), badge.heightAnchor.constraint(equalToConstant: 12)
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
                        field.heightAnchor.constraint(equalToConstant: 22)
                    ])
                }
                cell.renameField = field
            }
            cell.textField?.stringValue = item.title
            let symbol = item.folder.map { $0.parentID == nil ? "books.vertical" : "folder" } ?? "doc.on.doc"
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            cell.lockBadge.isHidden = item.folder?.isUnreadable != true
            let label = item.folder.map { "\(item.title), \($0.parentID == nil ? "library" : "folder")" } ?? item.title
            cell.setAccessibilityElement(true)
            cell.setAccessibilityLabel(item.folder?.isUnreadable == true ? "\(label), unreadable, permission denied" : label)
            cell.toolTip = item.folder?.isUnreadable == true ? "You don't have permission to view this folder." : nil
            return cell
        }
        func menu(_ event: NSEvent) -> NSMenu? {
            guard let outline else { return nil }
            let row = outline.row(at: outline.convert(event.locationInWindow, from: nil))
            guard let item = outline.item(atRow: row) as? Item, let folder = item.folder else { return nil }
            let menu = NSMenu()
            menu.autoenablesItems = false
            for (title, action) in [("New Document", #selector(newDocument(_:))), ("New Folder", #selector(newFolder(_:)))] {
                let entry = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
                entry.target = self; entry.representedObject = folder.relativePath; entry.isEnabled = workspace.canMutate
            }
            menu.addItem(.separator())
            let rename = menu.addItem(withTitle: "Rename…", action: #selector(renameFolder(_:)), keyEquivalent: "")
            rename.target = self; rename.representedObject = folder.relativePath
            rename.isEnabled = workspace.canMutate && !folder.relativePath.isEmpty
            let move = menu.addItem(withTitle: "Move To…", action: nil, keyEquivalent: "")
            move.isEnabled = false
            let reveal = menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealFolder(_:)), keyEquivalent: "")
            reveal.target = self; reveal.representedObject = folder.relativePath
            menu.addItem(.separator())
            let trash = menu.addItem(withTitle: "Move to Trash", action: nil, keyEquivalent: "")
            trash.isEnabled = false
            return menu
        }
        @objc private func newDocument(_ sender: NSMenuItem) { workspace.create(folder: false, parent: sender.representedObject as? String) }
        @objc private func newFolder(_ sender: NSMenuItem) { workspace.create(folder: true, parent: sender.representedObject as? String) }
        @objc private func renameFolder(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            workspace.beginRename(LibraryRename(path: path, isFolder: true))
        }
        @objc private func revealFolder(_ sender: NSMenuItem) { workspace.reveal(sender.representedObject as? String) }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !restoring, let outline, let item = outline.item(atRow: outline.selectedRow) as? Item else { return }
            workspace.selectFolder(item.folder?.relativePath)
            Task {
                // Wait for the guarded switch; restore the row if saving refused it.
                await workspace.waitForNavigation()
                restore()
            }
        }
        func outlineViewItemDidExpand(_ notification: Notification) { expansion(notification, expanded: true) }
        func outlineViewItemDidCollapse(_ notification: Notification) { expansion(notification, expanded: false) }
        private func expansion(_ notification: Notification, expanded: Bool) {
            guard !restoring, let item = notification.userInfo?["NSObject"] as? Item, let path = item.folder?.relativePath else { return }
            if expanded { workspace.session.expandedFolders.insert(path) }
            else { workspace.session.expandedFolders.remove(path) }
        }
    }
}

final class SidebarFolderCell: NSTableCellView {
    let lockBadge = NSImageView()
    var renameField: RenameNameField?
}

/// Arrow navigation and type-selection remain AppKit's native outline behavior.
final class SidebarOutlineView: NSOutlineView {
    var moveFocus: ((Bool) -> Void)?
    var renameSelected: (() -> Void)?
    var didFocus: (() -> Void)?
    var contextMenu: ((NSEvent) -> NSMenu?)?
    private var lastClick: (Int, TimeInterval)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { didFocus?() }
        return result
    }
    override func menu(for event: NSEvent) -> NSMenu? { contextMenu?(event) }
    override func mouseDown(with event: NSEvent) {
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        let wasSelected = clicked == selectedRow
        super.mouseDown(with: event)
        if wasSelected, let lastClick, lastClick.0 == clicked, (0.5...1.5).contains(event.timestamp - lastClick.1) {
            renameSelected?()
        }
        lastClick = (clicked, event.timestamp)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            renameSelected?()
        } else if event.keyCode == 48, !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
            moveFocus?(event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }
}

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
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let outline = SidebarOutlineView()
        outline.moveFocus = { backwards in workspace.focus(backwards ? 2 : 1) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folders"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 24
        outline.delegate = context.coordinator
        outline.dataSource = context.coordinator
        outline.allowsEmptySelection = false
        outline.autosaveExpandedItems = false
        outline.setAccessibilityLabel("Folders")
        scroll.documentView = outline
        context.coordinator.outline = outline
        context.coordinator.restore()
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.rootURL != snapshot.rootURL {
            coordinator.configure(snapshot)
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
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
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
            let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView ?? NSTableCellView()
            if cell.textField == nil {
                cell.identifier = identifier
                let text = NSTextField(labelWithString: "")
                text.lineBreakMode = .byTruncatingTail
                let image = NSImageView()
                text.translatesAutoresizingMaskIntoConstraints = false
                image.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(image)
                cell.addSubview(text)
                cell.textField = text
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16), image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
            }
            cell.textField?.stringValue = item.title
            let symbol = item.folder.map { $0.parentID == nil ? "books.vertical" : "folder" } ?? "doc.on.doc"
            cell.imageView?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            let label = item.folder.map { "\(item.title), \($0.parentID == nil ? "library" : "folder")" } ?? item.title
            cell.setAccessibilityElement(true)
            cell.setAccessibilityLabel(label)
            return cell
        }
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

/// Arrow navigation and type-selection remain AppKit's native outline behavior.
private final class SidebarOutlineView: NSOutlineView {
    var moveFocus: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, !event.modifierFlags.contains(.control), !event.modifierFlags.contains(.option) {
            moveFocus?(event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }
}

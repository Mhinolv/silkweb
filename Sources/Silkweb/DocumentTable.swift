import AppKit
import SwiftUI
import SilkwebCore

/// Stable, virtualized native rows in both standalone and split-view hosting.
struct DocumentTable: NSViewRepresentable {
    let workspace: LibraryWorkspace
    let documents: [LibraryDocument]
    let dateReference: Date
    var makeDragProvider: (([String]) -> NSItemProvider)?

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = DocumentTableView()
        table.coordinator = context.coordinator
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("document")))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.style = .inset
        table.intercellSpacing = .zero
        table.backgroundColor = .silkwebPaneBackground
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .silkwebPaneBackground
        scroll.documentView = table
        context.coordinator.table = table
        context.coordinator.update(documents: documents, dateReference: dateReference, makeDragProvider: makeDragProvider)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        _ = workspace.editor.refusedNavigation // Restore native selection when unsaved text blocks navigation.
        context.coordinator.update(documents: documents, dateReference: dateReference, makeDragProvider: makeDragProvider)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.pointerState.cancelRename()
        coordinator.table?.delegate = nil
        coordinator.table?.dataSource = nil
        coordinator.table?.coordinator = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let workspace: LibraryWorkspace
        let pointerState = DocumentRowPointerState()
        weak var table: DocumentTableView?
        private(set) var documents: [LibraryDocument] = []
        private var dateReference = Date()
        var makeDragProvider: (([String]) -> NSItemProvider)?
        private var updating = false
        private var includesSubfolders = false
        private var lastRename: LibraryRename?
        private var lastRevision = -1

        init(workspace: LibraryWorkspace) { self.workspace = workspace }

        func update(documents: [LibraryDocument], dateReference: Date,
                    makeDragProvider: (([String]) -> NSItemProvider)?) {
            guard let table else { return }
            updating = true
            defer { updating = false }
            let structureChanged = self.documents.count != documents.count || zip(self.documents, documents).contains {
                $0.id != $1.id || $0.relativePath != $1.relativePath
            }
            let reload = structureChanged || includesSubfolders != workspace.includesSubfolders
            self.documents = documents
            self.dateReference = dateReference
            self.makeDragProvider = makeDragProvider
            includesSubfolders = workspace.includesSubfolders
            let height: CGFloat = includesSubfolders ? 64 : 48
            if table.rowHeight != height { table.rowHeight = height }
            if reload { table.reloadData() }
            // Refresh realized cells only; summaries still load asynchronously in DocumentRow.
            let visible = table.rows(in: table.visibleRect)
            let first = min(visible.location, documents.count)
            let last = min(first + visible.length, documents.count)
            for row in first..<last {
                if let host = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSHostingView<DocumentRow> {
                    host.rootView = rowView(documents[row])
                }
            }
            let selected = IndexSet(documents.indices.filter { workspace.session.selectedDocuments.contains(documents[$0].relativePath) })
            if table.selectedRowIndexes != selected { table.selectRowIndexes(selected, byExtendingSelection: false) }
            if lastRename != workspace.rename, let rename = workspace.rename, !rename.isFolder,
               let row = documents.firstIndex(where: { $0.relativePath == rename.path }) {
                table.scrollRowToVisible(row)
            } else if lastRevision != workspace.revision, let row = selected.first { table.scrollRowToVisible(row) }
            lastRename = workspace.rename
            lastRevision = workspace.revision
        }

        private func rowView(_ document: LibraryDocument) -> DocumentRow {
            DocumentRow(document: document, root: workspace.snapshot!.rootURL, workspace: workspace,
                        dateReference: dateReference, pointerState: pointerState)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { documents.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let identifier = NSUserInterfaceItemIdentifier("documentCell")
            if let host = tableView.makeView(withIdentifier: identifier, owner: self) as? NSHostingView<DocumentRow> {
                host.rootView = rowView(documents[row])
                return host
            }
            let host = NSHostingView(rootView: rowView(documents[row]))
            host.identifier = identifier
            host.sizingOptions = []
            return host
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let table else { return }
            workspace.focusColumn = 1
            let selection = Set(table.selectedRowIndexes.compactMap {
                documents.indices.contains($0) ? documents[$0].relativePath : nil
            })
            if selection != workspace.session.selectedDocuments { workspace.selectDocuments(selection) }
        }

        func menu(path: String) -> NSMenu {
            let menu = NSMenu()
            menu.autoenablesItems = false
            func add(_ title: String, _ action: Selector?, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self; item.representedObject = path; item.isEnabled = enabled
                menu.addItem(item)
            }
            add("Open in New Tab", #selector(openTab(_:)), enabled: !workspace.loading && !workspace.mutating)
            menu.addItem(.separator())
            add("Rename…", #selector(rename(_:)), enabled: workspace.canMutate)
            add("Move To…", #selector(move(_:)), enabled: workspace.canMutate)
            add("Reveal in Finder", #selector(reveal(_:)))
            let export = NSMenuItem(title: "Export", action: nil, keyEquivalent: "")
            let exportMenu = NSMenu()
            exportMenu.autoenablesItems = false
            let html = NSMenuItem(title: "HTML…", action: #selector(exportHTML(_:)), keyEquivalent: "")
            html.target = self; html.representedObject = path
            html.isEnabled = workspace.canExport && workspace.documentDragPaths(path).count == 1
            exportMenu.addItem(html); export.submenu = exportMenu; menu.addItem(export)
            menu.addItem(.separator())
            let tagsItem = NSMenuItem(title: "Tags", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            let paths = workspace.documentDragPaths(path)
            let ids = Set(paths.compactMap { workspace.snapshot?.metadata.IDsByPath[$0] })
            for tag in workspace.tags {
                let item = NSMenuItem(title: tag.name, action: #selector(toggleTag(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = TagMenuSelection(tag: tag, paths: Set(paths))
                let count = ids.filter { workspace.snapshot?.metadata.tagsByDocument[$0.uuidString]?.contains(tag.id) == true }.count
                item.state = count == 0 ? .off : count == ids.count ? .on : .mixed
                item.isEnabled = workspace.canMutate
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let edit = NSMenuItem(title: "Edit Tags…", action: #selector(editTags(_:)), keyEquivalent: "")
            edit.target = self; edit.representedObject = path; edit.isEnabled = workspace.canMutate
            submenu.addItem(edit)
            tagsItem.submenu = submenu
            menu.addItem(tagsItem)
            add("Move to Trash", #selector(trash(_:)), enabled: workspace.canMutate)
            return menu
        }

        private struct TagMenuSelection { let tag: LibraryTag; let paths: Set<String> }
        @objc private func toggleTag(_ sender: NSMenuItem) {
            guard let selection = sender.representedObject as? TagMenuSelection else { return }
            workspace.toggleTag(selection.tag, paths: selection.paths)
        }
        @objc private func editTags(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            workspace.selectDocuments(Set(workspace.documentDragPaths(path)))
            Task { await workspace.waitForNavigation(); workspace.showInfo() }
        }
        @objc private func openTab(_ sender: NSMenuItem) {
            workspace.openSelectionInNewTab(sender.representedObject as? String)
        }
        @objc private func rename(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            workspace.beginRename(LibraryRename(path: path, isFolder: false))
        }
        @objc private func move(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            workspace.requestMove(workspace.documentDragPaths(path))
        }
        @objc private func exportHTML(_ sender: NSMenuItem) { workspace.exportHTML(path: sender.representedObject as? String) }
        @objc private func reveal(_ sender: NSMenuItem) { workspace.reveal(sender.representedObject as? String) }
        @objc private func trash(_ sender: NSMenuItem) {
            guard let path = sender.representedObject as? String else { return }
            workspace.requestTrash(workspace.documentDragPaths(path), pane: 1)
        }
    }
}

final class DocumentTableView: NSTableView {
    weak var coordinator: DocumentTable.Coordinator?
    var startDraggingSession: (([NSDraggingItem], NSEvent, NSDraggingSource) -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil, coordinator?.workspace.rename == nil else { return hit }
        let index = row(at: convert(point, from: superview))
        guard index >= 0, let row = rowView(atRow: index, makeIfNecessary: true) else { return hit }
        func source(in view: NSView) -> DocumentRowClickView? {
            if let source = view as? DocumentRowClickView { return source }
            return view.subviews.lazy.compactMap { source(in: $0) }.first
        }
        return source(in: row) ?? hit
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard let coordinator, coordinator.documents.indices.contains(row) else { return nil }
        return coordinator.menu(path: coordinator.documents[row].relativePath)
    }

    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        guard let coordinator, coordinator.workspace.canMutate,
              let row = rowIndexes.first, coordinator.documents.indices.contains(row) else { return false }
        let paths = coordinator.workspace.documentDragPaths(coordinator.documents[row].relativePath)
        _ = coordinator.makeDragProvider?(paths)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let workspace = coordinator?.workspace, workspace.rename == nil else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 36:
            workspace.focusColumn = 1
            workspace.beginRename()
        case 48:
            workspace.focus(event.modifierFlags.contains(.shift) ? 0 : 2)
        default: super.keyDown(with: event)
        }
    }
}

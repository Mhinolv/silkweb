import AppKit
import SilkwebCore

struct LibraryRename: Equatable {
    let path: String
    let isFolder: Bool
    var focusEditor = false
    var name: String {
        let name = (path as NSString).lastPathComponent
        return isFolder ? name : (name as NSString).deletingPathExtension
    }
    func filename(_ value: String) throws -> String {
        try LibraryMutations.renameFilename(value, for: path, isFolder: isFolder)
    }
}

enum LibraryUndo {
    case tags(LibraryMetadata, String)
    case newFolder(String)
    /// The renamed item, its previous name, and the exact reverse of the rename and its link rewrites.
    case rename(LibraryRename, String, MovePlan)
    case move(MovePlan)
    case trash([TrashedItem])
    var title: String {
        switch self {
        case .tags(_, let title): return title;
        case .newFolder: return "Undo New Folder";
        case .rename: return "Undo Rename";
        case .move: return "Undo Move";
        case .trash: return "Undo Move to Trash"
        }
    }
}

extension LibraryWorkspace {
    var canMutate: Bool { snapshot != nil && snapshot?.isReadOnly == false && !loading && !mutating }
    var targetFolder: String {
        session.selectedFolder ?? selectedDocument.map { ($0.relativePath as NSString).deletingLastPathComponent } ?? ""
    }
    var selectedItem: LibraryRename? {
        if focusColumn == 0 {
            return session.selectedFolder.flatMap { $0.isEmpty ? nil : LibraryRename(path: $0, isFolder: true) }
        }
        return selectedDocument.map { LibraryRename(path: $0.relativePath, isFolder: false) }
    }

    func create(folder: Bool, parent: String? = nil) {
        guard canMutate, let root else { return }
        let target = parent ?? targetFolder
        mutating = true
        Task {
            await waitForNavigation()
            defer { mutating = false }
            let editor = editor
            editor.loading = true
            guard await flushEditors() else { editor.loading = false; return }
            defer { editor.loading = false }
            do {
                let engine = try LibraryMutations(root: root)
                let name = try await engine.uniqueName(base: folder ? "Untitled Folder" : "Untitled.md", in: target)
                let changes =
                    try await
                    (folder
                    ? engine.createFolder(named: name, in: target) : engine.createDocument(named: name, in: target))
                guard let change = changes.changes.first else { return }
                try await refresh(changes)
                if folder { libraryUndo.append(.newFolder(change.newPath)) }
                session.expandedFolders.insert(target)
                // A tag scope or filter hides the new untagged row: never leave a rename pending on a
                // row that isn't on screen (it blocks Trash, Return, drag). Keep scope and selection.
                let visible =
                    folder
                    ? session.selectedTagID == nil
                    : search.text.isEmpty && documents.contains { $0.relativePath == change.newPath }
                if visible {
                    session.selectedFolder = folder ? change.newPath : target
                    session.selectedDocuments = folder ? [] : [change.newPath]
                } else if !folder {
                    session.selectedDocuments = []
                }
                if !folder, let document = snapshot?.documents.first(where: { $0.relativePath == change.newPath }) {
                    _ = await openTab(document, pinned: true)
                }
                if visible {
                    rename = LibraryRename(path: change.newPath, isFolder: folder, focusEditor: !folder)
                    focus(folder ? 0 : 1)
                } else if !folder {
                    focus(2)
                }
            } catch { mutationFailure(error) }
        }
    }

    /// Without an item (the menu bar) the sidebar or list must have focus (#104).
    func beginRename(_ item: LibraryRename? = nil) {
        guard canMutate, item != nil || libraryHasFocus, let item = item ?? selectedItem, !item.path.isEmpty
        else { return }
        Task {
            if item.isFolder, session.selectedFolder != item.path {
                selectFolder(item.path)
                await waitForNavigation()
                guard session.selectedFolder == item.path else { return }
            } else if !item.isFolder, session.selectedDocuments != [item.path] {
                selectDocuments([item.path])
                await waitForNavigation()
                guard session.selectedDocuments == [item.path] else { return }
            }
            rename = item
            focus(item.isFolder ? 0 : 1)
        }
    }

    func validateRename(_ item: LibraryRename, value: String) async -> String? {
        guard let root else { return nil }
        do {
            let name = try item.filename(value)
            let engine = try LibraryMutations(root: root)
            try await engine.validateRename(item.path, to: name)
            return nil
        } catch { return error.localizedDescription }
    }

    /// A click-away leaves focus with whatever the user clicked instead of moving it to the editor (#106).
    func finishRename(_ item: LibraryRename, value: String?, clickedAway: Bool = false) {
        guard rename == item else { return }
        let focusEditor = item.focusEditor && !clickedAway
        guard let value else {
            rename = nil
            if focusEditor { focus(2) }
            return
        }
        guard canMutate, let root else { return }
        mutating = true
        Task {
            await waitForNavigation()
            defer { mutating = false }
            let editor = editor
            editor.loading = true
            guard await flushEditors() else { editor.loading = false; rename = nil; return }
            defer { editor.loading = false }
            do {
                let engine = try LibraryMutations(root: root)
                let plan = try await engine.planRename(item.path, to: item.filename(value))
                // The field is gone after a click-away (#106): attach to the library's window, not the key one.
                let window = sidebarOutline?.window ?? documentTable?.window ?? NSApp.keyWindow
                guard await confirmUnsupportedLinks(plan, action: "Rename Anyway", window: window) else {
                    // Cancel works like Escape: the old name stays and nothing is added to undo.
                    rename = nil
                    if focusEditor { focus(2) }
                    return
                }
                let changes = try await commitMove(plan, using: engine)
                if let change = changes.changes.first {
                    libraryUndo.append(
                        .rename(
                            LibraryRename(path: change.newPath, isFolder: item.isFolder),
                            (item.path as NSString).lastPathComponent, plan.reversed))
                }
                rename = nil
                if focusEditor { focus(2) }
            } catch {
                rename = nil
                mutationFailure(error, title: "“\(item.name)” couldn’t be renamed.")
            }
        }
    }

    func reveal(_ path: String? = nil) {
        guard let root else { return }
        NSWorkspace.shared.activateFileViewerSelecting([
            root.appendingPathComponent(path ?? selectedItem?.path ?? targetFolder)
        ])
    }

    /// `added`: other Library paths Silkweb itself just wrote (an import, a restore from the Trash), so they're
    /// never shown as changed outside Silkweb (#230); the changes' new paths count too.
    func refresh(_ changes: LibraryChangeSet, added: [String] = []) async throws {
        guard let root else { return }
        let scanned = try await LibraryScanner.scan(root: root)
        await accountSilkwebChanges(changes.changes.map(\.newPath) + added, in: scanned)
        install(scanned)
        session = session.applying(changes)
        for editor in allEditors {
            guard let url = editor.url else { continue }
            let old = String(url.path.dropFirst(root.path.count + 1))
            let new = changes.remapping(old)
            if old != new { await editor.followRename(to: root.appendingPathComponent(new)) }
        }
        revision += 1
    }

    func mutationFailure(_ error: Error, title: String? = nil) {
        mutationRevealURLs = []
        mutationErrorTitle = title ?? error.localizedDescription
        mutationError = (error as? LocalizedError)?.recoverySuggestion ?? error.localizedDescription
    }
}

extension LibraryWorkspace {
    var usesTextUndo: Bool {
        if let window = NSApp.keyWindow {
            guard let text = window.firstResponder as? NSTextView else { return false }
            return text.isFieldEditor || text.undoManager?.canUndo == true || libraryUndo.isEmpty
        }
        return focusColumn == 2 && libraryUndo.isEmpty
    }
    var usesTextRedo: Bool {
        (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.canRedo == true
    }
    var canUndoLibrary: Bool {
        guard canMutate, let snapshot, let last = libraryUndo.last else { return false }
        switch last {
        case .move, .trash, .tags: return true
        case .newFolder(let path):
            return snapshot.folders.contains { $0.relativePath == path }
                && !snapshot.folders.contains { $0.relativePath.hasPrefix(path + "/") }
                && !snapshot.documents.contains { $0.relativePath.hasPrefix(path + "/") }
        case .rename(let item, let name, _):
            let parent = (item.path as NSString).deletingLastPathComponent
            let target = parent.isEmpty ? name : parent + "/" + name
            return !snapshot.folders.contains { $0.relativePath == target }
                && !snapshot.documents.contains { $0.relativePath == target }
        }
    }

    func undoLibrary() {
        guard canUndoLibrary, let last = libraryUndo.last, let root else { return }
        mutating = true
        Task {
            await waitForNavigation()
            let editor = editor
            editor.loading = true
            defer { editor.loading = false; mutating = false }
            guard await flushEditors() else { return }
            do {
                let engine = try LibraryMutations(root: root)
                switch last {
                case .tags(let metadata, _):
                    _ = try await TagStore.update(root: root) { current in
                        var result = current
                        result.tags = metadata.tags
                        result.tagsByDocument = metadata.tagsByDocument
                        result.tagRecency = metadata.tagRecency
                        return result
                    }
                    try await refresh(LibraryChangeSet(changes: []))
                case .trash(let items):
                    let result = await (try TrashService(root: root)).restore(items)
                    let restored = Set(result.items.map(\.originalPath))
                    let remaining = items.filter { !restored.contains($0.originalPath) }
                    libraryUndo.removeLast()
                    if !remaining.isEmpty { libraryUndo.append(.trash(remaining)) }
                    try await refresh(LibraryChangeSet(changes: []), added: Array(restored))
                    reportTrashFailures(result.failures, reveal: remaining.map(\.trashURL), restoring: true)
                    return
                case .move(let plan):
                    do {
                        do { _ = try await commitMove(plan, using: engine) } catch MovePlanError.changed {
                            // Something changed since the move: move back and rewrite links afresh.
                            _ = try await commitMove(engine.planRestore(plan.changes), using: engine)
                        }
                    } catch {
                        // Undo is all or nothing; drop the entry so older actions stay reachable.
                        libraryUndo.removeLast()
                        mutationFailure(error, title: "The move couldn’t be undone.")
                        var lines = [error.localizedDescription]
                        if let suggestion = (error as? LocalizedError)?.recoverySuggestion { lines.append(suggestion) }
                        if let failure = error as? LibraryMutationError, case .rollbackFailed = failure {
                            // The recovery suggestion identifies the preserved items.
                        } else {
                            lines.append("Nothing was changed.")
                        }
                        mutationError = lines.joined(separator: "\n")
                        return
                    }
                case .newFolder(let path):
                    try await engine.removeEmptyFolder(path)
                    if session.selectedFolder == path {
                        session.selectedFolder = (path as NSString).deletingLastPathComponent
                    }
                    session.expandedFolders.remove(path)
                    try await refresh(LibraryChangeSet(changes: []))
                case .rename(let item, let name, let plan):
                    do { _ = try await commitMove(plan, using: engine) } catch MovePlanError.changed {
                        // Something changed since the rename: rename back and rewrite links afresh.
                        let changes = try await engine.restoreName(item.path, to: name)
                        try await refresh(changes)
                    }
                }
                libraryUndo.removeLast()
            } catch { mutationFailure(error) }
        }
    }
}

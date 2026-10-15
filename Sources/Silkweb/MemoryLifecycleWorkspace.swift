import AppKit
import SilkwebCore

/// #141: one lifecycle action's Undo. `previous` holds the changed Documents' entries before the action; `moves` are
/// the reverse of an Archive or Restore move, applied first.
struct MemoryStateUndo {
    let title: String
    let previous: [UUID: MemoryLifecycleEntry]
    var moves: [MovePlan] = []
}

/// #141: the owner's lifecycle decisions for agent memory Documents (`.silkweb/memory-state.json`). Silkweb suggests
/// and the owner decides: every action here changes only the state file (and, for Archive and Restore, the Document's
/// Folder through the Move To… path), never Document text. Each action has one named Undo.
extension LibraryWorkspace {
    nonisolated static func loadMemoryState(root: URL) async -> (MemoryStateFile, locked: Bool) {
        await Task.detached(priority: .utility) {
            do {
                return (try MemoryStateStore.load(root: root), false)
            } catch {
                // A newer or unreadable-by-policy file: show no decisions and never overwrite it.
                return (MemoryStateFile(), true)
            }
        }.value
    }

    /// `.silkweb/memory-state.json` changed (another window, Undo): reread it. Nothing is written back.
    func reloadMemoryState() async {
        guard let root, snapshot != nil else { return }
        let previous = memoryStateReloadTask
        let task = Task {
            await previous?.value
            let (loaded, locked) = await Self.loadMemoryState(root: root)
            guard !Task.isCancelled, self.root == root else { return }
            if memoryState != loaded { memoryState = loaded }
            if memoryStateLocked != locked { memoryStateLocked = locked }
        }
        memoryStateReloadTask = task
        await task.value
    }

    var canChangeMemoryState: Bool { canMutate && !memoryStateLocked }

    /// The Document carries a `memory_id` (an agent memory envelope).
    func isMemoryDocument(_ path: String) -> Bool { memoryLinks.links[path] != nil }

    func memoryEntry(_ document: LibraryDocument) -> MemoryLifecycleEntry { memoryState[document.id] }

    private func memoryDocuments(_ paths: [String]) -> [LibraryDocument] {
        let documents = Dictionary(
            (snapshot?.documents ?? []).map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        return paths.compactMap { documents[$0] }.filter { isMemoryDocument($0.relativePath) }
    }

    /// The list menu's targets: the whole selection when the row is part of it, memory Documents only.
    func memoryMenuPaths(_ path: String) -> [String] {
        documentCopyPaths(path).filter(isMemoryDocument)
    }

    // MARK: Review, pin and review date

    /// Mark as Reviewed: binds the review to each Document's saved revision. Unsaved edits are saved first.
    func markReviewed(_ paths: [String]) {
        let documents = memoryDocuments(paths)
        guard !documents.isEmpty else { return }
        changeMemoryState(documents, undo: "Undo Mark as Reviewed", flush: true) { state, revisions, now in
            for document in documents {
                guard let revision = revisions[document.id] else { continue }
                state[document.id].reviewed = .init(revision: revision, at: now)
            }
        }
    }

    func setPinned(_ paths: [String], pinned: Bool) {
        let documents = memoryDocuments(paths)
        guard !documents.isEmpty else { return }
        changeMemoryState(documents, undo: pinned ? "Undo Pin" : "Undo Unpin") { state, _, _ in
            for document in documents { state[document.id].pinned = pinned }
        }
    }

    /// Change… ▸ Done sets the owner's date; Clear (`nil`) turns the review date off, the agent's suggestion too.
    func setReviewDate(_ document: LibraryDocument, to date: Date?) {
        changeMemoryState([document], undo: "Undo Change Review Date") { state, _, _ in
            state[document.id].reviewAfter = date
            state[document.id].reviewAfterCleared = date == nil
        }
    }

    // MARK: Supersession

    /// Accept or Decline `successor`'s claim to replace `target`. Bound to both Documents' saved revisions, and
    /// separate from reviewing either of them.
    func decideSupersession(target: String, successor: String, _ state: MemoryLifecycleEntry.ClaimState) {
        guard let targetDocument = snapshot?.documents.first(where: { $0.relativePath == target }),
            let successorDocument = snapshot?.documents.first(where: { $0.relativePath == successor }),
            let successorID = memoryLinks.links[successor]?.memoryID
        else { return }
        let title = state == .accepted ? "Undo Accept Replacement" : "Undo Decline Replacement"
        changeMemoryState([targetDocument], undo: title, flush: true, revisionsOf: [successorDocument]) {
            file, revisions, now in
            guard let revision = revisions[targetDocument.id], let successorRevision = revisions[successorDocument.id]
            else { return }
            file[targetDocument.id].decide(
                state, by: successorID, revision: revision, successorRevision: successorRevision, at: now)
        }
    }

    // MARK: Archive and Restore

    /// Archive: moves memory Documents into their project's `Archive` Folder (created on demand) with the Move To…
    /// path, so identity and links are kept, and records where each came from. Never the Trash.
    func archiveDocuments(_ paths: [String], undoTitle: String = "Undo Archive") {
        let documents = memoryDocuments(paths).filter {
            MemoryArchive.folder(for: $0.relativePath) != nil && !MemoryArchive.contains($0.relativePath)
        }
        guard canChangeMemoryState, let root, !documents.isEmpty else { return }
        mutating = true
        Task {
            await waitForNavigation()
            defer { mutating = false }
            guard await flushEditors() else { return }
            if let undo = await archive(documents, root: root, title: undoTitle) {
                libraryUndo.append(.memoryState(undo))
            }
        }
    }

    /// Archives `paths` without saving editors or adding Undo; the caller owns both (a merge's Archive Sources).
    func archive(_ paths: [String], root: URL, title: String) async -> MemoryStateUndo? {
        let documents = memoryDocuments(paths).filter { canArchive($0.relativePath) }
        guard !memoryStateLocked, !documents.isEmpty else { return nil }
        return await archive(documents, root: root, title: title)
    }

    private func archive(_ documents: [LibraryDocument], root: URL, title: String) async -> MemoryStateUndo? {
        await moveMemoryDocuments(
            documents, root: root, title: title, destination: { MemoryArchive.folder(for: $0.relativePath)! }
        ) { entry, document, now in
            entry.archived = .init(at: now, fromPath: (document.relativePath as NSString).deletingLastPathComponent)
        }
    }

    func canArchive(_ path: String) -> Bool {
        isMemoryDocument(path) && MemoryArchive.folder(for: path) != nil && !MemoryArchive.contains(path)
    }

    /// Restore: moves an archived Document back to the Folder it came from (recreated if needed).
    func restoreDocument(_ document: LibraryDocument) {
        guard canChangeMemoryState, let root, let from = memoryState[document.id].archived?.fromPath else { return }
        mutating = true
        Task {
            await waitForNavigation()
            defer { mutating = false }
            guard await flushEditors() else { return }
            if let undo = await moveMemoryDocuments(
                [document], root: root, title: "Undo Restore", destination: { _ in from },
                change: { entry, _, _ in entry.archived = nil })
            {
                libraryUndo.append(.memoryState(undo))
            }
        }
    }

    /// Moves `documents` (grouped by destination), then saves their entries. Returns one Undo for both, or `nil`
    /// when nothing moved.
    private func moveMemoryDocuments(
        _ documents: [LibraryDocument], root: URL, title: String, destination: (LibraryDocument) -> String,
        change: @escaping (inout MemoryLifecycleEntry, LibraryDocument, Date) -> Void
    ) async -> MemoryStateUndo? {
        let previous = Dictionary(
            documents.map { ($0.id, memoryState[$0.id]) }, uniquingKeysWith: { first, _ in first })
        var moves: [MovePlan] = []
        do {
            let engine = try LibraryMutations(root: root)
            let groups = Dictionary(grouping: documents, by: destination)
            for (folder, group) in groups.sorted(by: { $0.key < $1.key }) {
                try await ensureFolder(folder, engine: engine)
                let plan = try await engine.planMove(group.map(\.relativePath), toFolder: folder, keepBoth: true)
                guard await confirmUnsupportedLinks(plan, action: "Move Anyway", window: libraryWindow) else { break }
                _ = try await commitMove(plan, using: engine)
                moves.append(plan.reversed)
            }
        } catch {
            mutationFailure(error, title: "The documents couldn’t be moved.")
        }
        guard !moves.isEmpty else { return nil }
        // The reverse plans move each Document back to where it was.
        let moved = Set(moves.flatMap { $0.changes.changes.map(\.newPath) })
        let changed = documents.filter { moved.contains($0.relativePath) }
        let now = Date()
        do {
            let saved = try await Task.detached(priority: .userInitiated) {
                try MemoryStateStore.update(root: root) { state in
                    for document in changed { change(&state[document.id], document, now) }
                }
            }.value
            memoryState = saved
        } catch {
            mutationFailure(error, title: "The documents were moved, but their archive state couldn’t be saved.")
        }
        return MemoryStateUndo(
            title: title, previous: previous.filter { id, _ in changed.contains { $0.id == id } }, moves: moves)
    }

    /// Creates `path` and any missing parent Folders.
    private func ensureFolder(_ path: String, engine: LibraryMutations) async throws {
        var parent = ""
        for component in path.split(separator: "/").map(String.init) {
            let current = parent.isEmpty ? component : parent + "/" + component
            if snapshot?.folders.contains(where: { $0.relativePath == current }) != true {
                let changes = try await engine.createFolder(named: component, in: parent)
                try await refresh(changes)
            }
            parent = current
        }
    }

    // MARK: Saving and Undo

    /// Saves one change to some Documents' entries off the main thread, with one named Undo. `flush` saves open
    /// editors first, so a revision names the text on disk. `revisions` holds the saved revision of `documents` and
    /// `revisionsOf`.
    private func changeMemoryState(
        _ documents: [LibraryDocument], undo title: String, flush: Bool = false,
        revisionsOf others: [LibraryDocument] = [],
        _ change: @escaping @Sendable (inout MemoryStateFile, [UUID: String], Date) -> Void
    ) {
        guard canChangeMemoryState, let root, !documents.isEmpty else { return }
        let previous = Dictionary(
            documents.map { ($0.id, memoryState[$0.id]) }, uniquingKeysWith: { first, _ in first })
        let read = flush ? documents + others : []
        mutating = true
        Task {
            await waitForNavigation()
            defer { mutating = false }
            if flush { guard await flushEditors() else { return } }
            let targets = read.map { ($0.id, root.appendingPathComponent($0.relativePath)) }
            do {
                let saved = try await Task.detached(priority: .userInitiated) { () throws -> MemoryStateFile in
                    var revisions: [UUID: String] = [:]
                    for (id, url) in targets {
                        if let data = try? Data(contentsOf: url) { revisions[id] = MemoryStateStore.revision(data) }
                    }
                    let now = Date()
                    return try MemoryStateStore.update(root: root) { change(&$0, revisions, now) }
                }.value
                memoryState = saved
                libraryUndo.append(.memoryState(MemoryStateUndo(title: title, previous: previous)))
            } catch {
                mutationFailure(error, title: "The change couldn’t be saved.")
            }
        }
    }

    /// Undo: reverses an Archive or Restore move first, then puts the earlier entries back.
    func undoMemoryState(_ undo: MemoryStateUndo, root: URL) async throws {
        let engine = try LibraryMutations(root: root)
        for plan in undo.moves.reversed() {
            do { _ = try await commitMove(plan, using: engine) } catch MovePlanError.changed {
                _ = try await commitMove(engine.planRestore(plan.changes), using: engine)
            }
        }
        let previous = undo.previous
        memoryState = try await Task.detached(priority: .userInitiated) {
            try MemoryStateStore.update(root: root) { state in
                for (id, entry) in previous { state[id] = entry }
            }
        }.value
    }
}

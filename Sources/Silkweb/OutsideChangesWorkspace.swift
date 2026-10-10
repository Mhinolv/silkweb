import AppKit
import SilkwebCore

/// #230: Library changes that came neither through Silkweb nor through the helper. Detection runs off the main
/// thread after every snapshot or receipt change (the debounced watcher), never on keystrokes, and never writes to a
/// Document. Silkweb's own creates, moves, imports and saves, and the owner's Keep, go into a versioned sidecar.
extension LibraryWorkspace {
    nonisolated static func loadOutsideLedger(root: URL) async -> OutsideChangeLedger? {
        await Task.detached(priority: .utility) { () -> OutsideChangeLedger? in
            do { return try OutsideChangeLedger.load(root: root) } catch {
                NSLog("Silkweb could not read the outside-changes ledger: %@", error.localizedDescription)
                // A newer build's ledger turns detection off, so it's never overwritten; an undecodable one starts
                // over, like a Library this feature hasn't seen yet.
                return OutsideChangeLedger.isNewer(error) ? nil : OutsideChangeLedger()
            }
        }.value
    }

    func resetOutsideChanges() {
        outsideTask?.cancel()
        outsideTask = nil
        outsideSaveTask?.cancel()
        outsideSaveTask = nil
        outsideGeneration += 1
        outsideLedger = nil
        outsideUnsaved = [:]
        pendingSilkwebSaves = [:]
        outsideDetector = OutsideChangeDetector()
        outsideFilter = false
        outsideChanges = []
    }

    /// Agent Activity's list: with All Agents, receipts and outside changes, newest first and each Document once;
    /// with one agent, its receipts only; with Outside Silkweb, the outside changes only.
    var agentActivityDocuments: [LibraryDocument] {
        if outsideFilter { return Self.newestFirst(outsideChanges.map { ($0.document, $0.document.modified) }) }
        let entries = agentEntries.filter { agentFilter == nil || $0.agent == agentFilter }
        guard agentFilter == nil, !outsideChanges.isEmpty else { return entries.map(\.document) }
        let outside = Set(outsideChanges.map(\.document.id))
        // A Document changed after its receipt sorts by the change.
        let receipts = entries.filter { !outside.contains($0.document.id) }.map {
            ($0.document, $0.date ?? $0.document.created)
        }
        return Self.newestFirst(receipts + outsideChanges.map { ($0.document, $0.document.modified) })
    }

    /// The sidebar row's `(n)`: every Document All Agents lists.
    var agentActivityCount: Int {
        guard !outsideChanges.isEmpty else { return agentEntries.count }
        return Set(agentEntries.map(\.document.id)).union(outsideChanges.map(\.document.id)).count
    }

    private static func newestFirst(_ items: [(LibraryDocument, Date?)]) -> [LibraryDocument] {
        items.sorted { lhs, rhs in
            switch (lhs.1, rhs.1) {
            case (let left?, let right?) where left != right: return left > right
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.0.relativePath.localizedStandardCompare(rhs.0.relativePath) == .orderedAscending
            }
        }.map(\.0)
    }

    /// The flag Info and the row describe for one Document, in any scope.
    func outsideChange(for document: LibraryDocument) -> OutsideChange? {
        outsideByPath[document.relativePath].flatMap { $0.document.id == document.id ? $0 : nil }
    }

    // MARK: Detection

    /// Runs after the current snapshot and receipts; an older request that hasn't started is dropped.
    func scheduleOutsideDetection() {
        outsideGeneration += 1
        let generation = outsideGeneration
        guard let snapshot, outsideLedger != nil else {
            outsideTask?.cancel()
            if !outsideChanges.isEmpty { outsideChanges = [] }
            return
        }
        resolvePendingSaves(in: snapshot)
        let entries = agentEntries
        let pending = agentActivity.pendingDigests
        let previous = outsideTask
        outsideTask = Task {
            await previous?.value
            guard !Task.isCancelled, generation == outsideGeneration, let ledger = outsideLedger else { return }
            let detector = outsideDetector
            let (found, updated) = await Task.detached(priority: .utility) {
                var detector = detector
                let found = detector.detect(
                    snapshot: snapshot, entries: entries, ledger: ledger, pendingDigests: pending)
                return (found, detector)
            }.value
            guard !Task.isCancelled, generation == outsideGeneration else { return }
            outsideDetector = updated
            outsideChanges = found
        }
    }

    /// Waits until the detection for the current snapshot and receipts has landed.
    func waitForOutsideDetection() async {
        var generation: Int
        repeat {
            generation = outsideGeneration
            await outsideTask?.value
        } while generation != outsideGeneration
    }

    // MARK: Silkweb's own writes

    /// A save Silkweb made (#230): the saved bytes are accounted for, so they're never “outside Silkweb”. Only
    /// Documents detection looks at are recorded: under `Memory/`, with a receipt, or flagged.
    func noteSilkwebSave(_ url: URL, digest: String) {
        guard let snapshot, outsideLedger != nil else { return }
        let prefix = snapshot.rootURL.path + "/"
        let file = url.standardizedFileURL.path
        guard file.hasPrefix(prefix) else { return }
        let path = String(file.dropFirst(prefix.count))
        guard let id = snapshot.metadata.IDsByPath[path] else {
            // A conflict copy or Save Again: the index learns it on the next scan.
            if OutsideChangeDetector.isInMemory(path) { pendingSilkwebSaves[path] = digest }
            return
        }
        guard
            OutsideChangeDetector.isInMemory(path) || agentEntriesByPath[path] != nil || outsideByPath[path] != nil
        else { return }
        record([id.uuidString: digest])
        if outsideByPath[path] != nil { scheduleOutsideDetection() }
    }

    /// Saves whose path the index now knows become ledger entries.
    private func resolvePendingSaves(in snapshot: LibrarySnapshot) {
        guard !pendingSilkwebSaves.isEmpty else { return }
        var resolved: [String: String] = [:]
        for (path, digest) in pendingSilkwebSaves {
            guard let id = snapshot.metadata.IDsByPath[path] else { continue }
            resolved[id.uuidString] = digest
            pendingSilkwebSaves[path] = nil
        }
        if !resolved.isEmpty { record(resolved) }
    }

    /// Documents Silkweb just created, imported, moved or restored at `paths` (Folders include what's inside) that
    /// are new to the ledger. Called with the new snapshot before it's installed, so they never show as flagged.
    func accountSilkwebChanges(_ paths: [String], in scanned: LibrarySnapshot) async {
        guard let ledger = outsideLedger, !paths.isEmpty else { return }
        let flagged = Set(outsideChanges.map(\.document.id))
        let documents = scanned.documents.filter { document in
            OutsideChangeDetector.isInMemory(document.relativePath) && ledger.digest(for: document.id) == nil
                && !flagged.contains(document.id)
                && paths.contains { document.relativePath == $0 || document.relativePath.hasPrefix($0 + "/") }
        }
        guard !documents.isEmpty else { return }
        let root = scanned.rootURL
        let digests = await Task.detached(priority: .utility) {
            OutsideChangeDetector.digests(documents, root: root)
        }.value
        guard self.root == root || snapshot?.rootURL == root else { return }
        record(digests)
    }

    private func record(_ entries: [String: String]) {
        guard outsideLedger != nil, !entries.isEmpty else { return }
        outsideLedger?.documents.merge(entries) { _, new in new }
        outsideUnsaved.merge(entries) { _, new in new }
        outsideSaveTask?.cancel()
        outsideSaveTask = Task {
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            await persistOutsideLedgerNow()
        }
    }

    /// Writes the unsaved ledger entries now (atomic, merged with the file). A read-only Library keeps them in memory.
    func persistOutsideLedgerNow() async {
        guard let snapshot, !snapshot.isReadOnly, !outsideUnsaved.isEmpty else { return }
        let entries = outsideUnsaved
        outsideUnsaved = [:]
        do {
            _ = try await Task.detached(priority: .utility) {
                try OutsideChangeLedger.merge(
                    entries, root: snapshot.rootURL, existing: Set(snapshot.documents.map(\.id)))
            }.value
        } catch {
            outsideUnsaved.merge(entries) { current, _ in current }
            NSLog("Silkweb could not save the outside-changes ledger: %@", error.localizedDescription)
        }
    }

    // MARK: Keep and Move to Trash

    var canKeepOutsideChanges: Bool { canMutate && outsideLedger != nil }

    /// The flagged Documents among `paths`, or among the selection when `path` is part of it.
    func outsidePaths(_ path: String) -> [String] {
        documentDragPaths(path).filter { outsideByPath[$0] != nil }
    }

    /// Keep: the current bytes are accounted for. The flag comes back only if the file changes again (and has an
    /// envelope). Nothing is written to the Document.
    func keepOutsideChanges(_ paths: [String]) async {
        guard canKeepOutsideChanges, let root = snapshot?.rootURL else { return }
        let documents = paths.compactMap { outsideByPath[$0]?.document }
        guard !documents.isEmpty else { return }
        let digests = await Task.detached(priority: .utility) {
            OutsideChangeDetector.digests(documents, root: root)
        }.value
        guard snapshot?.rootURL == root else { return }
        record(digests)
        outsideSaveTask?.cancel()
        await persistOutsideLedgerNow()
        scheduleOutsideDetection()
        await waitForOutsideDetection()
    }

    /// Move to Trash…: the existing Trash command, with its confirmation rules and Undo.
    func trashOutsideChanges(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        requestTrash(paths, pane: 1)
    }
}

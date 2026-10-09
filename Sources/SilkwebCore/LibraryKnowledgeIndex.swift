import Foundation

/// The app's knowledge index for one Library (#177): a `KnowledgeGraph` fed from scanner snapshots (load, saves,
/// Library actions and the watcher's debounced reconciliation; never editor keystrokes), with its checkpoint in
/// `~/Library/Caches/Silkweb/knowledge/<Library name>-<hash>/`. The Markdown files stay the source of truth: the
/// cache is disposable, separate from the helper's per-grant caches, and nothing here writes into the Library,
/// takes the Library gate or touches `.silkweb/`. Reads and parsing run on workers, never on the main actor.
public actor LibraryKnowledgeIndex {
    public nonisolated let root: URL
    public nonisolated let store: KnowledgeCacheStore
    public private(set) var graph = KnowledgeGraph()
    /// Why the checkpoint couldn't be used at the first reconcile, if it couldn't.
    public private(set) var discarded: KnowledgeCacheStore.Discard?
    private var loaded = false
    private var loading: Task<KnowledgeCacheStore.Loaded, Never>?
    private var generation = 0
    private let checkpointDelay: Duration
    private var publishedRevision = 0
    private var checkpointWrite: Task<Void, Never>?
    private var checkpointWriting: Task<Void, Never>?

    /// `cacheDirectory` holds one folder per Library. Checkpoint writes are coalesced: one write
    /// `checkpointDelay` after the last change.
    public init(
        root: URL, cacheDirectory: URL = LibraryKnowledgeIndex.defaultCacheDirectory(),
        checkpointDelay: Duration = .seconds(2)
    ) {
        let root = root.standardizedFileURL
        self.root = root
        store = KnowledgeCacheStore(
            directory: cacheDirectory.appendingPathComponent(Self.cacheName(root: root), isDirectory: true),
            library: root.path)
        self.checkpointDelay = checkpointDelay
    }

    /// `~/Library/Caches/Silkweb/knowledge`, which macOS may purge; Silkweb rebuilds it.
    public static func defaultCacheDirectory() -> URL {
        let caches =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("Silkweb/knowledge", isDirectory: true)
    }

    /// The Library's folder name, readable in Finder, plus a hash of its full path.
    public static func cacheName(root: URL) -> String {
        let path = root.standardizedFileURL.path
        var name = root.lastPathComponent.replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        let hash = DocumentRevision(data: Data(path.utf8)).digest.prefix(16)
        return (name.isEmpty ? "Library" : name) + "-" + hash
    }

    static func listing(_ snapshot: LibrarySnapshot) -> KnowledgeGraph.Listing {
        KnowledgeGraph.Listing(
            documents: snapshot.documents.map { document in
                // A rename keeps the inode and date, so a moved Document isn't read again; a save changes both.
                let stamp = document.fileIdentity.flatMap { identity in
                    document.modified.map { "\(identity)@\($0.timeIntervalSinceReferenceDate)" }
                }
                return .init(path: document.relativePath, stamp: stamp, documentID: document.id)
            },
            folders: snapshot.folders.map(\.relativePath), caseSensitive: snapshot.caseSensitive)
    }

    /// Brings the index up to `snapshot`. Stale edges and postings of changed Documents are dropped before the
    /// first read, so queries say "not ready" for them instead of answering from the old revision. A newer
    /// reconcile or cancellation stops this one between Documents.
    public func reconcile(_ snapshot: LibrarySnapshot) async throws {
        guard snapshot.rootURL.standardizedFileURL == root else { throw LibraryError.invalidRoot }
        generation += 1
        let token = generation
        if !loaded {
            // Overlapping first reconciles share one load; the first to resume installs it.
            let store = store
            let load = loading ?? Task.detached(priority: .utility) { store.load() }
            loading = load
            let result = await load.value
            if !loaded {
                loaded = true
                restore(result)
            }
        }
        guard token == generation else { throw CancellationError() }
        let listing = await Task.detached(priority: .utility) { Self.listing(snapshot) }.value
        guard token == generation else { throw CancellationError() }
        let needed = graph.apply(listing)
        defer { if graph.revision != publishedRevision { scheduleCheckpoint() } }
        let documents = Dictionary(
            snapshot.documents.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        for entry in needed {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            guard let document = documents[entry.path] else { continue }
            let root = root
            let content = await Task.detached(priority: .utility) { () -> KnowledgeContent in
                // Unreadable or non-UTF-8: indexed as empty until the file changes, like the helper's `skipped`.
                guard let text = try? await LibraryScanner.readDocument(document, root: root) else { return .empty }
                return KnowledgeContent(text: text)
            }.value
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            graph.install(entry, content: content)
        }
    }

    private func restore(_ result: KnowledgeCacheStore.Loaded) {
        switch result {
        case .restored(_, let records):
            graph = KnowledgeGraph(records: records)
            publishedRevision = graph.revision
        case .discarded(let reason):
            if reason != .missing { discarded = reason }
            publishedRevision = -1
        }
    }

    // MARK: Queries

    public func document(_ path: String) -> KnowledgeLookup<KnowledgeRecord> { graph.document(path) }

    public func links(from path: String, kind: KnowledgeEdgeKind = .linksTo) -> KnowledgeLookup<[KnowledgeEdge]> {
        graph.links(from: path, kind: kind)
    }

    public func links(to path: String, kind: KnowledgeEdgeKind = .linksTo) -> KnowledgeLookup<[KnowledgeEdge]> {
        graph.links(to: path, kind: kind)
    }

    public func postings(for term: String) -> KnowledgeLookup<[String: KnowledgePosting]> {
        graph.postings(for: term)
    }

    // MARK: Checkpoint

    /// Writes a pending checkpoint now (tests). Quitting drops it instead: the cache is disposable.
    public func flushCheckpoint() async {
        checkpointWrite?.cancel()
        await writeCheckpointIfNeeded()
    }

    private func scheduleCheckpoint() {
        checkpointWrite?.cancel()
        let delay = checkpointDelay
        checkpointWrite = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            await self.writeCheckpointIfNeeded()
        }
    }

    private func writeCheckpointIfNeeded() async {
        guard graph.revision != publishedRevision else { return }
        publishedRevision = graph.revision
        // Pending Documents aren't in `records`; they're read again after a restore.
        let records = Array(graph.records.values)
        let store = store
        let previous = checkpointWriting
        let writing = Task.detached(priority: .utility) {
            await previous?.value
            do { try store.publish(records) } catch {
                KnowledgeCacheStore.log.info(
                    "Knowledge cache not written: \(error.localizedDescription, privacy: .public)")
            }
        }
        checkpointWriting = writing
        await writing.value
    }
}

import Foundation
import SilkwebCore

/// Feeds the window's Library into its knowledge index (#177). Called with every installed snapshot (load, saves,
/// Library actions, the watcher's debounced reconciliation), never from editor text changes. Nothing is
/// published to the UI; the index's own actor does all reading and parsing.
@MainActor
final class LibraryKnowledge {
    /// `~/Library/Caches/Silkweb/knowledge`; tests never write into the user's Caches.
    static let cacheDirectory =
        NSClassFromString("XCTestCase") == nil
        ? LibraryKnowledgeIndex.defaultCacheDirectory()
        : FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebTests-knowledge-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    private(set) var index: LibraryKnowledgeIndex?
    private var task: Task<Void, Never>?
    #if DEBUG
        /// Test seam: snapshots handed to the index.
        private(set) var reconcileCount = 0
    #endif

    deinit { task?.cancel() }

    func install(_ snapshot: LibrarySnapshot) {
        if index?.root != snapshot.rootURL.standardizedFileURL {
            index = LibraryKnowledgeIndex(root: snapshot.rootURL, cacheDirectory: Self.cacheDirectory)
        }
        task?.cancel()
        guard let index else { return }
        #if DEBUG
            reconcileCount += 1
        #endif
        task = Task(priority: .utility) {
            // Superseded or cancelled work is redone by the next snapshot; failures leave the old index.
            try? await index.reconcile(snapshot)
        }
    }

    /// The Library closed: unfinished work is dropped (the index is disposable).
    func reset() {
        task?.cancel()
        task = nil
        index = nil
    }

    func waitForIndex() async { await task?.value }
}

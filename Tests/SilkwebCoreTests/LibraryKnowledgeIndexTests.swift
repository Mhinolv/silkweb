import Darwin
import XCTest

@testable import SilkwebCore

/// #177: the app's knowledge index on a real Library, its disposable checkpoints, and the helper's per-grant copy.
final class LibraryKnowledgeIndexTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var caches: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Knowledge-\(UUID().uuidString)")
        library = root.appendingPathComponent("Writing")
        caches = root.appendingPathComponent("Caches/Silkweb/knowledge")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ path: String, _ text: String) throws -> URL {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Every entry under the Library with its kind, size and dates.
    private func tree() throws -> [String: String] {
        var result: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(atPath: library.path)!
        while let path = enumerator.nextObject() as? String {
            let attributes = try FileManager.default.attributesOfItem(atPath: library.appendingPathComponent(path).path)
            result[path] = [
                "\(attributes[.type] ?? "")", "\(attributes[.size] ?? "")",
                "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)",
            ].joined(separator: " ")
        }
        return result
    }

    private func index(delay: Duration = .seconds(60)) -> LibraryKnowledgeIndex {
        LibraryKnowledgeIndex(root: library, cacheDirectory: caches, checkpointDelay: delay)
    }

    /// A graph built from scratch for the Library as it is now, with no cache.
    private func rebuilt(_ snapshot: LibrarySnapshot) async throws -> KnowledgeGraph {
        let fresh = LibraryKnowledgeIndex(root: library, cacheDirectory: root.appendingPathComponent("Fresh-\(UUID())"))
        try await fresh.reconcile(snapshot)
        return await fresh.graph
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func records(_ names: [String]) -> [KnowledgeRecord] {
        names.map { KnowledgeRecord(path: $0 + ".md", stamp: $0, documentID: nil, content: KnowledgeContent(body: $0)) }
    }

    // MARK: App index

    func testIncrementalUpdatesOnDiskMatchAFullRebuild() async throws {
        try write("Hub.md", "# Hub\n[a](Notes/A.md) [b](Notes/B.md) [gone](Old.md)")
        try write("Notes/A.md", "Alpha [hub](../Hub.md)")
        try write("Old.md", "old")
        let index = index()
        var snapshot = try await LibraryScanner.scan(root: library)
        try await index.reconcile(snapshot)
        var graph = await index.graph
        XCTAssertEqual(graph.links(from: "Hub.md").value?.map(\.target), ["Notes/A.md", "Old.md"])
        XCTAssertEqual(graph.document("Hub.md").value?.documentID, snapshot.metadata.IDsByPath["Hub.md"])
        try await assertEqualIgnoringOrder(graph, try await rebuilt(snapshot))

        // Create, edit, move (rename a Folder) and delete, then reconcile like the watcher does.
        try write("Notes/B.md", "Beta")
        try write("Notes/A.md", "Alpha edited, no links")
        try FileManager.default.moveItem(
            at: library.appendingPathComponent("Notes"), to: library.appendingPathComponent("Ideas"))
        try FileManager.default.removeItem(at: library.appendingPathComponent("Old.md"))
        try write("Hub.md", "# Hub\n[a](Ideas/A.md) [b](Ideas/B.md)")
        snapshot = try await LibraryScanner.scan(root: library, previousSnapshot: snapshot)
        try await index.reconcile(snapshot)
        graph = await index.graph
        XCTAssertEqual(graph.links(from: "Hub.md").value?.map(\.target), ["Ideas/A.md", "Ideas/B.md"])
        XCTAssertEqual(graph.links(to: "Hub.md").value, [])
        XCTAssertEqual(graph.document("Old.md"), .notFound)
        XCTAssertEqual(graph.postings(for: "edited").value?.keys.sorted(), ["Ideas/A.md"])
        try await assertEqualIgnoringOrder(graph, try await rebuilt(snapshot))

        // A move alone reads nothing again: the stamp (file identity and date) is unchanged.
        try FileManager.default.moveItem(
            at: library.appendingPathComponent("Ideas/B.md"), to: library.appendingPathComponent("B moved.md"))
        snapshot = try await LibraryScanner.scan(root: library, previousSnapshot: snapshot)
        let before = await index.graph.records["Ideas/B.md"]
        try await index.reconcile(snapshot)
        graph = await index.graph
        XCTAssertEqual(graph.records["B moved.md"]?.stamp, before?.stamp)
        XCTAssertEqual(graph.links(from: "Hub.md").value?.map(\.target), ["Ideas/A.md"])
        try await assertEqualIgnoringOrder(graph, try await rebuilt(snapshot))
    }

    /// Two graphs from the same Library are equal except for `revision` bookkeeping.
    private func assertEqualIgnoringOrder(
        _ lhs: KnowledgeGraph, _ rhs: KnowledgeGraph, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertEqual(lhs, rhs, file: file, line: line)
        XCTAssertTrue(lhs.isReady, file: file, line: line)
    }

    func testCheckpointRestoresAndOnlyChangedDocumentsAreReadAgain() async throws {
        try write("A.md", "[b](B.md)")
        try write("B.md", "bee")
        var snapshot = try await LibraryScanner.scan(root: library)
        let first = index()
        try await first.reconcile(snapshot)
        await first.flushCheckpoint()
        let folder = caches.appendingPathComponent(LibraryKnowledgeIndex.cacheName(root: library))
        XCTAssertTrue(folder.lastPathComponent.hasPrefix("Writing-"), "readable per-Library folder name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try permissions(folder), 0o700)
        XCTAssertEqual(try permissions(folder.appendingPathComponent("manifest.json")), 0o600)

        try write("B.md", "bee changed while closed")
        snapshot = try await LibraryScanner.scan(root: library, previousSnapshot: snapshot)
        let second = index()
        try await second.reconcile(snapshot)
        let graph = await second.graph
        let discarded = await second.discarded
        XCTAssertNil(discarded)
        XCTAssertEqual(graph.postings(for: "closed").value?.keys.sorted(), ["B.md"])
        XCTAssertEqual(graph.links(to: "B.md").value?.map(\.source), ["A.md"])
        try await assertEqualIgnoringOrder(graph, try await rebuilt(snapshot))
    }

    func testOverlappingFirstReconcilesShareOneCheckpointLoad() async throws {
        try write("A.md", "[b](B.md)")
        try write("B.md", "bee")
        let first = try await LibraryScanner.scan(root: library)
        let seed = index()
        try await seed.reconcile(first)
        await seed.flushCheckpoint()
        try write("A.md", "[c](C.md)")
        try write("C.md", "sea")
        let second = try await LibraryScanner.scan(root: library, previousSnapshot: first)
        let index = index()
        // The second starts while the first is still loading the checkpoint; it must not be overwritten by it.
        async let older: Void = index.reconcile(second)
        async let newer: Void = index.reconcile(second)
        _ = try? await older
        _ = try? await newer
        let graph = await index.graph
        XCTAssertEqual(graph.links(from: "A.md").value?.map(\.target), ["C.md"])
        try await assertEqualIgnoringOrder(graph, try await rebuilt(second))
    }

    func testCorruptNewerOrForeignCachesRebuildWithoutWritingIntoTheLibrary() async throws {
        try write("A.md", "[b](B.md)")
        try write("B.md", "bee")
        let snapshot = try await LibraryScanner.scan(root: library)
        let expected = try await rebuilt(snapshot)
        let folder = caches.appendingPathComponent(LibraryKnowledgeIndex.cacheName(root: library))
        let manifest = folder.appendingPathComponent("manifest.json")
        let cases: [(String, Data, KnowledgeCacheStore.Discard?)] = [
            ("corrupt", Data("{not json".utf8), .corrupt),
            (
                "newer", Data(#"{"version":99,"library":"\#(library.standardizedFileURL.path)","generation":1}"#.utf8),
                .unsupportedVersion
            ),
            (
                "foreign",
                Data(#"{"version":1,"library":"/elsewhere","generation":1,"checkpoint":"checkpoint-1.json"}"#.utf8),
                .otherLibrary
            ),
            (
                "dangling",
                Data(
                    #"{"version":1,"library":"\#(library.standardizedFileURL.path)","generation":3,"checkpoint":"checkpoint-3.json"}"#
                        .utf8), .corrupt
            ),
        ]
        for (name, data, reason) in cases {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: manifest)
            let before = try tree()
            let index = index()
            try await index.reconcile(snapshot)
            let discarded = await index.discarded
            let graph = await index.graph
            XCTAssertEqual(discarded, reason, name)
            XCTAssertEqual(graph, expected, name)
            await index.flushCheckpoint()
            XCTAssertEqual(try tree(), before, "\(name): nothing written into the Library")
            guard case .restored(_, let records) = index.store.load() else { return XCTFail(name) }
            XCTAssertEqual(records.count, 2, name)
        }
    }

    func testACheckpointFromAnEarlierShapeStillLoads() throws {
        let store = KnowledgeCacheStore(directory: caches.appendingPathComponent("Old"), library: "/L")
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        // Only the keys an earlier build is guaranteed to have written.
        try Data(#"{"library":"/L","generation":1,"checkpoint":"checkpoint-1.json"}"#.utf8).write(to: store.manifestURL)
        try Data(
            #"{"library":"/L","generation":1,"records":[{"path":"A.md"},{"path":"B.md","content":{"links":["A.md"]}}]}"#
                .utf8
        )
        .write(to: store.directory.appendingPathComponent("checkpoint-1.json"))
        guard case .restored(1, let records) = store.load() else { return XCTFail("not restored") }
        var graph = KnowledgeGraph(records: records)
        XCTAssertEqual(
            graph.apply(
                .init(
                    documents: [.init(path: "A.md", stamp: nil), .init(path: "B.md", stamp: nil)], folders: [],
                    caseSensitive: false)
            ).count,
            2, "records without a stamp are read again")
        XCTAssertEqual(records.map(\.content.links), [[], ["A.md"]])
    }

    func testIndexingRunsOffTheMainActor() async throws {
        try write("A.md", "[b](B.md)")
        try write("B.md", "bee")
        let snapshot = try await LibraryScanner.scan(root: library)
        let index = index()
        // Started from the main actor, as the app does; the actor and its workers never run on the main thread.
        try await MainActor.run {
            XCTAssertTrue(Thread.isMainThread)
            return Task { try await index.reconcile(snapshot) }
        }.value
        let graph = await index.graph
        XCTAssertEqual(graph.links(from: "A.md").value?.map(\.target), ["B.md"])
    }

    // MARK: Checkpoint publication

    func testACrashAtAnyPublicationStepLeavesThePreviousGeneration() throws {
        let store = KnowledgeCacheStore(directory: caches.appendingPathComponent("Crash"), library: "/L")
        XCTAssertEqual(store.load(), .discarded(.missing))
        XCTAssertEqual(try store.publish(records(["one"])), 1)
        for step in KnowledgeCacheStore.Step.allCases {
            XCTAssertThrowsError(try store.publish(records(["two", "three"]), crashAfter: step))
            XCTAssertEqual(store.load(), .restored(generation: 1, records: records(["one"])), "\(step)")
        }
        // A crash never advances the manifest. The next publisher cleans up what the crashed ones left.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertTrue(leftovers.contains { $0.hasSuffix(".tmp") })
        XCTAssertEqual(try store.publish(records(["four"])), 2)
        XCTAssertEqual(store.load(), .restored(generation: 2, records: records(["four"])))
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted(),
            ["checkpoint-2.json", "manifest.json", "publish.lock"])
        for entry in ["checkpoint-2.json", "manifest.json", "publish.lock"] {
            XCTAssertEqual(try permissions(store.directory.appendingPathComponent(entry)), 0o600, entry)
        }
        XCTAssertEqual(try permissions(store.directory), 0o700)

        // A corrupt or vanished checkpoint behind a good manifest is a rebuild, never a partial load.
        try Data("{".utf8).write(to: store.directory.appendingPathComponent("checkpoint-2.json"))
        XCTAssertEqual(store.load(), .discarded(.corrupt))
        try FileManager.default.removeItem(at: store.directory.appendingPathComponent("checkpoint-2.json"))
        XCTAssertEqual(store.load(), .discarded(.corrupt))
        XCTAssertEqual(try store.publish(records(["five"])), 3)
        XCTAssertEqual(store.load(), .restored(generation: 3, records: records(["five"])))
    }

    func testConcurrentPublishersTakeTurnsAndTheLastOneWins() throws {
        let directory = caches.appendingPathComponent("Concurrent")
        let count = 12
        let results = UnsafeMutableBufferPointer<Int>.allocate(capacity: count)
        defer { results.deallocate() }
        // Separate store values, as separate windows or processes would have.
        DispatchQueue.concurrentPerform(iterations: count) { worker in
            let store = KnowledgeCacheStore(directory: directory, library: "/L")
            if worker % 3 == 0 { _ = try? store.publish(records(["crash\(worker)"]), crashAfter: .checkpointPublished) }
            results[worker] = (try? store.publish(records(["w\(worker)"]))) ?? -1
            _ = store.load()
        }
        let generations = Array(results)
        XCTAssertFalse(generations.contains(-1))
        let store = KnowledgeCacheStore(directory: directory, library: "/L")
        guard case .restored(let generation, let loaded) = store.load() else { return XCTFail("no checkpoint") }
        // Deterministic: the manifest names the highest generation, written by exactly one publisher.
        let last = try XCTUnwrap(generations.firstIndex(of: generations.max()!))
        XCTAssertEqual(generation, generations.max())
        XCTAssertEqual(loaded, records(["w\(last)"]))
        XCTAssertEqual(Set(generations).count, count, "every publisher got its own generation")
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(files.filter(KnowledgeCacheStore.isCheckpointName), ["checkpoint-\(generation).json"])
        XCTAssertFalse(files.contains { $0.hasSuffix(".tmp") })
    }

    // MARK: Helper

    func testTheHelperKeepsItsOwnScopedCachePerGrant() async throws {
        let grantsURL = root.appendingPathComponent("grants/agent-grants.json")
        try AgentGrantFile(grants: [
            AgentGrant(
                project: "Silkweb", library: LibraryLocation(path: library.path), access: .read,
                extraReadFolders: [], label: "Silkweb project")
        ]).write(to: grantsURL)
        try write("Memory/Projects/Silkweb/Plan.md", "# Plan\n[d](Decision.md) [secret](../../../Private/Journal.md)")
        try write("Memory/Projects/Silkweb/Decision.md", "Use library.lock")
        try write("Private/Journal.md", "canary")
        let helperCaches = AgentMemoryService.defaultCacheDirectory(home: root)
        let service = AgentMemoryService(
            session: AgentSession(project: "Silkweb", store: AgentGrantStore(url: grantsURL)),
            cacheDirectory: helperCaches)
        let graph = try service.knowledgeGraph()
        XCTAssertEqual(
            graph.links(from: "Memory/Projects/Silkweb/Plan.md").value?.map(\.target),
            ["Memory/Projects/Silkweb/Decision.md"], "an edge out of scope is simply absent")
        XCTAssertEqual(graph.document("Private/Journal.md"), .notFound)
        XCTAssertNil(graph.postings["canary"])
        XCTAssertEqual(
            graph.postings(for: "library.lock").value?.keys.sorted(), ["Memory/Projects/Silkweb/Decision.md"])
        XCTAssertEqual(
            service.knowledgeCacheURL,
            helperCaches.appendingPathComponent(AgentMemoryService.grantID(project: "Silkweb") + ".knowledge"))
        XCTAssertEqual(try permissions(service.knowledgeCacheURL), 0o700)
        XCTAssertEqual(try permissions(service.knowledgeCacheURL.appendingPathComponent("manifest.json")), 0o600)

        // The app's index for the same Library is a separate instance in a separate place.
        let snapshot = try await LibraryScanner.scan(root: library)
        let app = index()
        try await app.reconcile(snapshot)
        await app.flushCheckpoint()
        XCTAssertNotEqual(app.store.directory, service.knowledgeCacheURL)
        XCTAssertFalse(app.store.directory.path.hasPrefix(helperCaches.path))
        let appGraph = await app.graph
        XCTAssertEqual(appGraph.links(from: "Memory/Projects/Silkweb/Plan.md").value?.count, 2)

        // A restarted helper restores its checkpoint and follows edits.
        try write("Memory/Projects/Silkweb/Decision.md", "Use flock now")
        let restarted = AgentMemoryService(
            session: AgentSession(project: "Silkweb", store: AgentGrantStore(url: grantsURL)),
            cacheDirectory: helperCaches)
        let updated = try restarted.knowledgeGraph()
        XCTAssertEqual(updated.postings(for: "flock").value?.keys.sorted(), ["Memory/Projects/Silkweb/Decision.md"])
        XCTAssertEqual(updated.postings(for: "library.lock").value, [:])
        XCTAssertEqual(
            updated.links(to: "Memory/Projects/Silkweb/Decision.md").value?.map(\.source),
            ["Memory/Projects/Silkweb/Plan.md"])

        // Revoking the grant deletes its knowledge cache with the JSON cache.
        try AgentGrantFile(grants: [
            AgentGrant(
                project: "Silkweb", library: LibraryLocation(path: library.path), access: .read,
                extraReadFolders: [], label: "Silkweb project", revokedAt: Date())
        ]).write(to: grantsURL)
        XCTAssertThrowsError(try restarted.knowledgeGraph())
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.knowledgeCacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: restarted.cacheURL.path))
    }
}

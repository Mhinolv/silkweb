import Foundation
import XCTest
@testable import SilkwebCore

final class SearchIndexTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func note(_ path: String, _ body: String = "") throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: file, atomically: true, encoding: .utf8)
    }

    func testRankingLiteralMatchingAndSnippets() async throws {
        for name in ["Café", "Cafe society", "My cafe", "Decafeinated", "Body"] {
            try note(name + ".md", name == "Body" ? String(repeating: "intro ", count: 20) + "# **café** `tea` " + String(repeating: "tail ", count: 40) : "tea")
        }
        try note("Symbols.md", "literal \"quote\" tag:tea")
        let index = SearchIndex(root: root)
        try await index.reconcile(LibraryScanner.scan(root: root))
        let hits = try await index.query(SearchQuery("cafe"))
        XCTAssertEqual(hits.map(\.displayName), ["Café", "Cafe society", "My cafe", "Decafeinated", "Body"])
        XCTAssertEqual(hits.last?.matchKind, .body)
        let snippet = try XCTUnwrap(hits.last)
        XCTAssertTrue(snippet.snippet.hasPrefix("…"))
        XCTAssertTrue(snippet.snippet.hasSuffix("…"))
        XCTAssertFalse(snippet.snippet.contains("*"))
        XCTAssertEqual((snippet.snippet as NSString).substring(with: try XCTUnwrap(snippet.matchRanges.first)), "café")
        let both = try await index.query(SearchQuery("CAFE tea"))
        XCTAssertEqual(both.count, 5)
        let missing = try await index.query(SearchQuery("cafe absent"))
        XCTAssertTrue(missing.isEmpty)
        let literal = try await index.query(SearchQuery("\"quote\" tag:tea"))
        XCTAssertEqual(literal.map(\.displayName), ["Symbols"])
        let quick = try await index.query(SearchQuery("cafe", mode: .quickOpen))
        XCTAssertEqual(quick.count, 4)
    }

    func testRankingTiesUseDateThenName() async throws {
        try note("Alpha.md", "needle")
        try note("Beta.md", "needle")
        try note("Gamma.md", "needle")
        let snapshot = try await LibraryScanner.scan(root: root)
        let index = SearchIndex(root: root)
        try await index.reconcile(snapshot)
        for var document in snapshot.documents {
            document.modified = Date(timeIntervalSince1970: document.name == "Gamma.md" ? 20 : 10)
            await index.update(document, body: "needle")
        }
        let hits = try await index.query(SearchQuery("needle"))
        XCTAssertEqual(hits.map(\.displayName), ["Gamma", "Alpha", "Beta"])
    }

    func testScopesLimitsEmptyQueriesAndRecents() async throws {
        try note("Writing/One.md", "needle")
        try note("Writing/Drafts/Two.md", "needle")
        try note("WritingElse/Three.md", "needle")
        let snapshot = try await LibraryScanner.scan(root: root)
        let folder = try XCTUnwrap(snapshot.folders.first { $0.relativePath == "Writing" })
        let index = SearchIndex(root: root)
        try await index.reconcile(snapshot)
        for mode in [SearchQuery.Mode.library, .quickOpen] {
            for descendants in [false, true] {
                let results = try await index.query(SearchQuery("", scope: .folder(folder.id, includeSubfolders: descendants), mode: mode))
                XCTAssertEqual(results.count, descendants ? 2 : 1)
            }
            for limit in [-1, 0, 1, Int.max] {
                let results = try await index.query(SearchQuery("  \n ", mode: mode, limit: limit))
                XCTAssertEqual(results.count, limit <= 0 ? 0 : min(limit, 3))
            }
        }
        let unknown = try await index.query(SearchQuery("", scope: .folder(UUID(), includeSubfolders: true)))
        XCTAssertTrue(unknown.isEmpty)
        let one = try XCTUnwrap(snapshot.documents.first { $0.name == "One.md" })
        try await index.recordOpened(one.id)
        let quick = try await index.query(SearchQuery("", mode: .quickOpen))
        XCTAssertEqual(quick.first?.id, one.id)
        XCTAssertEqual(quick.first?.folderPathComponents, ["Writing"])
        let reopened = SearchIndex(root: root)
        try await reopened.reconcile(snapshot)
        let persisted = try await reopened.query(SearchQuery("", mode: .quickOpen))
        XCTAssertEqual(persisted.first?.id, one.id)
    }

    func testIncrementalEditsMovesDeletesAndReplacement() async throws {
        try note("First.md", "oldbody")
        var snapshot = try await LibraryScanner.scan(root: root)
        let index = SearchIndex(root: root)
        try await index.reconcile(snapshot)
        let original = snapshot.documents[0]
        await index.update(original, body: "savedbody")
        let saved = try await index.query(SearchQuery("savedbody"))
        XCTAssertEqual(saved.count, 1)
        let old = try await index.query(SearchQuery("oldbody"))
        XCTAssertTrue(old.isEmpty)
        try note("First.md", "externalbody")
        snapshot = try await LibraryScanner.scan(root: root, previousSnapshot: snapshot)
        try await index.reconcile(snapshot)
        let external = try await index.query(SearchQuery("externalbody"))
        XCTAssertEqual(external.count, 1)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Moved"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: root.appendingPathComponent("First.md"), to: root.appendingPathComponent("Moved/Renamed.md"))
        snapshot = try await LibraryScanner.scan(root: root, previousSnapshot: snapshot)
        try await index.reconcile(snapshot)
        let moved = try await index.query(SearchQuery("externalbody"))
        XCTAssertEqual(moved.first?.id, original.id)
        XCTAssertEqual(moved.first?.displayName, "Renamed")
        XCTAssertEqual(moved.first?.folderPathComponents, ["Moved"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("Moved/Renamed.md"))
        snapshot = try await LibraryScanner.scan(root: root, previousSnapshot: snapshot)
        try await index.reconcile(snapshot)
        let deleted = try await index.query(SearchQuery(""))
        XCTAssertTrue(deleted.isEmpty)
        try note("New.md", "replacement")
        snapshot = try await LibraryScanner.scan(root: root, previousSnapshot: snapshot)
        try await index.reconcile(snapshot)
        await index.remove(snapshot.documents[0].id)
        let removed = try await index.query(SearchQuery(""))
        XCTAssertTrue(removed.isEmpty)
    }

    func testCacheRecoveryTolerantFormatsAndOlderLibrary() async throws {
        try note("Old.md", "legacy body")
        let directory = root.appendingPathComponent(".silkweb")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{\"IDsByPath\":{}}".utf8).write(to: directory.appendingPathComponent("index.json"))
        let snapshot = try await LibraryScanner.scan(root: root)
        for cache in ["broken", "{\"formatVersion\":0}", "{\"formatVersion\":99}", "{}"] {
            try Data(cache.utf8).write(to: directory.appendingPathComponent("search-index.json"))
            try Data("{}".utf8).write(to: directory.appendingPathComponent("search-recents.json"))
            let index = SearchIndex(root: root)
            let stream = await index.states()
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            try await index.reconcile(snapshot)
            let firstState = await iterator.next()
            if cache == "broken" { XCTAssertEqual(firstState, .rebuilding(reason: .corrupt)) }
            else if cache != "{}" { XCTAssertEqual(firstState, .rebuilding(reason: .unsupportedVersion)) }
            else { XCTAssertEqual(firstState, .building(indexed: 0, total: 1)) }
            let state = await index.state
            XCTAssertEqual(state, .ready)
            let hits = try await index.query(SearchQuery("legacy"))
            XCTAssertEqual(hits.count, 1)
            let body = try String(contentsOf: root.appendingPathComponent("Old.md"), encoding: .utf8)
            XCTAssertEqual(body, "legacy body")
        }
        // Warm cache reuses scan tokens: no redundant read of an unchanged body.
        let warm = SearchIndex(root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Old.md"))
        try await warm.reconcile(snapshot)
        let hits = try await warm.query(SearchQuery("legacy"))
        XCTAssertEqual(hits.count, 1)
    }

    func testProgressConcurrentMutationAndCancelledBuildRecovery() async throws {
        for number in 0..<100 {
            try note("Note-\(number).md", String(repeating: "disk body ", count: 1000))
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        let index = SearchIndex(root: root)
        let stream = await index.states()
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        let build = Task { try await index.reconcile(snapshot) }
        let progress = await iterator.next()
        XCTAssertEqual(progress, .building(indexed: 0, total: 100))
        let changed = snapshot.documents[99], deleted = snapshot.documents[98]
        await index.update(changed, body: "new saved text")
        await index.remove(deleted.id)
        let during = try await index.query(SearchQuery("new saved text"))
        XCTAssertEqual(during.first?.id, changed.id)
        try await build.value
        let after = try await index.query(SearchQuery("new saved text"))
        XCTAssertEqual(after.first?.id, changed.id)
        let all = try await index.query(SearchQuery("", limit: 1000))
        XCTAssertFalse(all.contains { $0.id == deleted.id })
        XCTAssertEqual(all.count, 99)
        let cancelledIndex = SearchIndex(root: root)
        let cancelled = Task {
            while !Task.isCancelled { await Task.yield() }
            try await cancelledIndex.reconcile(snapshot)
        }
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        try await cancelledIndex.reconcile(snapshot)
        let ready = await cancelledIndex.state
        XCTAssertEqual(ready, .ready)
        let recovered = try await cancelledIndex.query(SearchQuery("", limit: 1000))
        XCTAssertEqual(recovered.count, 100)
    }

    func testSnippetUnicodeEmptyAndBoundarySweep() {
        for size in [0, 1, 119, 120, 121, 10000] {
            for body in [String(repeating: "a", count: size), String(repeating: "👩🏽‍💻é ", count: size)] {
                for terms in [[], ["a"], ["e"], ["absent"], ["👩🏽‍💻"]] {
                    let (snippet, ranges) = searchSnippet(body, terms: terms)
                    XCTAssertLessThanOrEqual(snippet.count, 124)
                    for range in ranges {
                        XCTAssertGreaterThan(range.length, 0)
                        XCTAssertLessThanOrEqual(NSMaxRange(range), (snippet as NSString).length)
                    }
                }
            }
        }
    }

    @MainActor
    func testTenThousandDocumentsPerformanceAndCancellation() async throws {
        for folder in 0..<1000 {
            for note in 0..<10 { try self.note("Folder-\(folder)/Note-\(note).md", "body needle café \(note)") }
        }
        let scanStart = Date()
        let snapshot = try await LibraryScanner.scan(root: root)
        let scanTime = Date().timeIntervalSince(scanStart)
        let index = SearchIndex(root: root)
        let buildStart = Date()
        try await index.reconcile(snapshot)
        let buildTime = Date().timeIntervalSince(buildStart)
        let queryStart = Date()
        let results = try await index.query(SearchQuery("needle cafe", limit: 10000))
        let queryTime = Date().timeIntervalSince(queryStart)
        print("Search benchmark: 10,000 documents / 1,000 folders; scan \(scanTime)s (10s budget), index \(buildTime)s (10s budget), query \(queryTime)s (1s budget)")
        XCTAssertEqual(results.count, 10000)
        XCTAssertLessThan(scanTime, 10)
        XCTAssertLessThan(buildTime, 10)
        XCTAssertLessThan(queryTime, 1)
        let cancelled = Task {
            try Task.checkCancellation()
            return try await index.query(SearchQuery("needle", limit: 10000))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        // Pre-cancelled calls exercise propagation into the detached query worker.
        let gated = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await index.query(SearchQuery("needle", limit: 10000))
        }
        gated.cancel()
        do { _ = try await gated.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let subsequent = try await index.query(SearchQuery("Note-0", mode: .quickOpen))
        XCTAssertEqual(subsequent.count, 100)
    }
}

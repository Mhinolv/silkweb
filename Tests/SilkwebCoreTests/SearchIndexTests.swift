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

    func testUnchangedReconcileDoesNotRewriteCache() async throws {
        try note("Coffee.md", "coffee")
        let index = SearchIndex(root: root)
        let snapshot = try await LibraryScanner.scan(root: root)
        let initial = try await index.reconcile(snapshot)
        XCTAssertTrue(initial)
        await index.flushCache()
        let cache = root.appendingPathComponent(".silkweb/search-index.json")
        let before = try FileManager.default.attributesOfItem(atPath: cache.path)
        for _ in 0..<5 {
            let changed = try await index.reconcile(LibraryScanner.scan(root: root, previousSnapshot: snapshot))
            XCTAssertFalse(changed)
        }
        let after = try FileManager.default.attributesOfItem(atPath: cache.path)
        XCTAssertEqual(before[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        try note("Tea.md", "tea")
        let added = try await index.reconcile(LibraryScanner.scan(root: root, previousSnapshot: snapshot))
        XCTAssertTrue(added)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Tea.md"))
        let removed = try await index.reconcile(LibraryScanner.scan(root: root, previousSnapshot: snapshot))
        XCTAssertTrue(removed)
    }

    /// 1.78: one autosave must not re-read or re-encode the library twice. The saved
    /// note is searchable at once; the cache file is written once, after the debounce.
    func testAutosaveUpdatesOneRecordAndDebouncesSingleCacheWrite() async throws {
        for number in 0..<12 { try note("Note-\(number).md", "original body \(number)") }
        let index = SearchIndex(root: root)
        let snapshot = try await LibraryScanner.scan(root: root)
        try await index.reconcile(snapshot)
        let cache = root.appendingPathComponent(".silkweb/search-index.json")
        func fileNumber() -> NSNumber? {
            (try? FileManager.default.attributesOfItem(atPath: cache.path))?[.systemFileNumber] as? NSNumber
        }
        for _ in 0..<80 where fileNumber() == nil { try await Task.sleep(for: .milliseconds(50)) }
        let initial = try XCTUnwrap(fileNumber())

        // Autosave: atomic replace, date refresh, then the watcher's rescan.
        let saved = try XCTUnwrap(snapshot.documents.first { $0.relativePath == "Note-3.md" })
        try note("Note-3.md", "freshly typed zanzibar")
        let refreshed = try await LibraryScanner.refreshingDates(in: snapshot, documentID: saved.id)
        let changed = try await index.reconcile(refreshed)
        XCTAssertTrue(changed)
        let scanned = try await LibraryScanner.scan(root: root, previousSnapshot: refreshed)
        XCTAssertEqual(
            scanned.documents.first { $0.id == saved.id }?.fileIdentity,
            refreshed.documents.first { $0.id == saved.id }?.fileIdentity,
            "date refresh must also refresh the file identity")
        XCTAssertTrue(scanned.documents == refreshed.documents)
        let rescanned = try await index.reconcile(scanned)
        XCTAssertFalse(rescanned, "watcher rescan after a save must not re-index the saved note")
        let hits = try await index.query(SearchQuery("zanzibar"))
        XCTAssertEqual(hits.map(\.id), [saved.id])
        XCTAssertEqual(fileNumber(), initial, "cache write is debounced, not done inside reconcile")

        for _ in 0..<80 where fileNumber() == initial { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertNotEqual(fileNumber(), initial)
        let written = try XCTUnwrap(fileNumber())
        try await Task.sleep(for: .milliseconds(2500))
        XCTAssertEqual(fileNumber(), written, "one coalesced cache write per save")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 1)
        let records = try XCTUnwrap(json["records"] as? [[String: Any]])
        XCTAssertEqual(records.count, 12)
        XCTAssertEqual(
            records.first { $0["path"] as? String == "Note-3.md" }?["body"] as? String, "freshly typed zanzibar")
        // A relaunch loads the debounced cache and reads no body.
        try FileManager.default.removeItem(at: root.appendingPathComponent("Note-3.md"))
        let warm = SearchIndex(root: root)
        try await warm.reconcile(scanned)
        let warmHits = try await warm.query(SearchQuery("zanzibar"))
        XCTAssertEqual(warmHits.map(\.id), [saved.id])
    }

    func testRankingLiteralMatchingAndSnippets() async throws {
        for name in ["Café", "Cafe society", "My cafe", "Decafeinated", "Body"] {
            try note(
                name + ".md",
                name == "Body"
                    ? String(repeating: "intro ", count: 20) + "# **café** `tea` "
                        + String(repeating: "tail ", count: 40) : "tea")
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
        // Search Library reads #179 syntax: `"quote"` is a phrase and `tag:` a filter; an unclosed quote is literal.
        let phrase = try await index.query(SearchQuery("\"quote\" literal"))
        XCTAssertEqual(phrase.map(\.displayName), ["Symbols"])
        let tagged = try await index.query(SearchQuery("\"quote\" tag:tea"))
        XCTAssertTrue(tagged.isEmpty)
        let literal = try await index.query(SearchQuery("\"quote tag:tea"))
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

    private func knowledge(_ snapshot: LibrarySnapshot) async throws -> LibraryKnowledgeIndex {
        let index = LibraryKnowledgeIndex(
            root: root, cacheDirectory: root.appendingPathComponent(".test-knowledge"), checkpointDelay: .seconds(60))
        try await index.reconcile(snapshot)
        return index
    }

    private func memory(_ id: String, type: String, status: String? = nil, created: String, body: String) -> String {
        var envelope = MemoryEnvelope(
            memoryID: id, type: type, project: "Silkweb", agent: "claude-code", session: "s-1",
            createdAt: AgentMemorySearchRequest.date(created)!)
        if let status { envelope["status"] = .string(status) }
        return try! envelope.document(body: body)
    }

    func testLibraryRanksExactTitleThenBM25ThenNewestThenName() async throws {
        try note("Flock.md", "Unrelated words.")
        try note("Locking.md", "# Flock\n\nWhy we flock the library.")
        try note("Notes.md", "flock flock flock, three times in one body.")
        try note("Long.md", "One flock. " + String(repeating: "Filler words that dilute the body. ", count: 40))
        try note("Twin A.md", "Twin flock")
        try note("Twin B.md", "Twin flock")
        try note("Elsewhere.md", "No match.")
        let snapshot = try await LibraryScanner.scan(root: root)
        let index = SearchIndex(root: root)
        try await index.reconcile(snapshot)
        let knowledge = try await knowledge(snapshot)
        let terms = ParsedSearchQuery("flock").rankingTerms
        let statistics = await knowledge.termStatistics(for: terms)
        let twins = snapshot.documents.filter { $0.name.hasPrefix("Twin") }
        for var document in twins {
            document.modified = Date(timeIntervalSince1970: 1_000)
            await index.update(document, body: "Twin flock")
        }
        let hits = try await index.query(SearchQuery("flock", ranking: statistics))
        XCTAssertEqual(hits.first?.displayName, "Flock", "an exact title match stays first")
        XCTAssertEqual(hits.count, 6)
        // Then BM25 with the matching Documents' statistics, highest first.
        let scores = KnowledgeBM25.scores(
            terms: terms, candidates: snapshot.documents.map(\.relativePath), statistics: statistics)
        let rest = hits.dropFirst().map { $0.displayName }
        XCTAssertEqual(
            rest, rest.sorted { (scores[$0 + ".md"] ?? 0, $1) > (scores[$1 + ".md"] ?? 0, $0) })
        XCTAssertEqual(rest.last, "Long", "a single hit in a long body ranks last")
        // Equal scores: newest first, then name.
        XCTAssertEqual(rest.filter { $0.hasPrefix("Twin") }, ["Twin A", "Twin B"])
        for var document in twins where document.name == "Twin B.md" {
            document.modified = Date(timeIntervalSince1970: 2_000)
            await index.update(document, body: "Twin flock")
        }
        let newer = try await index.query(SearchQuery("flock", ranking: statistics))
        XCTAssertEqual(newer.map(\.displayName).filter { $0.hasPrefix("Twin") }, ["Twin B", "Twin A"])
        XCTAssertEqual(newer.first { $0.displayName == "Locking" }?.matchKind, .body, "a heading counts as body")
        XCTAssertEqual(newer.first?.matchKind, .title)
        // Without statistics (no knowledge index yet) the title tiers still apply.
        let tiers = try await index.query(SearchQuery("flock"))
        XCTAssertEqual(tiers.map(\.displayName).first, "Flock")
        XCTAssertEqual(Set(tiers.map(\.id)), Set(newer.map(\.id)))
        await index.flushCache()
    }

    func testLibraryFiltersPhrasesAndTagsNarrowResults() async throws {
        let project = "Memory/Projects/Silkweb/"
        try note(
            project + "Memories/Decision A.md",
            memory("m_a", type: "decision", status: "open", created: "2026-10-02", body: "gate design"))
        try note(
            project + "Memories/Memory B.md", memory("m_b", type: "memory", created: "2026-09-20", body: "gate notes"))
        try note("Plain.md", "gate plain research")
        try note(project + "Loose.md", "gate loose\n\n  ends")
        // Without `created_at`, dates are the modified date.
        for path in ["Plain.md", project + "Loose.md"] {
            try FileManager.default.setAttributes(
                [.modificationDate: AgentMemorySearchRequest.date("2026-10-05")!],
                ofItemAtPath: root.appendingPathComponent(path).path)
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        let index = SearchIndex(root: root)
        try await index.reconcile(snapshot)
        func names(_ text: String, metadata: LibraryMetadata? = nil, mode: SearchQuery.Mode = .library) async throws
            -> [String]
        {
            try await index.query(SearchQuery(text, mode: mode, metadata: metadata)).map(\.displayName).sorted()
        }
        var result = try await names("gate type:decision")
        XCTAssertEqual(result, ["Decision A"])
        result = try await names("gate TYPE:decision type:memory")
        XCTAssertEqual(result, ["Decision A", "Memory B"])
        result = try await names("gate status:OPEN")
        XCTAssertEqual(result, ["Decision A"])
        result = try await names("gate status:open type:memory")
        XCTAssertEqual(result, [])
        result = try await names("gate project:silkweb")
        XCTAssertEqual(result, ["Decision A", "Loose", "Memory B"])
        result = try await names("gate project:Other")
        XCTAssertEqual(result, [])
        result = try await names("gate before:2026-10-01")
        XCTAssertEqual(result, ["Memory B"])
        result = try await names("gate after:2026-10-01 before:2026-10-03")
        XCTAssertEqual(result, ["Decision A"])
        // A filter-only query lists every Document that passes; an unknown key is a word.
        result = try await names("type:decision")
        XCTAssertEqual(result, ["Decision A"])
        result = try await names("folder:Memories")
        XCTAssertEqual(result, [])
        // Phrases: adjacent words across any whitespace.
        result = try await names("\"gate loose ends\"")
        XCTAssertEqual(result, ["Loose"])
        result = try await names("\"loose gate\"")
        XCTAssertEqual(result, [])
        // Tags: the sidebar's Tag, by name, ignoring case; ANDed with words.
        var metadata = snapshot.metadata
        let tag = LibraryTag(name: "Research")
        metadata.tags = [tag]
        let plain = try XCTUnwrap(snapshot.documents.first { $0.name == "Plain.md" })
        metadata.tagsByDocument[plain.id.uuidString] = [tag.id]
        result = try await names("gate tag:research", metadata: metadata)
        XCTAssertEqual(result, ["Plain"])
        result = try await names("tag:research tag:other", metadata: metadata)
        XCTAssertEqual(result, ["Plain"])
        result = try await names("design tag:research", metadata: metadata)
        XCTAssertEqual(result, [])
        result = try await names("gate tag:research")
        XCTAssertEqual(result, [], "no metadata, no Tags")
        // Highlights cover words and phrases, never a filter value.
        let highlighted = try await index.query(SearchQuery("tag:research \"gate plain\"", metadata: metadata))
        let hit = try XCTUnwrap(highlighted.first)
        XCTAssertEqual(hit.matchRanges.map { (hit.snippet as NSString).substring(with: $0) }, ["gate plain"])
        // Quick Open doesn't parse: a filter is a literal word there.
        result = try await names("type:decision", mode: .quickOpen)
        XCTAssertEqual(result, [])
        result = try await names("\"Decision", mode: .quickOpen)
        XCTAssertEqual(result, [])
        result = try await names("Decision", mode: .quickOpen)
        XCTAssertEqual(result, ["Decision A"])
        await index.flushCache()
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
                let results = try await index.query(
                    SearchQuery("", scope: .folder(folder.id, includeSubfolders: descendants), mode: mode))
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
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Moved"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("First.md"), to: root.appendingPathComponent("Moved/Renamed.md"))
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
            if cache == "broken" {
                XCTAssertEqual(firstState, .rebuilding(reason: .corrupt))
            } else if cache != "{}" {
                XCTAssertEqual(firstState, .rebuilding(reason: .unsupportedVersion))
            } else {
                XCTAssertEqual(firstState, .building(indexed: 0, total: 1))
            }
            let state = await index.state
            XCTAssertEqual(state, .ready)
            let hits = try await index.query(SearchQuery("legacy"))
            XCTAssertEqual(hits.count, 1)
            let body = try String(contentsOf: root.appendingPathComponent("Old.md"), encoding: .utf8)
            XCTAssertEqual(body, "legacy body")
            await index.flushCache()
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
        do { try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
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
        print(
            "Search benchmark: 10,000 documents / 1,000 folders; scan \(scanTime)s (10s budget), index \(buildTime)s (10s budget), query \(queryTime)s (1s budget)"
        )
        XCTAssertEqual(results.count, 10000)
        XCTAssertLessThan(scanTime, 10)
        XCTAssertLessThan(buildTime, 10)
        XCTAssertLessThan(queryTime, 1)
        // #179: warm BM25 Search Library, 50 results, statistics fetched from the knowledge index per query.
        let knowledge = try await knowledge(snapshot)
        var ranked: [TimeInterval] = []
        for text in ["needle", "cafe needle", "\"body needle\"", "needle type:memory", "note-3 needle"] {
            for _ in 0..<5 {
                let clock = Date()
                let statistics = await knowledge.termStatistics(for: ParsedSearchQuery(text).rankingTerms)
                let hits = try await index.query(SearchQuery(text, limit: 50, ranking: statistics))
                ranked.append(Date().timeIntervalSince(clock))
                XCTAssertEqual(hits.count, text.contains("type:") ? 0 : 50, text)
            }
        }
        var plain: [TimeInterval] = []
        for text in ["needle", "cafe needle", "\"body needle\"", "needle type:memory", "note-3 needle"] {
            for _ in 0..<5 {
                let clock = Date()
                _ = try await index.query(SearchQuery(text, limit: 50))
                plain.append(Date().timeIntervalSince(clock))
            }
        }
        let p95 = ranked.sorted()[Int(Double(ranked.count - 1) * 0.95)]
        print(
            "Search Library BM25, 10,000 documents: warm p95 \(p95)s for 50 results (0.1s target); "
                + "without statistics \(plain.sorted()[Int(Double(plain.count - 1) * 0.95)])s")
        XCTAssertLessThan(p95, 1)
        let cancelled = Task {
            try Task.checkCancellation()
            return try await index.query(SearchQuery("needle", limit: 10000))
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        // Pre-cancelled calls exercise propagation into the detached query worker.
        let gated = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await index.query(SearchQuery("needle", limit: 10000))
        }
        gated.cancel()
        do { _ = try await gated.value; XCTFail("Expected cancellation") } catch is CancellationError {}
        let subsequent = try await index.query(SearchQuery("Note-0", mode: .quickOpen))
        XCTAssertEqual(subsequent.count, 100)
        // Land the coalesced cache write now: on a loaded runner it otherwise fires ~2 s after `reconcile`,
        // mid-tearDown, and the recursive removal of the library fails with "directory not empty" (#63).
        await index.flushCache()
    }
}

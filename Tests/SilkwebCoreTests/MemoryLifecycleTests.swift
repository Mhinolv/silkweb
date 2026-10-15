import XCTest

@testable import SilkwebCore

/// #141: owner lifecycle state (`.silkweb/memory-state.json`), revision-bound supersession, review dates, archive,
/// the recent window for progress and handoffs, and integrity diagnostics in agent search.
final class MemoryLifecycleTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!
    private var cacheDirectory: URL!

    private let folder = "Memory/Projects/Silkweb/Memories"
    private static let now = AgentMemorySearchRequest.date("2026-10-15T12:00:00Z")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("Lifecycle-\(UUID().uuidString)")
        library = root.appendingPathComponent("Writing")
        grantsURL = root.appendingPathComponent("grants/agent-grants.json")
        cacheDirectory = AgentMemoryService.defaultCacheDirectory(home: root)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try AgentGrantFile(grants: [
            AgentGrant(
                project: "Silkweb", library: LibraryLocation(path: library.path), access: .read,
                label: "Silkweb project", limits: AgentGrantLimits(requestsPerMinute: 1_000_000))
        ]).write(to: grantsURL)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    /// Writes a Document and gives it a native ID in `.silkweb/index.json`.
    @discardableResult
    private func write(_ path: String, _ text: String) throws -> UUID {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        var (metadata, _) = try LibraryMetadataStore.load(root: library)
        let id = metadata.IDsByPath[path] ?? UUID()
        metadata.IDsByPath[path] = id
        try LibraryMetadataStore.save(metadata, root: library)
        return id
    }

    private func memory(
        _ id: String, type: String = "decision", created: String = "2026-10-01T09:00:00Z",
        supersedes: [String] = [], reviewAfter: String? = nil, body: String = "alpha"
    ) -> String {
        var envelope = MemoryEnvelope(
            memoryID: id, type: type, project: "Silkweb", agent: "claude-code", session: "s-1",
            createdAt: AgentMemorySearchRequest.date(created)!)
        if !supersedes.isEmpty { envelope["supersedes"] = .list(supersedes) }
        if let reviewAfter { envelope["review_after"] = .string(reviewAfter) }
        return try! envelope.document(body: body)
    }

    private func revision(_ path: String) throws -> String {
        AgentMemoryIndex.revision(try Data(contentsOf: library.appendingPathComponent(path)))
    }

    /// Library-backed: no review closure, so the helper reads `.silkweb/memory-state.json` itself.
    private func service(now: Date = MemoryLifecycleTests.now) -> AgentMemoryService {
        AgentMemoryService(
            session: AgentSession(project: "Silkweb", store: AgentGrantStore(url: grantsURL)),
            cacheDirectory: cacheDirectory, options: AgentMemoryIndexOptions(now: { now }))
    }

    private func search(_ request: AgentMemorySearchRequest = AgentMemorySearchRequest(limit: 50)) throws
        -> AgentMemorySearchResponse
    {
        try service().search(request)
    }

    private func names(_ response: AgentMemorySearchResponse) -> [String] {
        response.results.map { $0.document.title }
    }

    private func result(_ response: AgentMemorySearchResponse, _ title: String) -> AgentMemoryDocumentInfo? {
        response.results.first { $0.document.title == title }?.document
    }

    private func updateState(_ change: (inout MemoryStateFile) -> Void) throws {
        try MemoryStateStore.update(root: library, change)
    }

    private func run(_ arguments: [String]) throws -> [String: Any] {
        let output = AgentHelper.run(
            arguments + ["--grant", "Silkweb", "--grants", grantsURL.path], home: root)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any], output.stdout + output.stderr)
    }

    // MARK: State file

    func testStateFileRoundTripsAndDecodesTolerantly() throws {
        XCTAssertEqual(try MemoryStateStore.load(root: library), MemoryStateFile(), "a missing file is no decisions")
        let id = UUID()
        var entry = MemoryLifecycleEntry(
            reviewed: .init(revision: "sha256:aa", at: Self.now), pinned: true,
            reviewAfter: AgentMemorySearchRequest.date("2027-01-06"),
            archived: .init(at: Self.now, fromPath: "Memory/Projects/Silkweb/Progress"),
            dismissed: [.init(kind: "duplicate", revision: "sha256:aa")])
        entry.decide(.accepted, by: "mem_b", revision: "sha256:aa", successorRevision: "sha256:bb", at: Self.now)
        var state = MemoryStateFile()
        state[id] = entry
        try MemoryStateStore.save(state, root: library)
        XCTAssertEqual(try MemoryStateStore.load(root: library), state)
        let text = try String(contentsOf: MemoryStateStore.url(root: library), encoding: .utf8)
        XCTAssertTrue(text.contains("\"version\" : 1"), text)
        XCTAssertTrue(text.contains("\"reviewAfter\" : \"2027-01-06T00:00:00Z\""), text)
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "\"documents\"")).lowerBound,
            try XCTUnwrap(text.range(of: "\"version\"")).lowerBound,
            "sorted keys")

        // Missing keys read as defaults; one bad entry drops only itself; unknown keys are ignored.
        let other = UUID()
        let tolerant = """
            {"documents": {"\(id.uuidString)": {"pinned": true, "future": 1},
            "\(other.uuidString)": {"reviewed": "not an object", "supersession": [{"by": 3}, {"by": "mem_c",
            "state": "declined", "at": "2026-10-01T00:00:00Z", "revision": "r", "successorRevision": "s"}]},
            "bad": 7}}
            """
        let decoded = try MemoryStateStore.decode(Data(tolerant.utf8))
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded[id], MemoryLifecycleEntry(pinned: true))
        XCTAssertNil(decoded[other].reviewed)
        XCTAssertEqual(decoded[other].supersession.map(\.by), ["mem_c"])
        XCTAssertNil(decoded.documents["bad"])
        XCTAssertEqual(try MemoryStateStore.decode(Data("{ not json".utf8)), MemoryStateFile())

        // A newer file is never overwritten.
        try Data(#"{"version": 2, "documents": {}}"#.utf8).write(to: MemoryStateStore.url(root: library))
        XCTAssertThrowsError(try MemoryStateStore.update(root: library) { $0[id] = MemoryLifecycleEntry(pinned: true) })
        XCTAssertEqual(
            try String(contentsOf: MemoryStateStore.url(root: library), encoding: .utf8),
            #"{"version": 2, "documents": {}}"#)
    }

    func testEmptyEntriesAreRemoved() {
        var state = MemoryStateFile()
        let id = UUID()
        state[id] = MemoryLifecycleEntry(pinned: true)
        XCTAssertEqual(state.documents.count, 1)
        state[id].pinned = false
        XCTAssertTrue(state.documents.isEmpty)
    }

    // MARK: Review dates

    func testReviewDateNeverChangesTextAndOnlyRanksDueEntriesLower() throws {
        let due = "\(folder)/Alpha due.md"
        let fresh = "\(folder)/Alpha fresh.md"
        let pinned = "\(folder)/Alpha pinned due.md"
        try write(due, memory("m_due", created: "2026-10-10T00:00:00Z", reviewAfter: "2026-10-01T00:00:00Z"))
        try write(fresh, memory("m_fresh", created: "2026-09-01T00:00:00Z"))
        let pinnedID = try write(
            pinned, memory("m_pin", created: "2026-09-01T00:00:00Z", reviewAfter: "2026-10-01T00:00:00Z"))
        try updateState { $0[pinnedID].pinned = true }
        let before = try [due, fresh, pinned].map { try Data(contentsOf: library.appendingPathComponent($0)) }

        let response = try search(AgentMemorySearchRequest(query: "alpha"))
        // Pinned first and never sinks; a passed review date ranks below the same kind, even though it's newer.
        XCTAssertEqual(names(response), ["Alpha pinned due", "Alpha fresh", "Alpha due"])
        XCTAssertEqual(result(response, "Alpha due")?.reviewDue, true)
        XCTAssertEqual(result(response, "Alpha pinned due")?.reviewDue, true)
        XCTAssertEqual(result(response, "Alpha fresh")?.reviewDue, false)
        XCTAssertEqual(result(response, "Alpha due")?.reviewAfter, AgentMemorySearchRequest.date("2026-10-01"))
        XCTAssertEqual(
            try [due, fresh, pinned].map { try Data(contentsOf: library.appendingPathComponent($0)) }, before,
            "an elapsed review date never changes or deletes text")

        // Before the date nothing is due.
        let early = try service(now: AgentMemorySearchRequest.date("2026-09-20")!).search(
            AgentMemorySearchRequest(query: "alpha"))
        XCTAssertEqual(result(early, "Alpha due")?.reviewDue, false)
    }

    func testOwnerReviewDateWinsAndMarkingReviewedClearsDue() throws {
        let path = "\(folder)/Alpha.md"
        let id = try write(path, memory("m_a", reviewAfter: "2026-10-01T00:00:00Z"))
        XCTAssertEqual(try search().results.first?.document.reviewDue, true)

        // Mark as Reviewed after the date: no longer due, and the text is untouched.
        let revision = try revision(path)
        try updateState { $0[id].reviewed = .init(revision: revision, at: Self.now) }
        var info = try XCTUnwrap(try search().results.first?.document)
        XCTAssertEqual(info.review, .reviewed)
        XCTAssertFalse(info.reviewDue)

        // Remind Me Later: the owner's later date wins over the agent's.
        try updateState { $0[id].reviewAfter = AgentMemorySearchRequest.date("2027-01-15") }
        info = try XCTUnwrap(try search().results.first?.document)
        XCTAssertEqual(info.reviewAfter, AgentMemorySearchRequest.date("2027-01-15"))
        XCTAssertFalse(info.reviewDue)

        // Clear: neither date applies.
        try updateState {
            $0[id].reviewAfter = nil
            $0[id].reviewAfterCleared = true
            $0[id].reviewed = nil
        }
        info = try XCTUnwrap(try search().results.first?.document)
        XCTAssertNil(info.reviewAfter)
        XCTAssertFalse(info.reviewDue)
    }

    // MARK: Supersession

    func testAClaimNeverHidesOrSinksAReviewedMemoryUntilTheOwnerAccepts() throws {
        let old = "\(folder)/Alpha rule.md"
        let new = "\(folder)/Alpha rule v2.md"
        let oldID = try write(old, memory("m_old", created: "2026-10-02T00:00:00Z", body: "alpha old rule"))
        try write(new, memory("m_new", created: "2026-10-01T00:00:00Z", supersedes: ["m_old"], body: "alpha new"))
        let oldRevision = try revision(old)
        let newRevision = try revision(new)
        try updateState { $0[oldID].reviewed = .init(revision: oldRevision, at: Self.now) }

        // Claimed only: the reviewed Document stays first and visible.
        var response = try search(AgentMemorySearchRequest(query: "alpha"))
        XCTAssertEqual(names(response), ["Alpha rule", "Alpha rule v2"])
        XCTAssertEqual(
            result(response, "Alpha rule")?.supersededBy, [AgentMemorySupersession(memoryID: "m_new", state: .claimed)])

        // Declined: both untouched.
        try updateState {
            $0[oldID].decide(
                .declined, by: "m_new", revision: oldRevision, successorRevision: newRevision, at: Self.now)
        }
        response = try search(AgentMemorySearchRequest(query: "alpha"))
        XCTAssertEqual(names(response), ["Alpha rule", "Alpha rule v2"])
        XCTAssertEqual(result(response, "Alpha rule")?.supersededBy.first?.state, .declined)

        // Accepted: the predecessor sinks but is still returned, in default and ranked mode.
        try updateState {
            $0[oldID].decide(
                .accepted, by: "m_new", revision: oldRevision, successorRevision: newRevision, at: Self.now)
        }
        response = try search(AgentMemorySearchRequest(query: "alpha"))
        XCTAssertEqual(names(response), ["Alpha rule v2", "Alpha rule"])
        XCTAssertEqual(result(response, "Alpha rule")?.supersededBy.first?.state, .accepted)
        let ranked = try search(AgentMemorySearchRequest(query: "alpha", mode: .ranked))
        XCTAssertEqual(names(ranked).last, "Alpha rule")

        // Revision-bound: when the successor's text changes, the acceptance no longer applies.
        try write(new, memory("m_new", created: "2026-10-01T00:00:00Z", supersedes: ["m_old"], body: "alpha newer"))
        response = try search(AgentMemorySearchRequest(query: "alpha"))
        XCTAssertEqual(names(response), ["Alpha rule", "Alpha rule v2"])
        XCTAssertEqual(result(response, "Alpha rule")?.supersededBy.first?.state, .claimed)

        // The read response carries the same state.
        let read = try service().read(AgentMemoryReadRequest(path: old))
        XCTAssertEqual(read.document.supersededBy, [AgentMemorySupersession(memoryID: "m_new", state: .claimed)])
        XCTAssertEqual(read.document.review, .reviewed)
    }

    // MARK: Cache invalidation

    func testLifecycleChangesReachTheNextSearchWithoutADocumentEdit() throws {
        let path = "\(folder)/Alpha.md"
        let id = try write(path, memory("m_a"))
        let session = service()
        XCTAssertEqual(try session.search(AgentMemorySearchRequest()).results.first?.document.pinned, false)
        let modified =
            try FileManager.default.attributesOfItem(
                atPath: library.appendingPathComponent(path).path)[.modificationDate] as? Date

        try updateState { $0[id].pinned = true }
        XCTAssertEqual(try session.search(AgentMemorySearchRequest()).results.first?.document.pinned, true)
        try updateState { $0[id].archived = .init(at: Self.now, fromPath: folder) }
        XCTAssertTrue(try session.search(AgentMemorySearchRequest()).results.isEmpty)
        try updateState { $0[id].archived = nil }
        XCTAssertEqual(try session.search(AgentMemorySearchRequest()).results.count, 1)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(
                atPath: library.appendingPathComponent(path).path)[.modificationDate] as? Date, modified)
    }

    func testAnOlderHelperCacheIsRebuilt() throws {
        try write("\(folder)/Alpha.md", memory("m_a", reviewAfter: "2026-10-01T00:00:00Z"))
        let session = service()
        _ = try session.search(AgentMemorySearchRequest())
        // A version 1 cache has no review_after; it's rebuilt, so the date isn't silently lost.
        let old = """
            {"version":1,"library":"\(library.path)","project":"Silkweb","records":[]}
            """
        try Data(old.utf8).write(to: session.cacheURL)
        let rebuilt = try service().search(AgentMemorySearchRequest())
        XCTAssertEqual(rebuilt.index.state, .ready)
        XCTAssertEqual(rebuilt.results.first?.document.reviewDue, true)
    }

    // MARK: Archive

    func testArchivedDocumentsDropOutUnlessAsked() throws {
        let stateID = try write("\(folder)/Alpha state.md", memory("m_s"))
        try write("Memory/Projects/Silkweb/Archive/Alpha folder.md", memory("m_f"))
        try write("\(folder)/Alpha kept.md", memory("m_k"))
        try updateState { $0[stateID].archived = .init(at: Self.now, fromPath: folder) }

        XCTAssertEqual(names(try search(AgentMemorySearchRequest(query: "alpha"))), ["Alpha kept"])
        let all = try search(AgentMemorySearchRequest(query: "alpha", includeArchived: true))
        XCTAssertEqual(Set(names(all)), ["Alpha kept", "Alpha state", "Alpha folder"])
        XCTAssertEqual(result(all, "Alpha state")?.archived, true)
        XCTAssertEqual(result(all, "Alpha folder")?.archived, true)
        XCTAssertEqual(result(all, "Alpha kept")?.archived, false)

        XCTAssertEqual(MemoryArchive.folder(for: "\(folder)/Alpha.md"), "Memory/Projects/Silkweb/Archive")
        XCTAssertNil(MemoryArchive.folder(for: "Notes/Alpha.md"))
        XCTAssertNil(MemoryArchive.folder(for: "Memory/Projects/Silkweb.md"))
    }

    // MARK: Recent window (owner decision 2026-10-09)

    func testOlderProgressAndHandoffsDropOutWhileMemoriesStay() throws {
        // Dates relative to the real clock, because the CLI below uses it.
        let now = Date()
        let ago = { (days: Double) in MemoryEnvelope.timestamp(now.addingTimeInterval(-days * 86_400)) }
        try write("Memory/Projects/Silkweb/Progress/Recent.md", memory("p1", type: "progress", created: ago(5)))
        try write("Memory/Projects/Silkweb/Progress/Old.md", memory("p2", type: "progress", created: ago(60)))
        try write(
            "Memory/Projects/Silkweb/Handoffs/Old handoff.md", memory("h1", type: "handoff", created: ago(120)))
        try write("\(folder)/Old decision.md", memory("d1", type: "decision", created: ago(400)))
        try write("\(folder)/Old memory.md", memory("m1", type: "memory", created: ago(800)))
        let search = { (request: AgentMemorySearchRequest) in try self.service(now: now).search(request) }

        let response = try search(AgentMemorySearchRequest(limit: 50))
        XCTAssertEqual(Set(names(response)), ["Recent", "Old decision", "Old memory"])
        XCTAssertEqual(response.total, 3)

        // The caller turns the window off, with 0 or with dates of its own, or widens it.
        XCTAssertEqual(try search(AgentMemorySearchRequest(limit: 50, recentDays: 0)).total, 5)
        XCTAssertEqual(
            try search(AgentMemorySearchRequest(createdAfter: now.addingTimeInterval(-200 * 86_400), limit: 50)).total,
            3, "only the window is off: the 400- and 800-day documents are before createdAfter")
        XCTAssertEqual(try search(AgentMemorySearchRequest(limit: 50, recentDays: 90)).total, 4)

        // CLI and MCP take the same options.
        XCTAssertEqual(try run(["memory", "search"])["total"] as? Int, 3)
        XCTAssertEqual(try run(["memory", "search", "--recent-days", "0"])["total"] as? Int, 5)
        let refused = AgentHelper.run(
            ["memory", "search", "--recent-days", "-1", "--grant", "Silkweb", "--grants", grantsURL.path], home: root)
        XCTAssertNotEqual(refused.status, 0, refused.stderr)
    }

    func testAProjectWithNothingRecentKeepsItsTenBestOlderMatches() throws {
        for day in 1...12 {
            try write(
                "Memory/Projects/Silkweb/Progress/Step \(day).md",
                memory("p\(day)", type: "progress", created: String(format: "2026-06-%02dT00:00:00Z", day)))
        }
        let response = try search()
        XCTAssertEqual(response.total, 10)
        // Ranked as usual (newest first), so the two oldest drop out.
        XCTAssertEqual(names(response).first, "Step 12")
        XCTAssertFalse(names(response).contains("Step 1"))
        XCTAssertFalse(names(response).contains("Step 2"))
        // Capped by the caller's limit.
        XCTAssertEqual(try search(AgentMemorySearchRequest(limit: 3)).results.count, 3)
    }

    // MARK: Diagnostics

    func testDuplicateIDsCyclesAndConflictingSuccessorsAreReported() throws {
        try write("\(folder)/Dup one.md", memory("m_dup"))
        try write("\(folder)/Dup two.md", memory("m_dup"))
        try write("\(folder)/Loop a.md", memory("m_a", supersedes: ["m_b"]))
        try write("\(folder)/Loop b.md", memory("m_b", supersedes: ["m_a"]))
        let targetID = try write("\(folder)/Target.md", memory("m_t"))
        try write("\(folder)/Claim one.md", memory("m_c1", supersedes: ["m_t"]))
        try write("\(folder)/Claim two.md", memory("m_c2", supersedes: ["m_t"]))

        let response = try search()
        XCTAssertEqual(
            response.diagnostics,
            [
                AgentMemoryDiagnostic(
                    code: .duplicateMemoryID, memoryIDs: ["m_dup"],
                    related: ["\(folder)/Dup one.md", "\(folder)/Dup two.md"]),
                AgentMemoryDiagnostic(code: .supersessionCycle, memoryIDs: ["m_a", "m_b"]),
                AgentMemoryDiagnostic(code: .conflictingSuccessors, memoryIDs: ["m_t"], related: ["m_c1", "m_c2"]),
            ])
        let json = response.json.rendered
        XCTAssertTrue(json.contains("\"code\" : \"conflicting_successors\""), json)
        XCTAssertTrue(json.contains("2 documents claim to replace m_t."), json)

        // Declining one claim ends the conflict.
        let targetRevision = try revision("\(folder)/Target.md")
        let claim = try revision("\(folder)/Claim two.md")
        try updateState {
            $0[targetID].decide(.declined, by: "m_c2", revision: targetRevision, successorRevision: claim, at: Self.now)
        }
        XCTAssertFalse(try search().diagnostics.contains { $0.code == .conflictingSuccessors })
        XCTAssertEqual(AgentMemoryDiagnostic.find([("m_x", ["m_x"], "x.md")]).map(\.code), [.supersessionCycle])
    }

    // MARK: Helper output

    func testHelperJSONShowsLifecycleFields() throws {
        let path = "\(folder)/Alpha.md"
        let id = try write(path, memory("m_a", reviewAfter: "2026-10-01T00:00:00Z"))
        try write("\(folder)/Beta.md", memory("m_b", supersedes: ["m_a"], body: "beta"))
        let revision = try revision(path)
        try updateState {
            $0[id].pinned = true
            $0[id].reviewed = .init(revision: revision, at: AgentMemorySearchRequest.date("2026-09-01")!)
        }
        let json = try search(AgentMemorySearchRequest(query: "alpha")).json.rendered
        for field in [
            "\"pinned\" : true", "\"review\" : \"reviewed\"", "\"reviewAfter\" : \"2026-10-01T00:00:00Z\"",
            "\"archived\" : false", "\"memoryId\" : \"m_b\"", "\"state\" : \"claimed\"",
        ] {
            XCTAssertTrue(json.contains(field), field + "\n" + json)
        }
        let cli = try run(["memory", "search", "alpha", "--include-archived"])
        let first = try XCTUnwrap((cli["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(first["pinned"] as? Bool, true)
        XCTAssertNotNil(first["reviewDue"] as? Bool)
        XCTAssertEqual((first["supersededBy"] as? [[String: Any]])?.first?["state"] as? String, "claimed")
    }
}

import Darwin
import XCTest

@testable import SilkwebCore

/// #134: scoped headless search and paged reads with index freshness.
final class AgentMemorySearchTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!
    private var cacheDirectory: URL!

    private let projectPath = "Memory/Projects/Silkweb"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentSearch-\(UUID().uuidString)")
        // Not “Library”: the fake home's own ~/Library holds the helper cache.
        library = root.appendingPathComponent("Writing")
        grantsURL = root.appendingPathComponent("grants/agent-grants.json")
        cacheDirectory = AgentMemoryService.defaultCacheDirectory(home: root)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try writeGrants()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Fixtures

    private func writeGrants(
        extra: [String] = [], limits: AgentGrantLimits = AgentGrantLimits(), revoked: Bool = false
    ) throws {
        try AgentGrantFile(grants: [
            AgentGrant(
                project: "Silkweb", library: LibraryLocation(path: library.path), access: .read,
                extraReadFolders: extra, label: "Silkweb project", limits: limits,
                revokedAt: revoked ? Date() : nil)
        ]).write(to: grantsURL)
    }

    @discardableResult
    private func write(_ path: String, _ text: String, modified: Date? = nil) throws -> URL {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
        return url
    }

    private func memory(
        _ id: String, type: String, created: String = "2026-10-06T15:00:00Z", project: String = "Silkweb",
        status: String? = nil, supersedes: [String] = [], body: String
    ) -> String {
        var envelope = MemoryEnvelope(
            memoryID: id, type: type, project: project, agent: "claude-code", session: "s-1",
            createdAt: AgentMemorySearchRequest.date(created)!)
        if let status { envelope["status"] = .string(status) }
        if !supersedes.isEmpty { envelope["supersedes"] = .list(supersedes) }
        return try! envelope.document(body: body)
    }

    private func service(
        options: AgentMemoryIndexOptions = AgentMemoryIndexOptions(),
        reviews: @escaping AgentMemoryReviewLookup = { _, _ in nil }
    ) -> AgentMemoryService {
        AgentMemoryService(
            session: AgentSession(project: "Silkweb", store: AgentGrantStore(url: grantsURL)),
            cacheDirectory: cacheDirectory, options: options, reviews: reviews)
    }

    private func paths(_ response: AgentMemorySearchResponse) -> [String] {
        response.results.map { ($0.document.path as NSString).lastPathComponent }
    }

    private func assertRefused(
        _ expression: @autoclosure () throws -> Any, code: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) {
            XCTAssertEqual(($0 as? AgentAccessError)?.code, code, file: file, line: line)
        }
    }

    private func result(_ output: AgentHelper.Output) throws -> [String: Any] {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any], output.stdout)
    }

    private func run(_ arguments: [String]) -> AgentHelper.Output {
        AgentHelper.run(arguments + ["--grant", "Silkweb", "--grants", grantsURL.path, "--pretty"], home: root)
    }

    /// The common fixture: one of each type, a plain document, and secrets outside the grant.
    private func writeFixture() throws {
        try write(
            "\(projectPath)/Memories/Gate decision.md",
            memory(
                "mem_a", type: "decision", created: "2026-10-01T09:00:00Z", status: "accepted",
                body: "# Gate decision\n\nCommits go through the flock gate.\n"))
        try write(
            "\(projectPath)/Memories/Preference.md",
            memory(
                "mem_b", type: "memory", created: "2026-10-03T09:00:00Z",
                body: "# Preference\n\nThe owner prefers curly quotes in flock messages.\n"))
        try write(
            "\(projectPath)/Progress/2026-10-05 0900 — Spike.md",
            memory(
                "mem_c", type: "progress", created: "2026-10-05T09:00:00Z", status: "in-progress",
                body: "# Spike\n\nFlock gate prototype works.\n"))
        try write(
            "\(projectPath)/Handoffs/Resume.md",
            memory(
                "mem_d", type: "handoff", created: "2026-10-04T09:00:00Z", status: "open",
                body: "# Resume\n\nNext: wire the flock gate into create.\n"))
        try write(
            "\(projectPath)/Notes.md", "# Notes\n\nPlain flock notes without an envelope.\n",
            modified: AgentMemorySearchRequest.date("2026-09-01"))
        try write(
            "Memory/Projects/Silkweb2/Leak.md",
            memory("mem_x", type: "decision", project: "Silkweb2", body: "flock sibling secret"))
        try write("Memory/Projects/Other/Other.md", "flock other secret")
        try write("Notes/Private/Diary.md", "flock diary secret")
        try write(
            "Reference/Foreign.md",
            memory("mem_f", type: "decision", project: "Other", body: "# Foreign\n\nflock from elsewhere\n"))
    }

    // MARK: Filters and scope

    func testFiltersByTypeStatusProjectAndDateInsideTheGrant() throws {
        try writeFixture()
        let search = service()
        let all = try search.search(AgentMemorySearchRequest(query: "flock", limit: 50))
        XCTAssertEqual(all.total, 5)
        XCTAssertEqual(all.index.state, .ready)
        XCTAssertFalse(all.results.contains { $0.excerpt.contains("secret") }, "out-of-scope text never leaks")

        XCTAssertEqual(
            paths(try search.search(AgentMemorySearchRequest(query: "flock", types: ["decision", "memory"]))),
            ["Preference.md", "Gate decision.md"], "same tier and kind: newest first")
        let progress = try search.search(AgentMemorySearchRequest(types: ["progress"]))
        XCTAssertEqual(paths(progress), ["2026-10-05 0900 — Spike.md"])
        XCTAssertEqual(
            paths(try search.search(AgentMemorySearchRequest(statuses: ["OPEN", "accepted"]))),
            ["Gate decision.md", "Resume.md"])
        XCTAssertEqual(
            Set(paths(try search.search(AgentMemorySearchRequest(statuses: ["missing"])))), [],
            "documents without a matching status drop out")

        // created_at, or the modified date for documents without an envelope; after inclusive, before exclusive.
        let dated = try search.search(
            AgentMemorySearchRequest(
                createdAfter: AgentMemorySearchRequest.date("2026-10-03"),
                createdBefore: AgentMemorySearchRequest.date("2026-10-05T09:00:00Z"), limit: 50))
        XCTAssertEqual(Set(paths(dated)), ["Preference.md", "Resume.md"])
        let old = try search.search(
            AgentMemorySearchRequest(createdBefore: AgentMemorySearchRequest.date("2026-09-02"), limit: 50))
        XCTAssertEqual(paths(old), ["Notes.md"])

        // The grant's own project keeps envelope documents for it and plain documents in its Folder.
        try writeGrants(extra: ["Reference"])
        let wide = try search.search(AgentMemorySearchRequest(query: "flock", limit: 50))
        XCTAssertTrue(paths(wide).contains("Foreign.md"))
        let scoped = try search.search(AgentMemorySearchRequest(query: "flock", project: "Silkweb", limit: 50))
        XCTAssertEqual(scoped.total, 5)
        XCTAssertFalse(paths(scoped).contains("Foreign.md"))

        // Another project is refused with the grant's scope, never searched.
        assertRefused(try search.search(AgentMemorySearchRequest(project: "Other")), code: "out_of_scope")
        assertRefused(try search.search(AgentMemorySearchRequest(project: "Silkweb2")), code: "out_of_scope")
        assertRefused(try search.search(AgentMemorySearchRequest(types: ["note"])), code: "invalid_argument")
        assertRefused(try search.search(AgentMemorySearchRequest(limit: 0)), code: "invalid_argument")
    }

    func testLimitIsCappedByFiftyAndTheGrantAndTotalsCountOnlyInScopeMatches() throws {
        for index in 0..<60 { try write("\(projectPath)/Memories/Note \(index).md", "# Note\n\nshared word\n") }
        for index in 0..<30 { try write("Notes/Private/Secret \(index).md", "shared word") }
        let response = try service().search(AgentMemorySearchRequest(query: "shared", limit: 500))
        XCTAssertEqual(response.results.count, 50)
        XCTAssertEqual(response.total, 60)
        XCTAssertEqual(try service().search(AgentMemorySearchRequest(query: "shared")).results.count, 10)
        try writeGrants(limits: AgentGrantLimits(maxResults: 7))
        XCTAssertEqual(try service().search(AgentMemorySearchRequest(query: "shared", limit: 50)).results.count, 7)
    }

    // MARK: Result fields

    func testResultsCarryProvenanceRevisionAndEnvelopeFreeExcerpts() throws {
        try writeFixture()
        let decision = "\(projectPath)/Memories/Gate decision.md"
        let id = UUID()
        let metadata = library.appendingPathComponent(".silkweb/index.json")
        try FileManager.default.createDirectory(
            at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(LibraryMetadata(IDsByPath: [decision: id])).write(to: metadata)
        let indexBefore = try Data(contentsOf: metadata)

        let response = try service().search(AgentMemorySearchRequest(query: "gate decision"))
        let result = try XCTUnwrap(response.results.first)
        let document = result.document
        XCTAssertEqual(document.title, "Gate decision")
        XCTAssertEqual(document.path, decision)
        XCTAssertEqual(document.documentID, id, "native IDs come from the app index when it knows the document")
        XCTAssertEqual(document.memoryID, "mem_a")
        let bytes = try Data(contentsOf: library.appendingPathComponent(decision))
        XCTAssertEqual(document.revision, "sha256:" + DocumentRevision(data: bytes).digest)
        XCTAssertEqual(document.type, "decision")
        XCTAssertEqual(document.project, "Silkweb")
        XCTAssertEqual(document.status, "accepted")
        XCTAssertEqual(document.agent, "claude-code")
        XCTAssertEqual(document.session, "s-1")
        XCTAssertEqual(document.createdAt, "2026-10-01T09:00:00Z")
        XCTAssertEqual(document.review, .unreviewed, "missing app metadata reads as unreviewed")
        XCTAssertFalse(document.pinned)
        XCTAssertEqual(result.matchKind, .title)
        XCTAssertEqual(result.excerpt, "Gate decision Commits go through the flock gate.")
        XCTAssertEqual(try Data(contentsOf: metadata), indexBefore, "the app index is only read")

        let body = try XCTUnwrap(
            try service().search(AgentMemorySearchRequest(query: "prototype")).results.first)
        XCTAssertEqual(body.matchKind, .body)
        XCTAssertFalse(body.excerpt.contains("schema") || body.excerpt.contains("memory_id"))
        XCTAssertNil(
            try service().search(AgentMemorySearchRequest(query: "notes")).results.first {
                $0.document.title == "Notes"
            }?
            .document.documentID, "documents the app hasn't seen yet have no native ID")

        // Long bodies: about 120 characters around the first hit, `…` at the cut ends, no markup.
        let words = (0..<80).map { "word\($0)" }.joined(separator: " ")
        try write("\(projectPath)/Memories/Long.md", "# Long\n\n**\(words)** needle `\(words)`\n")
        let long = try XCTUnwrap(try service().search(AgentMemorySearchRequest(query: "needle")).results.first)
        XCTAssertTrue(long.excerpt.hasPrefix("…") && long.excerpt.hasSuffix("…"), long.excerpt)
        XCTAssertTrue(long.excerpt.contains("needle"))
        XCTAssertLessThanOrEqual(long.excerpt.count, 122)
        XCTAssertFalse(long.excerpt.contains("*") || long.excerpt.contains("`"))
    }

    func testCLIPrintsFieldsInTheDocumentedOrder() throws {
        try writeFixture()
        let output = run(["memory", "search", "gate", "--type", "decision", "--type", "handoff", "--limit", "5"])
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertEqual(output.stderr, "")
        let keys = [
            "title", "path", "documentId", "memoryId", "revision", "type", "project", "status", "agent", "session",
            "createdAt", "modified", "review", "pinned", "supersededBy", "matchKind", "excerpt",
        ]
        let positions = keys.map { output.stdout.range(of: "\"\($0)\" : ")?.lowerBound }
        XCTAssertFalse(positions.contains(nil), output.stdout)
        XCTAssertEqual(positions.compactMap { $0 }, positions.compactMap { $0 }.sorted(), output.stdout)
        let json = try result(output)
        let results = try XCTUnwrap(json["results"] as? [[String: Any]])
        XCTAssertEqual(results.compactMap { $0["type"] as? String }, ["decision", "handoff"])
        XCTAssertTrue(results[0]["documentId"] is NSNull)
        XCTAssertEqual(results[0]["review"] as? String, "unreviewed")
        XCTAssertEqual(results[0]["pinned"] as? Bool, false)
        XCTAssertEqual(results[0]["supersededBy"] as? [String], [])
        XCTAssertEqual(json["total"] as? Int, 2)
        let index = try XCTUnwrap(json["index"] as? [String: Any])
        XCTAssertEqual(index["state"] as? String, "ready")
        XCTAssertEqual(index["indexed"] as? Int, 5)
        XCTAssertEqual(index["total"] as? Int, 5)
        XCTAssertEqual(index["message"] as? String, "Up to date · 5 documents")
        XCTAssertNil(json["message"])

        let empty = try result(run(["memory", "search", "nothing"]))
        XCTAssertEqual(empty["message"] as? String, "No matches in Memory › Projects › Silkweb.")

        let refused = run(["memory", "search", "--project", "Other"])
        XCTAssertEqual(refused.status, 77)
        XCTAssertEqual(
            refused.stderr,
            "silkweb: That location is outside this grant’s read folders (Memory › Projects › Silkweb).\n")
        XCTAssertEqual(run(["memory", "search", "--created-after", "yesterday"]).status, 64)
        XCTAssertEqual(run(["memory", "search", "--limit", "ten"]).status, 64)
        XCTAssertEqual(run(["memory", "search", "--path", "x"]).status, 64)
        XCTAssertEqual(run(["memory", "read"]).status, 64, "read needs a path")
    }

    // MARK: Ranking

    func testRankingUsesTierThenKindThenRecencyAndSinksSupersededEntries() throws {
        let folder = "\(projectPath)/Memories"
        try write(
            "\(folder)/Alpha pinned.md",
            memory("m_pin", type: "progress", created: "2026-01-01T00:00:00Z", body: "alpha"))
        try write(
            "\(folder)/Alpha reviewed.md",
            memory("m_rev", type: "decision", created: "2026-01-02T00:00:00Z", body: "alpha"))
        try write(
            "\(folder)/Alpha new.md", memory("m_new", type: "memory", created: "2026-03-01T00:00:00Z", body: "alpha"))
        try write(
            "\(folder)/Alpha old.md", memory("m_old", type: "memory", created: "2026-02-01T00:00:00Z", body: "alpha"))
        try write(
            "\(folder)/Alpha handoff.md",
            memory("m_hand", type: "handoff", created: "2026-04-01T00:00:00Z", body: "alpha"))
        try write(
            "\(folder)/Alpha progress.md",
            memory("m_prog", type: "progress", created: "2026-05-01T00:00:00Z", body: "alpha"))
        try write(
            "\(folder)/Alpha changed.md",
            memory("m_chg", type: "decision", created: "2026-01-03T00:00:00Z", body: "alpha"))
        // Superseded by a reviewed document: sinks to the bottom of its tier but is still returned.
        try write(
            "\(folder)/Alpha stale.md",
            memory("m_stale", type: "decision", created: "2026-06-01T00:00:00Z", body: "alpha"))
        try write(
            "\(folder)/Alpha replacement.md",
            memory(
                "m_repl", type: "decision", created: "2026-01-04T00:00:00Z", supersedes: ["m_stale", "m_new"],
                body: "alpha"))
        // Body-only matches rank below every title match, whatever their kind.
        try write("\(folder)/Pinned body.md", memory("m_body", type: "decision", body: "alpha in the body"))

        let revisions = try Dictionary(
            uniqueKeysWithValues: FileManager.default.contentsOfDirectory(
                atPath: library.appendingPathComponent(folder).path
            )
            .map { name in
                (
                    "\(folder)/\(name)",
                    "sha256:"
                        + DocumentRevision(
                            data: try Data(contentsOf: library.appendingPathComponent("\(folder)/\(name)"))
                        ).digest
                )
            })
        let reviews: AgentMemoryReviewLookup = { _, path in
            let name = (path as NSString).lastPathComponent
            switch name {
            case "Alpha pinned.md", "Pinned body.md": return AgentMemoryReviewHint(pinned: true)
            case "Alpha reviewed.md", "Alpha replacement.md":
                return AgentMemoryReviewHint(reviewedRevision: revisions[path])
            case "Alpha changed.md":
                return AgentMemoryReviewHint(reviewedRevision: "sha256:" + String(repeating: "0", count: 64))
            default: return nil
            }
        }
        let response = try service(reviews: reviews).search(AgentMemorySearchRequest(query: "alpha", limit: 50))
        XCTAssertEqual(
            paths(response),
            [
                "Alpha pinned.md",
                "Alpha replacement.md", "Alpha reviewed.md", // reviewed decisions and memories, newest first
                "Alpha old.md", "Alpha changed.md", // unreviewed (an earlier revision counts as unreviewed)
                "Alpha handoff.md", "Alpha progress.md",
                "Alpha stale.md", "Alpha new.md", // superseded by a reviewed document
                "Pinned body.md",
            ])
        let byName = Dictionary(
            uniqueKeysWithValues: response.results.map { (($0.document.path as NSString).lastPathComponent, $0) })
        XCTAssertEqual(byName["Alpha changed.md"]?.document.review, .reviewedEarlierRevision)
        XCTAssertEqual(byName["Alpha reviewed.md"]?.document.review, .reviewed)
        XCTAssertEqual(byName["Alpha stale.md"]?.document.supersededBy, ["m_repl"])
        XCTAssertEqual(byName["Alpha pinned.md"]?.document.pinned, true)
        XCTAssertEqual(byName["Pinned body.md"]?.matchKind, .body)

        // Deterministic: the same answer every time, ending on document ID and path.
        for _ in 0..<3 {
            XCTAssertEqual(
                paths(try service(reviews: reviews).search(AgentMemorySearchRequest(query: "alpha", limit: 50))),
                paths(response))
        }
        // Title tiers come first: exact, prefix, word, then anywhere in the title.
        try write("\(projectPath)/Beta.md", "x")
        try write("\(projectPath)/Beta notes.md", "x")
        try write("\(projectPath)/Notes beta.md", "x")
        try write("\(projectPath)/Alphabeta.md", "x")
        XCTAssertEqual(
            paths(try service().search(AgentMemorySearchRequest(query: "beta"))),
            ["Beta.md", "Beta notes.md", "Notes beta.md", "Alphabeta.md"])
    }

    // MARK: Read-after-create and freshness

    func testReadAfterCreateInTheSameSessionWithoutTheApp() throws {
        try writeFixture()
        let session = service(options: AgentMemoryIndexOptions(readLimit: 0))
        let first = try session.search(AgentMemorySearchRequest(limit: 50))
        XCTAssertEqual(first.index.state, .indexing)
        XCTAssertEqual(first.index.reason, .firstRun)

        let created = "\(projectPath)/Progress/2026-10-07 0930 — Helper spike.md"
        try write(created, memory("mem_new", type: "progress", body: "# Helper spike\n\nReadback canary.\n"))
        // The create's own authorization (a Read Only grant here, so a read one stands in for it).
        session.didCreate(created, authorization: try session.session.authorize(.read, path: created))
        session.didCreate("Notes/Private/Diary.md", authorization: try session.session.authorize(.read))
        let found = try session.search(AgentMemorySearchRequest(query: "canary"))
        XCTAssertEqual(found.results.map(\.document.path), [created], "indexed immediately, despite the budget")
        XCTAssertEqual(found.index.state, .indexing, "the rest of the first build is still honest")
        let read = try session.read(AgentMemoryReadRequest(path: created))
        XCTAssertEqual(read.document.memoryID, "mem_new")
        XCTAssertEqual(read.page, "# Helper spike\n\nReadback canary.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(".silkweb").path))

        // A document that appears between searches is picked up by the next refresh too.
        let session2 = service()
        _ = try session2.search(AgentMemorySearchRequest())
        try write("\(projectPath)/Memories/Later.md", "# Later\n\nsecond canary\n")
        XCTAssertEqual(paths(try session2.search(AgentMemorySearchRequest(query: "second canary"))), ["Later.md"])
    }

    func testFreshnessReportsIndexingPartialAndReady() throws {
        try writeFixture()
        let slow = service(options: AgentMemoryIndexOptions(readLimit: 2))
        let first = try slow.search(AgentMemorySearchRequest(query: "no such words"))
        XCTAssertEqual(
            first.index, AgentMemoryFreshness(state: .indexing, indexed: 2, total: 5, skipped: 0, reason: .firstRun))
        XCTAssertEqual(first.index.message, "Indexing… 2 of 5 · Results may be incomplete")
        XCTAssertEqual(
            first.message, "No matches yet. The index isn’t finished, so this doesn’t mean no memory exists.")
        // Another process continues the same build from the cache, with the same reason.
        let next = try service(options: AgentMemoryIndexOptions(readLimit: 2)).search(AgentMemorySearchRequest())
        XCTAssertEqual(next.index.indexed, 4)
        XCTAssertEqual(next.index.reason, .firstRun)
        let done = try service(options: AgentMemoryIndexOptions(readLimit: 2)).search(AgentMemorySearchRequest())
        XCTAssertEqual(done.index, AgentMemoryFreshness(state: .ready, indexed: 5, total: 5, skipped: 0, reason: nil))

        // Unreadable, oversized or non-UTF-8 documents and unreadable Folders make it partial.
        let locked = try write("\(projectPath)/Memories/Locked.md", "flock locked")
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { chmod(locked.path, 0o644) }
        try Data([0xFF, 0xFE, 0x00]).write(to: library.appendingPathComponent("\(projectPath)/Memories/Binary.md"))
        try write("\(projectPath)/Memories/Huge.md", String(repeating: "x", count: 5000))
        let closed = library.appendingPathComponent("\(projectPath)/Closed")
        try FileManager.default.createDirectory(at: closed, withIntermediateDirectories: true)
        try Data("hidden".utf8).write(to: closed.appendingPathComponent("Inside.md"))
        XCTAssertEqual(chmod(closed.path, 0), 0)
        defer { chmod(closed.path, 0o755) }
        try writeGrants(limits: AgentGrantLimits(maxReadBytes: 4096))
        let partial = try service().search(AgentMemorySearchRequest(query: "flock"))
        XCTAssertEqual(partial.index.state, .partial)
        XCTAssertEqual(partial.index.skipped, 4)
        XCTAssertEqual(partial.index.indexed, 5)
        XCTAssertEqual(partial.index.total, 8)
        XCTAssertEqual(partial.index.message, "4 items couldn’t be read · Results may be incomplete")
        XCTAssertEqual(partial.total, 5)
        let json = partial.json.rendered
        XCTAssertTrue(json.contains("\"skipped\" : 4"), json)
    }

    func testCorruptOrNewerCacheIsRebuiltWithoutTouchingDocuments() throws {
        try writeFixture()
        let before = try libraryContents()
        _ = try service().search(AgentMemorySearchRequest())
        let cache = service().cacheURL
        XCTAssertEqual(cache.deletingLastPathComponent(), cacheDirectory)
        XCTAssertEqual(try permissions(cache), 0o600, "the cache is private to the owner")
        XCTAssertEqual(try permissions(cacheDirectory), 0o700)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 1)
        XCTAssertFalse(String(data: try Data(contentsOf: cache), encoding: .utf8)!.contains("secret"))

        for (contents, reason) in [
            ("{ not json", AgentMemoryFreshness.Reason.corrupt),
            (#"{"version":2,"records":"future"}"#, .unsupportedVersion),
        ] {
            try Data(contents.utf8).write(to: cache)
            let rebuilding = try service(options: AgentMemoryIndexOptions(readLimit: 1)).search(
                AgentMemorySearchRequest())
            XCTAssertEqual(rebuilding.index.state, .indexing)
            XCTAssertEqual(rebuilding.index.reason, reason)
            XCTAssertTrue(rebuilding.index.message.hasPrefix("Rebuilding the index… 1 of 5"), rebuilding.index.message)
            let rebuilt = try service().search(AgentMemorySearchRequest(query: "flock"))
            XCTAssertEqual(rebuilt.index.state, .ready)
            XCTAssertEqual(rebuilt.total, 5)
        }
        XCTAssertEqual(try libraryContents(), before, "documents are never written, and no app sidecar appears")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: library.appendingPathComponent(".silkweb/search-index.json").path))
    }

    func testCacheFromAnEarlierShapeStillLoads() throws {
        try write("\(projectPath)/Memories/Kept.md", "# Kept\n\nolder cache text\n")
        let session = service()
        _ = try session.search(AgentMemorySearchRequest())
        let cache = session.cacheURL
        // Strip optional keys, as a sparser earlier writer would have left them.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: cache)) as? [String: Any])
        json["building"] = nil
        json["records"] = (json["records"] as? [[String: Any]])?.map { record in
            record.filter { ["path", "size", "modified", "identity", "revision", "body"].contains($0.key) }
        }
        try JSONSerialization.data(withJSONObject: json).write(to: cache)
        let loaded = try service(options: AgentMemoryIndexOptions(readLimit: 0)).search(
            AgentMemorySearchRequest(query: "older"))
        XCTAssertEqual(loaded.index.state, .ready, "nothing needed a re-read")
        XCTAssertEqual(paths(loaded), ["Kept.md"])
    }

    func testRevokingOrRemovingTheGrantDeletesItsCache() throws {
        try writeFixture()
        let session = service()
        _ = try session.search(AgentMemorySearchRequest())
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.cacheURL.path))
        try writeGrants(revoked: true)
        assertRefused(try session.search(AgentMemorySearchRequest()), code: "grant_revoked")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.cacheURL.path))

        try writeGrants()
        _ = try session.search(AgentMemorySearchRequest())
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.cacheURL.path))
        try AgentGrantFile(grants: []).write(to: grantsURL)
        XCTAssertEqual(run(["memory", "search"]).status, 77)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.cacheURL.path))
        XCTAssertNotEqual(
            AgentMemoryService.grantID(project: "Silkweb"), AgentMemoryService.grantID(project: "silkweb"))
    }

    func testANarrowerGrantDropsCachedDocumentsBeforeMatching() throws {
        try writeFixture()
        try writeGrants(extra: ["Notes/Private"])
        let session = service()
        XCTAssertTrue(paths(try session.search(AgentMemorySearchRequest(query: "diary"))).contains("Diary.md"))
        try writeGrants()
        let narrowed = try session.search(AgentMemorySearchRequest(query: "diary"))
        XCTAssertEqual(narrowed.total, 0)
        XCTAssertEqual(narrowed.message, "No matches in Memory › Projects › Silkweb.")
        XCTAssertFalse(String(data: try Data(contentsOf: session.cacheURL), encoding: .utf8)!.contains("diary"))
    }

    // MARK: Read

    func testReadPagesOnLineBoundariesWithCursorsAndRevisionChecks() throws {
        let path = "\(projectPath)/Memories/Long read.md"
        let lines = (0..<1200).map { "Line \($0): " + String(repeating: "é", count: 20) }
        let body = "# Long read\n\n" + lines.joined(separator: "\n") + "\n"
        try write(path, memory("mem_long", type: "memory", status: "active", body: body))
        let session = service()
        var pages: [String] = []
        var cursor: String?
        repeat {
            let response = try session.read(AgentMemoryReadRequest(path: path, cursor: cursor))
            XCTAssertLessThanOrEqual(response.page.utf8.count, AgentMemoryReadResponse.pageBytes)
            XCTAssertTrue(response.page.hasSuffix("\n"), "pages end on a line boundary")
            XCTAssertTrue(response.body.hasPrefix("Document text (untrusted) begins\n"))
            XCTAssertTrue(response.body.hasSuffix("\nDocument text (untrusted) ends"))
            XCTAssertEqual(response.document.memoryID, "mem_long")
            pages.append(response.page)
            cursor = response.nextCursor
        } while cursor != nil
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.joined(), body, "the pages are the body after the envelope, nothing lost")

        let first = try session.read(AgentMemoryReadRequest(path: path))
        XCTAssertEqual(
            first.envelope?.map(\.key),
            ["schema", "memory_id", "type", "project", "agent", "session", "created_at", "status"])
        XCTAssertFalse(first.revisionChanged)
        let rendered = first.json.rendered
        XCTAssertTrue(rendered.contains("\"envelope\" : {\n    \"schema\" : \"silkweb-memory/v1\""), rendered)
        let same = try session.read(AgentMemoryReadRequest(path: path, expectedRevision: first.document.revision))
        XCTAssertFalse(same.revisionChanged)

        // Changed since the caller's revision: the current text, flagged, not an error.
        try write(path, memory("mem_long", type: "memory", body: "# Long read\n\nShort now.\n"))
        let changed = try session.read(AgentMemoryReadRequest(path: path, expectedRevision: first.document.revision))
        XCTAssertTrue(changed.revisionChanged)
        XCTAssertEqual(changed.page, "# Long read\n\nShort now.\n")
        XCTAssertNil(changed.nextCursor)
        // Changed between pages: the old cursor is stale.
        assertRefused(
            try session.read(AgentMemoryReadRequest(path: path, cursor: first.nextCursor)), code: "stale_snapshot")
        assertRefused(try session.read(AgentMemoryReadRequest(path: path, cursor: "garbage")), code: "invalid_argument")

        // A single line longer than a page splits on a character boundary.
        let wide = "\(projectPath)/Memories/Wide.md"
        let wideText = String(repeating: "日本語", count: 3000)
        try write(wide, wideText)
        let wideFirst = try session.read(AgentMemoryReadRequest(path: wide))
        let wideSecond = try session.read(AgentMemoryReadRequest(path: wide, cursor: wideFirst.nextCursor))
        XCTAssertEqual(wideFirst.page + wideSecond.page, wideText)
        XCTAssertNil(wideSecond.document.memoryID)
        XCTAssertNil(wideSecond.envelope)
    }

    func testReadRefusalsNeverIncludeDocumentText() throws {
        try writeFixture()
        try write(
            "\(projectPath)/Memories/Broken.md",
            "---\nschema: \"silkweb-memory/v1\"\nmemory_id: {\n---\n\nbroken secret\n")
        try write("\(projectPath)/Memories/Image.png", "png")
        let session = service()
        XCTAssertThrowsError(try session.read(AgentMemoryReadRequest(path: "\(projectPath)/Memories/Broken.md"))) {
            let error = $0 as? AgentAccessError
            XCTAssertEqual(error?.code, "envelope_malformed")
            XCTAssertEqual(
                error?.message, "The front matter in “Broken” couldn’t be read (line 3). The document is unchanged.")
        }
        // Still listed by title in search, without its text.
        let broken = try session.search(AgentMemorySearchRequest(query: "broken"))
        XCTAssertEqual(broken.results.map(\.excerpt), [""])
        XCTAssertEqual(try session.search(AgentMemorySearchRequest(query: "secret")).total, 0)

        assertRefused(try session.read(AgentMemoryReadRequest(path: "Notes/Private/Diary.md")), code: "out_of_scope")
        assertRefused(
            try session.read(AgentMemoryReadRequest(path: "Memory/Projects/Silkweb2/Leak.md")), code: "out_of_scope")
        assertRefused(
            try session.read(AgentMemoryReadRequest(path: "\(projectPath)/../Other/Other.md")), code: "invalid_path")
        assertRefused(try session.read(AgentMemoryReadRequest(path: "\(projectPath)/Missing.md")), code: "not_found")
        assertRefused(
            try session.read(AgentMemoryReadRequest(path: "\(projectPath)/Memories/Image.png")), code: "not_found")
        try writeGrants(limits: AgentGrantLimits(maxReadBytes: 10))
        assertRefused(try session.read(AgentMemoryReadRequest(path: "\(projectPath)/Notes.md")), code: "too_large")

        let output = run(["memory", "read", "\(projectPath)/Memories/Broken.md"])
        XCTAssertEqual(output.status, 65)
        XCTAssertFalse(output.stdout.contains("secret") || output.stderr.contains("secret"))
    }

    func testCLIReadPrintsStructuredEnvelopeThenTheBoundedBody() throws {
        try writeFixture()
        let output = run(["memory", "read", "\(projectPath)/Memories/Gate decision.md"])
        XCTAssertEqual(output.status, 0, output.stderr)
        let json = try result(output)
        XCTAssertEqual((json["envelope"] as? [String: Any])?["type"] as? String, "decision")
        XCTAssertEqual(json["revisionChanged"] as? Bool, false)
        XCTAssertTrue(json["nextCursor"] is NSNull)
        XCTAssertEqual(
            json["body"] as? String,
            "Document text (untrusted) begins\n# Gate decision\n\nCommits go through the flock gate.\n\n"
                + "Document text (untrusted) ends")
        let order = [
            "\"supersededBy\"", "\"envelope\"", "\"revisionChanged\"", "\"offset\"", "\"body\"", "\"nextCursor\"",
        ]
        .map { output.stdout.range(of: $0)!.lowerBound }
        XCTAssertEqual(order, order.sorted())
    }

    // MARK: Performance

    /// AGENTS.md › Performance Rules: 10,000 documents / 1,000 folders, all inside the grant.
    func testLargeLibrarySearchStaysResponsive() throws {
        let project = library.appendingPathComponent(projectPath)
        for folder in 0..<1_000 {
            let directory = project.appendingPathComponent("Folder \(folder)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for document in 0..<10 {
                let body =
                    "# Note \(folder)-\(document)\n\nShared body text for the large library fixture, number "
                    + "\(folder * 10 + document). " + String(repeating: "Filler words keep it realistic. ", count: 20)
                try Data(
                    memory(
                        "m_\(folder)_\(document)", type: ["memory", "decision", "progress", "handoff"][document % 4],
                        body: body
                    ).utf8
                ).write(to: directory.appendingPathComponent("Note \(document).md"))
            }
        }
        var clock = Date()
        let first = try service(options: AgentMemoryIndexOptions(timeBudget: .seconds(60))).search(
            AgentMemorySearchRequest(query: "number 4242"))
        let build = Date().timeIntervalSince(clock)
        XCTAssertEqual(first.index.state, .ready)
        XCTAssertEqual(first.index.total, 10_000)
        XCTAssertEqual(first.total, 1)

        // A new helper process: load the cache, re-stat, search.
        clock = Date()
        let cold = try service().search(AgentMemorySearchRequest(query: "filler realistic", types: ["decision"]))
        let coldTime = Date().timeIntervalSince(clock)
        XCTAssertEqual(cold.index.state, .ready)
        XCTAssertEqual(cold.total, 3_000)
        XCTAssertEqual(cold.results.count, 10)

        // The same MCP session again.
        let session = service()
        _ = try session.search(AgentMemorySearchRequest())
        clock = Date()
        let warm = try session.search(AgentMemorySearchRequest(query: "note 999-9"))
        let warmTime = Date().timeIntervalSince(clock)
        XCTAssertEqual(warm.results.first?.document.title, "Note 9")
        print(
            "Agent search, 10,000 documents / 1,000 folders: first build \(build)s, cold search \(coldTime)s, "
                + "warm search \(warmTime)s (budgets: 30s, 5s, 2s)")
        XCTAssertLessThan(build, 30)
        XCTAssertLessThan(coldTime, 5)
        XCTAssertLessThan(warmTime, 2)

        // A first run never blocks past its budget: it answers `indexing` and continues next time.
        try FileManager.default.removeItem(at: session.cacheURL)
        clock = Date()
        let bounded = try service(options: AgentMemoryIndexOptions(timeBudget: .milliseconds(300))).search(
            AgentMemorySearchRequest(query: "note"))
        XCTAssertLessThan(Date().timeIntervalSince(clock), 5)
        XCTAssertEqual(bounded.index.state, .indexing)
        XCTAssertLessThan(bounded.index.indexed, 10_000)
    }

    // MARK: Helpers

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    private func libraryContents() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: library.path))
        while let path = walker.nextObject() as? String {
            let url = library.appendingPathComponent(path)
            if let data = try? Data(contentsOf: url) { result[path] = data } else { result[path] = Data() }
        }
        return result
    }
}

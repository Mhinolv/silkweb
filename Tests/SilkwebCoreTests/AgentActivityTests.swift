import XCTest

@testable import SilkwebCore

/// #137: receipts read for display, matched to Documents, and Document Info provenance.
final class AgentActivityTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private let progress = "Memory/Projects/Silkweb/Progress"
    /// 2026-10-07 09:30:00 UTC.
    private let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentActivity-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        library = library.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func service(at date: Date? = nil) throws -> AgentCreateService {
        let grant = AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path))
        var service = AgentCreateService(
            library: library, grantId: "Silkweb", scope: try AgentScope(grant: grant),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        let now = date ?? fixedDate
        service.now = { now }
        service.timeZone = TimeZone(identifier: "UTC")!
        return service
    }

    @discardableResult
    private func create(
        _ title: String, agent: String = "claude-code", key: String? = nil, minutes: Double = 0
    ) throws -> AgentCreateResult {
        try service(at: fixedDate.addingTimeInterval(minutes * 60)).create(
            AgentCreateRequest(
                idempotencyKey: key ?? title, type: "progress", title: title, body: "Objective: \(title).",
                agent: agent, session: "s-1", client: "claude-code-cli"))
    }

    private func write(_ receipt: AgentReceipt) throws {
        let events = library.appendingPathComponent(".silkweb/agent-events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        try AgentReceipt.encoded(receipt).write(to: events.appendingPathComponent(receipt.operationId + ".json"))
    }

    /// Every file under `.silkweb/` with its bytes and modification date.
    private func metadataState() throws -> [String: String] {
        let metadata = library.appendingPathComponent(".silkweb")
        var state: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(at: metadata, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let data = values.isDirectory == true ? Data() : try Data(contentsOf: url)
            state[url.path] = "\(data.base64EncodedString()) \(values.contentModificationDate ?? .distantPast)"
        }
        return state
    }

    func testLoadReadsPublishedReceiptsAndWritesNothing() throws {
        XCTAssertEqual(AgentActivity.load(root: library), AgentActivity())
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: library.appendingPathComponent(".silkweb").path),
            "loading receipts created .silkweb")
        let created = try create("Helper spike")
        let events = library.appendingPathComponent(".silkweb/agent-events")
        // Temporary, hidden, foreign, oversized and undecodable files are skipped, never repaired.
        try Data("{".utf8).write(to: events.appendingPathComponent("op_broken.json"))
        try Data("{}".utf8).write(to: events.appendingPathComponent("op_x.json.tmp-1"))
        try Data("{}".utf8).write(to: events.appendingPathComponent(".hidden.json"))
        try Data("note".utf8).write(to: events.appendingPathComponent("README.md"))
        try Data(repeating: 0x20, count: 70_000).write(to: events.appendingPathComponent("op_huge.json"))
        try FileManager.default.createSymbolicLink(
            at: events.appendingPathComponent("op_link.json"),
            withDestinationURL: events.appendingPathComponent(created.receipt.operationId + ".json"))
        let before = try metadataState()
        let activity = AgentActivity.load(root: library)
        XCTAssertEqual(activity.receipts, [created.receipt])
        XCTAssertTrue(activity.hasPublished)
        XCTAssertEqual(try metadataState(), before, "loading receipts wrote to .silkweb")
    }

    /// Receipts written by #133 builds, and ones missing keys, still load (version 1, tolerant decoding).
    func testEarlierAndPartialReceiptsLoad() throws {
        let events = library.appendingPathComponent(".silkweb/agent-events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        let id = UUID()
        try Data(
            """
            {"agent":"codex","byteCount":12,"client":"cli","contentDigest":null,"createdAt":"2026-10-07T09:30:00Z",
            "destination":"Memory/A.md","documentId":"\(id.uuidString)","grantId":"Silkweb","idempotencyKey":"k",
            "memoryId":"mem_1","operationId":"op_a","outcome":"created","refusal":null,"requestDigest":"sha256:x",
            "session":"s","version":1}
            """.utf8
        ).write(to: events.appendingPathComponent("op_a.json"))
        try Data(#"{"operationId":"op_b","outcome":"published-later"}"#.utf8)
            .write(to: events.appendingPathComponent("op_b.json"))
        let receipts = AgentActivity.load(root: library).receipts
        XCTAssertEqual(receipts.map(\.operationId), ["op_a", "op_b"])
        XCTAssertEqual(receipts[0].documentId, id)
        XCTAssertEqual(receipts[0].agent, "codex")
        // An unknown outcome from a newer build counts as published.
        XCTAssertEqual(receipts[1].outcome, .created)
        XCTAssertEqual(receipts[1].agent, "")
    }

    func testHasPublishedNeedsACreatedOrReconciledReceipt() {
        func receipt(_ outcome: AgentCreateOutcome) -> AgentReceipt {
            AgentReceipt(
                operationId: "op_\(outcome)", idempotencyKey: "k", grantId: "Silkweb", client: "", agent: "a",
                session: "s", createdAt: "", requestDigest: "", outcome: outcome)
        }
        XCTAssertFalse(AgentActivity().hasPublished)
        XCTAssertFalse(AgentActivity(receipts: [receipt(.abandoned), receipt(.refused)]).hasPublished)
        XCTAssertTrue(AgentActivity(receipts: [receipt(.refused), receipt(.created)]).hasPublished)
        XCTAssertTrue(AgentActivity(receipts: [receipt(.reconciled)]).hasPublished)
    }

    func testEntriesFollowIdentityNewestFirstAndSkipMissingDocuments() async throws {
        let first = try create("First", agent: "agent-10", minutes: 0)
        let second = try create("Second", agent: "agent-2", minutes: 5)
        let third = try create("Third", agent: "agent-2", minutes: 10)
        let gone = try create("Gone", agent: "codex", minutes: 15)
        try Data("# Human\n".utf8).write(to: library.appendingPathComponent("Human.md"))
        // A refused create never appears, whatever its destination.
        try write(
            AgentReceipt(
                operationId: "op_refused", idempotencyKey: "r", grantId: "Silkweb", client: "", agent: "codex",
                session: "s", createdAt: "2026-10-08T00:00:00Z", destination: "Human.md", requestDigest: "",
                outcome: .refused, refusal: "out_of_scope"))
        // The owner renamed one in Silkweb (the index keeps its identity) and deleted another.
        let renamed = progress + "/Renamed.md"
        _ = try await LibraryMutations(root: library).rename(try XCTUnwrap(second.path), to: "Renamed.md")
        try FileManager.default.removeItem(at: library.appendingPathComponent(try XCTUnwrap(gone.path)))
        let snapshot = try await LibraryScanner.scan(root: library)
        let entries = AgentActivity.load(root: library).entries(in: snapshot)
        XCTAssertEqual(entries.map(\.document.relativePath), [third.path, renamed, first.path])
        XCTAssertEqual(entries.map(\.receipt.operationId), [third, second, first].map(\.receipt.operationId))
        XCTAssertEqual(entries.first?.date, fixedDate.addingTimeInterval(600))
        let agents = AgentActivity.agents(in: entries)
        XCTAssertEqual(agents.map(\.name), ["agent-2", "agent-10"])
        XCTAssertEqual(agents.map(\.count), [2, 1])
    }

    func testDestinationFallbackDuplicatesAndOrdering() async throws {
        for name in ["A.md", "B.md", "C.md", "D.md"] {
            try Data("# \(name)\n".utf8).write(to: library.appendingPathComponent(name))
        }
        let snapshot = try await LibraryScanner.scan(root: library)
        func receipt(
            _ id: String, path: String, created: String, documentID: UUID? = UUID(), agent: String = " "
        ) -> AgentReceipt {
            AgentReceipt(
                operationId: id, idempotencyKey: id, grantId: "Silkweb", client: "", agent: agent, session: "",
                createdAt: created, destination: path, documentId: documentID, requestDigest: "", outcome: .created)
        }
        let known = try XCTUnwrap(snapshot.metadata.IDsByPath["D.md"])
        let activity = AgentActivity(receipts: [
            // The index never learned this identity: the Document at the destination counts.
            receipt("op_a", path: "A.md", created: "2026-10-07T09:00:00Z"),
            // Two receipts for one Document: only the newest shows.
            receipt("op_b1", path: "B.md", created: "2026-10-07T08:00:00Z", documentID: nil),
            receipt("op_b2", path: "B.md", created: "2026-10-07T10:00:00.250Z", documentID: nil),
            // Unreadable dates sink to the end, in path order.
            receipt("op_c", path: "C.md", created: "yesterday", documentID: nil),
            // A known identity wins over the destination.
            receipt("op_d", path: "C.md", created: "2026-10-07T11:00:00Z", documentID: known),
        ])
        let entries = activity.entries(in: snapshot)
        XCTAssertEqual(entries.map(\.receipt.operationId), ["op_d", "op_b2", "op_a", "op_c"])
        XCTAssertEqual(entries.map(\.document.relativePath), ["D.md", "B.md", "A.md", "C.md"])
        XCTAssertNil(entries.last?.date)
        XCTAssertEqual(entries.first?.agent, "Unknown agent")
        XCTAssertEqual(AgentActivity().entries(in: snapshot), [])
    }

    func testProvenanceDistinguishesUnchangedEditedAndRenamed() throws {
        let created = try create("Helper spike")
        let path = try XCTUnwrap(created.path)
        let receipt = created.receipt
        var provenance = try XCTUnwrap(AgentProvenance.load(relativePath: path, root: library, receipt: receipt))
        XCTAssertEqual(provenance.agentLabel, "Agent-created · claude-code")
        XCTAssertEqual(provenance.session, "s-1")
        XCTAssertEqual(provenance.client, "claude-code-cli")
        XCTAssertEqual(provenance.operationLabel, receipt.operationId)
        XCTAssertEqual(provenance.created, fixedDate)
        XCTAssertEqual(provenance.sinceCreation, .unchanged)
        // A rename or move isn't an edit: the bytes are the same.
        let moved = "Moved Helper spike.md"
        try FileManager.default.moveItem(
            at: library.appendingPathComponent(path), to: library.appendingPathComponent(moved))
        provenance = try XCTUnwrap(AgentProvenance.load(relativePath: moved, root: library, receipt: receipt))
        XCTAssertEqual(provenance.sinceCreation, .unchanged)
        // Same length, other bytes: hashed.
        let url = library.appendingPathComponent(moved)
        var text = try String(contentsOf: url, encoding: .utf8)
        text = text.replacingOccurrences(of: "Objective", with: "Objectivf")
        try Data(text.utf8).write(to: url)
        XCTAssertEqual(try Data(contentsOf: url).count, receipt.byteCount)
        provenance = try XCTUnwrap(AgentProvenance.load(relativePath: moved, root: library, receipt: receipt))
        XCTAssertEqual(provenance.sinceCreation, .edited)
        // Longer than published, beyond the 64 KB head: an edit without reading it all.
        try Data((text + String(repeating: "More text.\n", count: 10_000)).utf8).write(to: url)
        provenance = try XCTUnwrap(AgentProvenance.load(relativePath: moved, root: library, receipt: receipt))
        XCTAssertEqual(provenance.sinceCreation, .edited)
        // Unreadable now (deleted): the receipt still says who claims it, with no comparison.
        try FileManager.default.removeItem(at: url)
        provenance = try XCTUnwrap(AgentProvenance.load(relativePath: moved, root: library, receipt: receipt))
        XCTAssertEqual(provenance.operationId, receipt.operationId)
        XCTAssertNil(provenance.sinceCreation)
    }

    func testProvenanceFromEnvelopeClaimsOnlyAndHumanDocuments() throws {
        let envelope =
            "---\nschema: \"silkweb-memory/v1\"\nmemory_id: \"mem_1\"\ntype: \"memory\"\nproject: \"Silkweb\"\n"
            + "agent: \"codex\"\nsession: \"2026-10-07-a\"\ncreated_at: \"2026-10-07T09:30:00Z\"\n---\n\n# Claimed\n"
        try Data(envelope.utf8).write(to: library.appendingPathComponent("Claimed.md"))
        let claimed = try XCTUnwrap(AgentProvenance.load(relativePath: "Claimed.md", root: library, receipt: nil))
        XCTAssertEqual(claimed.agentLabel, "codex (claimed)")
        XCTAssertEqual(claimed.session, "2026-10-07-a")
        XCTAssertEqual(claimed.operationLabel, "No Silkweb receipt")
        XCTAssertFalse(claimed.hasReceipt)
        XCTAssertNil(claimed.client)
        XCTAssertNil(claimed.created, "only the receipt dates a create")
        XCTAssertNil(claimed.sinceCreation)
        // Human Documents, other front matter, malformed envelopes and empty claims show nothing.
        let others = [
            "# Human\n", "---\ntitle: Jekyll\n---\n\n# Post\n",
            "---\nschema: \"silkweb-memory/v1\"\nagent: {name: x}\n---\n",
            "---\nschema: \"silkweb-memory/v1\"\nagent: \" \"\n---\n",
            "",
        ]
        for (index, text) in others.enumerated() {
            try Data(text.utf8).write(to: library.appendingPathComponent("Other \(index).md"))
            XCTAssertNil(
                AgentProvenance.load(relativePath: "Other \(index).md", root: library, receipt: nil), text)
        }
        XCTAssertNil(AgentProvenance.load(relativePath: "Missing.md", root: library, receipt: nil))
        // A link where the Document should be is never followed.
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: library.appendingPathComponent("Folder/Link.md"),
            withDestinationURL: library.appendingPathComponent("Claimed.md"))
        XCTAssertNil(AgentProvenance.load(relativePath: "Folder/Link.md", root: library, receipt: nil))
    }
}

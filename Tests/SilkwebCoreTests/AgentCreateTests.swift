import CryptoKit
import XCTest

@testable import SilkwebCore

/// #133: idempotent create-only publication, receipts and recovery.
final class AgentCreateTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!
    private let project = "Memory/Projects/Silkweb"
    /// 2026-10-07 09:30:00 UTC.
    private let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    private struct Crash: Error {}

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCreate-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(project + "/Memories"), withIntermediateDirectories: true)
        library = library.resolvingSymlinksInPath()
        grantsURL = root.appendingPathComponent("agent-grants.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func service(
        maxBytes: Int = AgentGrantLimits.defaultMaxCreateBytes,
        fault: (@Sendable (AgentCreateService.Step) throws -> Void)? = nil
    ) throws -> AgentCreateService {
        let grant = AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path))
        var service = AgentCreateService(
            library: library, grantId: "Silkweb", scope: try AgentScope(grant: grant), maxBytes: maxBytes)
        let date = fixedDate
        service.now = { date }
        service.timeZone = TimeZone(identifier: "UTC")!
        service.fault = fault
        return service
    }

    private func request(
        key: String = "key-1", type: String = "progress", title: String = "Helper spike",
        body: String = "Objective: prove creates are idempotent."
    ) -> AgentCreateRequest {
        AgentCreateRequest(
            idempotencyKey: key, type: type, title: title, body: body, agent: "claude-code", session: "s-1",
            status: "in-progress")
    }

    private func url(_ path: String) -> URL { library.appendingPathComponent(path) }
    private func text(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }
    private func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []).sorted()
    }

    /// Every file under the Library (including `.silkweb/`) with its bytes.
    private func tree() throws -> [String: Data] {
        var result: [String: Data] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: library.path))
        while let path = walker.nextObject() as? String {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url(path).path, isDirectory: &isFolder)
            result[path] = isFolder.boolValue ? Data() : try Data(contentsOf: url(path))
        }
        // The gate's lock file holds the last holder's pid only while held.
        result.removeValue(forKey: ".silkweb/library.lock")
        return result
    }

    private func code(_ body: () throws -> Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch let error as AgentAccessError {
            return error.code
        } catch {
            return "\(error)"
        }
    }

    // MARK: Create

    func testCreatePublishesOneDocumentWithEnvelopeIdentityAndReceipt() async throws {
        let result = try service().create(request())
        let path = project + "/Progress/2026-10-07 0930 — Helper spike.md"
        XCTAssertEqual(result.path, path)
        XCTAssertFalse(result.replayed)
        XCTAssertEqual(result.outcome, .created)

        let document = try text(path)
        guard case .envelope(let envelope, let body) = MemoryEnvelope.parse(document) else {
            return XCTFail("the document starts with a v1 envelope")
        }
        XCTAssertEqual(envelope.string("type"), "progress")
        XCTAssertEqual(envelope.string("project"), "Silkweb")
        XCTAssertEqual(envelope.string("created_at"), "2026-10-07T09:30:00Z")
        XCTAssertEqual(envelope.string("status"), "in-progress")
        XCTAssertEqual(String(document[body]), "# Helper spike\n\nObjective: prove creates are idempotent.")

        let receipt = result.receipt
        XCTAssertEqual(receipt.version, 1)
        XCTAssertEqual(receipt.destination, path)
        XCTAssertEqual(receipt.memoryId, envelope.memoryID)
        XCTAssertEqual(receipt.byteCount, Data(document.utf8).count)
        XCTAssertEqual(
            receipt.contentDigest,
            "sha256:" + SHA256.hash(data: Data(document.utf8)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(receipt.grantId, "Silkweb")
        XCTAssertEqual(receipt.agent, "claude-code")
        XCTAssertEqual(receipt.client, "cli")

        // The receipt on disk: sorted keys, every field present, no body text.
        let file = try String(
            contentsOf: url(".silkweb/agent-events/\(receipt.operationId).json"), encoding: .utf8)
        XCTAssertFalse(file.contains("Objective"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any]).keys.sorted()
        XCTAssertEqual(
            keys,
            [
                "agent", "byteCount", "client", "contentDigest", "createdAt", "destination", "documentId",
                "grantId", "idempotencyKey", "memoryId", "operationId", "outcome", "refusal", "requestDigest",
                "session", "version",
            ])
        XCTAssertEqual(try JSONDecoder().decode(AgentReceipt.self, from: Data(file.utf8)), receipt)
        XCTAssertEqual(names(".silkweb/agent-staging"), [], "nothing is left staged")

        // The app sees exactly one new Document, with the receipt's identity; nothing from `.silkweb/`.
        let snapshot = try await LibraryScanner.scan(root: library, writesMetadata: false)
        XCTAssertEqual(snapshot.documents.map(\.relativePath), [path])
        XCTAssertEqual(snapshot.documents.first?.id, receipt.documentId)
        XCTAssertNotNil(snapshot.metadata.IDsByPath[project + "/Progress"], "the folder made on demand is indexed")
        XCTAssertTrue(snapshot.folders.contains { $0.relativePath == project + "/Progress" })
    }

    func testMemoryAndHandoffNamesAndExistingHeadingIsKept() throws {
        let service = try service()
        let memory = try service.create(
            request(key: "m", type: "decision", title: "Use flock", body: "# Use flock\n\nWhy."))
        XCTAssertEqual(memory.path, project + "/Memories/Use flock.md")
        XCTAssertTrue(
            try text(memory.path!).hasSuffix("\n\n# Use flock\n\nWhy."), "an agent's own heading isn't doubled")
        let handoff = try service.create(request(key: "h", type: "handoff", title: "Resume here", body: ""))
        XCTAssertEqual(handoff.path, project + "/Handoffs/Resume here.md")
        XCTAssertTrue(try text(handoff.path!).hasSuffix("\n\n# Resume here\n"))
    }

    func testTakenNameGetsSuffixAndNeverReplaces() throws {
        try Data("owner text".utf8).write(to: url(project + "/Memories/Decision.md"))
        try Data("owner text 2".utf8).write(to: url(project + "/Memories/decision 2.md"))
        let result = try service().create(request(type: "memory", title: "Decision"))
        XCTAssertEqual(result.path, project + "/Memories/Decision 3.md", "case-insensitive names are taken too")
        XCTAssertEqual(try text(project + "/Memories/Decision.md"), "owner text")
        XCTAssertEqual(try text(project + "/Memories/decision 2.md"), "owner text 2")
    }

    func testConcurrentCreatesForTheSamePathNeverReplaceEachOther() throws {
        try Data("owner text".utf8).write(to: url(project + "/Memories/Shared.md"))
        let count = 12
        let results = Results()
        let services = try (0..<count).map { _ in try service() }
        DispatchQueue.concurrentPerform(iterations: count) { index in
            results.append(
                Result { try services[index].create(self.request(key: "k\(index)", type: "memory", title: "Shared")) })
        }
        let paths = try results.all.map { try XCTUnwrap(try $0.get().path) }
        XCTAssertEqual(Set(paths).count, count)
        XCTAssertEqual(try text(project + "/Memories/Shared.md"), "owner text")
        XCTAssertEqual(names(project + "/Memories").count, count + 1)
        let ids = try paths.map { MemoryEnvelope.parse(try text($0)) }.compactMap { parse -> String? in
            if case .envelope(let envelope, _) = parse { return envelope.memoryID }
            return nil
        }
        XCTAssertEqual(Set(ids).count, count, "each file holds its own create, none overwritten")
    }

    func testConcurrentRetriesOfOneKeyPublishOnce() throws {
        let results = Results()
        let services = try (0..<8).map { _ in try service() }
        DispatchQueue.concurrentPerform(iterations: 8) { index in
            results.append(Result { try services[index].create(self.request()) })
        }
        let all = try results.all.map { try $0.get() }
        XCTAssertEqual(all.filter { !$0.replayed }.count, 1)
        XCTAssertTrue(all.allSatisfy { $0.receipt == all[0].receipt })
        XCTAssertEqual(names(project + "/Progress").count, 1)
    }

    // MARK: Idempotency

    func testSameKeyAndPayloadReplaysTheOriginalReceipt() throws {
        let first = try service().create(request())
        let before = try tree()
        var later = try service()
        later.now = { Date(timeIntervalSince1970: 1_791_400_000) }
        let replay = try later.create(request())
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.outcome, .duplicate)
        XCTAssertEqual(replay.receipt, first.receipt)
        XCTAssertEqual(replay.path, first.path)
        XCTAssertEqual(try tree(), before, "a replay writes nothing")
    }

    func testSameKeyWithDifferentPayloadConflictsWithoutTouchingDisk() throws {
        _ = try service().create(request())
        let before = try tree()
        for changed in [
            request(body: "Different text"), request(title: "Other title"), request(type: "handoff"),
            request(body: String(repeating: "x", count: 300_000)),
        ] {
            XCTAssertThrowsError(try service().create(changed)) { error in
                XCTAssertEqual(error as? AgentAccessError, .idempotencyConflict)
            }
        }
        XCTAssertEqual(
            AgentAccessError.idempotencyConflict.message,
            "This request key was already used with different content. Nothing was changed. Use a new key.")
        XCTAssertEqual(try tree(), before)
        // Keys are per grant and per key: another key is a new create.
        XCTAssertFalse(try service().create(request(key: "key-2", body: "Different text")).replayed)
    }

    func testRetryKeepsOwnerEditsRenamesMovesAndTrash() async throws {
        let first = try service().create(request())
        let path = try XCTUnwrap(first.path)
        let edited = try text(path) + "\n\nOwner's note."
        try Data(edited.utf8).write(to: url(path))

        var replay = try service().create(request())
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(try text(path), edited, "a retry never reverts the owner's edit")

        let mutations = try LibraryMutations(root: library)
        _ = try await mutations.rename(path, to: "Renamed by owner.md")
        replay = try service().create(request())
        XCTAssertEqual(replay.path, project + "/Progress/Renamed by owner.md", "the path follows the document UUID")
        XCTAssertEqual(try text(project + "/Progress/Renamed by owner.md"), edited)

        _ = try await mutations.move(project + "/Progress/Renamed by owner.md", toFolder: project + "/Memories")
        replay = try service().create(request())
        XCTAssertEqual(replay.path, project + "/Memories/Renamed by owner.md")

        try FileManager.default.createDirectory(at: url("Elsewhere"), withIntermediateDirectories: true)
        _ = try await mutations.move(project + "/Memories/Renamed by owner.md", toFolder: "Elsewhere")
        replay = try service().create(request())
        XCTAssertTrue(replay.replayed)
        XCTAssertNil(replay.path, "a location outside the read folders is never revealed")

        let trash = root.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashService = try TrashService(root: library) { url in
            let target = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
        _ = try await trashService.execute(trashService.plan(["Elsewhere/Renamed by owner.md"]))
        let before = try tree()
        replay = try service().create(request())
        XCTAssertTrue(replay.replayed)
        XCTAssertNil(replay.path)
        XCTAssertEqual(replay.receipt, first.receipt, "the original receipt comes back")
        XCTAssertEqual(try tree(), before, "a trashed document isn't recreated")
    }

    // MARK: Failure injection

    func testInterruptedBeforePublishIsAbandonedThenRetried() throws {
        XCTAssertThrowsError(try service(fault: { if $0 == .intent { throw Crash() } }).create(request()))
        XCTAssertEqual(names(".silkweb/agent-staging").count, 2, "the staged file and its intent survive the crash")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(project + "/Progress").path))

        let settled = try service().reconcile()
        XCTAssertEqual(settled.map(\.outcome), [.abandoned])
        XCTAssertNil(settled.first?.destination)
        XCTAssertEqual(names(".silkweb/agent-staging"), [])
        let receipt = try JSONDecoder().decode(
            AgentReceipt.self,
            from: Data(contentsOf: url(".silkweb/agent-events/\(settled[0].operationId).json")))
        XCTAssertEqual(receipt.outcome, .abandoned, "the intent is recorded before the staged file is discarded")

        let retry = try service().create(request())
        XCTAssertFalse(retry.replayed, "an abandoned create was never published, so the agent simply retries")
        XCTAssertEqual(retry.outcome, .created)
        XCTAssertEqual(names(project + "/Progress").count, 1)
    }

    func testInterruptedAfterPublishIsReconciledAndNeverDuplicated() throws {
        for step in [AgentCreateService.Step.published, .indexed] {
            try? FileManager.default.removeItem(at: library)
            try FileManager.default.createDirectory(at: url(project), withIntermediateDirectories: true)
            XCTAssertThrowsError(try service(fault: { if $0 == step { throw Crash() } }).create(request()))
            let path = project + "/Progress/2026-10-07 0930 — Helper spike.md"
            let published = try text(path)
            // The owner edits the document before anything recovers.
            try Data((published + "\nOwner line").utf8).write(to: url(path))

            let settled = try service().reconcile()
            XCTAssertEqual(settled.map(\.outcome), [.reconciled], "\(step)")
            XCTAssertEqual(settled.first?.destination, path)
            XCTAssertNotNil(settled.first?.documentId)
            XCTAssertEqual(try text(path), published + "\nOwner line", "recovery never rewrites a published document")
            XCTAssertEqual(names(".silkweb/agent-staging"), [])
            XCTAssertEqual(try service().reconcile(), [], "recovery runs once")

            let retry = try service().create(request())
            XCTAssertTrue(retry.replayed, "\(step)")
            XCTAssertEqual(retry.receipt.outcome, .reconciled)
            XCTAssertEqual(retry.path, path)
            XCTAssertEqual(names(project + "/Progress"), [(path as NSString).lastPathComponent])
            XCTAssertEqual(try text(path), published + "\nOwner line")
        }
    }

    func testInterruptedAfterReceiptOnlyClearsTheJournal() throws {
        XCTAssertThrowsError(try service(fault: { if $0 == .receipt { throw Crash() } }).create(request()))
        XCTAssertEqual(names(".silkweb/agent-staging").count, 1)
        XCTAssertEqual(try service().reconcile(), [])
        XCTAssertEqual(names(".silkweb/agent-staging"), [])
        let retry = try service().create(request())
        XCTAssertTrue(retry.replayed)
        XCTAssertEqual(retry.receipt.outcome, .created)
    }

    func testReceiptWriteFailureKeepsThePublishedDocument() throws {
        // A file where the receipts folder should be makes every receipt write fail.
        try FileManager.default.createDirectory(at: url(".silkweb"), withIntermediateDirectories: true)
        try Data().write(to: url(".silkweb/agent-events"))
        XCTAssertThrowsError(try service().create(request())) { error in
            XCTAssertEqual(error as? AgentAccessError, .writeFailed)
        }
        let path = project + "/Progress/2026-10-07 0930 — Helper spike.md"
        let published = try text(path)
        XCTAssertTrue(
            published.contains("Objective"), "a published document is never deleted because its receipt failed")
        XCTAssertEqual(try service().reconcile(), [], "it stays journaled while receipts can't be written")
        XCTAssertEqual(try text(path), published)

        try FileManager.default.removeItem(at: url(".silkweb/agent-events"))
        let retry = try service().create(request())
        XCTAssertTrue(retry.replayed)
        XCTAssertEqual(retry.receipt.outcome, .reconciled)
        XCTAssertEqual(retry.path, path)
        XCTAssertEqual(names(project + "/Progress").count, 1)
    }

    func testRecoveryDiscardsOrphansButKeepsUnreadableJournalEntries() throws {
        let staging = url(".silkweb/agent-staging")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("half".utf8).write(to: staging.appendingPathComponent("A.md"))
        try Data("tmp".utf8).write(to: staging.appendingPathComponent("B.json.tmp-1"))
        try Data("not json".utf8).write(to: staging.appendingPathComponent("C.json"))
        try Data("kept".utf8).write(to: staging.appendingPathComponent("C.md"))
        XCTAssertEqual(try service().reconcile(), [])
        XCTAssertEqual(names(".silkweb/agent-staging"), ["C.json", "C.md"])
    }

    // MARK: Refusals

    func testRefusalsUseStableCodesAndCreateNothing() throws {
        let before = try tree()
        let cases: [(AgentCreateRequest, String)] = [
            (request(key: ""), "invalid_request"),
            (request(key: "a\nb"), "invalid_request"),
            (request(type: "note"), "envelope_invalid_field"),
            (request(title: "Bad: name"), "invalid_path"),
            (request(title: "  "), "invalid_path"),
            (request(type: "memory", title: "CLAUDE"), "excluded_name"),
        ]
        for (request, expected) in cases {
            XCTAssertEqual(code { try self.service().create(request) }, expected, request.title)
        }
        var outside = request()
        outside.folder = "Notes"
        XCTAssertEqual(code { try self.service().create(outside) }, "out_of_scope")
        outside.folder = project + "/Progress/Proposals"
        XCTAssertEqual(code { try self.service().create(outside) }, "excluded_name")
        outside.observedAt = "yesterday"
        outside.folder = nil
        XCTAssertEqual(code { try self.service().create(outside) }, "envelope_invalid_field")
        XCTAssertEqual(
            Set(try tree().keys).subtracting(before.keys).filter { !$0.hasPrefix(".silkweb") }, [],
            "no document or Folder appears")
    }

    func testOversizedAndEnvelopeBodiesAreRefusedWithReceipts() throws {
        let small = try service(maxBytes: 2048)
        XCTAssertThrowsError(try small.create(request(body: String(repeating: "x", count: 4096)))) { error in
            XCTAssertEqual(
                (error as? AgentAccessError)?.message,
                "This document is larger than the grant allows (2 KB). Nothing was created.")
        }
        let refused = try XCTUnwrap(small.receipt(small.operationID("key-1")))
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertEqual(refused.refusal, "too_large")
        XCTAssertNil(refused.destination)

        XCTAssertEqual(
            code { try self.service().create(self.request(key: "e1", body: "---\nschema: \"silkweb-memory/v1\"\n")) },
            "envelope_malformed")
        XCTAssertEqual(
            code {
                try self.service().create(
                    self.request(key: "e2", body: "---\nschema: \"silkweb-memory/v1\"\nmemory_id: \"x\"\n---\n\nHi"))
            }, "envelope_invalid_field")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(project + "/Progress").path))

        // A refused key can be fixed and retried.
        XCTAssertEqual(try service().create(request()).outcome, .created)
    }

    func testLinkedDestinationFolderIsRefused() throws {
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url(project + "/Progress"), withDestinationURL: outside)
        XCTAssertEqual(code { try self.service().create(self.request()) }, "invalid_path")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        // Never published, so recovery abandons it.
        XCTAssertEqual(names(".silkweb/agent-staging"), [])
    }

    func testCreateFolderMakesMissingFoldersOnce() throws {
        let service = try service()
        let made = try service.createFolder(project + "/Progress/Sprint 1")
        XCTAssertEqual(made, .init(path: project + "/Progress/Sprint 1", created: true))
        XCTAssertEqual(try service.createFolder(project + "/Progress/Sprint 1").created, false)
        let index = try LibraryMetadataStore.load(root: library).0
        XCTAssertNotNil(index.IDsByPath[project + "/Progress"])
        XCTAssertNotNil(index.IDsByPath[project + "/Progress/Sprint 1"])
        XCTAssertEqual(code { try service.createFolder("Notes/New") }, "out_of_scope")

        var request = request()
        request.folder = project + "/progress/sprint 1"
        let result = try service.create(request)
        XCTAssertEqual(
            result.path, project + "/Progress/Sprint 1/2026-10-07 0930 — Helper spike.md",
            "receipts and the index use the on-disk spelling")
    }

    // MARK: Formats

    func testReceiptsAndLimitsDecodeTolerantly() throws {
        let empty = try JSONDecoder().decode(AgentReceipt.self, from: Data("{}".utf8))
        XCTAssertEqual(empty.version, 1)
        XCTAssertEqual(empty.outcome, .created, "an unknown or missing outcome never allows a duplicate")
        let newer = try JSONDecoder().decode(
            AgentReceipt.self,
            from: Data(#"{"version":2,"outcome":"merged","destination":null,"byteCount":"x","extra":[1]}"#.utf8))
        XCTAssertEqual(newer.version, 2)
        XCTAssertTrue(newer.outcome.isPublished)
        XCTAssertNil(newer.destination)

        // Grants saved before #133 have no create limit.
        let limits = try JSONDecoder().decode(AgentGrantLimits.self, from: Data(#"{"max_read_bytes":10}"#.utf8))
        XCTAssertEqual(limits.maxCreateBytes, 262_144)
        XCTAssertEqual(
            try JSONDecoder().decode(AgentGrantLimits.self, from: Data(#"{"max_create_bytes":-1}"#.utf8))
                .maxCreateBytes, 262_144)

        // An index saved by an earlier build keeps its identities and gains the new document's.
        let existing = UUID()
        try FileManager.default.createDirectory(at: url(".silkweb"), withIntermediateDirectories: true)
        try Data(#"{"formatVersion":2,"IDsByPath":{"Memory":"\#(existing.uuidString)"}}"#.utf8)
            .write(to: url(".silkweb/index.json"))
        let result = try service().create(request())
        let index = try LibraryMetadataStore.load(root: library).0
        XCTAssertEqual(index.IDsByPath["Memory"], existing)
        XCTAssertEqual(index.IDsByPath[result.path!], result.receipt.documentId)
    }

    func testUnreadableIndexIsLeftForTheApp() throws {
        try FileManager.default.createDirectory(at: url(".silkweb"), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url(".silkweb/index.json"))
        let result = try service().create(request())
        XCTAssertEqual(try String(contentsOf: url(".silkweb/index.json"), encoding: .utf8), "not json")
        // Without the index the replay still finds the document by its `memory_id` at the destination.
        XCTAssertEqual(try service().create(request()).path, result.path)
    }

    // MARK: Helper

    func testHelperCreateReplayConflictAndCreateFolder() throws {
        try Data(
            """
            {"version":1,"grants":[{"project":"Silkweb","library":{"path":"\(library.path)"},"access":"read-create"}]}
            """.utf8
        ).write(to: grantsURL)
        let bodyURL = root.appendingPathComponent("body.md")
        try Data("Checkpoint.".utf8).write(to: bodyURL)
        let arguments = [
            "memory", "create", "--project", "Silkweb", "--key", "cli-1", "--type", "memory", "--title", "Note",
            "--agent", "codex", "--session", "s", "--body-file", bodyURL.path, "--client", "codex-cli", "--grants",
            grantsURL.path,
        ]
        let first = AgentHelper.run(arguments, home: root)
        XCTAssertEqual(first.status, 0, first.stderr)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(first.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(json["outcome"] as? String, "created")
        XCTAssertEqual(json["replayed"] as? Bool, false)
        XCTAssertEqual(json["path"] as? String, project + "/Memories/Note.md")
        XCTAssertEqual((json["receipt"] as? [String: Any])?["client"] as? String, "codex-cli")
        XCTAssertFalse(first.stdout.contains("Checkpoint."), "output never echoes body text")

        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data("Checkpoint.".utf8))
        try pipe.fileHandleForWriting.close()
        var stdinArguments = arguments
        stdinArguments[stdinArguments.firstIndex(of: bodyURL.path)!] = "-"
        let replay = AgentHelper.run(stdinArguments, home: root, standardInput: pipe.fileHandleForReading)
        XCTAssertEqual(replay.status, 0, replay.stderr)
        let replayJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(replay.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(replayJSON["replayed"] as? Bool, true)
        XCTAssertEqual(replayJSON["outcome"] as? String, "duplicate")

        try Data("Other text.".utf8).write(to: bodyURL)
        let conflict = AgentHelper.run(arguments, home: root)
        XCTAssertEqual(conflict.status, 1)
        XCTAssertTrue(conflict.stdout.contains("\"idempotency_conflict\""))
        XCTAssertFalse(conflict.stderr.contains("Other text"))

        let folder = AgentHelper.run(
            [
                "memory", "create-folder", "--project", "Silkweb", "--path", project + "/Handoffs/Next",
                "--grants", grantsURL.path,
            ], home: root)
        XCTAssertEqual(folder.status, 0, folder.stderr)
        XCTAssertTrue(folder.stdout.contains("\"created\" : true"))

        let missingKey = arguments.filter { $0 != "--key" && $0 != "cli-1" }
        XCTAssertEqual(AgentHelper.run(missingKey, home: root).status, 64, "required options are checked")
        XCTAssertEqual(AgentHelper.run(arguments + ["--title", "Twice"], home: root).status, 64)
    }
}

/// Collects results from `concurrentPerform`.
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Result<AgentCreateResult, Error>] = []
    func append(_ value: Result<AgentCreateResult, Error>) { lock.withLock { values.append(value) } }
    var all: [Result<AgentCreateResult, Error>] { lock.withLock { values } }
}

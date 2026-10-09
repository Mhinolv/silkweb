import Darwin
import XCTest

@testable import SilkwebCore

/// #204: direct updates of agent-created documents — compare-and-swap, eligibility, unsaved changes in the app,
/// the Library gate, earlier versions, receipts, idempotency and recovery.
final class AgentUpdateTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!
    private let project = "Memory/Projects/Silkweb"
    /// 2026-10-07 09:30:00 UTC.
    private let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    private struct Crash: Error {}

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentUpdate-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(project + "/Handoffs"), withIntermediateDirectories: true)
        library = library.resolvingSymlinksInPath()
        grantsURL = root.appendingPathComponent("agent-grants.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private var scope: AgentScope {
        get throws {
            try AgentScope(
                grant: AgentGrant(
                    project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreateUpdate))
        }
    }

    private func creates() throws -> AgentCreateService {
        var service = AgentCreateService(
            library: library, grantId: "Silkweb", scope: try scope, maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        let date = fixedDate
        service.now = { date }
        service.timeZone = TimeZone(identifier: "UTC")!
        return service
    }

    private func service(
        minutes: Double = 10, maxBytes: Int = AgentGrantLimits.defaultMaxCreateBytes,
        gateTimeout: Duration = LibraryGate.defaultTimeout,
        fault: (@Sendable (AgentUpdateService.Step) throws -> Void)? = nil
    ) throws -> AgentUpdateService {
        var service = AgentUpdateService(
            library: library, grantId: "Silkweb", scope: try scope, maxBytes: maxBytes,
            maxReadBytes: AgentGrantLimits.defaultMaxReadBytes)
        let date = fixedDate.addingTimeInterval(minutes * 60)
        service.now = { date }
        service.gateTimeout = gateTimeout
        service.fault = fault
        return service
    }

    @discardableResult
    private func create(_ title: String = "Next steps") throws -> AgentCreateResult {
        try creates().create(
            AgentCreateRequest(
                idempotencyKey: "create-" + title, type: "handoff", title: title, body: "Start with the gate.",
                agent: "claude-code", session: "s-1"))
    }

    private func url(_ path: String) -> URL { library.appendingPathComponent(path) }
    private func data(_ path: String) throws -> Data { try Data(contentsOf: url(path)) }
    private func text(_ path: String) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }
    private func revision(_ path: String) throws -> String { AgentCreateService.digest(try data(path)) }

    private func request(
        _ path: String, key: String = "update-1", revision: String, body: String = "# Next steps\n\nShip it.\n"
    ) -> AgentUpdateRequest {
        AgentUpdateRequest(
            idempotencyKey: key, path: path, expectedRevision: revision, body: body, agent: "claude-code",
            session: "s-2")
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

    private func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []).sorted()
    }

    /// Every saved earlier version, across Documents.
    private func savedVersions() -> [String] {
        names(".silkweb/agent-history").flatMap { names(".silkweb/agent-history/" + $0) }
    }

    /// The envelope's bytes: everything up to and including the closing line.
    private func envelopeBytes(_ path: String) throws -> Data {
        let text = try text(path)
        guard case .envelope(_, let body) = MemoryEnvelope.parse(text) else {
            XCTFail("no envelope")
            return Data()
        }
        return Data(String(text[..<body.lowerBound]).utf8)
    }

    // MARK: Update

    func testUpdateReplacesOnlyTheBodyKeepsTheEarlierVersionAndWritesAReceipt() throws {
        let created = try create()
        let path = try XCTUnwrap(created.path)
        let envelope = try envelopeBytes(path)
        let original = try data(path)
        let base = try revision(path)

        let result = try service().update(request(path, revision: base))
        XCTAssertEqual(result.outcome, .updated)
        XCTAssertFalse(result.replayed)
        XCTAssertEqual(result.path, path)
        XCTAssertEqual(try envelopeBytes(path), envelope, "the envelope's bytes are untouched")
        XCTAssertTrue(envelope.suffix(5) == Data("---\n\n".utf8), "the blank line after the envelope stays too")
        XCTAssertEqual(try text(path), String(decoding: envelope, as: UTF8.self) + "# Next steps\n\nShip it.\n")
        XCTAssertEqual(result.revision, try revision(path), "the result names the new revision")

        let receipt = result.receipt
        XCTAssertEqual(receipt.operation, .update)
        XCTAssertEqual(receipt.version, AgentReceipt.updateVersion)
        XCTAssertEqual(receipt.sequence, 1)
        XCTAssertEqual(receipt.baseDigest, base)
        XCTAssertEqual(receipt.memoryId, created.receipt.memoryId)
        XCTAssertEqual(receipt.documentId, created.receipt.documentId)
        XCTAssertEqual(receipt.destination, path)
        XCTAssertEqual(receipt.createdAt, "2026-10-07T09:40:00Z")
        XCTAssertEqual(receipt.agent, "claude-code")
        XCTAssertEqual(receipt.session, "s-2")

        // The earlier text is a plain Markdown file under `.silkweb/agent-history/<documentId>/`.
        let version = try XCTUnwrap(receipt.previousVersion)
        XCTAssertEqual(
            version,
            ".silkweb/agent-history/\(try XCTUnwrap(created.receipt.documentId).uuidString)/v0 2026-10-07 094000Z.md")
        XCTAssertEqual(try data(version), original)

        // The receipt on disk: version 2's keys, no text.
        let file = try String(
            contentsOf: url(".silkweb/agent-events/\(receipt.operationId).json"), encoding: .utf8)
        XCTAssertFalse(file.contains("Ship it"))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(file.utf8)) as? [String: Any]).keys.sorted()
        XCTAssertEqual(
            keys,
            [
                "agent", "baseDigest", "byteCount", "client", "contentDigest", "createdAt", "destination",
                "documentId", "grantId", "idempotencyKey", "memoryId", "operation", "operationId", "outcome",
                "previousVersion", "refusal", "requestDigest", "sequence", "session", "version",
            ])
        XCTAssertEqual(try JSONDecoder().decode(AgentReceipt.self, from: Data(file.utf8)), receipt)
        XCTAssertEqual(names(".silkweb/agent-update-staging"), [], "nothing is left staged")

        // A second update chains from the first: sequence 2, its own earlier version.
        let second = try service(minutes: 20).update(
            request(path, key: "update-2", revision: try revision(path), body: "Done."))
        XCTAssertEqual(second.receipt.sequence, 2)
        XCTAssertTrue(try text(path).hasSuffix("---\n\nDone."), "the body replaces exactly what memory_read returns")
        // What memory_read returns as the body goes back unchanged: a read-then-update round trip.
        let service = AgentMemoryService(
            session: AgentSession(project: "Silkweb", store: AgentGrantStore(url: grantsURL)),
            cacheDirectory: root.appendingPathComponent("cache"))
        try AgentGrantFile(grants: [
            AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreateUpdate)
        ]).write(to: grantsURL)
        let read = try service.read(AgentMemoryReadRequest(path: path))
        XCTAssertEqual(read.document.revision, try revision(path))
        XCTAssertEqual(read.page, "Done.")
        XCTAssertEqual(
            AgentCreateService.digest(try data(try XCTUnwrap(second.receipt.previousVersion))),
            result.receipt.contentDigest, "the second update kept the first update's text")
        XCTAssertEqual(names(".silkweb/agent-history/\(try XCTUnwrap(created.receipt.documentId).uuidString)").count, 2)

        // Nothing under `.silkweb/` is a Document: the app sees one Document.
        let scanned = names(project + "/Handoffs")
        XCTAssertEqual(scanned, ["Next steps.md"])
    }

    func testRevisionMismatchIsRefusedWithTheCurrentRevisionAndWritesNothing() throws {
        let path = try XCTUnwrap(create().path)
        let before = try data(path)
        do {
            _ = try service().update(request(path, revision: "sha256:" + String(repeating: "0", count: 64)))
            XCTFail("a stale revision was accepted")
        } catch let error as AgentAccessError {
            XCTAssertEqual(error.code, "revision_changed")
            XCTAssertEqual(error.currentRevision, AgentCreateService.digest(before))
            XCTAssertEqual(error.fields["currentRevision"] as? String, AgentCreateService.digest(before))
        }
        XCTAssertEqual(try data(path), before)
        XCTAssertEqual(savedVersions(), [], "a refused update keeps no version")
        // The refusal is recorded, and a retry with the same key and the right revision still works.
        let service = try service()
        let refused = try XCTUnwrap(service.creates.receipt(service.operationID("update-1")))
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertEqual(refused.refusal, "revision_changed")
        XCTAssertEqual(refused.operation, .update)
        XCTAssertEqual(try service.update(request(path, revision: AgentCreateService.digest(before))).outcome, .updated)
    }

    func testOwnerEditedAndHumanDocumentsNeedAProposal() throws {
        let path = try XCTUnwrap(create().path)
        // The owner edits the agent's document: proposal only, even with the right revision.
        try Data((try text(path) + "Owner note.\n").utf8).write(to: url(path))
        XCTAssertEqual(
            code { try self.service().update(self.request(path, revision: try self.revision(path))) },
            "update_requires_proposal")
        // A document the owner wrote, with or without a claimed envelope, never had a receipt.
        let human = project + "/Handoffs/Human.md"
        try Data("# Human\n\nMine.\n".utf8).write(to: url(human))
        XCTAssertEqual(
            code { try self.service().update(self.request(human, revision: try self.revision(human))) },
            "update_requires_proposal")
        let claimed = project + "/Handoffs/Claimed.md"
        try Data(
            ("---\nschema: \"silkweb-memory/v1\"\nmemory_id: \"mem_CLAIMED\"\ntype: \"handoff\"\nproject: \"Silkweb\"\n"
                + "agent: \"codex\"\nsession: \"s\"\ncreated_at: \"2026-10-07T09:30:00Z\"\n---\n\n# Claimed\n").utf8
        ).write(to: url(claimed))
        let claimedBefore = try data(claimed)
        XCTAssertEqual(
            code { try self.service().update(self.request(claimed, revision: try self.revision(claimed))) },
            "update_requires_proposal")
        XCTAssertEqual(try data(claimed), claimedBefore)
    }

    func testScopeAndInputRefusals() throws {
        let path = try XCTUnwrap(create().path)
        let revision = try revision(path)
        let notes = "Notes/Note.md"
        try FileManager.default.createDirectory(at: url("Notes"), withIntermediateDirectories: true)
        try Data("# Note\n".utf8).write(to: url(notes))
        XCTAssertEqual(code { try self.service().update(self.request(notes, revision: revision)) }, "out_of_scope")
        XCTAssertEqual(
            code { try self.service().update(self.request(self.project + "/Handoffs/Missing.md", revision: revision)) },
            "not_found")
        XCTAssertEqual(code { try self.service().update(self.request("../x.md", revision: revision)) }, "invalid_path")
        XCTAssertEqual(
            code { try self.service().update(self.request(self.project + "/Handoffs/AGENTS.md", revision: revision)) },
            "excluded_name")
        // A body that brings its own envelope is refused, never merged.
        XCTAssertEqual(
            code {
                try self.service().update(
                    self.request(path, revision: revision, body: "---\nschema: \"silkweb-memory/v1\"\n---\n"))
            }, "envelope_invalid_field")
        XCTAssertEqual(
            code {
                try self.service(maxBytes: 300).update(
                    self.request(path, revision: revision, body: String(repeating: "x", count: 400)))
            }, "too_large")
        XCTAssertEqual(
            code { try self.service().update(self.request(path, key: " ", revision: revision)) }, "invalid_argument")
        // By document ID: unknown IDs look like missing documents.
        var byID = request(path, revision: revision)
        byID.path = nil
        byID.documentID = UUID()
        XCTAssertEqual(code { try self.service().update(byID) }, "not_found")
        byID.documentID = try XCTUnwrap(AgentCreateService.index(library)?.IDsByPath[path])
        byID.idempotencyKey = "by-id"
        XCTAssertEqual(try service().update(byID).path, path)
    }

    func testIdempotentReplayAndConflict() throws {
        let path = try XCTUnwrap(create().path)
        let base = try revision(path)
        let first = try service().update(request(path, revision: base))
        let after = try data(path)
        // Same key and payload: the original result, and nothing written again (the revision moved on).
        let replay = try service(minutes: 30).update(request(path, revision: base))
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.outcome, .duplicate)
        XCTAssertEqual(replay.receipt, first.receipt)
        XCTAssertEqual(try data(path), after)
        // Same key, other payload: refused.
        XCTAssertEqual(
            code { try self.service().update(self.request(path, revision: base, body: "Other.")) },
            "idempotency_conflict")
        // A create key and an update key never share an operation.
        XCTAssertNotEqual(try service().operationID("k"), try creates().operationID("k"))
    }

    // MARK: Coordination

    /// The app's buffer has unsaved changes: the update is refused and neither disk nor the buffer changes. Once
    /// the buffer is back to the agent's text and saved, the marker is gone and the update goes through.
    func testUnsavedChangesInTheAppRefuseTheUpdate() async throws {
        let path = try XCTUnwrap(create().path)
        let document = url(path)
        let coordinator = SaveCoordinator(
            store: DocumentStore(root: library), recoveryDirectory: root.appendingPathComponent("Recovery"))
        let loaded = try await coordinator.open(document)
        let base = try revision(path)
        let before = try data(path)
        XCTAssertFalse(
            DocumentEditingMarker.isHeld(library: library, relativePath: path), "a clean buffer holds nothing")

        try await coordinator.edit(loaded.text + "Typing…", at: document)
        let holding = await coordinator.isHoldingEditingMarker(path)
        XCTAssertTrue(holding)
        XCTAssertTrue(DocumentEditingMarker.isHeld(library: library, relativePath: path))
        XCTAssertTrue(
            DocumentEditingMarker.isHeld(library: library, relativePath: path.uppercased()),
            "the key ignores case, as the default volume does")
        XCTAssertEqual(
            code { try self.service().update(self.request(path, revision: base)) }, "document_has_unsaved_changes")
        XCTAssertEqual(try data(path), before, "disk is unchanged")
        let draft = await coordinator.draft(for: document)
        XCTAssertEqual(draft, loaded.text + "Typing…", "the buffer is unchanged")
        let state = await coordinator.state(for: document)
        XCTAssertEqual(state, .dirty)

        // Back to the agent's text and saved: the bytes are still the agent's, and the marker is let go.
        try await coordinator.edit(loaded.text, at: document)
        let saved = await coordinator.save(document)
        XCTAssertEqual(saved, .clean)
        XCTAssertFalse(DocumentEditingMarker.isHeld(library: library, relativePath: path))
        XCTAssertEqual(names(".silkweb/editing"), [], "a released marker is removed")
        XCTAssertEqual(try service().update(request(path, key: "retry", revision: base)).outcome, .updated)

        // The clean buffer picks up the update like any external change.
        let reloaded = try await coordinator.reconcile(document)
        XCTAssertEqual(reloaded?.text, try text(path))
        let clean = await coordinator.state(for: document)
        XCTAssertEqual(clean, .clean)
    }

    /// A marker held by a process that died is gone with it (the kernel drops the lock); closing a buffer lets
    /// it go too.
    func testMarkerFollowsTheHolderAndClosing() async throws {
        let path = try XCTUnwrap(create().path)
        let document = url(path)
        var coordinator: SaveCoordinator? = SaveCoordinator(
            store: DocumentStore(root: library), recoveryDirectory: root.appendingPathComponent("Recovery"))
        let loaded = try await coordinator!.open(document)
        try await coordinator!.edit(loaded.text + "x", at: document)
        XCTAssertTrue(DocumentEditingMarker.isHeld(library: library, relativePath: path))
        coordinator = nil
        XCTAssertFalse(DocumentEditingMarker.isHeld(library: library, relativePath: path), "the holder went away")

        let other = SaveCoordinator(
            store: DocumentStore(root: library), recoveryDirectory: root.appendingPathComponent("Recovery 2"))
        _ = try await other.open(document)
        try await other.edit(loaded.text + "y", at: document)
        XCTAssertTrue(DocumentEditingMarker.isHeld(library: library, relativePath: path))
        let closed = await other.close(document)
        XCTAssertTrue(closed, "the close saved the buffer")
        XCTAssertFalse(DocumentEditingMarker.isHeld(library: library, relativePath: path))
    }

    /// Another writer holds the Library gate for the whole wait: `library_busy`, nothing written.
    func testUpdateWaitsForTheGateAndNeverWritesWithoutIt() throws {
        let path = try XCTUnwrap(create().path)
        let before = try data(path)
        let lease = try LibraryGate(root: library).acquire()
        XCTAssertEqual(
            code {
                try self.service(gateTimeout: .milliseconds(100)).update(
                    self.request(path, revision: try self.revision(path)))
            },
            "library_busy")
        XCTAssertEqual(try data(path), before)
        lease.release()
        XCTAssertEqual(try service().update(request(path, revision: try revision(path))).outcome, .updated)
    }

    /// A writer that doesn't take the gate changes the document after the update read it: the re-check before
    /// the rename refuses, the other writer's text stays, and the staged file and saved version are removed.
    func testChangeBetweenReadAndReplaceIsRefused() throws {
        let path = try XCTUnwrap(create().path)
        let target = url(path)
        let base = try revision(path)
        let external = Data((try text(path) + "Edited in another editor.\n").utf8)
        let service = try service(fault: { step in
            if step == .staged { try external.write(to: target) }
        })
        do {
            _ = try service.update(request(path, revision: base))
            XCTFail("the update replaced a document that changed under it")
        } catch let error as AgentAccessError {
            XCTAssertEqual(error.code, "revision_changed")
            XCTAssertEqual(error.currentRevision, AgentCreateService.digest(external))
        }
        XCTAssertEqual(try data(path), external, "the other writer's text survives")
        XCTAssertEqual(names(".silkweb/agent-update-staging"), [])
        XCTAssertEqual(savedVersions(), [], "a refused update keeps no version")
    }

    /// The app's save and an agent's update race for one document many times: each commit holds the gate and
    /// re-checks the revision, so the file is always one whole version and exactly one writer wins.
    func testConcurrentAppSaveAndAgentUpdateNeverTearTheFile() throws {
        let store = DocumentStore(root: library)
        var winners: Set<String> = []
        for round in 0..<12 {
            // A fresh agent Document each round: once the owner's save wins, a Document is proposal-only.
            let path = try XCTUnwrap(create("Race \(round)").path)
            let target = url(path)
            let base = try store.load(target)
            let mine = base.text + "Owner round \(round).\n" + String(repeating: "o", count: 20_000)
            let body = "Agent round \(round).\n" + String(repeating: "a", count: 20_000)
            let service = try service()
            let request = request(path, key: "race-\(round)", revision: "sha256:" + base.revision.digest, body: body)
            let results = ConcurrentResults()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 {
                    do {
                        _ = try store.save(mine, to: target, expectedRevision: base.revision)
                        results.record("app")
                    } catch {
                        results.record("app-refused")
                    }
                } else {
                    do {
                        _ = try service.update(request)
                        results.record("agent")
                    } catch {
                        results.record("agent-refused")
                    }
                }
            }
            let final = try text(path)
            let won = results.values.filter { $0 == "app" || $0 == "agent" }
            XCTAssertEqual(won.count, 1, "round \(round): \(results.values)")
            if won == ["app"] {
                XCTAssertEqual(final, mine, "round \(round)")
            } else {
                XCTAssertTrue(final.hasSuffix("\n" + body), "round \(round)")
                XCTAssertEqual(final.utf8.count, try data(path).count)
            }
            winners.formUnion(won)
        }
        XCTAssertFalse(winners.isEmpty)
    }

    // MARK: Recovery

    func testCrashBeforeReplaceIsAbandonedAndCleanedUp() throws {
        let path = try XCTUnwrap(create().path)
        let before = try data(path)
        let base = try revision(path)
        XCTAssertThrowsError(
            try service(fault: { if $0 == .staged { throw Crash() } }).update(request(path, revision: base)))
        XCTAssertEqual(try data(path), before)
        XCTAssertEqual(names(".silkweb/agent-update-staging").count, 2, "the journal and staged file wait")
        let settled = try service().reconcile()
        XCTAssertEqual(settled.map(\.outcome), [.abandoned])
        XCTAssertEqual(names(".silkweb/agent-update-staging"), [])
        XCTAssertEqual(savedVersions(), [], "an abandoned update keeps no version")
        // The key can still update.
        XCTAssertEqual(try service().update(request(path, revision: base)).outcome, .updated)
    }

    func testCrashAfterReplaceGetsItsReceiptOnTheNextOperation() throws {
        let path = try XCTUnwrap(create().path)
        let base = try revision(path)
        for step in [AgentUpdateService.Step.replaced, .receipt] {
            let key = "crash-\(step)"
            let current = try revision(path)
            XCTAssertThrowsError(
                try service(fault: { if $0 == step { throw Crash() } }).update(
                    request(path, key: key, revision: current, body: "After \(step).")))
            XCTAssertTrue(try text(path).hasSuffix("After \(step)."), "\(step): the document was replaced")
            // A retry of the same key finishes the receipt and replays it.
            let retry = try service().update(request(path, key: key, revision: current, body: "After \(step)."))
            XCTAssertTrue(retry.replayed, "\(step)")
            XCTAssertEqual(retry.receipt.outcome, .updated)
            XCTAssertEqual(retry.receipt.contentDigest, try revision(path))
            XCTAssertEqual(names(".silkweb/agent-update-staging"), [], "\(step)")
        }
        XCTAssertNotEqual(base, try revision(path))
        // And the document stays eligible: the reconciled receipt is the latest agent write.
        XCTAssertEqual(
            try service().update(request(path, key: "after", revision: try revision(path))).outcome, .updated)
    }

    // MARK: Receipts

    /// Create receipts keep version 1's shape; receipts from before #204 decode as creates.
    func testEarlierReceiptsDecodeAsCreates() throws {
        let decoded = try JSONDecoder().decode(
            AgentReceipt.self,
            from: Data(#"{"version":1,"operationId":"op_a","outcome":"created","contentDigest":"sha256:x"}"#.utf8))
        XCTAssertEqual(decoded.operation, .create)
        XCTAssertEqual(decoded.sequence, 0)
        XCTAssertNil(decoded.previousVersion)
        let weird = try JSONDecoder().decode(
            AgentReceipt.self, from: Data(#"{"operation":"merge","sequence":-4,"outcome":"updated"}"#.utf8))
        XCTAssertEqual(weird.operation, .create)
        XCTAssertEqual(weird.sequence, 0)
        XCTAssertTrue(weird.outcome.isPublished)
        let created = try create()
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: AgentReceipt.encoded(created.receipt)) as? [String: Any])
        XCTAssertNil(json["operation"], "create receipts keep version 1's keys")
        XCTAssertEqual(json["version"] as? Int, 1)
    }

    // MARK: Grants, CLI

    private func writeGrants(_ access: AgentGrant.Access) throws {
        try AgentGrantFile(grants: [
            AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path), access: access)
        ]).write(to: grantsURL)
    }

    private func cli(_ arguments: [String], stdin: String = "") -> (json: [String: Any], status: Int32) {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? pipe.fileHandleForWriting.close()
        let output = AgentHelper.run(
            ["memory"] + arguments + ["--grants", grantsURL.path], home: root, environment: [:],
            standardInput: pipe.fileHandleForReading)
        let json = (try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any]) ?? [:]
        return (json, output.status)
    }

    func testGrantProfilesAndCapabilities() throws {
        let decoded = try JSONDecoder().decode(
            AgentGrantFile.self,
            from: Data(
                #"{"version":1,"grants":[{"project":"Silkweb","library":{"path":"/L"},"access":"read-create-update"}]}"#
                    .utf8))
        XCTAssertEqual(decoded.grants.first?.access, .readCreateUpdate)
        XCTAssertEqual(AgentGrant.Access.readCreateUpdate.displayName, "Read, Create and Update")
        XCTAssertTrue(AgentGrant.Access.readCreateUpdate.allowsCreate)
        XCTAssertFalse(AgentGrant.Access.readCreate.allowsUpdate)

        let path = try XCTUnwrap(create().path)
        let revision = try revision(path)
        try Data("# Next steps\n\nFrom the CLI.\n".utf8).write(to: root.appendingPathComponent("body.md"))
        let update = [
            "update", path, "--expected-revision", revision, "--body-file", root.appendingPathComponent("body.md").path,
            "--agent", "codex", "--session", "s-9", "--idempotency-key", "cli-1",
        ]
        for access in [AgentGrant.Access.read, .readCreate] {
            try writeGrants(access)
            let capabilities = cli(["capabilities"]).json["result"] as? [String: Any]
            XCTAssertEqual(
                (capabilities?["operations"] as? [String])?.contains("update"), false, "\(access)")
            let refused = cli(update)
            XCTAssertEqual((refused.json["error"] as? [String: Any])?["code"] as? String, "update_not_allowed")
            XCTAssertEqual(refused.status, 77)
        }
        XCTAssertEqual(try data(path), try data(path))

        try writeGrants(.readCreateUpdate)
        let capabilities = try XCTUnwrap(cli(["capabilities"]).json["result"] as? [String: Any])
        XCTAssertEqual(capabilities["access"] as? String, "read-create-update")
        XCTAssertEqual(capabilities["profile"] as? String, "Read, Create and Update")
        XCTAssertEqual(
            capabilities["operations"] as? [String],
            ["capabilities", "list", "search", "read", "activity", "create", "create-folder", "update"])

        // A stale revision: exit 65 and the current revision in the error.
        var stale = update
        stale[3] = "sha256:" + String(repeating: "1", count: 64)
        let refused = cli(stale)
        XCTAssertEqual(refused.status, 65)
        let error = try XCTUnwrap(refused.json["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "revision_changed")
        XCTAssertEqual(error["currentRevision"] as? String, revision)

        let updated = cli(update)
        XCTAssertEqual(updated.status, 0, "\(updated.json)")
        let result = try XCTUnwrap(updated.json["result"] as? [String: Any])
        XCTAssertEqual(result["outcome"] as? String, "updated")
        XCTAssertEqual(result["replayed"] as? Bool, false)
        XCTAssertEqual(result["path"] as? String, path)
        XCTAssertEqual(result["revision"] as? String, try self.revision(path))
        XCTAssertEqual((result["receipt"] as? [String: Any])?["client"] as? String, "cli")
        XCTAssertTrue(try text(path).hasSuffix("---\n\n# Next steps\n\nFrom the CLI.\n"))
        let replayed = try XCTUnwrap(cli(update).json["result"] as? [String: Any])
        XCTAssertEqual(replayed["replayed"] as? Bool, true)

        // Usage: a path or --id, not both; the required options.
        XCTAssertEqual(
            cli(["update", "--expected-revision", "r", "--body-file", "-", "--agent", "a", "--session", "s"]).status, 64
        )
        XCTAssertEqual(cli(["update", path, "--body-file", "-", "--agent", "a", "--session", "s"]).status, 64)
        // Updates show in `memory activity`.
        let activity = try XCTUnwrap(cli(["activity"]).json["result"] as? [String: Any])
        let receipts = try XCTUnwrap(activity["receipts"] as? [[String: Any]])
        XCTAssertEqual(receipts.first?["operation"] as? String, "update")
    }

    func testGrantInitAddsTheProfileButNeverWidens() throws {
        let file = AgentGrantFile(grants: [
            AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreate)
        ])
        XCTAssertThrowsError(
            try AgentGrantInit.merge(
                file, project: "Silkweb", library: library, access: .readCreateUpdate, now: fixedDate))
        let wide = AgentGrantFile(grants: [
            AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreateUpdate)
        ])
        let narrowed = try AgentGrantInit.merge(
            wide, project: "Silkweb", library: library, access: .readCreate, now: fixedDate)
        XCTAssertEqual(narrowed.grant.access, .readCreate)
        let added = try AgentGrantInit.merge(
            AgentGrantFile(), project: "Silkweb", library: library, access: .readCreateUpdate, now: fixedDate)
        XCTAssertEqual(added.grant.access, .readCreateUpdate)
    }

    // MARK: Activity and provenance

    func testActivityAndProvenanceShowUpdates() async throws {
        let created = try create()
        let path = try XCTUnwrap(created.path)
        let first = try service(minutes: 10).update(request(path, revision: try revision(path), body: "One."))
        let second = try service(minutes: 20).update(
            request(path, key: "update-2", revision: try revision(path), body: "Two."))
        let snapshot = try await LibraryScanner.scan(root: library)
        let entries = AgentActivity.load(root: library).entries(in: snapshot)
        XCTAssertEqual(entries.count, 1, "one row per Document, not per operation")
        let entry = try XCTUnwrap(entries.first)
        XCTAssertTrue(entry.isUpdate)
        XCTAssertEqual(entry.receipt, second.receipt)
        XCTAssertEqual(entry.date, fixedDate.addingTimeInterval(1200))
        XCTAssertEqual(
            entry.receipts.map(\.operationId), [created.receipt, first.receipt, second.receipt].map(\.operationId))

        var provenance = try XCTUnwrap(
            AgentProvenance.load(relativePath: path, root: library, receipts: entry.receipts))
        XCTAssertEqual(provenance.agentLabel, "Agent-created · claude-code")
        XCTAssertEqual(provenance.session, "s-1", "the creator's claims")
        XCTAssertEqual(provenance.created, fixedDate)
        XCTAssertEqual(provenance.operationLabel, second.receipt.operationId, "the latest operation")
        XCTAssertEqual(provenance.updates, 2)
        XCTAssertEqual(provenance.updatesLabel, "2 updates")
        XCTAssertEqual(provenance.lastUpdate, fixedDate.addingTimeInterval(1200))
        XCTAssertEqual(provenance.sinceLabel, "Since last agent write")
        XCTAssertEqual(provenance.sinceValue(edited: "Oct 9"), "Unchanged")
        XCTAssertEqual(provenance.agentUpdates, .allowed)
        XCTAssertEqual(provenance.agentUpdates?.label, "Allowed")
        XCTAssertEqual(provenance.earlierVersions, 2)
        XCTAssertEqual(provenance.newestVersion, second.receipt.previousVersion)

        // The owner edits it: proposals only. A deleted saved version is no longer counted.
        try Data((try text(path) + "\nOwner.").utf8).write(to: url(path))
        try FileManager.default.removeItem(at: url(try XCTUnwrap(first.receipt.previousVersion)))
        provenance = try XCTUnwrap(AgentProvenance.load(relativePath: path, root: library, receipts: entry.receipts))
        XCTAssertEqual(
            provenance.sinceValue(edited: "Oct 9 at 3:10 PM"), "Edited after agent update · Oct 9 at 3:10 PM")
        XCTAssertEqual(provenance.agentUpdates?.label, "Proposals only · edited in Silkweb")
        XCTAssertEqual(provenance.earlierVersions, 1)

        // A created Document with no updates keeps #137's strings.
        let plain = try XCTUnwrap(AgentProvenance.load(relativePath: path, root: library, receipt: created.receipt))
        XCTAssertEqual(plain.sinceLabel, "Since creation")
        XCTAssertEqual(plain.updates, 0)
        // An envelope claim without a receipt.
        let claimed = project + "/Handoffs/Claimed.md"
        try Data(
            ("---\nschema: \"silkweb-memory/v1\"\nmemory_id: \"mem_C\"\ntype: \"handoff\"\nproject: \"Silkweb\"\n"
                + "agent: \"codex\"\nsession: \"s\"\ncreated_at: \"2026-10-07T09:30:00Z\"\n---\n\n# Claimed\n").utf8
        ).write(to: url(claimed))
        XCTAssertEqual(
            AgentProvenance.load(relativePath: claimed, root: library, receipts: [])?.agentUpdates?.label,
            "Proposals only · no Silkweb receipt")
    }
}

private final class ConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    func record(_ value: String) { lock.withLock { stored.append(value) } }
    var values: [String] { lock.withLock { stored } }
}

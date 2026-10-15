import Darwin
import XCTest

@testable import SilkwebCore

/// #140: owner-reviewed Proposals — the helper saves them under `.silkweb/proposals/` without touching a Document,
/// they decode tolerantly, and the app's apply replaces a Document only at its base revision.
final class AgentProposalsTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private let project = "Memory/Projects/Silkweb"
    /// 2026-10-07 09:30:00 UTC.
    private let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentProposals-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        for folder in ["Notes", "Archive", "Handoffs"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(project + "/" + folder), withIntermediateDirectories: true)
        }
        library = library.resolvingSymlinksInPath()
        try write("Notes/Plan.md", "# Plan\n\nOne\nTwo\nThree\n")
        try write("Notes/Ideas.md", "# Ideas\n\nAlpha\n")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func path(_ name: String) -> String { project + "/" + name }
    private func url(_ name: String) -> URL { library.appendingPathComponent(path(name)) }
    private func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: url(name))
    }
    private func text(_ name: String) throws -> String { try String(contentsOf: url(name), encoding: .utf8) }
    private func revision(_ name: String) throws -> String {
        AgentCreateService.digest(try Data(contentsOf: url(name)))
    }

    private func service(maxBytes: Int = AgentGrantLimits.defaultMaxCreateBytes) throws -> AgentProposeService {
        let scope = try AgentScope(
            grant: AgentGrant(
                project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreatePropose))
        var service = AgentProposeService(
            library: library, grantId: "Silkweb", scope: scope, maxBytes: maxBytes,
            maxReadBytes: AgentGrantLimits.defaultMaxReadBytes)
        let date = fixedDate
        service.now = { date }
        return service
    }

    private func request(
        _ kind: AgentProposal.Kind, key: String = "p-1", path: String? = nil, sources: [String] = [],
        revision: String? = nil, body: String? = nil, destination: String? = nil, title: String? = nil,
        reason: String = "Tidy up."
    ) -> AgentProposeRequest {
        AgentProposeRequest(
            kind: kind, idempotencyKey: key, path: path, sources: sources, expectedRevision: revision, body: body,
            destination: destination, title: title, reason: reason, agent: "claude-code", session: "s-1")
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

    private func proposalFiles() -> [String] {
        let folder = library.appendingPathComponent(".silkweb/proposals")
        return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    // MARK: Propose

    func testEditProposalIsSavedWithoutChangingTheDocumentAndReplays() throws {
        let before = try text("Notes/Plan.md")
        let base = try revision("Notes/Plan.md")
        let edit = request(.edit, path: path("Notes/Plan.md"), revision: base, body: "# Plan\n\nOne\nTwo!\nThree\n")
        let result = try service().propose(edit)
        XCTAssertFalse(result.replayed)
        XCTAssertEqual(try text("Notes/Plan.md"), before, "a proposal never changes the Document")
        XCTAssertEqual(proposalFiles(), [result.proposal.proposalId + ".json"])
        XCTAssertTrue(result.proposal.proposalId.hasPrefix("prop_"))
        XCTAssertEqual(result.proposal.proposalId.count, 37)
        XCTAssertEqual(result.proposal.status, .pending)
        XCTAssertEqual(result.proposal.createdAt, "2026-10-07T09:30:00Z")
        XCTAssertEqual(result.proposal.targets.map(\.path), [path("Notes/Plan.md")])
        XCTAssertEqual(result.proposal.targets.first?.baseRevision, base)
        let rendered = result.json.rendered(pretty: false)
        XCTAssertTrue(rendered.contains("\"status\":\"pending\""), rendered)
        XCTAssertFalse(rendered.contains("Two!"), "the result never echoes document text")

        // Same key and payload: the original, replayed. Same key, other payload: a conflict, nothing saved.
        let replay = try service().propose(edit)
        XCTAssertTrue(replay.replayed)
        XCTAssertEqual(replay.proposal, result.proposal)
        var other = edit
        other.body = "# Plan\n\nDifferent\n"
        XCTAssertEqual(code { try self.service().propose(other) }, "idempotency_conflict")
        XCTAssertEqual(proposalFiles().count, 1)

        // Loaded back from disk, the same Proposal.
        XCTAssertEqual(AgentProposalStore.load(root: library), [result.proposal])
        XCTAssertTrue(AgentProposalStore.exists(root: library))
    }

    func testEditValidationRefusesAndSavesNothing() throws {
        let base = try revision("Notes/Plan.md")
        let plan = path("Notes/Plan.md")
        let service = try service()
        // A revision the agent didn't read, no revision, the same text, an envelope, a blank or huge reason.
        XCTAssertEqual(
            code { try service.propose(self.request(.edit, path: plan, revision: "sha256:00", body: "x\n")) },
            "revision_changed")
        XCTAssertEqual(code { try service.propose(self.request(.edit, path: plan, body: "x\n")) }, "invalid_argument")
        XCTAssertEqual(
            code {
                try service.propose(
                    self.request(.edit, path: plan, revision: base, body: try self.text("Notes/Plan.md")))
            },
            "invalid_argument")
        let envelope =
            MemoryEnvelope(
                memoryID: "mem_01", type: "memory", project: "Silkweb", agent: "claude-code", session: "s-1",
                createdAt: fixedDate
            ).text + "\nBody\n"
        XCTAssertEqual(
            code { try service.propose(self.request(.edit, key: "p-env", path: plan, revision: base, body: envelope)) },
            "envelope_invalid_field")
        XCTAssertEqual(
            code { try service.propose(self.request(.edit, path: plan, revision: base, body: "x\n", reason: " \n\t")) },
            "invalid_argument")
        let long = String(repeating: "a", count: AgentProposeService.maxReasonLength + 1)
        XCTAssertEqual(
            code { try service.propose(self.request(.edit, path: plan, revision: base, body: "x\n", reason: long)) },
            "invalid_argument")
        // Outside the read folders, not Markdown, missing.
        try Data("x".utf8).write(to: library.appendingPathComponent("Outside.md"))
        XCTAssertNotNil(
            code { try service.propose(self.request(.edit, path: "Outside.md", revision: base, body: "x\n")) })
        try write("Notes/Data.txt", "x")
        XCTAssertEqual(
            code {
                try service.propose(self.request(.edit, path: self.path("Notes/Data.txt"), revision: base, body: "y"))
            },
            "not_found")
        XCTAssertEqual(
            code {
                try service.propose(self.request(.edit, path: self.path("Notes/Gone.md"), revision: base, body: "y"))
            },
            "not_found")
        // Too large for the grant: the finished text counts.
        XCTAssertEqual(
            code {
                try self.service(maxBytes: 8).propose(
                    self.request(.edit, path: plan, revision: base, body: "longer body\n"))
            },
            "too_large")
        XCTAssertEqual(proposalFiles(), [])
    }

    func testOrganizationProposalsValidateAndSave() throws {
        let service = try service()
        let plan = path("Notes/Plan.md")
        let move = try service.propose(self.request(.move, key: "m", path: plan, destination: path("Archive")))
        XCTAssertEqual(move.proposal.destination, path("Archive"))
        XCTAssertEqual(move.proposal.headline(), "Move “Plan” to Memory › Projects › Silkweb › Archive")
        let rename = try service.propose(self.request(.rename, key: "r", path: plan, title: "Roadmap"))
        XCTAssertEqual(rename.proposal.title, "Roadmap")
        XCTAssertEqual(rename.proposal.headline(), "Rename “Plan” to “Roadmap”")
        let merge = try service.propose(
            self.request(
                .merge, key: "g", sources: [plan, path("Notes/Ideas.md")], body: "# Both\n", destination: path("Notes"),
                title: "Both"))
        XCTAssertEqual(merge.proposal.targets.map(\.path), [plan, path("Notes/Ideas.md")])
        XCTAssertEqual(merge.proposal.headline(), "Merge 2 Documents into “Both”")
        XCTAssertEqual(proposalFiles().count, 3)

        // Refused: same folder, missing folder, same name, bad title, one source, a repeated source, empty body.
        XCTAssertEqual(
            code { try service.propose(self.request(.move, key: "a", path: plan, destination: self.path("Notes"))) },
            "invalid_argument")
        XCTAssertEqual(
            code { try service.propose(self.request(.move, key: "b", path: plan, destination: self.path("Nope"))) },
            "not_found")
        XCTAssertEqual(
            code { try service.propose(self.request(.rename, key: "c", path: plan, title: " Plan ")) },
            "invalid_argument")
        XCTAssertEqual(
            code { try service.propose(self.request(.rename, key: "d", path: plan, title: "a/b")) }, "invalid_argument")
        XCTAssertEqual(
            code { try service.propose(self.request(.rename, key: "e", path: plan, title: "AGENTS")) }, "excluded_name")
        XCTAssertEqual(
            code {
                try service.propose(
                    self.request(
                        .merge, key: "f", sources: [plan], body: "x", destination: self.path("Notes"), title: "X"))
            },
            "invalid_argument")
        XCTAssertEqual(
            code {
                try service.propose(
                    self.request(
                        .merge, key: "h", sources: [plan, plan], body: "x", destination: self.path("Notes"), title: "X")
                )
            },
            "invalid_argument")
        XCTAssertEqual(
            code {
                try service.propose(
                    self.request(
                        .merge, key: "i", sources: [plan, self.path("Notes/Ideas.md")], body: " \n",
                        destination: self.path("Notes"), title: "X"))
            }, "invalid_argument")
        // A stale revision on a move is refused when given.
        XCTAssertEqual(
            code {
                try service.propose(
                    self.request(.move, key: "j", path: plan, revision: "sha256:00", destination: self.path("Archive")))
            },
            "revision_changed")
        XCTAssertEqual(proposalFiles().count, 3)
        XCTAssertEqual(try text("Notes/Plan.md"), "# Plan\n\nOne\nTwo\nThree\n")
    }

    // MARK: Apply

    func testReplaceAppliesOnlyAtTheBaseRevisionAndKeepsPermissions() throws {
        let plan = path("Notes/Plan.md")
        let base = try revision("Notes/Plan.md")
        let original = try Data(contentsOf: url("Notes/Plan.md"))
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url("Notes/Plan.md").path)
        // A stale base changes nothing.
        XCTAssertThrowsError(
            try AgentProposalApply.replace(root: library, path: plan, expected: "sha256:00", with: Data("x".utf8))
        ) { XCTAssertEqual($0 as? AgentProposalError, .outOfDate("Plan")) }
        XCTAssertEqual(try Data(contentsOf: url("Notes/Plan.md")), original)

        let previous = try AgentProposalApply.replace(
            root: library, path: plan, expected: base, with: Data("Applied\n".utf8))
        XCTAssertEqual(previous, original, "Undo gets the replaced bytes")
        XCTAssertEqual(try text("Notes/Plan.md"), "Applied\n")
        let mode = try FileManager.default.attributesOfItem(atPath: url("Notes/Plan.md").path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o640)
        XCTAssertEqual(AgentProposalApply.revision(root: library, path: plan)?.text, "Applied\n")

        // Undo: only while the bytes are still what Apply wrote.
        let applied = AgentProposalApply.revision(of: Data("Applied\n".utf8))
        try AgentProposalApply.replace(root: library, path: plan, expected: applied, with: previous)
        XCTAssertEqual(try Data(contentsOf: url("Notes/Plan.md")), original)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: url("Notes").path).contains {
                $0.hasPrefix(".silkweb-")
            },
            "no staged file is left behind")

        XCTAssertThrowsError(
            try AgentProposalApply.replace(root: library, path: path("Notes/Gone.md"), expected: base, with: Data())
        ) { XCTAssertEqual($0 as? AgentProposalError, .sourceMissing) }
        XCTAssertNil(AgentProposalApply.revision(root: library, path: path("Notes/Gone.md")))
    }

    func testReplaceRefusesADocumentWithUnsavedChanges() async throws {
        let plan = path("Notes/Plan.md")
        let document = url("Notes/Plan.md")
        let base = try revision("Notes/Plan.md")
        let coordinator = SaveCoordinator(
            store: DocumentStore(root: library), recoveryDirectory: root.appendingPathComponent("Recovery"))
        let loaded = try await coordinator.open(document)
        try await coordinator.edit(loaded.text + "Typing…", at: document)
        XCTAssertThrowsError(
            try AgentProposalApply.replace(root: library, path: plan, expected: base, with: Data("x".utf8))
        ) { XCTAssertEqual($0 as? AgentProposalError, .unsavedChanges("Plan")) }
        XCTAssertEqual(try revision("Notes/Plan.md"), base)
    }

    func testStoreUpdateRecordsTheDecision() throws {
        let saved = try service().propose(request(.rename, path: path("Notes/Plan.md"), title: "Roadmap")).proposal
        let rejected = try AgentProposalStore.update(saved.proposalId, root: library) {
            $0.status = .rejected
            $0.decidedAt = "2026-10-08T10:00:00Z"
        }
        XCTAssertEqual(AgentProposalStore.load(root: library), [rejected])
        XCTAssertEqual(rejected.decided, AgentActivity.date("2026-10-08T10:00:00Z"))
        XCTAssertFalse(rejected.isPending)
        XCTAssertThrowsError(try AgentProposalStore.update("prop_missing", root: library) { _ in }) {
            XCTAssertEqual($0 as? AgentProposalError, .missing)
        }
    }

    // MARK: Command line

    private func cli(_ access: AgentGrant.Access, _ arguments: [String], stdin: String = "") throws
        -> (json: [String: Any], status: Int32)
    {
        let grants = root.appendingPathComponent("agent-grants.json")
        try AgentGrantFile(grants: [
            AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path), access: access)
        ]).write(to: grants)
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? pipe.fileHandleForWriting.close()
        let output = AgentHelper.run(
            ["memory"] + arguments + ["--grants", grants.path], home: root, environment: [:],
            standardInput: pipe.fileHandleForReading)
        let json = (try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any]) ?? [:]
        return (json, output.status)
    }

    private func errorCode(_ json: [String: Any]) -> String? {
        (json["error"] as? [String: Any])?["code"] as? String
    }

    func testProfilesAllowProposingOnlyFromReadCreatePropose() throws {
        XCTAssertFalse(AgentGrant.Access.read.allowsPropose)
        XCTAssertFalse(AgentGrant.Access.readCreate.allowsPropose)
        XCTAssertTrue(AgentGrant.Access.readCreatePropose.allowsPropose)
        XCTAssertFalse(AgentGrant.Access.readCreatePropose.allowsUpdate)
        XCTAssertTrue(AgentGrant.Access.readCreateUpdate.allowsPropose)
        XCTAssertEqual(AgentGrant.Access.readCreatePropose.displayName, "Read, Create and Propose")
        XCTAssertLessThan(AgentGrant.Access.readCreate.rank, AgentGrant.Access.readCreatePropose.rank)
        XCTAssertLessThan(AgentGrant.Access.readCreatePropose.rank, AgentGrant.Access.readCreateUpdate.rank)
        let decoded = try JSONDecoder().decode(
            AgentGrantFile.self,
            from: Data(
                #"{"version":1,"grants":[{"project":"S","library":{"path":"/L"},"access":"read-create-propose"}]}"#
                    .utf8))
        XCTAssertEqual(decoded.grants.first?.access, .readCreatePropose)

        let move = [
            "propose-organization", "--kind", "move", path("Notes/Plan.md"), "--destination", path("Archive"),
            "--reason", "Archive it", "--agent", "a", "--session", "s",
        ]
        let refused = try cli(.readCreate, move)
        XCTAssertEqual(
            errorCode(refused.json), "propose_not_allowed",
            "\((refused.json["error"] as? [String: Any])?["message"] ?? "")")
        XCTAssertEqual(refused.status, 77)
        XCTAssertEqual(proposalFiles(), [])

        let capabilities = try cli(.readCreatePropose, ["capabilities"])
        let result = try XCTUnwrap(capabilities.json["result"] as? [String: Any])
        XCTAssertEqual(result["profile"] as? String, "Read, Create and Propose")
        let operations = try XCTUnwrap(result["operations"] as? [String])
        XCTAssertTrue(operations.contains("propose-change"))
        XCTAssertFalse(operations.contains("update"))
    }

    func testCommandLineProposesEveryKind() throws {
        let plan = path("Notes/Plan.md")
        let who = ["--reason", "Because", "--agent", "a", "--session", "s"]
        let edit = try cli(
            .readCreatePropose,
            ["propose-change", plan, "--expected-revision", try revision("Notes/Plan.md"), "--body-file", "-"] + who,
            stdin: "# Plan\n\nNew\n")
        XCTAssertEqual(edit.status, 0, "\(edit.json)")
        XCTAssertEqual((edit.json["result"] as? [String: Any])?["kind"] as? String, "edit")
        for arguments in [
            ["propose-organization", "--kind", "move", plan, "--destination", path("Archive")],
            ["propose-organization", "--kind", "rename", plan, "--title", "Roadmap"],
            [
                "propose-organization", "--kind", "merge", "--source", plan, "--source", path("Notes/Ideas.md"),
                "--title", "Both", "--destination", path("Notes"), "--body-file", "-",
            ],
        ] {
            let result = try cli(.readCreatePropose, arguments + who, stdin: "# Both\n")
            XCTAssertEqual(result.status, 0, "\(arguments): \(result.json)")
        }
        XCTAssertEqual(proposalFiles().count, 4)
        XCTAssertEqual(try text("Notes/Plan.md"), "# Plan\n\nOne\nTwo\nThree\n")

        // Usage mistakes: exit 64, nothing saved.
        for arguments in [
            ["propose-organization", "--kind", "edit", plan],
            ["propose-organization", "--kind", "move", plan],
            ["propose-organization", "--kind", "rename", plan, "--id", UUID().uuidString, "--title", "X"],
            ["propose-organization", "--kind", "move", plan, "--destination", "X", "--source", plan],
            [
                "propose-organization", "--kind", "merge", plan, "--title", "X", "--destination", "X", "--body-file",
                "-",
            ],
            ["propose-organization", "--kind", "merge", "--source", plan, "--title", "X", "--destination", "X"],
            ["propose-change", plan, "--expected-revision", "r", "--body-file", "-", "--agent", "a", "--session", "s"],
        ] {
            let result = try cli(.readCreatePropose, arguments + (arguments.contains("--agent") ? [] : who))
            XCTAssertEqual(result.status, 64, "\(arguments)")
            XCTAssertEqual(errorCode(result.json), "invalid_argument")
        }
        XCTAssertEqual(proposalFiles().count, 4)
    }

    // MARK: Format

    func testDecodingIsTolerantAndUnknownKindsAreSkipped() throws {
        let minimal = try JSONDecoder().decode(
            AgentProposal.self, from: Data(#"{"proposalId":"prop_1","kind":"edit"}"#.utf8))
        XCTAssertEqual(minimal.version, 1)
        XCTAssertEqual(minimal.status, .pending)
        XCTAssertEqual(minimal.targets, [])
        XCTAssertNil(minimal.body)
        let unknownStatus = try JSONDecoder().decode(
            AgentProposal.self,
            from: Data(#"{"proposalId":"prop_2","kind":"move","status":"snoozed","targets":[{"path":"a.md"}]}"#.utf8))
        XCTAssertEqual(unknownStatus.status, .rejected, "nothing unknown is ever applicable")
        XCTAssertEqual(unknownStatus.targets.first?.path, "a.md")
        XCTAssertEqual(unknownStatus.targets.first?.baseRevision, "")
        XCTAssertNil(unknownStatus.targets.first?.documentId)
        XCTAssertThrowsError(
            try JSONDecoder().decode(AgentProposal.self, from: Data(#"{"proposalId":"prop_3","kind":"split"}"#.utf8)))

        // Round trip, and the store skips files it can't use.
        let saved = try service().propose(
            request(.rename, path: path("Notes/Plan.md"), title: "Roadmap")
        ).proposal
        XCTAssertEqual(try JSONDecoder().decode(AgentProposal.self, from: JSONEncoder().encode(saved)), saved)
        let folder = library.appendingPathComponent(".silkweb/proposals")
        try Data(#"{"proposalId":"prop_x","kind":"split"}"#.utf8).write(
            to: folder.appendingPathComponent("prop_x.json"))
        try Data("not json".utf8).write(to: folder.appendingPathComponent("prop_y.json"))
        try Data(#"{"proposalId":"prop_other","kind":"edit"}"#.utf8).write(
            to: folder.appendingPathComponent("prop_z.json"))
        try Data("{}".utf8).write(to: folder.appendingPathComponent("x.json.tmp-1"))
        XCTAssertEqual(AgentProposalStore.load(root: library), [saved])
    }

    func testEditedTextKeepsTheEnvelopeByteForByte() throws {
        let header =
            MemoryEnvelope(
                memoryID: "mem_01", type: "memory", project: "Silkweb", agent: "claude-code", session: "s-1",
                createdAt: fixedDate
            ).text + "\n"
        var proposal = AgentProposal(
            proposalId: "prop_1", kind: .edit, createdAt: "", agent: "", session: "", client: "", grantId: "",
            idempotencyKey: "", requestDigest: "", reason: "", targets: [], body: "New body\n")
        XCTAssertEqual(proposal.editedText(current: header + "Old body\n"), header + "New body\n")
        XCTAssertEqual(proposal.editedText(current: "Plain\n"), "New body\n")
        proposal.kind = .move
        XCTAssertNil(proposal.editedText(current: "Plain\n"))
    }

    func testReasonIsFlattenedToOneLine() throws {
        XCTAssertEqual(try AgentProposeService.reason("  Fix\nthe\t\tsidebar  drag \r\n"), "Fix the sidebar drag")
        let limit = String(repeating: "é", count: AgentProposeService.maxReasonLength)
        XCTAssertEqual(try AgentProposeService.reason(limit), limit)
    }
}

import XCTest

@testable import SilkwebCore

/// #206: a grant's `agent_folder` makes `Memory/Agents/<Key>` readable whole, creates go only in its
/// `Memories` with the agent folder key as envelope `project`, search accepts the key as `project` and ranks
/// project documents first on ties, capabilities reports the roots, and an invalid key fails the grant closed.
final class AgentFolderTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!
    private let project = "Memory/Projects/Silkweb"
    private let agent = "Memory/Agents/Claude"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentFolder-\(UUID().uuidString)")
        library = root.appendingPathComponent("Writing Library")
        grantsURL = root.appendingPathComponent("grants.json")
        for folder in [project, "Memory/Projects/Other", agent, "Memory/Agents/Codex"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        // The owner's hand-placed decision document, at the top of the agent folder, without front matter.
        try write(
            "# How Claude works\n\nAlways run the quartz check before handing off.\n", "\(agent)/How Claude works.md")
        try write("# Codex notes\n\nquartz secrets for another agent\n", "Memory/Agents/Codex/Codex notes.md")
        try writeGrants([grant(), grant("Other")])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func grant(
        _ project: String = "Silkweb", access: AgentGrant.Access = .readCreate, agentFolder: String? = "Claude"
    ) -> AgentGrant {
        AgentGrant(
            project: project, library: LibraryLocation(path: library.path), access: access, agentFolder: agentFolder)
    }

    private func writeGrants(_ grants: [AgentGrant]) throws {
        try AgentGrantFile(grants: grants).write(to: grantsURL)
    }

    private func write(_ text: String, _ path: String, modified: Date? = nil) throws {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified { try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path) }
    }

    private func run(_ arguments: [String], grant: String = "Silkweb", stdin: String? = nil) -> AgentHelper.Output {
        let pipe = Pipe()
        if let stdin { pipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? pipe.fileHandleForWriting.close()
        return AgentHelper.run(
            arguments + ["--grants", grantsURL.path, "--grant", grant], home: root, environment: [:],
            standardInput: pipe.fileHandleForReading)
    }

    private func json(_ output: AgentHelper.Output) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any], output.stdout)
    }

    private func result(_ output: AgentHelper.Output, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: Any]
    {
        XCTAssertEqual(output.status, 0, output.stdout + output.stderr, file: file, line: line)
        return try XCTUnwrap(try json(output)["result"] as? [String: Any], output.stdout, file: file, line: line)
    }

    private func error(_ output: AgentHelper.Output, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: Any]
    {
        try XCTUnwrap(try json(output)["error"] as? [String: Any], output.stdout, file: file, line: line)
    }

    private func paths(_ output: AgentHelper.Output, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String]
    {
        let rows = try XCTUnwrap(try result(output, file: file, line: line)["results"] as? [[String: Any]])
        return rows.compactMap { $0["path"] as? String }
    }

    private func envelope(_ path: String) throws -> MemoryEnvelope {
        let text = try String(contentsOf: library.appendingPathComponent(path), encoding: .utf8)
        guard case .envelope(let envelope, _) = MemoryEnvelope.parse(text) else {
            XCTFail("no front matter in \(path)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return envelope
    }

    private func create(_ title: String, folder: String, type: String? = nil, grant: String = "Silkweb")
        -> AgentHelper.Output
    {
        run(
            [
                "memory", "create", "--folder", folder, "--title", title, "--agent", "claude-code", "--session", "s1",
                "--body-file", "-",
            ] + (type.map { ["--type", $0] } ?? []), grant: grant, stdin: "Agent-level quartz rule.\n")
    }

    // MARK: Reading

    /// The owner's report: a decision document placed in `Memory/Agents/Claude` was invisible to search and read.
    func testTheOwnersHandPlacedAgentDocumentIsSearchableReadableAndListed() throws {
        let path = "\(agent)/How Claude works.md"
        XCTAssertEqual(try paths(run(["memory", "search", "quartz", "check"])), [path])
        let read = try result(run(["memory", "read", path]))
        XCTAssertTrue((read["body"] as? String)?.contains("Always run the quartz check") == true)
        let listed = try XCTUnwrap(try result(run(["memory", "list"]))["documents"] as? [[String: Any]])
        XCTAssertEqual(listed.compactMap { $0["path"] as? String }, [path])

        // Another project's grant with the same agent folder shares it; another agent's folder stays closed.
        XCTAssertEqual(try paths(run(["memory", "search", "quartz", "check"], grant: "Other")), [path])
        XCTAssertEqual(try paths(run(["memory", "search", "secrets"])), [])
        let other = run(["memory", "read", "Memory/Agents/Codex/Codex notes.md"])
        XCTAssertEqual(other.status, 77)
        XCTAssertEqual(try error(other)["code"] as? String, "out_of_scope")
        XCTAssertFalse(other.stdout.contains("quartz"))
    }

    func testWithoutAnAgentFolderTheAgentTreeStaysClosed() throws {
        try writeGrants([grant(agentFolder: nil)])
        XCTAssertEqual(try paths(run(["memory", "search", "quartz"])), [])
        XCTAssertEqual(run(["memory", "read", "\(agent)/How Claude works.md"]).status, 77)
        let refused = create("Rule", folder: "agent-memories")
        XCTAssertEqual(refused.status, 77)
        XCTAssertEqual(try error(refused)["code"] as? String, "out_of_scope")
        XCTAssertEqual(
            refused.stderr,
            "silkweb: This grant has no agent folder. Ask the owner to add one with “silkweb grant init --agent-folder”.\n"
        )
        // The key comes from the grant, never from the agent's own claim.
        XCTAssertEqual(create("Rule", folder: "\(agent)/Memories", type: "memory").status, 77)
    }

    // MARK: Creating

    func testAgentMemoriesCreatesInTheAgentFolderWithTheAgentKeyAsProject() throws {
        let created = try result(create("Prefer small PRs", folder: "agent-memories"))
        let path = try XCTUnwrap(created["path"] as? String)
        XCTAssertEqual(path, "\(agent)/Memories/Prefer small PRs.md")
        let envelope = try self.envelope(path)
        XCTAssertEqual(envelope.string("project"), "Claude")
        XCTAssertEqual(envelope.string("type"), "memory")
        XCTAssertEqual((created["receipt"] as? [String: Any])?["grantId"] as? String, "Silkweb", "the grant's receipt")

        // decision goes there too, by alias or by path; Library-relative Folders below Memories work.
        let decision = try result(create("Use flock", folder: "agent-memories", type: "decision"))
        XCTAssertEqual(decision["path"] as? String, "\(agent)/Memories/Use flock.md")
        XCTAssertEqual(
            try result(run(["memory", "create-folder", "\(agent)/Memories/Swift"]))["created"] as? Bool, true)
        let nested = try result(create("Actors", folder: "\(agent)/Memories/Swift", type: "memory"))
        XCTAssertEqual(nested["path"] as? String, "\(agent)/Memories/Swift/Actors.md")

        // Project creates keep the project key.
        let projectPath = try XCTUnwrap(try result(create("Project rule", folder: "memories"))["path"] as? String)
        XCTAssertEqual(try self.envelope(projectPath).string("project"), "Silkweb")

        // The agent's own memories are read back by any grant sharing the folder.
        XCTAssertEqual(
            try paths(run(["memory", "search", "prefer", "small"], grant: "Other")),
            ["\(agent)/Memories/Prefer small PRs.md"])
    }

    func testCreatesOutsideTheAgentMemoriesFolderAreRefused() throws {
        let documents = {
            try FileManager.default.subpathsOfDirectory(atPath: self.library.path).filter { !$0.hasPrefix(".") }
                .sorted()
        }
        let before = try documents()
        // Progress and handoffs never go in the agent folder.
        let handoff = create("Next", folder: "agent-memories", type: "handoff")
        XCTAssertEqual(handoff.status, 64)
        XCTAssertEqual(
            handoff.stderr,
            "silkweb: The type “handoff” can’t go in “agent-memories”: only memory and decision can.\n")
        let progress = create("Next", folder: "\(agent)/Memories", type: "progress")
        XCTAssertEqual(progress.status, 65)
        XCTAssertEqual(try error(progress)["code"] as? String, "envelope_invalid_field")
        // Not the agent folder's top level, its other Folders, another agent's, or the bare Agents Folder.
        for folder in [agent, "\(agent)/Notes", "Memory/Agents/Codex/Memories", "Memory/Agents"] {
            let refused = create("Rule", folder: folder, type: "memory")
            XCTAssertEqual(refused.status, 77, folder)
            XCTAssertEqual(try error(refused)["code"] as? String, "out_of_scope", folder)
        }
        for folder in [agent + "/Notes", "Memory/Agents/Codex/Memories/X"] {
            XCTAssertEqual(run(["memory", "create-folder", folder]).status, 77, folder)
        }
        XCTAssertEqual(try documents(), before, "only refused receipts are written")

        // A Read Only grant still reads the agent folder but creates nothing in it.
        try writeGrants([grant(access: .read)])
        XCTAssertEqual(try paths(run(["memory", "search", "quartz", "check"])), ["\(agent)/How Claude works.md"])
        XCTAssertEqual(try error(create("Rule", folder: "agent-memories"))["code"] as? String, "create_not_allowed")
    }

    // MARK: Capabilities

    func testCapabilitiesReportTheAgentFolderAndItsRoots() throws {
        let scope = try result(run(["memory", "capabilities"]))
        XCTAssertEqual(scope["agent_folder"] as? String, "Claude")
        XCTAssertEqual(scope["agent_read_root"] as? String, agent)
        XCTAssertEqual(scope["agent_create_root"] as? String, "\(agent)/Memories")
        XCTAssertEqual(scope["read_roots"] as? [String], [project, agent])
        XCTAssertEqual(
            scope["create_roots"] as? [String],
            [project + "/Memories", project + "/Progress", project + "/Handoffs", agent + "/Memories"])

        try writeGrants([grant(access: .read)])
        let readOnly = try result(run(["memory", "capabilities"]))
        XCTAssertEqual(readOnly["agent_read_root"] as? String, agent)
        XCTAssertTrue(readOnly["agent_create_root"] is NSNull)

        try writeGrants([grant(agentFolder: nil)])
        let none = try result(run(["memory", "capabilities"]))
        for key in ["agent_folder", "agent_read_root", "agent_create_root"] {
            XCTAssertTrue(none[key] is NSNull, key)
        }
        XCTAssertEqual(none["read_roots"] as? [String], [project])
    }

    // MARK: Invalid key

    func testAnInvalidAgentFolderFailsThatGrantClosed() throws {
        let valid = #"{"project":"Other","library":{"path":"\#(library.path)"},"access":"read-create"}"#
        for value in [#""""#, #""a/b""#, #"".hidden""#, #""..""#, "42", #"["Claude"]"#, #""Claude\u0007""#] {
            let invalid =
                #"{"project":"Silkweb","library":{"path":"\#(library.path)"},"access":"read-create","agent_folder":\#(value)}"#
            try Data(#"{"version":1,"grants":[\#(invalid),\#(valid)]}"#.utf8).write(to: grantsURL)
            for command in [["memory", "capabilities"], ["memory", "search", "quartz"], ["memory", "list"]] {
                let output = run(command)
                XCTAssertEqual(output.status, 65, "\(value) \(command)")
                XCTAssertEqual(try error(output)["code"] as? String, "invalid_agent_folder", value)
                XCTAssertEqual(output.stderr, "silkweb: The agent folder isn’t a valid folder name.\n")
            }
            XCTAssertEqual(create("Rule", folder: "memories").status, 65, value)
            // Other grants in the same file keep working.
            XCTAssertEqual(run(["memory", "capabilities"], grant: "Other").status, 0, value)
        }
        // `null` is the same as no agent folder.
        let none = #"{"project":"Silkweb","library":{"path":"\#(library.path)"},"agent_folder":null}"#
        try Data(#"{"grants":[\#(none)]}"#.utf8).write(to: grantsURL)
        XCTAssertTrue(try result(run(["memory", "capabilities"]))["agent_folder"] is NSNull)
    }

    func testGrantsFromEarlierBuildsLoadAndTheKeyRoundTrips() throws {
        let old = try JSONDecoder().decode(
            AgentGrant.self, from: Data(#"{"project":"Silkweb","library":{"path":"/x"},"access":"read"}"#.utf8))
        XCTAssertNil(old.agentFolder)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertFalse(String(decoding: try encoder.encode(old), as: UTF8.self).contains("agent_folder"))
        var withKey = old
        withKey.agentFolder = "Claude"
        let data = try encoder.encode(withKey)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""agent_folder":"Claude""#))
        XCTAssertEqual(try JSONDecoder().decode(AgentGrant.self, from: data), withKey)
    }

    // MARK: Search

    func testSearchProjectAcceptsTheAgentFolderKey() throws {
        _ = try result(create("Agent quartz memory", folder: "agent-memories"))
        _ = try result(create("Project quartz memory", folder: "memories"))
        try write("# Loose\n\nquartz without front matter\n", "\(project)/Loose.md")
        let hand = "\(agent)/How Claude works.md"

        XCTAssertEqual(
            Set(try paths(run(["memory", "search", "quartz", "--project", "Claude"]))),
            [hand, "\(agent)/Memories/Agent quartz memory.md"])
        XCTAssertEqual(
            Set(try paths(run(["memory", "search", "quartz", "--project", "Silkweb"]))),
            ["\(project)/Memories/Project quartz memory.md", "\(project)/Loose.md"])
        XCTAssertEqual(
            Set(try paths(run(["memory", "search", "--ranked", "quartz", "project:claude"]))),
            [hand, "\(agent)/Memories/Agent quartz memory.md"])
        // Any other key is still out of scope, including another agent's folder.
        for key in ["Codex", "Other"] {
            let refused = run(["memory", "search", "quartz", "--project", key])
            XCTAssertEqual(refused.status, 77, key)
            XCTAssertEqual(try error(refused)["code"] as? String, "out_of_scope", key)
        }
    }

    /// Owner decision: equally relevant project memories rank above agent-level ones, even when older.
    func testEquallyRelevantProjectDocumentsRankAboveAgentDocuments() throws {
        let text = "# Shared rule\n\nKeep the quartz gate closed.\n"
        try write(text, "\(project)/Shared rule.md", modified: Date(timeIntervalSince1970: 1_700_000_000))
        try write(text, "\(agent)/Shared rule.md", modified: Date(timeIntervalSince1970: 1_800_000_000))
        let order = ["\(project)/Shared rule.md", "\(agent)/Shared rule.md"]
        XCTAssertEqual(try paths(run(["memory", "search", "shared", "rule"])), order)
        XCTAssertEqual(try paths(run(["memory", "search", "--ranked", "shared", "rule"])), order)
        // Relevance still comes first: a better agent-level match beats a weaker project one.
        try write("# Gate notes\n\nshared rule mentioned in passing\n", "\(project)/Gate notes.md")
        XCTAssertEqual(try paths(run(["memory", "search", "shared", "rule"])), order + ["\(project)/Gate notes.md"])
    }

    // MARK: Scope

    func testScopeKeepsTheAgentFolderWhenNarrowedAndComparesWholeComponents() throws {
        let scope = try AgentScope(grant: grant(), caseSensitive: false)
        XCTAssertTrue(scope.isAgentLevel("memory/agents/claude/x.md"))
        XCTAssertFalse(scope.isAgentLevel("Memory/Agents/Claude2/x.md"))
        XCTAssertFalse(scope.isAgentLevel("\(project)/x.md"))
        XCTAssertThrowsError(try scope.checkRead("Memory/Agents/Claude2/x.md"))
        XCTAssertThrowsError(try scope.checkCreate("\(agent)/x.md"))
        XCTAssertEqual(try scope.checkCreate("\(agent)/Memories/x.md"), "\(agent)/Memories/x.md")
        XCTAssertThrowsError(try scope.checkCreate("\(agent)/Memories/Proposals/x.md"), "reserved Folders stay off")
        XCTAssertThrowsError(try scope.checkCreate("\(agent)/Memories/CLAUDE.md"), "instruction files stay off")

        let narrowed = scope.narrowed(to: [project])
        XCTAssertEqual(narrowed.agentFolder, "Claude")
        XCTAssertEqual(narrowed.readRoots, [project])
        XCTAssertFalse(narrowed.createRoots.contains("\(agent)/Memories"), "MCP roots can drop the agent folder")
        XCTAssertEqual(scope.narrowed(to: ["\(agent)/Memories"]).createRoots, ["\(agent)/Memories"])
        XCTAssertNotEqual(scope.key, try AgentScope(grant: grant(agentFolder: nil)).key, "caches follow the scope")

        let sensitive = try AgentScope(grant: grant(), caseSensitive: true)
        XCTAssertFalse(sensitive.isAgentLevel("memory/agents/claude/x.md"))
        XCTAssertThrowsError(try AgentScope(grant: grant(agentFolder: "a/b"))) {
            XCTAssertEqual($0 as? AgentScopeError, .invalidAgentFolder)
        }
    }
}

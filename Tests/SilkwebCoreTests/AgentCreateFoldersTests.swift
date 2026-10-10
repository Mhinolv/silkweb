import Foundation
import XCTest

@testable import SilkwebCore

/// #228: a grant's `create_folders` let the owner choose where agents create (the project's top level, owner-named
/// Folders, more of the agent folder), recursively and readable too. Progress and handoffs stay in their entry folders,
/// creates never replace, invalid entries fail the grant closed, and `grant init`, `grant request` and approval add
/// them with the #206 confirmation.
final class AgentCreateFoldersTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var library: URL!
    private var grantsURL: URL!
    private var requestsURL: URL!
    private let project = "Memory/Projects/Silkweb"
    private let agent = "Memory/Agents/Claude"
    private let now = Date(timeIntervalSince1970: 1_791_554_400)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCreateFolders-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        library = root.appendingPathComponent("Writing Library")
        grantsURL = root.appendingPathComponent("grants.json")
        requestsURL = root.appendingPathComponent("requests.json")
        for folder in [project + "/Progress", "Memory/Projects/Other", agent, "Reference/Shared"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try write("# Overview\n\nThe quartz overview the owner wrote.\n", "\(project)/Overview.md")
        try write("# Shared\n\nquartz notes for every project\n", "Reference/Shared/Shared.md")
        try writeGrants([grant()])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Helpers

    private func grant(
        _ project: String = "Silkweb", access: AgentGrant.Access = .readCreate, agentFolder: String? = nil,
        createFolders: [String] = ["Memory/Projects/Silkweb"]
    ) -> AgentGrant {
        AgentGrant(
            project: project, library: LibraryLocation(path: library.path), access: access, agentFolder: agentFolder,
            createFolders: createFolders)
    }

    private func writeGrants(_ grants: [AgentGrant]) throws {
        try AgentGrantFile(grants: grants).write(to: grantsURL)
    }

    private func write(_ text: String, _ path: String) throws {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func run(_ arguments: [String], grant: String = "Silkweb", stdin: String? = nil) -> AgentHelper.Output {
        let pipe = Pipe()
        if let stdin { pipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? pipe.fileHandleForWriting.close()
        return AgentHelper.run(
            arguments + ["--grants", grantsURL.path, "--grant", grant], home: root, environment: [:],
            standardInput: pipe.fileHandleForReading)
    }

    private func create(_ title: String, folder: String, type: String? = "memory") -> AgentHelper.Output {
        run(
            [
                "memory", "create", "--folder", folder, "--title", title, "--agent", "claude-code", "--session", "s1",
                "--body-file", "-",
            ] + (type.map { ["--type", $0] } ?? []), stdin: "A quartz fact.\n")
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

    private func code(_ output: AgentHelper.Output) throws -> String? {
        (try json(output)["error"] as? [String: Any])?["code"] as? String
    }

    private func envelope(_ path: String) throws -> MemoryEnvelope {
        let text = try String(contentsOf: library.appendingPathComponent(path), encoding: .utf8)
        guard case .envelope(let envelope, _) = MemoryEnvelope.parse(text) else {
            XCTFail("no front matter in \(path)")
            throw CocoaError(.fileReadCorruptFile)
        }
        return envelope
    }

    private func documents() throws -> [String] {
        try FileManager.default.subpathsOfDirectory(atPath: library.path).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// `grant <arguments>` with temporary grants and requests files.
    private func grantCommand(_ arguments: [String], answers: [String] = [], terminal: Bool = false) -> (
        output: AgentHelper.Output, prompts: String
    ) {
        var remaining = answers
        var prompts = ""
        let console = AgentGrantInit.Console(
            isTerminal: terminal, readLine: { remaining.isEmpty ? nil : remaining.removeFirst() },
            write: { prompts += $0 })
        var target = ["--grants", grantsURL.path]
        if arguments.first != "init" { target.append(contentsOf: ["--requests", requestsURL.path]) }
        if ["request", "requests"].contains(arguments.first) { target = ["--requests", requestsURL.path] }
        let output = AgentGrantInit.run(
            ["grant"] + arguments + target, console: console, home: home, environment: ["PATH": "/usr/bin"],
            executable: nil, currentDirectory: root.path, now: now)
        return (output, prompts)
    }

    private func initFlags(_ project: String = "Silkweb", access: String = "read-create") -> [String] {
        ["init", "--library", library.path, "--project", project, "--access", access]
    }

    private func load() throws -> AgentGrantFile {
        try JSONDecoder().decode(AgentGrantFile.self, from: Data(contentsOf: grantsURL))
    }

    // MARK: Without the key

    func testWithoutCreateFoldersScopeStaysExactlyAsBefore() throws {
        try writeGrants([grant(createFolders: [])])
        let scope = try result(run(["memory", "capabilities"]))
        XCTAssertEqual(scope["read_roots"] as? [String], [project])
        XCTAssertEqual(
            scope["create_roots"] as? [String], [project + "/Memories", project + "/Progress", project + "/Handoffs"])
        let refused = create("Top", folder: project)
        XCTAssertEqual(refused.status, 77)
        XCTAssertEqual(try code(refused), "out_of_scope")
        XCTAssertEqual(run(["memory", "read", "Reference/Shared/Shared.md"]).status, 77)

        // Older grants files load, and an empty list is never written.
        let old = try JSONDecoder().decode(
            AgentGrant.self, from: Data(#"{"project":"Silkweb","library":{"path":"/x"},"access":"read"}"#.utf8))
        XCTAssertEqual(old.createFolders, [])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertFalse(String(decoding: try encoder.encode(old), as: UTF8.self).contains("create_folders"))
        var withFolders = old
        withFolders.createFolders = [project]
        let data = try encoder.encode(withFolders)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""create_folders":["#))
        XCTAssertEqual(try JSONDecoder().decode(AgentGrant.self, from: data), withFolders)
    }

    // MARK: Creating

    /// The owner's request: an overview at the top of the project, and owner-named Folders under it.
    func testTheProjectFolderAsACreateFolderAllowsTopLevelAndNestedCreates() throws {
        let scope = try result(run(["memory", "capabilities"]))
        XCTAssertEqual(scope["create_roots"] as? [String], [project], "the project folder holds the entry folders")
        XCTAssertEqual(scope["read_roots"] as? [String], [project])

        let top = try result(create("Architecture overview", folder: project, type: "decision"))
        XCTAssertEqual(top["path"] as? String, "\(project)/Architecture overview.md")
        XCTAssertEqual(try envelope("\(project)/Architecture overview.md").string("project"), "Silkweb")
        XCTAssertEqual(try result(run(["memory", "create-folder", "\(project)/Research"]))["created"] as? Bool, true)
        let nested = try result(create("Vendors", folder: "\(project)/Research"))
        XCTAssertEqual(nested["path"] as? String, "\(project)/Research/Vendors.md")

        // Entry folders keep working, including their keywords.
        let progress = try result(create("Spike", folder: "progress", type: nil))
        XCTAssertTrue((progress["path"] as? String)?.hasPrefix("\(project)/Progress/") == true)
        XCTAssertNotNil(try result(create("Next", folder: "handoffs", type: nil))["path"])

        // Create never replaces: the owner's overview stays, the new one gets a numbered name.
        let again = try result(create("Overview", folder: project))
        XCTAssertNotEqual(again["path"] as? String, "\(project)/Overview.md")
        XCTAssertEqual(
            try String(contentsOf: library.appendingPathComponent("\(project)/Overview.md"), encoding: .utf8),
            "# Overview\n\nThe quartz overview the owner wrote.\n")
    }

    func testProgressAndHandoffsStayInTheirEntryFolders() throws {
        try writeGrants([grant(agentFolder: "Claude", createFolders: [project, "Reference/Shared", "\(agent)/Notes"])])
        let before = try documents()
        for (type, folder) in [
            ("progress", project), ("progress", "\(project)/Handoffs"), ("handoff", "\(project)/Progress"),
            ("handoff", "Reference/Shared"), ("progress", "\(agent)/Notes"), ("handoff", "\(agent)/Memories"),
        ] {
            let refused = create("Wrong place", folder: folder, type: type)
            XCTAssertEqual(refused.status, 65, "\(type) in \(folder)")
            XCTAssertEqual(try code(refused), "envelope_invalid_field", "\(type) in \(folder)")
        }
        XCTAssertEqual(try documents(), before, "nothing was created")
        // Memories and decisions go anywhere in scope, the entry folders included.
        for folder in ["\(project)/Progress", "\(project)/Handoffs", "Reference/Shared", "\(agent)/Notes"] {
            XCTAssertEqual(create("Fact", folder: folder).status, 0, folder)
        }
        XCTAssertEqual(create("Progress here", folder: "\(project)/Progress/Sprint 1", type: "progress").status, 0)
    }

    func testFoldersOutsideTheProjectAreReadableAndCreatable() throws {
        try writeGrants([grant(createFolders: ["Reference/Shared"])])
        let scope = try result(run(["memory", "capabilities"]))
        XCTAssertEqual(scope["read_roots"] as? [String], [project, "Reference/Shared"])
        XCTAssertEqual(
            scope["create_roots"] as? [String],
            [project + "/Memories", project + "/Progress", project + "/Handoffs", "Reference/Shared"])
        XCTAssertNotNil(try result(run(["memory", "read", "Reference/Shared/Shared.md"]))["body"])
        let created = try result(create("Cross project fact", folder: "Reference/Shared"))
        let path = try XCTUnwrap(created["path"] as? String)
        XCTAssertEqual(try envelope(path).string("project"), "Silkweb")
        // The Folder itself and its siblings are still outside.
        XCTAssertEqual(create("Sibling", folder: "Reference").status, 77)
        XCTAssertEqual(create("Top", folder: project).status, 77)
    }

    func testAgentFolderCreateFoldersKeepTheAgentKeyAndMemoryTypes() throws {
        try writeGrants([grant(agentFolder: "Claude", createFolders: ["\(agent)/Notes", "Memory/Agents/Shared/Team"])])
        let scope = try result(run(["memory", "capabilities"]))
        XCTAssertEqual(scope["agent_create_root"] as? String, "\(agent)/Memories")
        XCTAssertEqual(
            scope["create_roots"] as? [String],
            [
                project + "/Memories", project + "/Progress", project + "/Handoffs", agent + "/Memories",
                agent + "/Notes", "Memory/Agents/Shared/Team",
            ])
        let mine = try XCTUnwrap(try result(create("Style", folder: "\(agent)/Notes"))["path"] as? String)
        XCTAssertEqual(try envelope(mine).string("project"), "Claude")
        let shared = try XCTUnwrap(
            try result(create("Team rule", folder: "Memory/Agents/Shared/Team"))["path"] as? String)
        XCTAssertEqual(try envelope(shared).string("project"), "Shared", "the agent folder it's in")
        // The agent folder's top level is still readable only.
        XCTAssertEqual(create("Top", folder: agent).status, 77)
    }

    /// The owner decision (2026-10-10): `Memory/Projects` gives every project, top levels included, for reading,
    /// creating and updating, with progress and handoffs in each project's own entry folders.
    func testMemoryProjectsCoversEveryProjectForCreateAndUpdate() throws {
        try writeGrants([grant(access: .readCreateUpdate, createFolders: ["Memory/Projects"])])
        try write("# Plan\n\nThe owner's plan for Other.\n", "Memory/Projects/Other/Plan.md")
        let scope = try result(run(["memory", "capabilities"]))
        XCTAssertEqual(scope["create_roots"] as? [String], ["Memory/Projects"])
        XCTAssertNotNil(try result(run(["memory", "read", "Memory/Projects/Other/Plan.md"]))["body"])

        let top = try XCTUnwrap(
            try result(create("Other overview", folder: "Memory/Projects/Other", type: "decision"))["path"] as? String)
        XCTAssertEqual(top, "Memory/Projects/Other/Other overview.md")
        XCTAssertEqual(try envelope(top).string("project"), "Other", "the project it's in")
        let own = try XCTUnwrap(try result(create("Own overview", folder: project))["path"] as? String)
        XCTAssertEqual(try envelope(own).string("project"), "Silkweb")
        let progress = try XCTUnwrap(
            try result(create("Spike", folder: "Memory/Projects/Other/Progress", type: "progress"))["path"] as? String)
        XCTAssertEqual(try envelope(progress).string("project"), "Other")
        XCTAssertEqual(create("Next", folder: "Memory/Projects/Other/Handoffs/Week 1", type: "handoff").status, 0)
        XCTAssertEqual(create("Next", folder: "\(project)/Handoffs", type: "handoff").status, 0)

        // Progress and handoffs still go only in a project's entry folders; reserved Folders stay off.
        let before = try documents()
        for (type, folder) in [
            ("progress", "Memory/Projects/Other"), ("handoff", "Memory/Projects/Other/Progress"),
            ("progress", "Memory/Projects"), ("handoff", "Memory/Projects/Other/Notes/Handoffs"),
        ] {
            let refused = create("Wrong place", folder: folder, type: type)
            XCTAssertEqual(try code(refused), "envelope_invalid_field", "\(type) in \(folder)")
        }
        XCTAssertEqual(create("Idea", folder: "Memory/Projects/Other/Proposals").status, 77)
        XCTAssertEqual(try documents(), before, "nothing was created")

        // Updates work inside the create folder for what an agent created; owner files need a proposal.
        let update = { (path: String) -> AgentHelper.Output in
            let revision = (try? self.result(self.run(["memory", "read", path])))?["revision"] as? String ?? ""
            return self.run(
                [
                    "memory", "update", path, "--expected-revision", revision, "--body-file", "-", "--agent",
                    "claude-code", "--session", "s2",
                ], stdin: "# Revised\n\nRevised.\n")
        }
        XCTAssertEqual(try result(update(top))["outcome"] as? String, "updated")
        XCTAssertTrue(
            try String(contentsOf: library.appendingPathComponent(top), encoding: .utf8).hasSuffix("\nRevised.\n"))
        XCTAssertEqual(try envelope(top).string("project"), "Other")
        XCTAssertEqual(try code(update("Memory/Projects/Other/Plan.md")), "update_requires_proposal")
        XCTAssertEqual(
            try String(contentsOf: library.appendingPathComponent("Memory/Projects/Other/Plan.md"), encoding: .utf8),
            "# Plan\n\nThe owner's plan for Other.\n")
    }

    /// QA (#228): an update inside an owner-chosen create folder with a Read, Create and Update grant.
    func testUpdateInsideACreateFolder() throws {
        try writeGrants([grant(access: .readCreateUpdate, createFolders: ["Reference/Shared"])])
        let path = try XCTUnwrap(try result(create("Shared fact", folder: "Reference/Shared"))["path"] as? String)
        let revision = try XCTUnwrap(try result(run(["memory", "read", path]))["revision"] as? String)
        let updated = try result(
            run(
                [
                    "memory", "update", path, "--expected-revision", revision, "--body-file", "-", "--agent",
                    "claude-code", "--session", "s2",
                ], stdin: "# Shared fact\n\nRevised.\n"))
        XCTAssertEqual(updated["outcome"] as? String, "updated")
        XCTAssertEqual(updated["path"] as? String, path)
        XCTAssertTrue(
            try String(contentsOf: library.appendingPathComponent(path), encoding: .utf8).hasSuffix("\nRevised.\n"))
    }

    // MARK: Invalid entries

    func testInvalidCreateFoldersFailThatGrantClosed() throws {
        let valid = #"{"project":"Other","library":{"path":"\#(library.path)"},"access":"read-create"}"#
        for value in [
            #"[""]"#, #"["/"]"#, #"["Memory"]"#, #"["memory/agents"]"#, #"["Memory/Agents/"]"#, #"["../x"]"#,
            #"["Memory/Projects/Silkweb/../Other"]"#, #"["Memory/Projects/Silkweb/Proposals"]"#, #"[".silkweb"]"#,
            #"["Memory/Projects/Silkweb", "MEMORY"]"#, "42", #""Memory/Projects/Silkweb""#, "[42]",
        ] {
            let invalid =
                #"{"project":"Silkweb","library":{"path":"\#(library.path)"},"access":"read-create","create_folders":\#(value)}"#
            try Data(#"{"version":1,"grants":[\#(invalid),\#(valid)]}"#.utf8).write(to: grantsURL)
            for command in [["memory", "capabilities"], ["memory", "search", "quartz"], ["memory", "list"]] {
                let output = run(command)
                XCTAssertEqual(output.status, 65, "\(value) \(command)")
                XCTAssertEqual(try code(output), "invalid_create_folder", value)
                XCTAssertTrue(output.stderr.contains("can’t be a create folder"), output.stderr)
                XCTAssertFalse(output.stdout.contains("quartz"))
            }
            XCTAssertEqual(create("Rule", folder: "memories").status, 65, value)
            XCTAssertEqual(run(["memory", "capabilities"], grant: "Other").status, 0, value)
        }
        // `null` is the same as no create folders.
        let none = #"{"project":"Silkweb","library":{"path":"\#(library.path)"},"create_folders":null}"#
        try Data(#"{"grants":[\#(none)]}"#.utf8).write(to: grantsURL)
        XCTAssertEqual(try result(run(["memory", "capabilities"]))["read_roots"] as? [String], [project])
    }

    // MARK: Scope

    func testScopeNormalizesDeduplicatesAndNarrows() throws {
        let scope = try AgentScope(
            grant: grant(createFolders: ["Memory/Projects/Silkweb/Progress", project + "/", "Reference/Shared"]),
            caseSensitive: false)
        XCTAssertEqual(scope.createRoots, [project, "Reference/Shared"])
        XCTAssertEqual(scope.readRoots, [project, "Reference/Shared"])
        XCTAssertNoThrow(try scope.checkCreate("memory/projects/silkweb/Top.md"), "case is ignored on this volume")
        XCTAssertThrowsError(try scope.checkCreate("\(project)/AGENTS.md"), "instruction files stay off")
        XCTAssertThrowsError(try scope.checkCreate("\(project)/Proposals/Idea.md"), "reserved Folders stay off")
        XCTAssertThrowsError(try scope.checkCreate("Reference/SharedOther/x.md"), "whole components only")
        XCTAssertThrowsError(try scope.checkCreateFolder(project), "a create folder isn't inside itself")
        XCTAssertEqual(scope.narrowed(to: ["\(project)/Research"]).createRoots, ["\(project)/Research"])
        XCTAssertEqual(scope.narrowed(to: ["Reference"]).createRoots, ["Reference/Shared"])

        // Read Only grants and unqualified filesystems read the create folders but create nothing.
        let readOnly = try AgentScope(grant: grant(access: .read))
        XCTAssertEqual(readOnly.createRoots, [])
        XCTAssertEqual(readOnly.readRoots, [project])
        XCTAssertEqual(try AgentScope(grant: grant(), createAllowed: false).createRoots, [])

        XCTAssertEqual(try AgentScope.validateCreateFolder("Notes//Swift"), "Notes/Swift")
        XCTAssertEqual(try AgentScope.validateCreateFolder("Memory/Projects/"), "Memory/Projects")
        for refused in ["", "/", "Memory", "memory/AGENTS", "Memory/Agents", "a/../b", "Notes/proposals/x"] {
            XCTAssertThrowsError(try AgentScope.validateCreateFolder(refused), refused) {
                guard case .invalidCreateFolder = $0 as? AgentScopeError else {
                    return XCTFail("\(refused): \($0)")
                }
            }
        }
    }

    // MARK: grant init

    func testGrantInitSavesCreateFoldersForANewGrant() throws {
        try FileManager.default.removeItem(at: grantsURL)
        let (output, _) = grantCommand(
            initFlags() + [
                "--create-folder", project, "--create-folder", "Reference/Shared/", "--create-folder", project,
            ])
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stdout.contains("  Create   \(project)\n  Create   Reference/Shared\n"), output.stdout)
        XCTAssertEqual(try load().grants.map(\.createFolders), [[project, "Reference/Shared"]])

        // Read Only grants can't have them, invalid ones are refused, and nothing is saved.
        let saved = try Data(contentsOf: grantsURL)
        let readOnly = grantCommand(initFlags("Plain", access: "read") + ["--create-folder", "Notes"]).output
        XCTAssertEqual(readOnly.status, 64)
        XCTAssertEqual(readOnly.stderr, "silkweb: Create folders need read-create or read-create-update access.\n")
        for invalid in ["Memory", "Memory/Agents", "", "../x"] {
            let refused = grantCommand(initFlags("New") + ["--create-folder", invalid]).output
            XCTAssertEqual(refused.status, 64, invalid)
            XCTAssertTrue(refused.stderr.contains("can’t be a create folder"), refused.stderr)
        }
        let many = (1...11).flatMap { ["--create-folder", "Notes/\($0)"] }
        XCTAssertEqual(
            grantCommand(initFlags("New") + many).output.stderr, "silkweb: Give at most 10 create folders.\n")
        XCTAssertEqual(try Data(contentsOf: grantsURL), saved)

        // The owner's choice for every project (2026-10-10).
        let flags = initFlags("Claude", access: "read-create-update") + ["--create-folder", "Memory/Projects"]
        let everyProject = grantCommand(flags).output
        XCTAssertEqual(everyProject.status, 0, everyProject.stderr)
        XCTAssertEqual(try load().grants.map(\.createFolders), [[project, "Reference/Shared"], ["Memory/Projects"]])
    }

    func testGrantInitAsksOneQuestionForTheProjectTopLevel() throws {
        try FileManager.default.removeItem(at: grantsURL)
        let (output, prompts) = grantCommand(
            ["init"], answers: [library.path, "Silkweb", "2", "", "y", "y"], terminal: true)
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(
            prompts.contains("Let agents create anywhere in Memory/Projects/Silkweb, including its top level? [y/N] "))
        XCTAssertEqual(try load().grants.map(\.createFolders), [[project]])

        // No (the default) keeps the default template; Read Only isn't asked.
        let declined = grantCommand(["init"], answers: [library.path, "Second", "2", "", "", "y"], terminal: true)
        XCTAssertEqual(declined.output.status, 0, declined.output.stderr)
        let readOnly = grantCommand(["init"], answers: [library.path, "Third", "1", "", "y"], terminal: true)
        XCTAssertFalse(readOnly.prompts.contains("Let agents create"))
        XCTAssertEqual(try load().grants.map(\.createFolders), [[project], [], []])
    }

    /// Adding create folders widens the grant, so it needs the #206 confirmation.
    func testAddingCreateFoldersToAnExistingGrantNeedsConfirmation() throws {
        try writeGrants([grant(createFolders: [])])
        let saved = try Data(contentsOf: grantsURL)
        let arguments = initFlags() + ["--create-folder", project]

        let refused = grantCommand(arguments)
        XCTAssertEqual(refused.output.status, 77)
        XCTAssertEqual(
            refused.output.stderr,
            "silkweb: Adding a create folder widens the grant “Silkweb”. Run this in Terminal to confirm, or add "
                + "--yes. Nothing was saved.\n")
        XCTAssertEqual(
            refused.prompts,
            "This adds a create folder to the grant “Silkweb”. Agents can read and create in it, and in any folder "
                + "inside:\n  Create   \(project)\n")
        for answer in ["n", ""] {
            let declined = grantCommand(arguments, answers: [answer], terminal: true)
            XCTAssertEqual(declined.output.stdout, "Nothing was saved.\n")
            XCTAssertTrue(declined.prompts.hasSuffix("Add the create folder to “Silkweb”? [y/N] "), declined.prompts)
        }
        let dry = grantCommand(arguments + ["--dry-run"]).output
        XCTAssertTrue(dry.stdout.contains(#""create_folders" : ["#), dry.stdout)
        XCTAssertEqual(try Data(contentsOf: grantsURL), saved)

        let accepted = grantCommand(arguments, answers: ["y"], terminal: true)
        XCTAssertEqual(accepted.output.status, 0, accepted.output.stderr)
        XCTAssertTrue(accepted.output.stdout.contains("Added create folder: \(project).\n"), accepted.output.stdout)
        XCTAssertEqual(try load().grants.map(\.createFolders), [[project]])

        // Folders it already holds change nothing; a wider one replaces the narrower and needs --yes again.
        let held = grantCommand(initFlags() + ["--create-folder", project + "/Research"]).output
        XCTAssertTrue(held.stdout.hasPrefix("Agent access for “Silkweb” is already set up.\n"), held.stdout)
        try writeGrants([grant(createFolders: [project + "/Research", "Notes"])])
        let both = grantCommand(
            initFlags() + [
                "--create-folder", project, "--create-folder", "Reference/Shared", "--agent-folder", "Claude",
            ])
        XCTAssertEqual(both.output.status, 77)
        XCTAssertTrue(
            both.output.stderr.contains("Adding an agent folder and create folders widens"), both.output.stderr)
        let yes = grantCommand(
            initFlags() + [
                "--create-folder", project, "--create-folder", "Reference/Shared", "--agent-folder", "Claude", "--yes",
            ])
        XCTAssertEqual(yes.output.status, 0, yes.output.stderr)
        XCTAssertTrue(
            yes.output.stdout.contains(
                "Added agent folder: Memory/Agents/Claude.\nAdded create folders: \(project), Reference/Shared.\n"),
            yes.output.stdout)
        XCTAssertEqual(try load().grants.map(\.createFolders), [["Notes", project, "Reference/Shared"]])
        XCTAssertEqual(try load().grants.map(\.agentFolder), ["Claude"])
    }

    // MARK: Access requests

    func testAgentsCanRequestCreateFoldersAndApprovalAddsThem() throws {
        try writeGrants([grant(createFolders: [])])
        let base = [
            "request", "--library", library.path, "--project", "Silkweb", "--agent", "claude-code", "--session", "s-1",
        ]
        let readOnly = grantCommand(base + ["--access", "read", "--create-folder", project]).output
        XCTAssertEqual(readOnly.status, 64)
        XCTAssertEqual(try code(readOnly), "invalid_argument")
        XCTAssertTrue(readOnly.stderr.contains("Create folders need read-create access."), readOnly.stderr)
        let wide = grantCommand(base + ["--access", "read-create", "--create-folder", "Memory/Agents"]).output
        XCTAssertEqual(try code(wide), "invalid_argument")

        let arguments =
            base + ["--access", "read-create", "--create-folder", project + "/", "--create-folder", project]
        let submitted = try result(grantCommand(arguments).output)
        let id = try XCTUnwrap(submitted["requestId"] as? String)
        XCTAssertEqual(try result(grantCommand(arguments).output)["duplicate"] as? Bool, true)
        let stored = try XCTUnwrap(try AgentAccessRequestStore(url: requestsURL).load().requests.first)
        XCTAssertEqual(stored.createFolders, [project])
        XCTAssertEqual(
            stored.folderSummary, "Memory › Projects › Silkweb · Create in: Memory › Projects › Silkweb")
        XCTAssertTrue(stored.accessibilityLabel(now).contains(", 1 folder, 1 create folder, "))
        let listed = grantCommand(["requests"]).output.stdout
        XCTAssertTrue(listed.contains(" + 1 create folder  expires"), listed)

        // The owner sees the create folders before answering, and approving adds them to the existing grant.
        let approved = grantCommand(["approve", id], answers: ["y"], terminal: true)
        XCTAssertEqual(approved.output.status, 0, approved.output.stderr)
        XCTAssertTrue(approved.prompts.contains("  Create   Memory › Projects › Silkweb\n"), approved.prompts)
        XCTAssertTrue(approved.output.stdout.contains("Added create folder: \(project).\n"), approved.output.stdout)
        XCTAssertEqual(try load().grants.map(\.createFolders), [[project]])
        XCTAssertEqual(create("Overview two", folder: project).status, 0)

        // A request for a new project saves its create folders with the grant.
        let other = try result(
            grantCommand([
                "request", "--library", library.path, "--project", "Other", "--access", "read-create",
                "--create-folder", "Memory/Projects/Other",
            ]).output)
        let decision = try AgentAccessRequestStore(url: requestsURL).decide(
            try XCTUnwrap(other["requestId"] as? String), approve: true, via: .app, grantsURL: grantsURL, now: now)
        XCTAssertEqual(decision.grant?.createFolders, ["Memory/Projects/Other"])
        XCTAssertEqual(decision.outcome, .added)
    }

    func testRequestsFromEarlierBuildsLoadWithoutCreateFolders() throws {
        let old = #"{"requestId":"req_1","project":"Silkweb","profile":"read-create","readFolders":["Notes"]}"#
        let request = try JSONDecoder().decode(AgentAccessRequest.self, from: Data(old.utf8))
        XCTAssertEqual(request.createFolders, [])
        XCTAssertEqual(request.folderSummary, "Memory › Projects › Silkweb + 1 read folder: Notes")
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(encoded.contains("createFolders"))
    }
}

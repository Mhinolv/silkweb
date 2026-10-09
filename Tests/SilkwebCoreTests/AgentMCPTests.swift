import Darwin
import XCTest

@testable import SilkwebCore

/// `silkweb mcp` (#136): initialize, tool discovery, calls, cancellation and shutdown over the
/// newline-delimited stdio transport, stdout purity, and parity with the CLI's refusals.
final class AgentMCPTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!
    private var outURL: URL!
    private var errURL: URL!
    private var descriptors: [Int32] = []
    private var server: AgentMCPServer!
    private var consumed = 0
    private let project = "Memory/Projects/Silkweb"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentMCP-\(UUID().uuidString)")
        library = root.appendingPathComponent("Writing Library")
        grantsURL = root.appendingPathComponent("grants.json")
        outURL = root.appendingPathComponent("stdout")
        errURL = root.appendingPathComponent("stderr")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(project), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Notes/Private"), withIntermediateDirectories: true)
        try Data("# Diary\n\nprivate words".utf8).write(to: library.appendingPathComponent("Notes/Private/Diary.md"))
        try writeGrants([grant()])
        server = makeServer()
    }

    override func tearDownWithError() throws {
        server?.queue.sync {}
        descriptors.forEach { close($0) }
        try? FileManager.default.removeItem(at: root)
    }

    private func grant(
        _ project: String = "Silkweb", label: String = "", access: AgentGrant.Access = .readCreate,
        limits: AgentGrantLimits = AgentGrantLimits(), revoked: Bool = false
    ) -> AgentGrant {
        AgentGrant(
            project: project, library: LibraryLocation(path: library.path), access: access, label: label,
            limits: limits, revokedAt: revoked ? Date() : nil)
    }

    private func writeGrants(_ grants: [AgentGrant]) throws {
        try AgentGrantFile(grants: grants).write(to: grantsURL)
    }

    private func descriptor(_ url: URL) -> Int32 {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND | O_CLOEXEC, 0o600)
        descriptors.append(descriptor)
        return descriptor
    }

    /// stdout and stderr go to files, so the test reads exactly what was written.
    private func makeServer() -> AgentMCPServer {
        let store = AgentGrantStore(url: grantsURL)
        let session = AgentSession(project: "Silkweb", store: store)
        let service = AgentMemoryService(session: session, cacheDirectory: root.appendingPathComponent("cache"))
        consumed = 0
        return AgentMCPServer(
            session: session, service: service, agent: "claude-code", sessionID: "s1", output: descriptor(outURL),
            errors: descriptor(errURL))
    }

    private var stdout: String { (try? String(contentsOf: outURL, encoding: .utf8)) ?? "" }
    private var stderr: String { (try? String(contentsOf: errURL, encoding: .utf8)) ?? "" }

    private func send(_ message: [String: Any]) throws {
        server.receive(Array(try JSONSerialization.data(withJSONObject: message)))
    }

    private func send(raw: String) { server.receive(Array(raw.utf8)) }

    /// Frames written since the last call. Every stdout line must be one JSON-RPC 2.0 object.
    private func newFrames(file: StaticString = #filePath, line: UInt = #line) throws -> [[String: Any]] {
        server.queue.sync {}
        let lines = stdout.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        let frames = try lines.dropFirst(consumed).map { text in
            let frame = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], String(text), file: file,
                line: line)
            XCTAssertEqual(frame["jsonrpc"] as? String, "2.0", file: file, line: line)
            return frame
        }
        consumed = lines.count
        return frames
    }

    private func request(
        _ id: Int, _ method: String, _ params: [String: Any] = [:], file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String: Any] {
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let frames = try newFrames(file: file, line: line)
        XCTAssertEqual(frames.count, 1, "one answer per request", file: file, line: line)
        let frame = try XCTUnwrap(frames.first, file: file, line: line)
        XCTAssertEqual(frame["id"] as? Int, id, file: file, line: line)
        return frame
    }

    /// The `tools/call` result object.
    private func call(
        _ id: Int, _ tool: String, _ arguments: [String: Any] = [:], file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> [String: Any] {
        let frame = try request(id, "tools/call", ["name": tool, "arguments": arguments], file: file, line: line)
        return try XCTUnwrap(frame["result"] as? [String: Any], "\(frame)", file: file, line: line)
    }

    private func structured(_ result: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }

    private func text(_ result: [String: Any]) throws -> String {
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content.first?["type"] as? String, "text")
        return try XCTUnwrap(content.first?["text"] as? String)
    }

    /// A tool result refusal: `isError`, the message as text and the CLI's `error` object.
    private func refusal(_ result: [String: Any], file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: Any]
    {
        XCTAssertEqual(result["isError"] as? Bool, true, "\(result)", file: file, line: line)
        let error = try XCTUnwrap(try structured(result)["error"] as? [String: Any], file: file, line: line)
        XCTAssertEqual(try text(result), error["message"] as? String, file: file, line: line)
        return error
    }

    private func cli(_ arguments: [String], stdin: String? = nil) -> AgentHelper.Output {
        let pipe = Pipe()
        if let stdin { pipe.fileHandleForWriting.write(Data(stdin.utf8)) }
        try? pipe.fileHandleForWriting.close()
        return AgentHelper.run(
            arguments + ["--grants", grantsURL.path], home: root, environment: [:],
            standardInput: pipe.fileHandleForReading)
    }

    private func cliError(_ output: AgentHelper.Output) throws -> [String: Any] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, false, output.stdout)
        return try XCTUnwrap(json["error"] as? [String: Any])
    }

    private func cliResult(_ output: AgentHelper.Output) throws -> [String: Any] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, true, output.stdout)
        return try XCTUnwrap(json["result"] as? [String: Any])
    }

    private func initialize(_ version: String = "2025-06-18") throws -> [String: Any] {
        let frame = try request(
            1, "initialize",
            [
                "protocolVersion": version, "capabilities": [:],
                "clientInfo": ["name": "test-client", "version": "1.0"],
            ])
        try send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        XCTAssertTrue(try newFrames().isEmpty, "notifications get no answer")
        return try XCTUnwrap(frame["result"] as? [String: Any])
    }

    // MARK: Initialize and discovery

    func testInitializeNegotiatesVersionAndOffersToolsOnly() throws {
        let result = try initialize()
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-06-18")
        XCTAssertEqual(
            result["serverInfo"] as? [String: String],
            ["name": "silkweb", "title": "Silkweb", "version": SilkwebCore.version])
        XCTAssertEqual(result["capabilities"] as? [String: [String: Bool]], ["tools": ["listChanged": false]])
        XCTAssertEqual(
            result["instructions"] as? String,
            "Read and create Markdown documents in the Silkweb Library folders this grant allows. "
                + "Grants that allow updates can also replace the body of documents an agent created; earlier "
                + "versions are kept. Nothing is ever deleted.")

        for version in AgentMCPServer.protocolVersions {
            XCTAssertEqual(
                AgentMCPServer.initializeResult(requested: version)[key: "protocolVersion"]?.stringValue, version)
        }
        XCTAssertEqual(
            AgentMCPServer.initializeResult(requested: "1999-01-01")[key: "protocolVersion"]?.stringValue,
            AgentMCPServer.protocolVersions[0], "an unknown version gets the newest")
        XCTAssertEqual(try request(2, "ping")["result"] as? [String: String], [:])
    }

    func testToolsListMatchesGoldenTitlesAndAnnotations() throws {
        _ = try initialize()
        let result = try XCTUnwrap(try request(2, "tools/list")["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        XCTAssertEqual(
            tools.compactMap { $0["name"] as? String },
            [
                "memory_capabilities", "memory_search", "memory_read", "memory_create", "memory_create_folder",
                "memory_update", "memory_activity",
            ])
        let expected: [String: (title: String, readOnly: Bool)] = [
            "memory_capabilities": ("Silkweb: What This Grant Allows", true),
            "memory_search": ("Silkweb: Search Memory", true),
            "memory_read": ("Silkweb: Read Document", true),
            "memory_create": ("Silkweb: Create Document", false),
            "memory_create_folder": ("Silkweb: Create Folder", false),
            "memory_update": ("Silkweb: Update Document", false),
            "memory_activity": ("Silkweb: Recent Agent Activity", true),
        ]
        for tool in tools {
            let name = try XCTUnwrap(tool["name"] as? String)
            let annotations = try XCTUnwrap(tool["annotations"] as? [String: Any])
            XCTAssertEqual(tool["title"] as? String, expected[name]?.title)
            XCTAssertEqual(annotations["readOnlyHint"] as? Bool, expected[name]?.readOnly, name)
            // Only an update replaces existing text (kept as an earlier version).
            XCTAssertEqual(annotations["destructiveHint"] as? Bool, name == "memory_update", name)
            XCTAssertEqual(annotations["idempotentHint"] as? Bool, true, name)
            XCTAssertEqual(annotations["openWorldHint"] as? Bool, false, name)
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any], name)
            XCTAssertNotNil(tool["outputSchema"] as? [String: Any], name)
        }
        let create = try XCTUnwrap(tools.first { $0["name"] as? String == "memory_create" })
        XCTAssertTrue(
            (create["description"] as? String)?.hasPrefix(
                "Creates a new Markdown document in Memories, Progress or Handoffs. Never replaces or edits an "
                    + "existing document; if the name is taken, a numbered name is used.") == true)
        let folder = try XCTUnwrap(tools.first { $0["name"] as? String == "memory_create_folder" })
        XCTAssertTrue(
            (folder["description"] as? String)?.hasPrefix(
                "Creates a folder inside a create folder. Never moves, renames or deletes.") == true)

        // The golden list is published in docs/; SILKWEB_RECORD_GOLDEN=1 rewrites it after a deliberate change.
        let actual = AgentJSON.object([("tools", .array(AgentMCPTool.allCases.map(\.definition)))]).rendered
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/agent-memory-mcp-tools.json")
        if ProcessInfo.processInfo.environment["SILKWEB_RECORD_GOLDEN"] == "1" {
            try actual.write(to: golden, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(
            actual, try String(contentsOf: golden, encoding: .utf8), "tools/list differs from \(golden.path)")
    }

    // MARK: Calls

    func testEveryToolSucceedsWithStructuredContentAndSummary() throws {
        _ = try initialize()

        let capabilities = try call(2, "memory_capabilities")
        XCTAssertEqual(capabilities["isError"] as? Bool, false)
        XCTAssertEqual(
            try structured(capabilities) as NSDictionary,
            try cliResult(cli(["memory", "capabilities"])) as NSDictionary,
            "the CLI's result, unchanged")
        XCTAssertTrue(try text(capabilities).hasPrefix("Read and Create access to Memory › Projects › Silkweb.\n\n{"))

        let created = try call(
            3, "memory_create",
            [
                "folder": "memories", "title": "Use flock", "body": "Commits go through the quartz gate.\n",
                "idempotencyKey": "k1",
            ])
        XCTAssertEqual(created["isError"] as? Bool, false)
        let creation = try structured(created)
        XCTAssertEqual(creation["outcome"] as? String, "created")
        XCTAssertEqual(creation["replayed"] as? Bool, false)
        let path = try XCTUnwrap(creation["path"] as? String)
        XCTAssertEqual(path, project + "/Memories/Use flock.md")
        let receipt = try XCTUnwrap(creation["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["agent"] as? String, "claude-code")
        XCTAssertEqual(receipt["session"] as? String, "s1")
        XCTAssertEqual(receipt["client"] as? String, "test-client", "the client's name from initialize")
        XCTAssertTrue(try text(created).hasPrefix("Created “Use flock” in Memory › Projects › Silkweb › Memories.\n\n"))
        XCTAssertFalse(try text(created).contains("quartz"), "a create never echoes body text")

        // A replay is a success with the original receipt.
        let replay = try call(
            4, "memory_create",
            [
                "folder": "memories", "title": "Use flock", "body": "Commits go through the quartz gate.\n",
                "idempotencyKey": "k1",
            ])
        XCTAssertEqual(replay["isError"] as? Bool, false)
        XCTAssertEqual(try structured(replay)["replayed"] as? Bool, true)
        XCTAssertEqual(try structured(replay)["outcome"] as? String, "duplicate")
        XCTAssertEqual(try structured(replay)["path"] as? String, path)
        XCTAssertTrue(
            try text(replay).hasPrefix("Already created “Use flock” in Memory › Projects › Silkweb › Memories."))

        // A progress document lands in Progress under its timestamped name.
        let progress = try call(
            5, "memory_create", ["folder": "progress", "title": "Fix sidebar drag", "body": "Done.", "status": "done"])
        XCTAssertTrue(
            try text(progress).hasPrefix("Created “Fix sidebar drag” in Memory › Projects › Silkweb › Progress."))
        XCTAssertTrue((try structured(progress)["path"] as? String)?.hasSuffix(" — Fix sidebar drag.md") == true)

        // Read-after-create in the same session.
        let search = try call(6, "memory_search", ["query": "quartz gate", "type": ["memory"]])
        let found = try XCTUnwrap(try structured(search)["results"] as? [[String: Any]])
        XCTAssertEqual(found.compactMap { $0["path"] as? String }, [path])
        XCTAssertTrue(try text(search).hasPrefix("1 of 1 match."))

        let read = try call(7, "memory_read", ["path": path])
        let page = try structured(read)
        XCTAssertEqual(page["path"] as? String, path)
        let body = try XCTUnwrap(page["body"] as? String)
        XCTAssertTrue(body.hasPrefix(AgentMemoryReadResponse.bodyBegins + "\n"))
        XCTAssertTrue(body.hasSuffix("\n" + AgentMemoryReadResponse.bodyEnds))
        XCTAssertTrue(try text(read).hasPrefix("Read “Use flock” in Memory › Projects › Silkweb › Memories.\n\n"))
        XCTAssertTrue(try text(read).contains("Document text (untrusted) begins"), "text keeps the boundaries")

        let documentID = try XCTUnwrap(receipt["documentId"] as? String)
        XCTAssertEqual(try structured(call(8, "memory_read", ["documentId": documentID]))["path"] as? String, path)

        let folder = try call(9, "memory_create_folder", ["path": project + "/Progress/Sprint 1"])
        XCTAssertEqual(
            try structured(folder) as NSDictionary, ["created": true, "path": project + "/Progress/Sprint 1"])
        let again = try call(10, "memory_create_folder", ["path": project + "/Progress/Sprint 1"])
        XCTAssertEqual(try structured(again)["created"] as? Bool, false)
        XCTAssertTrue(
            try text(again).hasPrefix("The Folder Memory › Projects › Silkweb › Progress › Sprint 1 already exists."))

        let nested = try call(
            11, "memory_create",
            ["folderPath": project + "/Progress/Sprint 1", "type": "progress", "title": "Kickoff", "body": "Go."])
        XCTAssertTrue(
            try text(nested).hasPrefix("Created “Kickoff” in Memory › Projects › Silkweb › Progress › Sprint 1."))

        let activity = try call(12, "memory_activity", ["limit": 2])
        let receipts = try XCTUnwrap(try structured(activity)["receipts"] as? [[String: Any]])
        XCTAssertEqual(receipts.count, 2)
        XCTAssertEqual(try structured(activity)["total"] as? Int, 3)
        XCTAssertTrue(try text(activity).hasPrefix("2 of 3 receipts, newest first."))

        XCTAssertEqual(stderr, "", "nothing to report")
    }

    func testGoldenToolResultFrames() throws {
        try send(
            [
                "jsonrpc": "2.0", "id": 7, "method": "tools/call",
                "params": ["name": "memory_create_folder", "arguments": ["path": project + "/Progress/Sprint 1"]],
            ])
        try send(
            [
                "jsonrpc": "2.0", "id": "r-8", "method": "tools/call",
                "params": ["name": "memory_read", "arguments": ["path": "Notes/Private/Diary.md"]],
            ])
        server.queue.sync {}
        XCTAssertEqual(
            stdout,
            #"{"jsonrpc":"2.0","id":7,"result":{"content":[{"type":"text","text":"Created the Folder Memory › "#
                + #"Projects › Silkweb › Progress › Sprint 1.\n\n{\"created\":true,\"path\":\"Memory/Projects/"#
                + #"Silkweb/Progress/Sprint 1\"}"}],"structuredContent":{"created":true,"path":"Memory/Projects/"#
                + #"Silkweb/Progress/Sprint 1"},"isError":false}}"# + "\n"
                + #"{"jsonrpc":"2.0","id":"r-8","result":{"content":[{"type":"text","text":"That location is "#
                + #"outside this grant’s read folders (Memory › Projects › Silkweb)."}],"structuredContent":"#
                + #"{"error":{"code":"out_of_scope","message":"That location is outside this grant’s read folders "#
                + #"(Memory › Projects › Silkweb).","title":"No Agent Access"}},"isError":true}}"# + "\n")
        XCTAssertEqual(
            stderr,
            "silkweb: memory_read: That location is outside this grant’s read folders (Memory › Projects › Silkweb).\n")
    }

    // MARK: Refusals match the CLI

    func testRefusalsMatchTheCLIs() throws {
        _ = try initialize()
        var id = 10
        func expect(
            _ tool: String, _ arguments: [String: Any], cli command: [String], stdin: String? = nil, code: String,
            line: UInt = #line
        ) throws {
            id += 1
            let mcp = try refusal(try call(id, tool, arguments, line: line), line: line)
            var terminal = try cliError(cli(command, stdin: stdin))
            XCTAssertEqual(mcp["code"] as? String, code, line: line)
            // An invalid value names the argument the caller sent (documentId, not --id).
            for (option, argument) in AgentMCPServer.argumentNames
            where terminal["message"] as? String == AgentAccessError.invalidArgument(option).message {
                terminal["message"] = AgentAccessError.invalidArgument(argument).message
            }
            XCTAssertEqual(mcp as NSDictionary, terminal as NSDictionary, "same code and copy as the CLI", line: line)
        }
        let create = ["memory", "create", "--agent", "claude-code", "--session", "s1", "--body-file", "-"]

        try expect(
            "memory_read", ["path": "Notes/Private/Diary.md"], cli: ["memory", "read", "Notes/Private/Diary.md"],
            code: "out_of_scope")
        try expect(
            "memory_read", ["path": "../Diary.md"], cli: ["memory", "read", "../Diary.md"], code: "invalid_path")
        try expect(
            "memory_read", ["path": project + "/Missing.md"], cli: ["memory", "read", project + "/Missing.md"],
            code: "not_found")
        try expect(
            "memory_read", ["documentId": "not-a-uuid"], cli: ["memory", "read", "--id", "not-a-uuid"],
            code: "invalid_argument")
        try expect(
            "memory_search", ["project": "Notes"], cli: ["memory", "search", "--project", "Notes"], code: "out_of_scope"
        )
        try expect(
            "memory_search", ["createdAfter": "yesterday"], cli: ["memory", "search", "--created-after", "yesterday"],
            code: "invalid_argument")
        try expect(
            "memory_create_folder", ["path": "Notes/New"], cli: ["memory", "create-folder", "Notes/New"],
            code: "out_of_scope")
        try expect(
            "memory_create", ["folder": "memories", "title": "CLAUDE", "body": "x"],
            cli: create + ["--folder", "memories", "--title", "CLAUDE"], stdin: "x", code: "excluded_name")
        try expect(
            "memory_create", ["folder": "progress", "type": "memory", "title": "Wrong", "body": "x"],
            cli: create + ["--folder", "progress", "--type", "memory", "--title", "Wrong"], stdin: "x",
            code: "invalid_argument")
        try expect(
            "memory_create", ["folderPath": "Notes", "type": "memory", "title": "Out", "body": "x"],
            cli: create + ["--folder", "Notes", "--type", "memory", "--title", "Out"], stdin: "x", code: "out_of_scope")

        // Same key, other content: a conflict on both surfaces, and the CLI's own create replays over MCP.
        _ = cli(create + ["--folder", "memories", "--title", "Shared", "--idempotency-key", "k9"], stdin: "first")
        try expect(
            "memory_create", ["folder": "memories", "title": "Shared", "body": "second", "idempotencyKey": "k9"],
            cli: create + ["--folder", "memories", "--title", "Shared", "--idempotency-key", "k9"], stdin: "second",
            code: "idempotency_conflict")
        let replay = try call(
            40, "memory_create", ["folder": "memories", "title": "Shared", "body": "first", "idempotencyKey": "k9"])
        XCTAssertEqual(try structured(replay)["replayed"] as? Bool, true, "a create made by the CLI replays over MCP")

        // More than a pipe holds, so the CLI reads it from a file.
        let oversize = String(repeating: "a", count: AgentGrantLimits.defaultMaxCreateBytes + 1)
        let bodyFile = root.appendingPathComponent("big.md")
        try Data(oversize.utf8).write(to: bodyFile)
        try expect(
            "memory_create", ["folder": "memories", "title": "Big", "body": oversize],
            cli: Array(create.dropLast()) + [bodyFile.path, "--folder", "memories", "--title", "Big"], code: "too_large"
        )

        // Read Only: creates are refused; the server re-checks the grant on every call.
        try writeGrants([grant(access: .read)])
        try expect(
            "memory_create", ["folder": "memories", "title": "Nope", "body": "x"],
            cli: create + ["--folder", "memories", "--title", "Nope"], stdin: "x", code: "create_not_allowed")
        try expect(
            "memory_create_folder", ["path": project + "/Memories/New"],
            cli: ["memory", "create-folder", project + "/Memories/New"], code: "create_not_allowed")

        try writeGrants([grant(revoked: true)])
        try expect("memory_capabilities", [:], cli: ["memory", "capabilities"], code: "grant_revoked")
        try expect("memory_search", ["query": "x"], cli: ["memory", "search", "x"], code: "grant_revoked")

        XCTAssertFalse(stderr.contains("private words") || stderr.contains("Diary"), stderr)
        XCTAssertFalse(stderr.contains("first") || stderr.contains("second"), "never body text")
        XCTAssertTrue(stderr.hasPrefix("silkweb: memory_read: "), stderr)
    }

    /// #204: `memory_update` over the same service as `memory update`: read → update → stale revision → replay,
    /// and the refusal for grants without updates matches the CLI's.
    func testUpdateToolReplacesTheBodyAndRefusesLikeTheCLI() throws {
        try writeGrants([grant(access: .readCreateUpdate)])
        _ = try initialize()
        let created = try call(
            2, "memory_create", ["folder": "handoffs", "title": "Next steps", "body": "Start.", "idempotencyKey": "c1"])
        let path = try XCTUnwrap(try structured(created)["path"] as? String)
        let read = try structured(try call(3, "memory_read", ["path": path]))
        let revision = try XCTUnwrap(read["revision"] as? String)
        let documentID = try XCTUnwrap(read["documentId"] as? String)

        let updated = try call(
            4, "memory_update",
            ["path": path, "expectedRevision": revision, "body": "# Next steps\n\nFinish.\n", "idempotencyKey": "u1"])
        XCTAssertEqual(updated["isError"] as? Bool, false, "\(updated)")
        let result = try structured(updated)
        XCTAssertEqual(result["outcome"] as? String, "updated")
        XCTAssertEqual(result["path"] as? String, path)
        XCTAssertTrue(
            try text(updated).hasPrefix(
                "Updated “Next steps” in Memory › Projects › Silkweb › Handoffs. The earlier version was kept.\n\n"))
        XCTAssertFalse(try text(updated).contains("Finish"), "an update never echoes body text")
        let receipt = try XCTUnwrap(result["receipt"] as? [String: Any])
        XCTAssertEqual(receipt["client"] as? String, "test-client")
        XCTAssertEqual(receipt["session"] as? String, "s1")
        // Read-after-update in the same session sees the new text and revision.
        let reread = try structured(try call(5, "memory_read", ["documentId": documentID]))
        XCTAssertEqual(reread["revision"] as? String, result["revision"] as? String)
        XCTAssertTrue((reread["body"] as? String)?.contains("Finish.") == true)

        // The old revision: refused with the current one, nothing written.
        let stale = try refusal(
            try call(6, "memory_update", ["documentId": documentID, "expectedRevision": revision, "body": "Again."]))
        XCTAssertEqual(stale["code"] as? String, "revision_changed")
        XCTAssertEqual(stale["currentRevision"] as? String, result["revision"] as? String)
        // A replay of the first call is its original result.
        let replay = try call(
            7, "memory_update",
            ["path": path, "expectedRevision": revision, "body": "# Next steps\n\nFinish.\n", "idempotencyKey": "u1"])
        XCTAssertEqual(try structured(replay)["replayed"] as? Bool, true)
        // Both or neither of path and documentId is a protocol error.
        let both = try request(
            8, "tools/call",
            [
                "name": "memory_update",
                "arguments": [
                    "path": path, "documentId": documentID, "expectedRevision": "r",
                    "body": "x",
                ],
            ])
        XCTAssertEqual((both["error"] as? [String: Any])?["code"] as? Int, -32602)

        try writeGrants([grant(access: .readCreate)])
        let notAllowed = try refusal(
            try call(9, "memory_update", ["path": path, "expectedRevision": revision, "body": "x"]))
        XCTAssertEqual(notAllowed["code"] as? String, "update_not_allowed")
        let cliError = try cliError(
            cli(
                [
                    "memory", "update", path, "--expected-revision", revision, "--body-file", "-", "--agent", "a",
                    "--session", "s",
                ], stdin: "x"))
        XCTAssertEqual(cliError as NSDictionary, notAllowed as NSDictionary)
    }

    func testRateLimitIsSharedAcrossTheSession() throws {
        try writeGrants([grant(limits: AgentGrantLimits(requestsPerMinute: 2))])
        XCTAssertEqual(try call(1, "memory_capabilities")["isError"] as? Bool, false)
        XCTAssertEqual(try call(2, "memory_search", ["query": "x"])["isError"] as? Bool, false)
        let error = try refusal(try call(3, "memory_capabilities"))
        XCTAssertEqual(error["code"] as? String, "rate_limited")
        XCTAssertNotNil(error["retryAfter"] as? Int)
        // tools/list and ping aren't operations on the Library.
        XCTAssertNotNil(try request(4, "tools/list")["result"])
    }

    // MARK: Protocol faults

    func testProtocolFaultsAreJSONRPCErrors() throws {
        func errorCode(_ frame: [String: Any]) -> Int? { (frame["error"] as? [String: Any])?["code"] as? Int }
        func fault(_ id: Int, _ tool: String, _ arguments: Any, line: UInt = #line) throws -> String {
            let frame = try request(id, "tools/call", ["name": tool, "arguments": arguments], line: line)
            XCTAssertNil(frame["result"], line: line)
            XCTAssertEqual(errorCode(frame), -32602, line: line)
            return (frame["error"] as? [String: Any])?["message"] as? String ?? ""
        }
        XCTAssertEqual(try fault(1, "write_file", ["path": "x"]), "Unknown tool.")
        XCTAssertEqual(
            try fault(2, "memory_search", ["limit": 99]),
            "Invalid arguments for memory_search: “limit” must be at most 50.")
        XCTAssertEqual(
            try fault(3, "memory_search", ["limit": 0]),
            "Invalid arguments for memory_search: “limit” must be at least 1.")
        XCTAssertEqual(
            try fault(4, "memory_search", ["limit": "10"]),
            "Invalid arguments for memory_search: “limit” must be a whole number.")
        XCTAssertEqual(
            try fault(5, "memory_search", ["type": ["note"]]),
            "Invalid arguments for memory_search: “type item” must be one of memory, decision, progress, handoff.")
        XCTAssertEqual(
            try fault(6, "memory_search", ["type": "memory"]),
            "Invalid arguments for memory_search: “type” must be a list.")
        XCTAssertEqual(
            try fault(7, "memory_read", ["path": "a.md", "documentId": "b"]),
            "Invalid arguments for memory_read: give path or documentId, not both.")
        XCTAssertEqual(
            try fault(8, "memory_read", [:]), "Invalid arguments for memory_read: give path or documentId, not both.")
        XCTAssertEqual(
            try fault(9, "memory_create", ["title": "T", "body": "B"]),
            "Invalid arguments for memory_create: give folder or type.")
        XCTAssertEqual(
            try fault(10, "memory_create", ["folder": "memories", "title": "T"]),
            "Invalid arguments for memory_create: “body” is required.")
        XCTAssertEqual(
            try fault(11, "memory_create", ["folder": "Memories/X", "title": "T", "body": "B"]),
            "Invalid arguments for memory_create: “folder” must be one of memories, progress, handoffs.")
        XCTAssertEqual(
            try fault(
                12, "memory_create", ["folderPath": "Memory/Projects/Silkweb/Memories", "title": "T", "body": "B"]),
            "Invalid arguments for memory_create: folderPath needs type.")
        XCTAssertEqual(
            try fault(
                13, "memory_create",
                ["folder": "memories", "title": "T", "body": "B", "idempotencyKey": String(repeating: "k", count: 201)]),
            "Invalid arguments for memory_create: “idempotencyKey” must be at most 200 characters.")
        XCTAssertEqual(
            try fault(14, "memory_create_folder", ["path": "p", "recursive": true]),
            "Invalid arguments for memory_create_folder: “recursive” isn’t a known argument.")
        XCTAssertEqual(
            try fault(15, "memory_activity", ["limit": 2.5]),
            "Invalid arguments for memory_activity: “limit” must be a whole number.")
        XCTAssertEqual(
            try fault(16, "memory_capabilities", "all"),
            "Invalid arguments for memory_capabilities: The arguments must be an object.")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: library.appendingPathComponent(project + "/Memories").path),
            "a refused call never reaches the Library")

        XCTAssertEqual(errorCode(try request(20, "resources/list")), -32601)
        XCTAssertEqual(errorCode(try request(21, "logging/setLevel", ["level": "debug"])), -32601)

        send(raw: "{not json")
        send(raw: #"{"jsonrpc":"1.0","id":22,"method":"ping"}"#)
        send(raw: #"[{"jsonrpc":"2.0","id":23,"method":"ping"}]"#)
        send(raw: #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#)
        send(raw: "   \r")
        // A response from the client and an unknown notification are ignored.
        send(raw: #"{"jsonrpc":"2.0","id":"x","result":{}}"#)
        send(raw: #"{"jsonrpc":"2.0","method":"notifications/roots/list_changed"}"#)
        send(raw: #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":999}}"#)
        let frames = try newFrames()
        XCTAssertEqual(frames.map { errorCode($0) }, [-32700, -32600, -32600, -32600])
        XCTAssertTrue(frames.allSatisfy { $0["id"] is NSNull })
        XCTAssertEqual(try request(24, "ping")["result"] as? [String: String], [:], "the session keeps going")
    }

    // MARK: Cancellation and shutdown

    func testCancellationSkipsQueuedCallsAndLetsStartedCreatesFinishSilently() throws {
        let started = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        server.willRun = { key in
            guard ["1", "3", "4"].contains(key) else { return }
            started.signal()
            _ = proceed.wait(timeout: .now() + 30)
        }
        func waitUntilStarted(line: UInt = #line) {
            XCTAssertEqual(started.wait(timeout: .now() + 30), .success, "the call started", line: line)
        }
        func call(_ id: Int, _ tool: String, _ arguments: [String: Any]) throws {
            try send(
                ["jsonrpc": "2.0", "id": id, "method": "tools/call", "params": ["name": tool, "arguments": arguments]])
        }
        func cancel(_ id: Int) throws {
            try send(
                [
                    "jsonrpc": "2.0", "method": "notifications/cancelled",
                    "params": ["requestId": id, "reason": "User interrupted"],
                ])
        }
        let memories = library.appendingPathComponent(project + "/Memories")

        // 2 is queued behind 1 and cancelled before it starts: it never runs.
        try call(1, "memory_capabilities", [:])
        waitUntilStarted()
        try call(2, "memory_create", ["folder": "memories", "title": "Never started", "body": "x"])
        try cancel(2)
        proceed.signal()
        XCTAssertEqual(try newFrames().compactMap { $0["id"] as? Int }, [1])
        XCTAssertFalse(FileManager.default.fileExists(atPath: memories.appendingPathComponent("Never started.md").path))

        // 3 has started when it's cancelled: the create finishes atomically and sends nothing.
        try call(3, "memory_create", ["folder": "memories", "title": "Started", "body": "x", "idempotencyKey": "k3"])
        waitUntilStarted()
        try cancel(3)
        proceed.signal()
        XCTAssertTrue(try newFrames().isEmpty, "no answer to a cancelled request")
        XCTAssertTrue(FileManager.default.fileExists(atPath: memories.appendingPathComponent("Started.md").path))
        let receipts = try FileManager.default.contentsOfDirectory(
            at: library.appendingPathComponent(".silkweb/agent-events"), includingPropertiesForKeys: nil)
        XCTAssertEqual(receipts.count, 1, "the create completed with its receipt")

        // 4, a read that has started, stops and sends nothing.
        try call(4, "memory_read", ["path": project + "/Memories/Started.md"])
        waitUntilStarted()
        try cancel(4)
        proceed.signal()
        XCTAssertTrue(try newFrames().isEmpty)

        // Retrying the cancelled create with its key is a replay, not a second document.
        let retry = try self.call(
            5, "memory_create", ["folder": "memories", "title": "Started", "body": "x", "idempotencyKey": "k3"])
        XCTAssertEqual(try structured(retry)["replayed"] as? Bool, true)
        XCTAssertEqual(try request(6, "ping")["result"] as? [String: String], [:])
    }

    func testEOFReturnsZeroAfterInFlightWorkSettles() throws {
        server.willRun = { key in if key == "3" { usleep(200_000) } }
        let input = Pipe()
        let finished = expectation(description: "serve returned")
        let status = LockedStatus()
        let reading = input.fileHandleForReading.fileDescriptor
        let server = self.server!
        Thread.detachNewThread {
            status.value = server.serve(input: reading)
            finished.fulfill()
        }
        let lines = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"c","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_create","arguments":{"folder":"handoffs","title":"Resume here","body":"Line one\r\nline two\n"}}}"#,
        ]
        // Written in small pieces, so frames are reassembled across reads; the last line has no newline.
        let bytes = Data(lines.joined(separator: "\n").utf8)
        for start in stride(from: 0, to: bytes.count, by: 37) {
            input.fileHandleForWriting.write(bytes[start..<min(start + 37, bytes.count)])
        }
        try input.fileHandleForWriting.close()
        wait(for: [finished], timeout: 30)
        XCTAssertEqual(status.value, 0)
        let frames = try newFrames()
        XCTAssertEqual(frames.compactMap { $0["id"] as? Int }, [1, 2, 3], "the create answered before serve returned")
        let result = try XCTUnwrap(frames.last?["result"] as? [String: Any])
        XCTAssertEqual(try structured(result)["outcome"] as? String, "created")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: library.appendingPathComponent(project + "/Handoffs/Resume here.md").path))
    }

    func testLaunchSelectsOneGrantOrExitsBeforeInitialize() throws {
        func launch(_ arguments: [String], environment: [String: String] = [:]) -> (Int32, String, String) {
            let out = descriptor(outURL)
            let err = descriptor(errURL)
            let input = open("/dev/null", O_RDONLY)
            defer { close(input) }
            let status = AgentMCPServer.main(
                ["mcp"] + arguments + ["--grants", grantsURL.path], home: root, environment: environment,
                input: input, output: out, errors: err)
            return (status, stdout, stderr)
        }
        // One grant, stdin already closed: a clean start and a clean exit, with nothing on stdout.
        XCTAssertEqual(launch([]).0, 0)
        XCTAssertEqual(stdout, "")

        try writeGrants([grant(), grant("Notes", label: "Notes", access: .read)])
        let ambiguous = launch([])
        XCTAssertEqual(ambiguous.0, 77)
        XCTAssertEqual(ambiguous.1, "", "stdout stays MCP-only")
        XCTAssertEqual(ambiguous.2, "silkweb: Choose a grant with --grant. Available: “Silkweb project”, “Notes”.\n")
        XCTAssertEqual(launch(["--grant", "Notes"]).0, 0)
        XCTAssertEqual(launch([], environment: ["SILKWEB_GRANT": "Silkweb"]).0, 0)

        let missing = launch(["--grant", "Other"])
        XCTAssertEqual(missing.0, 77)
        XCTAssertEqual(
            missing.2, "silkweb: No agent access named “Other” exists. Ask the owner to create one in Silkweb.\n")

        let unknown = launch(["--pretty"])
        XCTAssertEqual(unknown.0, 64)
        XCTAssertEqual(
            unknown.2, "silkweb: The option “--pretty” isn’t valid for “mcp”. Run “silkweb mcp --help” for usage.\n")
        XCTAssertEqual(launch(["--type", "memory"]).0, 64)
        XCTAssertEqual(launch(["extra"]).0, 64)

        let help = launch(["--help"])
        XCTAssertEqual(help.0, 0)
        XCTAssertEqual(help.1, AgentMCPServer.help)
    }

    /// The built `silkweb` binary as an agent launches it: every stdout line is an MCP frame.
    func testBuiltHelperBinaryKeepsStdoutForMCPFramesOnly() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("SilkwebHelper")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("SilkwebHelper isn't built next to the test bundle")
        }
        func launch(_ input: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
            let process = Process()
            process.executableURL = binary
            process.arguments = ["mcp", "--grants", grantsURL.path, "--agent", "codex"]
            let stdin = Pipe()
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()
            // A server that exits before reading (a launch failure) closes the pipe: no SIGPIPE here.
            signal(SIGPIPE, SIG_IGN)
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.map { $0 + "\n" }.joined().utf8))
            try? stdin.fileHandleForWriting.close()
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
            defer { watchdog.cancel() }
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (
                process.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self)
            )
        }
        // Only calls that keep the search cache out of the real home folder.
        let session = try launch([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"codex","version":"1"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"memory_capabilities","arguments":{}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"memory_read","arguments":{"path":"Notes/Private/Diary.md"}}}"#,
            #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"memory_create_folder","arguments":{"path":"Memory/Projects/Silkweb/Progress/Sprint 1"}}}"#,
            #"{"jsonrpc":"2.0","id":6,"method":"ping"}"#,
        ])
        XCTAssertEqual(session.status, 0, session.stderr)
        let lines = session.stdout.split(separator: "\n")
        XCTAssertTrue(session.stdout.hasSuffix("\n"))
        var ids: [Int] = []
        for line in lines {
            let frame = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], String(line))
            XCTAssertEqual(frame["jsonrpc"] as? String, "2.0")
            ids += [frame["id"] as? Int].compactMap { $0 }
        }
        // ping is answered at once; tool calls answer in order on their queue.
        XCTAssertEqual(ids.sorted(), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(ids.filter { (3...5).contains($0) }, [3, 4, 5])
        XCTAssertEqual(
            session.stderr,
            "silkweb: memory_read: That location is outside this grant’s read folders (Memory › Projects › Silkweb).\n")
        XCTAssertFalse(session.stdout.contains("private words"))

        try writeGrants([grant(), grant("Notes", label: "Notes", access: .read)])
        let ambiguous = try launch([#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#])
        XCTAssertEqual(ambiguous.status, 77)
        XCTAssertEqual(ambiguous.stdout, "")
        XCTAssertEqual(
            ambiguous.stderr, "silkweb: Choose a grant with --grant. Available: “Silkweb project”, “Notes”.\n")
    }
}

private final class LockedStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32 = -1
    var value: Int32 {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

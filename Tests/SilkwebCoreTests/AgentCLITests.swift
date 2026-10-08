import XCTest

@testable import SilkwebCore

/// The `silkweb memory …` terminal contract (#135): one JSON envelope on stdout, `silkweb: …` on
/// stderr, sysexits statuses, grant selection, and input handling. Runs with Silkweb closed.
final class AgentCLITests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!
    private let project = "Memory/Projects/Silkweb"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentCLI-\(UUID().uuidString)")
        library = root.appendingPathComponent("Writing Library 日本語")
        grantsURL = root.appendingPathComponent("grants.json")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(project), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Notes/Private"), withIntermediateDirectories: true)
        try Data("# Diary\n\nprivate words".utf8).write(to: library.appendingPathComponent("Notes/Private/Diary.md"))
        try writeGrants([grant()])
    }

    override func tearDownWithError() throws {
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

    private func run(
        _ arguments: [String], environment: [String: String] = [:], stdin: String? = nil
    ) -> AgentHelper.Output {
        let pipe = Pipe()
        if let stdin {
            pipe.fileHandleForWriting.write(Data(stdin.utf8))
        }
        try? pipe.fileHandleForWriting.close()
        return AgentHelper.run(
            arguments + ["--grants", grantsURL.path], home: root, environment: environment,
            standardInput: pipe.fileHandleForReading)
    }

    private func envelope(_ output: AgentHelper.Output) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any], output.stdout)
    }

    private func result(_ output: AgentHelper.Output, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: Any]
    {
        XCTAssertEqual(output.status, 0, output.stdout + output.stderr, file: file, line: line)
        let json = try envelope(output)
        XCTAssertEqual(json["ok"] as? Bool, true, file: file, line: line)
        XCTAssertEqual(json["version"] as? Int, 1, file: file, line: line)
        return try XCTUnwrap(json["result"] as? [String: Any], output.stdout, file: file, line: line)
    }

    private func error(_ output: AgentHelper.Output) throws -> [String: Any] {
        let json = try envelope(output)
        XCTAssertEqual(json["ok"] as? Bool, false)
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertNil(json["result"])
        return try XCTUnwrap(json["error"] as? [String: Any], output.stdout)
    }

    private func create(
        title: String, folder: String = "memories", key: String? = nil, body: String = "Body text.",
        extra: [String] = [], environment: [String: String] = [:]
    ) -> AgentHelper.Output {
        var arguments = [
            "memory", "create", "--folder", folder, "--title", title, "--agent", "claude-code", "--session", "s1",
            "--body-file", "-",
        ]
        if let key { arguments += ["--idempotency-key", key] }
        return run(arguments + extra, environment: environment, stdin: body)
    }

    // MARK: Every command, headless

    func testEveryCommandSucceedsHeadlessWithOneJSONEnvelope() throws {
        var outputs: [AgentHelper.Output] = []

        let capabilities = run(["memory", "capabilities"])
        outputs.append(capabilities)
        let scope = try result(capabilities)
        XCTAssertEqual(scope["label"] as? String, "Silkweb project")
        XCTAssertEqual(scope["profile"] as? String, "Read and Create")
        XCTAssertEqual(scope["schema"] as? String, "silkweb-memory/v1")
        XCTAssertNotNil(scope["limits"] as? [String: Int])
        XCTAssertNil(scope["documents"], "capabilities never counts documents")

        let created = create(title: "Use flock", key: "k1", body: "Commits go through the quartz gate.\n")
        outputs.append(created)
        let creation = try result(created)
        XCTAssertEqual(creation["outcome"] as? String, "created")
        let path = try XCTUnwrap(creation["path"] as? String)
        XCTAssertEqual(path, project + "/Memories/Use flock.md")
        let receipt = try XCTUnwrap(creation["receipt"] as? [String: Any])
        let documentID = try XCTUnwrap(receipt["documentId"] as? String)

        let folder = run(["memory", "create-folder", project + "/Progress/Sprint 1"])
        outputs.append(folder)
        XCTAssertEqual(try result(folder)["created"] as? Bool, true)

        let search = run(["memory", "search", "quartz", "gate", "--type", "memory"])
        outputs.append(search)
        let found = try XCTUnwrap(try result(search)["results"] as? [[String: Any]])
        XCTAssertEqual(found.compactMap { $0["path"] as? String }, [path])
        XCTAssertEqual(found.first?["documentId"] as? String, documentID)

        let read = run(["memory", "read", path])
        outputs.append(read)
        XCTAssertTrue((try result(read)["body"] as? String)?.contains("quartz gate") == true)

        let byID = run(["memory", "read", "--id", documentID])
        outputs.append(byID)
        XCTAssertEqual(try result(byID)["path"] as? String, path)

        let activity = run(["memory", "activity"])
        outputs.append(activity)
        let receipts = try XCTUnwrap(try result(activity)["receipts"] as? [[String: Any]])
        XCTAssertEqual(receipts.compactMap { $0["idempotencyKey"] as? String }, ["k1"])
        XCTAssertEqual(try result(activity)["total"] as? Int, 1)

        let list = run(["memory", "list"])
        outputs.append(list)
        XCTAssertEqual((try result(list)["documents"] as? [[String: Any]])?.count, 1)

        for output in outputs {
            XCTAssertEqual(output.stderr, "")
            XCTAssertTrue(output.stdout.hasPrefix(#"{"ok":true,"result":"#), output.stdout)
            XCTAssertTrue(output.stdout.hasSuffix(#","version":1}"# + "\n"), output.stdout)
            XCTAssertEqual(output.stdout.filter { $0 == "\n" }.count, 1, "compact: one line")
        }
        XCTAssertFalse(created.stdout.contains("quartz"), "create never echoes body text")
        XCTAssertFalse(activity.stdout.contains("quartz"), "receipts never hold body text")
    }

    func testGoldenOutputCompactAndPretty() throws {
        let compact = run(["memory", "create-folder", project + "/Progress/Sprint 1"])
        XCTAssertEqual(
            compact.stdout,
            #"{"ok":true,"result":{"created":true,"path":"Memory/Projects/Silkweb/Progress/Sprint 1"},"version":1}"#
                + "\n")
        let pretty = run(["memory", "create-folder", project + "/Progress/Sprint 1", "--pretty"])
        XCTAssertEqual(
            pretty.stdout,
            """
            {
              "ok" : true,
              "result" : {
                "created" : false,
                "path" : "Memory/Projects/Silkweb/Progress/Sprint 1"
              },
              "version" : 1
            }

            """)

        let refused = run(["memory", "read", "Notes/Private/Diary.md"])
        XCTAssertEqual(refused.status, 77)
        XCTAssertEqual(
            refused.stdout,
            #"{"error":{"code":"out_of_scope","message":"That location is outside this grant’s read folders "#
                + #"(Memory › Projects › Silkweb).","title":"No Agent Access"},"ok":false,"version":1}"# + "\n")
        XCTAssertEqual(
            refused.stderr,
            "silkweb: That location is outside this grant’s read folders (Memory › Projects › Silkweb).\n")
    }

    // MARK: Grants

    func testGrantSelectionByFlagLabelAndEnvironment() throws {
        // One grant: used without asking.
        XCTAssertEqual(try result(run(["memory", "capabilities"]))["project"] as? String, "Silkweb")

        try writeGrants([grant(), grant("Notes", label: "Notes", access: .read)])
        let ambiguous = run(["memory", "capabilities"])
        XCTAssertEqual(ambiguous.status, 77)
        XCTAssertEqual(try error(ambiguous)["code"] as? String, "grant_required")
        XCTAssertEqual(
            ambiguous.stderr, "silkweb: Choose a grant with --grant. Available: “Silkweb project”, “Notes”.\n")
        XCTAssertFalse(ambiguous.stdout.contains(library.path), "labels only, never Library paths")

        XCTAssertEqual(try result(run(["memory", "capabilities", "--grant", "Notes"]))["project"] as? String, "Notes")
        XCTAssertEqual(
            try result(run(["memory", "capabilities", "--grant=Silkweb project"]))["project"] as? String, "Silkweb",
            "a label selects its grant")
        XCTAssertEqual(
            try result(run(["memory", "capabilities"], environment: ["SILKWEB_GRANT": "Notes"]))["project"]
                as? String, "Notes")
        XCTAssertEqual(
            try result(run(["memory", "capabilities", "--grant", "Silkweb"], environment: ["SILKWEB_GRANT": "Notes"]))[
                "project"] as? String, "Silkweb", "the flag wins over the environment")
        XCTAssertEqual(
            try error(run(["memory", "capabilities"], environment: ["SILKWEB_GRANT": ""]))["code"] as? String,
            "grant_required", "an empty variable counts as unset")

        let unknown = run(["memory", "capabilities", "--grant", "Other"])
        XCTAssertEqual(unknown.status, 77)
        XCTAssertEqual(try error(unknown)["code"] as? String, "grant_not_found")
        XCTAssertEqual(
            unknown.stderr, "silkweb: No agent access named “Other” exists. Ask the owner to create one in Silkweb.\n")

        try writeGrants([])
        XCTAssertEqual(try error(run(["memory", "capabilities"]))["code"] as? String, "grant_not_found")
    }

    /// Missing, revoked and out-of-scope failures exit non-zero and never tell anyone to turn off
    /// an agent's sandbox, OS permissions or other protections.
    func testRefusalsNeverAdviseDisablingProtections() throws {
        var failures: [(AgentHelper.Output, String, Int32)] = []
        try FileManager.default.removeItem(at: grantsURL)
        failures.append((run(["memory", "search"]), "no_grants_file", 77))

        try writeGrants([grant()])
        failures.append((run(["memory", "capabilities", "--grant", "Missing"]), "grant_not_found", 77))
        failures.append((run(["memory", "read", "Notes/Private/Diary.md"]), "out_of_scope", 77))
        failures.append((run(["memory", "create-folder", "Notes/Private/New"]), "out_of_scope", 77))
        failures.append(
            (create(title: "Escape", folder: "Notes/Private", extra: ["--type", "memory"]), "out_of_scope", 77))
        failures.append((run(["memory", "read", project + "/../../Notes/Private/Diary.md"]), "invalid_path", 77))
        failures.append((run(["memory", "read", project + "/Missing.md"]), "not_found", 65))

        try writeGrants([grant(access: .read)])
        failures.append((create(title: "Read only"), "create_not_allowed", 77))

        try writeGrants([grant(revoked: true)])
        for command in [["memory", "capabilities"], ["memory", "search"], ["memory", "activity"]] {
            failures.append((run(command), "grant_revoked", 77))
        }
        failures.append((create(title: "Revoked"), "grant_revoked", 77))

        for (output, code, status) in failures {
            XCTAssertEqual(try error(output)["code"] as? String, code, output.stdout)
            XCTAssertEqual(output.status, status, code)
            XCTAssertTrue(output.stderr.hasPrefix("silkweb: "), output.stderr)
            XCTAssertEqual(output.stderr.filter { $0 == "\n" }.count, 1, "one human line")
            let text = (output.stdout + output.stderr).lowercased()
            for advice in ["sandbox", "disable", "dangerously", "turn off", "csrutil", "full disk access"] {
                XCTAssertFalse(text.contains(advice), "\(code): \(advice)")
            }
            XCTAssertFalse(text.contains("diary"), "\(code): out-of-grant targets are never named")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("Notes/Private/New").path))
    }

    // MARK: Input handling

    func testUnicodeSpacesAndMultilineInputBehavePredictably() throws {
        let body = "First line — ünïcode ✓\n\n  indented line\nCRLF line\r\nlast line without break"
        // NFD title: the file name and the receipt use NFC, so a retry spelled either way replays.
        let decomposed = "Cafe\u{301} notes 日本"
        let created = create(title: decomposed, key: "u1", body: body)
        let path = try XCTUnwrap(try result(created)["path"] as? String)
        XCTAssertEqual(path, project + "/Memories/Caf\u{E9} notes 日本.md")
        XCTAssertEqual(path.unicodeScalars.count, (project + "/Memories/Café notes 日本.md").unicodeScalars.count)
        let replay = create(title: "Caf\u{E9} notes 日本", key: "u1", body: body)
        XCTAssertEqual(try result(replay)["replayed"] as? Bool, true)

        let disk = try String(contentsOf: library.appendingPathComponent(path), encoding: .utf8)
        XCTAssertTrue(disk.hasSuffix("# Café notes 日本\n\n" + body), "body bytes are kept exactly")

        // A body file with spaces and Unicode in its own path.
        let bodyFile = root.appendingPathComponent("my body ✓.md")
        try Data("From a file.\nSecond line.".utf8).write(to: bodyFile)
        let fromFile = run([
            "memory", "create", "--folder", "handoffs", "--title", "Next steps", "--agent", "a", "--session", "s",
            "--body-file", bodyFile.path,
        ])
        XCTAssertEqual(try result(fromFile)["path"] as? String, project + "/Handoffs/Next steps.md")

        // Read with a decomposed path, and paths with spaces; the query can start with “-” after `--`.
        let nfdPath = project + "/Memories/Cafe\u{301} notes 日本.md"
        XCTAssertTrue((try result(run(["memory", "read", nfdPath]))["body"] as? String)?.contains("CRLF line") == true)
        let dashed = AgentHelper.run(
            ["memory", "search", "--grants", grantsURL.path, "--", "-x"], home: root, environment: [:],
            standardInput: pipe(Data()))
        XCTAssertEqual(try result(dashed)["total"] as? Int, 0)
        let made = run(["memory", "create-folder", project + "/Progress/Spring 2026 ✓"])
        XCTAssertEqual(try result(made)["path"] as? String, project + "/Progress/Spring 2026 ✓")

        // Progress documents get a time stamp in the name; `--folder` keywords ignore case.
        let progress = create(title: "Checkpoint", folder: "Progress", body: "Done.")
        let progressPath = try XCTUnwrap(try result(progress)["path"] as? String)
        XCTAssertTrue(progressPath.hasPrefix(project + "/Progress/") && progressPath.hasSuffix(" — Checkpoint.md"))
        // A Library-relative `--folder` needs `--type`.
        XCTAssertEqual(create(title: "Typeless", folder: project + "/Progress/Sprint 1").status, 64)
        let nested = create(
            title: "Nested", folder: project + "/Progress/Spring 2026 ✓", extra: ["--type", "progress"])
        XCTAssertTrue((try result(nested)["path"] as? String)?.hasPrefix(project + "/Progress/Spring 2026 ✓/") == true)
    }

    func testOversizePayloadsFailWithClearErrors() throws {
        try writeGrants([grant(limits: AgentGrantLimits(maxReadBytes: 64, maxCreateBytes: 1024))])
        let large = create(title: "Too big", body: String(repeating: "x", count: 5_000))
        XCTAssertEqual(large.status, 65)
        XCTAssertEqual(try error(large)["code"] as? String, "too_large")
        XCTAssertEqual(
            large.stderr, "silkweb: This document is larger than the grant allows (1 KB). Nothing was created.\n")
        XCTAssertFalse(large.stdout.contains("xxxx"))
        // Fits as a body, but not once the front matter is added.
        XCTAssertEqual(
            try error(create(title: "Almost", body: String(repeating: "y", count: 1_000)))["code"] as? String,
            "too_large")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: library.appendingPathComponent(project + "/Memories").path))

        try writeGrants([grant(limits: AgentGrantLimits(maxReadBytes: 1024))])
        let path = try XCTUnwrap(
            try result(create(title: "Readable", body: String(repeating: "z", count: 900)))["path"] as? String)
        try writeGrants([grant(limits: AgentGrantLimits(maxReadBytes: 64))])
        let tooLargeToRead = run(["memory", "read", path])
        XCTAssertEqual(tooLargeToRead.status, 65)
        XCTAssertEqual(try error(tooLargeToRead)["code"] as? String, "too_large")
        XCTAssertFalse(tooLargeToRead.stdout.contains("zzzz"))
    }

    // MARK: Usage and codes

    /// #134 sent `invalid_argument` and #133 `invalid_request`; every command now sends `invalid_argument`.
    func testUsageAndBadInputShareOneCode() throws {
        try Data("# A".utf8).write(to: library.appendingPathComponent(project + "/A.md"))
        let cases: [[String]] = [
            ["memory", "search", "--limit", "ten"],
            ["memory", "search", "--created-after", "yesterday"],
            ["memory", "search", "--type", "note"],
            ["memory", "read", "--id", "not-a-uuid"],
            ["memory", "read", project + "/A.md", "--id", UUID().uuidString],
            ["memory", "read", "--cursor", "bad", project + "/A.md"],
            ["memory", "activity", "--limit", "0"],
            ["memory", "activity", "--since", "soon"],
            ["memory", "create", "--title", "T", "--body", "inline text is never accepted"],
            ["memory", "search", "--pretty=yes"],
            ["memory", "search", "-x"],
            ["memory", "list", "--grant"],
        ]
        for arguments in cases {
            let output = run(arguments)
            XCTAssertEqual(try error(output)["code"] as? String, "invalid_argument", "\(arguments)")
            XCTAssertEqual(output.status, 64, "\(arguments)")
        }
        XCTAssertEqual(try error(create(title: "Key", key: "a\u{7}b"))["code"] as? String, "invalid_argument")
        XCTAssertEqual(
            try error(create(title: "Mismatch", extra: ["--type", "progress"]))["code"] as? String, "invalid_argument")
        let notUTF8 = AgentHelper.run(
            [
                "memory", "create", "--folder", "memories", "--title", "Bytes", "--agent", "a", "--session", "s",
                "--body-file", "-", "--grants", grantsURL.path,
            ],
            home: root, environment: [:], standardInput: pipe(Data([0xFF, 0xFE, 0x00])))
        XCTAssertEqual(try error(notUTF8)["code"] as? String, "invalid_argument")
        XCTAssertEqual(notUTF8.stderr, "silkweb: The document text must be UTF-8.\n")
        let unreadable = run([
            "memory", "create", "--folder", "memories", "--title", "Gone", "--agent", "a", "--session", "s",
            "--body-file", root.appendingPathComponent("missing.md").path,
        ])
        XCTAssertEqual(try error(unreadable)["code"] as? String, "invalid_argument")
        XCTAssertFalse(unreadable.stderr.contains("missing.md"))
    }

    func testExitStatusesFollowSysexits() {
        let expected: [String: Int32] = [
            "invalid_argument": 64, "envelope_malformed": 65, "envelope_schema_newer": 65,
            "envelope_invalid_field": 65, "too_large": 65, "idempotency_conflict": 65, "not_found": 65,
            "library_busy": 69, "stale_snapshot": 69, "rate_limited": 69, "library_not_found": 74,
            "library_unreadable": 74, "unreadable": 74, "write_failed": 74, "grant_required": 77,
            "grant_not_found": 77, "grant_revoked": 77, "out_of_scope": 77, "create_not_allowed": 77,
            "invalid_path": 77, "excluded_name": 77, "no_grants_file": 77, "internal_error": 70,
            "invalid_request": 70,
        ]
        for (code, status) in expected {
            XCTAssertEqual(AgentHelper.exitStatus(for: code), status, code)
        }
        let limited = AgentHelper.refusal(.rateLimited(retryAfter: 7))
        XCTAssertEqual(limited.status, 69)
        XCTAssertTrue(limited.stdout.contains(#""retryAfter":7"#), limited.stdout)
    }

    func testActivityListsOnlyThisGrantsReceiptsInScope() throws {
        try writeGrants([grant(), grant("Other", label: "Other")])
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Memory/Projects/Other"), withIntermediateDirectories: true)
        for key in ["a1", "a2"] {
            XCTAssertEqual(create(title: "Mine " + key, key: key, extra: ["--grant", "Silkweb"]).status, 0)
        }
        XCTAssertEqual(create(title: "Theirs", key: "b1", extra: ["--grant", "Other"]).status, 0)
        XCTAssertEqual(
            create(title: "Bad: name", key: "a3", extra: ["--grant", "Silkweb"]).status, 77, "refused, with a receipt")

        let all = try result(run(["memory", "activity", "--grant", "Silkweb"]))
        let receipts = try XCTUnwrap(all["receipts"] as? [[String: Any]])
        XCTAssertEqual(Set(receipts.compactMap { $0["idempotencyKey"] as? String }), ["a1", "a2", "a3"])
        XCTAssertEqual(all["total"] as? Int, 3)
        XCTAssertEqual(receipts.compactMap { $0["grantId"] as? String }, ["Silkweb", "Silkweb", "Silkweb"])
        let dates = receipts.compactMap { $0["createdAt"] as? String }
        XCTAssertEqual(dates, dates.sorted(by: >), "newest first")

        let one = try result(run(["memory", "activity", "--grant", "Silkweb", "--limit", "1"]))
        XCTAssertEqual((one["receipts"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual(one["total"] as? Int, 3)
        let future = try result(run(["memory", "activity", "--grant", "Silkweb", "--since", "2999-01-01"]))
        XCTAssertEqual(future["total"] as? Int, 0)

        // A grant with no receipts yet, and a Library without `.silkweb/`, are empty pages.
        try FileManager.default.removeItem(at: library.appendingPathComponent(".silkweb"))
        XCTAssertEqual(try result(run(["memory", "activity", "--grant", "Other"]))["total"] as? Int, 0)
    }

    private func pipe(_ data: Data) -> FileHandle {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(data)
        try? pipe.fileHandleForWriting.close()
        return pipe.fileHandleForReading
    }
}

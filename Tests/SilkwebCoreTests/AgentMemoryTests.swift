import XCTest

@testable import SilkwebCore

final class AgentMemoryTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentMemory-\(UUID().uuidString)")
        library = root.appendingPathComponent("My Library 日本語")
        grantsURL = root.appendingPathComponent("Application Support/Silkweb/agent-grants.json")
        let project = library.appendingPathComponent("Memory/Projects/Silkweb")
        for folder in ["Progress", "Memories", ".hidden", "Handoffs/Nested", "../Other"] {
            try FileManager.default.createDirectory(
                at: project.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Notes/Private"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: grantsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let files = [
            "Memory/Projects/Silkweb/Progress/2026-10-07 0900 — Spike.md": "# Spike secret body",
            "Memory/Projects/Silkweb/Memories/Preserve competing text.md": "# Preserve",
            "Memory/Projects/Silkweb/Handoffs/Nested/Resume.md": "# Resume",
            "Memory/Projects/Silkweb/Memories/image.png": "png",
            "Memory/Projects/Silkweb/.hidden/Hidden.md": "hidden",
            "Memory/Projects/Silkweb/.DS_Store": "",
            "Memory/Projects/Other/Other.md": "other project",
            "Notes/Private/Diary.md": "private",
        ]
        for (path, text) in files {
            try Data(text.utf8).write(to: library.appendingPathComponent(path))
        }
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("Linked"), withDestinationURL: library.appendingPathComponent("Notes"))
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("Memories/Linked.md"),
            withDestinationURL: library.appendingPathComponent("Notes/Private/Diary.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeGrants(_ json: String) throws {
        try Data(json.utf8).write(to: grantsURL)
    }

    private func grantJSON(access: String = "read-create", extra: [String] = []) -> String {
        let folders = extra.map { "\"\($0)\"" }.joined(separator: ",")
        return """
            {"version":1,"grants":[{"project":"Silkweb","library":{"path":"\(library.path)"},
            "access":"\(access)","extra_read_folders":[\(folders)]}]}
            """
    }

    private func run(_ arguments: [String]) -> AgentHelper.Output {
        AgentHelper.run(arguments + ["--grants", grantsURL.path], home: root)
    }

    /// The `result` of a successful command's envelope.
    private func object(_ output: AgentHelper.Output) throws -> [String: Any] {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        return try XCTUnwrap(envelope["result"] as? [String: Any], output.stdout)
    }

    /// The `error` of a failed command's envelope.
    private func failure(_ output: AgentHelper.Output) throws -> [String: Any] {
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(envelope["ok"] as? Bool, false)
        return try XCTUnwrap(envelope["error"] as? [String: Any], output.stdout)
    }

    // MARK: Grants file

    func testGrantFileDecodesTolerantlyAndRoundTrips() throws {
        let empty = try JSONDecoder().decode(AgentGrantFile.self, from: Data("{}".utf8))
        XCTAssertEqual(empty, AgentGrantFile())
        XCTAssertEqual(empty.version, 1)

        let sparse = try JSONDecoder().decode(
            AgentGrantFile.self,
            from: Data(#"{"grants":[{"project":"Silkweb","library":{"path":"/L"},"access":"admin","x":1}]}"#.utf8))
        let grant = try XCTUnwrap(sparse.grant(for: "Silkweb"))
        XCTAssertEqual(grant.library, LibraryLocation(path: "/L"))
        XCTAssertEqual(grant.access, .read, "unknown access levels fall back to read-only")
        XCTAssertEqual(grant.extraReadFolders, [])
        XCTAssertNil(sparse.grant(for: "silkweb"), "project keys are exact")

        let full = AgentGrantFile(grants: [
            AgentGrant(
                project: "Silkweb", library: LibraryLocation(bookmark: Data([1]), path: "/L"),
                extraReadFolders: ["Reference"])
        ])
        let data = try JSONEncoder().encode(full)
        XCTAssertEqual(try JSONDecoder().decode(AgentGrantFile.self, from: data), full)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("extra_read_folders"))
        XCTAssertEqual(
            AgentGrantFile.defaultURL(home: URL(fileURLWithPath: "/Users/me")).path,
            "/Users/me/Library/Application Support/Silkweb/agent-grants.json")
    }

    // MARK: Scope

    func testDefaultTemplateReadsProjectAndCreatesOnlyInEntryFolders() throws {
        let scope = try AgentScope(
            grant: AgentGrant(
                project: "Silkweb", library: LibraryLocation(path: "/L"), extraReadFolders: ["Reference/"]))
        XCTAssertEqual(scope.readRoots, ["Memory/Projects/Silkweb", "Reference"])
        XCTAssertEqual(
            scope.createRoots,
            [
                "Memory/Projects/Silkweb/Memories", "Memory/Projects/Silkweb/Progress",
                "Memory/Projects/Silkweb/Handoffs",
            ])

        XCTAssertEqual(try scope.checkRead("Memory/Projects/Silkweb"), "Memory/Projects/Silkweb")
        XCTAssertEqual(
            try scope.checkRead("memory//projects/silkweb/Progress/a.md"), "memory/projects/silkweb/Progress/a.md")
        XCTAssertEqual(try scope.checkRead("Reference/Spec.md"), "Reference/Spec.md")
        for outside in [
            "Notes/Private/Diary.md", "Memory/Projects/Silkweb2/a.md", "Memory/Projects", "Memory/Projects/Other",
        ] {
            XCTAssertThrowsError(try scope.checkRead(outside)) {
                XCTAssertEqual($0 as? AgentScopeError, .outsideRead(outside))
            }
        }
        for invalid in [
            "", "/", "/etc/passwd", "Memory/Projects/Silkweb/../Other", "Memory/Projects/Silkweb/.silkweb/x",
            ".silkweb/index.json", "Memory/./Projects/Silkweb", "Memory/Projects/Silkweb/a\u{0}.md",
            "Memory/Projects/Silkweb/a\n.md",
        ] {
            XCTAssertThrowsError(try scope.checkRead(invalid), invalid) {
                XCTAssertEqual($0 as? AgentScopeError, .invalidPath(invalid))
            }
        }

        XCTAssertEqual(
            try scope.checkCreate("Memory/Projects/Silkweb/Progress/2026-10-07 0900 — Spike.md"),
            "Memory/Projects/Silkweb/Progress/2026-10-07 0900 — Spike.md")
        XCTAssertNoThrow(try scope.checkCreate("Memory/Projects/Silkweb/Memories/Sub/Decision.md"))
        for outside in [
            "Memory/Projects/Silkweb/Top level.md", "Reference/New.md", "Memory/Projects/Silkweb/Memories",
            "Memory/Projects/Silkweb/Archive/a.md",
        ] {
            XCTAssertThrowsError(try scope.checkCreate(outside), outside) {
                XCTAssertEqual($0 as? AgentScopeError, .outsideCreate(outside))
            }
        }
        for excluded in [
            "Memory/Projects/Silkweb/Memories/AGENTS.md", "Memory/Projects/Silkweb/Memories/claude.md",
            "Memory/Projects/Silkweb/Handoffs/GEMINI.md", "Memory/Projects/Silkweb/Progress/CLAUDE.local.md",
            "Memory/Projects/Silkweb/Progress/mcp.json", "Memory/Projects/Silkweb/Progress/Script.sh",
            "Memory/Projects/Silkweb/Memories/Proposals/Idea.md", "Memory/Projects/Silkweb/Memories/Image",
        ] {
            XCTAssertThrowsError(try scope.checkCreate(excluded), excluded) {
                XCTAssertEqual($0 as? AgentScopeError, .excluded(excluded))
            }
        }
        XCTAssertThrowsError(try scope.checkCreate("Memory/Projects/Silkweb/Progress/.mcp.json")) {
            XCTAssertEqual($0 as? AgentScopeError, .invalidPath("Memory/Projects/Silkweb/Progress/.mcp.json"))
        }
    }

    func testReadOnlyUnqualifiedAndInvalidGrants() throws {
        let library = LibraryLocation(path: "/L")
        XCTAssertEqual(try AgentScope(grant: AgentGrant(project: "P", library: library, access: .read)).createRoots, [])
        XCTAssertEqual(
            try AgentScope(grant: AgentGrant(project: "P", library: library), createAllowed: false).createRoots, [])
        XCTAssertEqual(try AgentScope(grant: AgentGrant(project: "P", library: library)).createRoots.count, 3)
        let nested = try AgentScope(
            grant: AgentGrant(project: "P", library: library, extraReadFolders: ["memory/projects/p/Sub", "A", "A/B"]))
        XCTAssertEqual(nested.readRoots, ["Memory/Projects/P", "A"], "covered folders aren't repeated")
        for project in ["", " P", "A/B", "A:B", ".P", "..", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try AgentScope(grant: AgentGrant(project: project, library: library)), project) {
                XCTAssertEqual($0 as? AgentScopeError, .invalidProject)
            }
        }
        XCTAssertThrowsError(
            try AgentScope(grant: AgentGrant(project: "P", library: library, extraReadFolders: ["../Up"])))
    }

    func testScopeMessagesUseDisplayPathsAndCurlyQuotes() {
        XCTAssertEqual(
            AgentMemoryContract.displayPath("Memory/Projects/Silkweb/Progress"),
            "Memory › Projects › Silkweb › Progress")
        XCTAssertEqual(
            AgentScopeError.outsideRead("Notes/Private").message,
            "“Notes › Private” is outside this grant’s read folders.")
        XCTAssertEqual(
            AgentScopeError.outsideCreate("Reference/New.md").message,
            "“Reference › New.md” is outside this grant’s create folders.")
        XCTAssertEqual(
            AgentScopeError.excluded("Memory/AGENTS.md").message,
            "Agents can’t create “Memory › AGENTS.md”: only Markdown documents that aren’t instruction files.")
    }

    // MARK: Filesystems

    func testOnlyLocalAPFSAndHFSOutsideSyncFoldersQualify() {
        let home = "/Users/me"
        XCTAssertEqual(
            AgentFilesystem.classify(path: home + "/Writing", isLocal: true, typeName: "apfs", isUbiquitous: false),
            .qualified)
        XCTAssertEqual(
            AgentFilesystem.classify(path: "/Volumes/Disk/L", isLocal: true, typeName: "HFS", isUbiquitous: nil),
            .qualified)
        let unqualified: [(String, Bool?, String?, Bool?)] = [
            (home + "/Library/Mobile Documents/com~apple~CloudDocs/L", true, "apfs", false),
            (home + "/Library/Mobile Documents", true, "apfs", false),
            (home + "/Library/CloudStorage/Dropbox/L", true, "apfs", false),
            (home + "/Writing", true, "apfs", true),
            ("/Volumes/Share/L", false, "smbfs", false),
            ("/Volumes/NAS/L", false, "apfs", false),
            ("/Volumes/USB/L", true, "msdos", false),
            ("/Volumes/USB/L", true, "exfat", false),
            ("/L", nil, nil, nil),
        ]
        for (path, local, type, ubiquitous) in unqualified {
            XCTAssertEqual(
                AgentFilesystem.classify(path: path, isLocal: local, typeName: type, isUbiquitous: ubiquitous),
                .unqualified,
                "\(path) \(String(describing: type))")
        }
        XCTAssertEqual(
            AgentFilesystem.probe(library), .qualified, "the temporary directory is on the local boot volume")
    }

    // MARK: Helper commands (Silkweb closed)

    func testCapabilitiesReportsScopeWithoutTouchingTheLibrary() throws {
        try writeGrants(grantJSON(extra: ["Notes/Private"]))
        let before = try snapshot()
        let output = run(["memory", "capabilities", "--grant", "Silkweb"])
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertEqual(output.stderr, "")
        let json = try object(output)
        XCTAssertEqual(json["contract_version"] as? Int, 1)
        XCTAssertEqual(json["project"] as? String, "Silkweb")
        XCTAssertEqual(json["library"] as? String, library.standardizedFileURL.path)
        XCTAssertEqual(json["filesystem"] as? String, "qualified")
        XCTAssertEqual(json["access"] as? String, "read-create")
        XCTAssertEqual(json["profile"] as? String, "Read and Create")
        XCTAssertEqual(json["label"] as? String, "Silkweb project")
        XCTAssertEqual(json["schema"] as? String, "silkweb-memory/v1")
        XCTAssertEqual(
            json["operations"] as? [String],
            ["capabilities", "list", "search", "read", "activity", "create", "create-folder"])
        XCTAssertEqual(json["read_roots"] as? [String], ["Memory/Projects/Silkweb", "Notes/Private"])
        XCTAssertEqual((json["create_roots"] as? [String])?.count, 3)
        XCTAssertEqual(json["project_folder_exists"] as? Bool, true)
        XCTAssertEqual(try snapshot(), before, "read-only: no files or sidecars are written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(".silkweb").path))

        try writeGrants(grantJSON(access: "read"))
        try FileManager.default.removeItem(at: library.appendingPathComponent("Memory"))
        let readOnly = try object(run(["memory", "capabilities", "--grant", "Silkweb"]))
        XCTAssertEqual(readOnly["create_roots"] as? [String], [])
        XCTAssertEqual(readOnly["operations"] as? [String], ["capabilities", "list", "search", "read", "activity"])
        XCTAssertEqual(readOnly["profile"] as? String, "Read Only")
        XCTAssertEqual(readOnly["project_folder_exists"] as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent("Memory").path))
    }

    func testListReturnsGrantedMarkdownPathsOnly() throws {
        try writeGrants(grantJSON())
        let output = run(["memory", "list", "--grant", "Silkweb"])
        XCTAssertEqual(output.status, 0, output.stderr)
        let documents = try XCTUnwrap(try object(output)["documents"] as? [[String: Any]])
        XCTAssertEqual(
            documents.compactMap { $0["path"] as? String },
            [
                "Memory/Projects/Silkweb/Handoffs/Nested/Resume.md",
                "Memory/Projects/Silkweb/Memories/Preserve competing text.md",
                "Memory/Projects/Silkweb/Progress/2026-10-07 0900 — Spike.md",
            ])
        XCTAssertEqual(documents.last?["size"] as? Int, "# Spike secret body".utf8.count)
        XCTAssertFalse((documents.last?["modified"] as? String ?? "").isEmpty)
        XCTAssertFalse(output.stdout.contains("secret body"), "bodies are never listed")

        try writeGrants(grantJSON(extra: ["Notes/Private"]))
        let extra = try XCTUnwrap(
            try object(run(["memory", "list", "--grant", "Silkweb"]))["documents"] as? [[String: Any]])
        XCTAssertEqual(extra.compactMap { $0["path"] as? String }.last, "Notes/Private/Diary.md")
    }

    func testHelperFailuresUseSharedTitlesAndJSONCodes() throws {
        let missing = run(["memory", "list", "--grant", "Silkweb"])
        XCTAssertEqual(missing.status, 77)
        XCTAssertEqual(try failure(missing)["code"] as? String, "no_grants_file")
        XCTAssertEqual(try failure(missing)["title"] as? String, "No Agent Access")

        try writeGrants("not json")
        XCTAssertEqual(
            try failure(run(["memory", "list", "--grant", "Silkweb"]))["code"] as? String, "invalid_grants_file")

        try writeGrants(#"{"version":2,"grants":[]}"#)
        XCTAssertEqual(
            try failure(run(["memory", "list", "--grant", "Silkweb"]))["code"] as? String, "unsupported_grants_version")

        try writeGrants(grantJSON())
        let noGrant = run(["memory", "capabilities", "--grant", "Other"])
        XCTAssertEqual(noGrant.status, 77)
        XCTAssertEqual(
            noGrant.stderr, "silkweb: No agent access named “Other” exists. Ask the owner to create one in Silkweb.\n")

        try writeGrants(grantJSON(extra: [".silkweb"]))
        XCTAssertEqual(try failure(run(["memory", "list", "--grant", "Silkweb"]))["code"] as? String, "invalid_grant")

        try writeGrants(grantJSON())
        try FileManager.default.removeItem(at: library)
        let gone = run(["memory", "capabilities", "--grant", "Silkweb"])
        XCTAssertEqual(gone.status, 74)
        XCTAssertEqual(try failure(gone)["code"] as? String, "library_not_found")
        XCTAssertEqual(try failure(gone)["title"] as? String, "Library Not Found")
        XCTAssertEqual(gone.stderr, "silkweb: The Library “My Library 日本語” can’t be found.\n")

        try writeGrants(#"{"version":1,"grants":[{"project":"Silkweb"}]}"#)
        XCTAssertEqual(
            try failure(run(["memory", "list", "--grant", "Silkweb"]))["title"] as? String, "Library Not Found")
    }

    func testDefaultGrantsLocationAndUsage() throws {
        try writeGrants(grantJSON())
        let output = AgentHelper.run(
            ["memory", "capabilities", "--grant", "Silkweb"], home: root.appendingPathComponent("elsewhere"))
        XCTAssertEqual(output.status, 77, "the default path is under the given home, not --grants")
        let home = root.appendingPathComponent("home")
        let target = AgentGrantFile.defaultURL(home: home)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: grantsURL, to: target)
        XCTAssertEqual(AgentHelper.run(["memory", "capabilities", "--grant", "Silkweb"], home: home).status, 0)

        for arguments in [
            [], ["memory"], ["memory", "delete", "--grant", "Silkweb"], ["memory", "list", "--grant"],
            ["memory", "list", "--grant", "A", "--grant", "B"], ["memory", "list", "--path", "x"], ["write_file"],
            ["memory", "capabilities", "extra"], ["memory", "create-folder"],
        ] {
            let usage = AgentHelper.run(arguments, home: home)
            XCTAssertEqual(usage.status, 64, "\(arguments)")
            XCTAssertEqual(try failure(usage)["code"] as? String, "invalid_argument", "\(arguments)")
            XCTAssertTrue(usage.stderr.hasPrefix("silkweb: "), usage.stderr)
            XCTAssertTrue(usage.stderr.hasSuffix(" Run “silkweb --help” for usage.\n"), usage.stderr)
        }
        for arguments in [["--help"], ["memory", "--help"], ["memory", "search", "-h"]] {
            let help = AgentHelper.run(arguments, home: home)
            XCTAssertEqual(help.status, 0)
            XCTAssertEqual(help.stdout, AgentHelper.help)
        }
        for arguments in [["version"], ["--version"]] {
            let version = try object(AgentHelper.run(arguments, home: home))
            XCTAssertEqual(version["contract_version"] as? Int, AgentMemoryContract.version)
        }
    }

    /// A document published by `create` (#133) is found by `search` and returned by `read` (#134),
    /// and the staging and receipt files under `.silkweb/` never show up in results.
    func testCreatedMemoryIsSearchableAndReadable() throws {
        try writeGrants(grantJSON())
        let bodyURL = root.appendingPathComponent("body.md")
        try Data("Checkpoint about the quartz gate.".utf8).write(to: bodyURL)
        let created = run([
            "memory", "create", "--grant", "Silkweb", "--idempotency-key", "k1", "--type", "decision", "--title",
            "Quartz", "--agent", "codex", "--session", "s1", "--body-file", bodyURL.path,
        ])
        XCTAssertEqual(created.status, 0, created.stderr)
        let path = try XCTUnwrap(try object(created)["path"] as? String)

        let search = run(["memory", "search", "--grant", "Silkweb", "quartz"])
        XCTAssertEqual(search.status, 0, search.stderr)
        let results = try XCTUnwrap(try object(search)["results"] as? [[String: Any]])
        XCTAssertEqual(results.compactMap { $0["path"] as? String }, [path])
        XCTAssertEqual(results.first?["type"] as? String, "decision")
        XCTAssertEqual(results.first?["agent"] as? String, "codex")

        let read = run(["memory", "read", "--grant", "Silkweb", path])
        XCTAssertEqual(read.status, 0, read.stderr)
        XCTAssertTrue((try object(read)["body"] as? String)?.contains("Checkpoint about the quartz gate.") == true)

        let staged = run(["memory", "search", "--grant", "Silkweb", "agent-staging"])
        XCTAssertEqual((try object(staged)["results"] as? [[String: Any]])?.count, 0)
        XCTAssertEqual(
            run(["memory", "search", "--grant", "Silkweb", "--limit", "1", "--limit", "2"]).status, 64,
            "only --type, --status and --supersedes may repeat")
    }

    /// The real signed helper binary, launched as its own process like an agent would.
    func testBuiltHelperBinaryRunsHeadless() throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("SilkwebHelper")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("SilkwebHelper isn't built next to the test bundle")
        }
        try writeGrants(grantJSON())
        let process = Process()
        process.executableURL = binary
        process.arguments = ["memory", "list", "--grants", grantsURL.path]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(((json["result"] as? [String: Any])?["documents"] as? [[String: Any]])?.count, 3)
    }

    private func snapshot() throws -> [String: Date] {
        var result: [String: Date] = [:]
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: library.path))
        while let path = walker.nextObject() as? String {
            result[path] = walker.fileAttributes?[.modificationDate] as? Date
        }
        return result
    }
}

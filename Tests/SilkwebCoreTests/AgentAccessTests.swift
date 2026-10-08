import Darwin
import XCTest

@testable import SilkwebCore

/// #130: grant profiles, revocation, limits and descriptor-based path enforcement.
final class AgentAccessTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentAccess-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        grantsURL = root.appendingPathComponent("Application Support/Silkweb/agent-grants.json")
        let files = [
            "Memory/Projects/Silkweb/Progress/2026-10-07 0900 — Spike.md": "# Spike",
            "Memory/Projects/Silkweb/Memories/Decision.md": "# Decision",
            "Memory/Projects/Silkweb2/Leak.md": "# sibling secret",
            "Memory/Projects/Other/Other.md": "# other secret",
            "Notes/Private/Diary.md": "# diary secret",
        ]
        for (path, text) in files {
            let url = library.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Memory/Projects/Silkweb/Handoffs"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var project: URL { library.appendingPathComponent("Memory/Projects/Silkweb") }

    private func writeGrants(_ grants: [AgentGrant]) throws {
        try AgentGrantFile(grants: grants).write(to: grantsURL)
    }

    private func grant(
        _ access: AgentGrant.Access = .readCreate, extra: [String] = [], limits: AgentGrantLimits = AgentGrantLimits()
    ) -> AgentGrant {
        AgentGrant(
            project: "Silkweb", library: LibraryLocation(path: library.path), access: access, extraReadFolders: extra,
            label: "Silkweb project", limits: limits)
    }

    private func session(clientRoots: [String]? = nil, now: @escaping @Sendable () -> Date = { Date() })
        -> AgentSession
    {
        AgentSession(
            project: "Silkweb", store: AgentGrantStore(url: grantsURL), clientRoots: clientRoots, now: now)
    }

    private func assertRefused(
        _ expression: @autoclosure () throws -> Any, _ expected: AgentAccessError, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try expression(), message, file: file, line: line) {
            XCTAssertEqual($0 as? AgentAccessError, expected, message, file: file, line: line)
        }
    }

    // MARK: Grants file

    func testSpikeGrantFilesStillLoadAndNewKeysDecodeTolerantly() throws {
        // Saved by the #129 build: no label, limits or dates.
        let spike = try JSONDecoder().decode(
            AgentGrantFile.self,
            from: Data(
                #"{"version":1,"grants":[{"project":"Silkweb","library":{"path":"/L"},"access":"read-create"}]}"#.utf8))
        let old = try XCTUnwrap(spike.grant(for: "Silkweb"))
        XCTAssertEqual(old.access, .readCreate)
        XCTAssertEqual(old.label, "")
        XCTAssertEqual(old.displayLabel, "Silkweb project")
        XCTAssertEqual(old.limits, AgentGrantLimits())
        XCTAssertNil(old.createdAt)
        XCTAssertFalse(old.isRevoked)

        let sparse = try JSONDecoder().decode(
            AgentGrant.self,
            from: Data(
                #"""
                {"project":"P","access":"read-only","label":7,"created_at":"yesterday",
                 "limits":{"max_read_bytes":0,"max_results":"many","requests_per_minute":5},"revoked_at":null}
                """#.utf8))
        XCTAssertEqual(sparse.access, .read, "“read-only” is the design-notes spelling of read")
        XCTAssertEqual(sparse.label, "")
        XCTAssertNil(sparse.createdAt)
        XCTAssertNil(sparse.revokedAt, "null means on")
        XCTAssertEqual(
            sparse.limits,
            AgentGrantLimits(
                maxReadBytes: AgentGrantLimits.defaultMaxReadBytes, maxResults: AgentGrantLimits.defaultMaxResults,
                requestsPerMinute: 5))

        let garbled = try JSONDecoder().decode(
            AgentGrant.self, from: Data(#"{"project":"P","revoked_at":"soon"}"#.utf8))
        XCTAssertTrue(garbled.isRevoked, "an unreadable revocation date still keeps access off")
        let numeric = try JSONDecoder().decode(AgentGrant.self, from: Data(#"{"project":"P","revoked_at":0}"#.utf8))
        XCTAssertTrue(numeric.isRevoked)

        XCTAssertEqual(AgentGrant.Access.read.displayName, "Read Only")
        XCTAssertEqual(AgentGrant.Access.readCreate.displayName, "Read and Create")
    }

    func testRevocationIsPersistedWithSortedKeysAndRoundTrips() throws {
        var file = AgentGrantFile(grants: [
            AgentGrant(
                project: "Silkweb", library: LibraryLocation(path: "/Users/me/Writing"), label: "Silkweb project",
                limits: AgentGrantLimits(maxReadBytes: 10, maxResults: 20, requestsPerMinute: 30),
                createdAt: Date(timeIntervalSince1970: 1_791_331_200))
        ])
        let revokedAt = Date(timeIntervalSince1970: 1_791_334_800)
        XCTAssertTrue(file.setEnabled(false, project: "Silkweb", at: revokedAt))
        XCTAssertTrue(file.setEnabled(false, project: "Silkweb", at: Date()), "keeps the first revocation date")
        XCTAssertFalse(file.setEnabled(false, project: "Other"))
        try file.write(to: grantsURL)

        let text = try String(contentsOf: grantsURL, encoding: .utf8)
        XCTAssertTrue(text.contains(#""revoked_at" : "2026-10-07T01:00:00Z""#), text)
        XCTAssertTrue(text.contains(#""created_at" : "2026-10-07T00:00:00Z""#), text)
        XCTAssertTrue(text.contains(#""path" : "/Users/me/Writing""#), "slashes aren't escaped")
        let keys = [
            "access", "created_at", "extra_read_folders", "label", "library", "limits", "project", "revoked_at",
        ]
        let offsets = keys.map { text.range(of: "\"\($0)\"")!.lowerBound }
        XCTAssertEqual(offsets, offsets.sorted(), "keys are sorted so the owner can diff the file")

        let loaded = try JSONDecoder().decode(AgentGrantFile.self, from: Data(contentsOf: grantsURL))
        XCTAssertEqual(loaded, file)
        XCTAssertEqual(loaded.grants[0].revokedAt, revokedAt)

        file.setEnabled(true, project: "Silkweb")
        try file.write(to: grantsURL)
        XCTAssertFalse(try String(contentsOf: grantsURL, encoding: .utf8).contains("revoked_at"))
    }

    // MARK: Scope

    func testContainmentComparesWholeComponentsLikeAPFS() throws {
        let library = LibraryLocation(path: "/L")
        let insensitive = try AgentScope(grant: AgentGrant(project: "Café", library: library))
        let sensitive = try AgentScope(grant: AgentGrant(project: "Café", library: library), caseSensitive: true)
        let decomposed = "Memory/Projects/Cafe\u{301}/Progress/a.md"
        for scope in [insensitive, sensitive] {
            XCTAssertNoThrow(try scope.checkRead(decomposed), "normalization never changes the Folder")
            for outside in [
                "Memory/Projects/Café2/a.md", "Memory/Projects/Café /a.md", "Memory/Projects/Café.md",
                "Memory/Projects/Caf/é/a.md", "Memory/Projects", "Memory/ProjectsCafé/a.md",
                "Memory/Projects/Cafe/a.md",
                "Memory/Projects/Café\u{200B}/a.md",
            ] {
                XCTAssertThrowsError(try scope.checkRead(outside), outside)
            }
        }
        XCTAssertNoThrow(try insensitive.checkRead("MEMORY/projects/CAFÉ/a.md"))
        XCTAssertThrowsError(
            try sensitive.checkRead("MEMORY/projects/CAFÉ/a.md"),
            "on a case-sensitive volume a different spelling is a different Folder")
        XCTAssertThrowsError(try sensitive.checkCreate("memory/Projects/Café/Progress/a.md"))
        XCTAssertNoThrow(try sensitive.checkCreate("Memory/Projects/Café/Progress/a.md"))
    }

    func testCreateFolderOnlyInsideCreateFolders() throws {
        let scope = try AgentScope(grant: grant())
        XCTAssertEqual(
            try scope.checkCreateFolder("Memory/Projects/Silkweb/Memories/Architecture"),
            "Memory/Projects/Silkweb/Memories/Architecture")
        XCTAssertNoThrow(try scope.checkCreateFolder("Memory/Projects/Silkweb/Handoffs/2026/October"))
        for outside in [
            "Memory/Projects/Silkweb/Memories", "Memory/Projects/Silkweb/Archive", "Memory/Projects/Silkweb",
            "Notes/New", "Memory/Projects/Silkweb2/Memories/New",
        ] {
            XCTAssertThrowsError(try scope.checkCreateFolder(outside), outside) {
                XCTAssertEqual($0 as? AgentScopeError, .outsideCreate(outside))
            }
        }
        XCTAssertThrowsError(try scope.checkCreateFolder("Memory/Projects/Silkweb/Memories/Proposals")) {
            XCTAssertEqual($0 as? AgentScopeError, .excluded("Memory/Projects/Silkweb/Memories/Proposals"))
        }
        for invalid in ["Memory/Projects/Silkweb/Memories/A:B", "Memory/Projects/Silkweb/Memories/ Padded"] {
            XCTAssertThrowsError(try scope.checkCreateFolder(invalid), invalid) {
                XCTAssertEqual($0 as? AgentScopeError, .invalidPath(invalid))
            }
        }
        XCTAssertThrowsError(
            try AgentScope(grant: grant(.read)).checkCreateFolder("Memory/Projects/Silkweb/Memories/A"))
    }

    func testClientRootsNarrowButNeverBroaden() throws {
        let scope = try AgentScope(grant: grant(extra: ["Reference"]))
        let progress = scope.narrowed(to: ["Memory/Projects/Silkweb/Progress"])
        XCTAssertEqual(progress.readRoots, ["Memory/Projects/Silkweb/Progress"])
        XCTAssertEqual(progress.createRoots, ["Memory/Projects/Silkweb/Progress"])
        XCTAssertNoThrow(try progress.checkRead("Memory/Projects/Silkweb/Progress/a.md"))
        XCTAssertThrowsError(try progress.checkRead("Memory/Projects/Silkweb/Memories/a.md"))
        XCTAssertThrowsError(try progress.checkCreate("Memory/Projects/Silkweb/Memories/a.md"))

        let wide = scope.narrowed(to: ["Memory", "Notes", "Reference/Specs"])
        XCTAssertEqual(
            wide.readRoots, ["Memory/Projects/Silkweb", "Reference/Specs"], "a wider client root adds nothing")
        XCTAssertEqual(wide.createRoots, scope.createRoots)
        XCTAssertThrowsError(try wide.checkRead("Notes/Private/Diary.md"))

        let invalid = scope.narrowed(to: ["/", "../Memory", ".silkweb", "Memory/Projects/Silkweb2"])
        XCTAssertEqual(invalid.readRoots, [])
        XCTAssertEqual(invalid.createRoots, [])
        XCTAssertEqual(scope.narrowed(to: []).readRoots, [], "an empty root list grants nothing")
        XCTAssertEqual(
            scope.narrowed(to: ["Memory/Projects/Silkweb/Progress", "memory/projects/silkweb"]).readRoots,
            ["memory/projects/silkweb"], "overlapping client roots collapse to the outer one")
    }

    func testScopeFilteringHappensBeforeCounting() throws {
        let scope = try AgentScope(grant: grant())
        let hits = [
            "Memory/Projects/Silkweb/Progress/a.md", "Memory/Projects/Silkweb2/Leak.md", "Notes/Private/Diary.md",
            "Memory/Projects/Silkweb/../Other/Other.md", ".silkweb/index.json", "Memory/Projects/Silkweb/Memories/b.md",
        ]
        let visible = scope.readable(hits) { $0 }
        XCTAssertEqual(visible, ["Memory/Projects/Silkweb/Progress/a.md", "Memory/Projects/Silkweb/Memories/b.md"])
        XCTAssertEqual(scope.readable(["Notes/Private/Diary.md"]) { $0 }.count, 0)
    }

    // MARK: Session: profiles

    func testReadOnlyGrantReadsInsideReadFoldersAndNeverCreates() throws {
        try writeGrants([grant(.read, extra: ["Notes/Private"])])
        let session = session()
        for operation in [AgentOperation.capabilities, .list, .search, .activity] {
            XCTAssertNoThrow(try session.authorize(operation), operation.rawValue)
        }
        XCTAssertEqual(
            try session.authorize(.read, path: "Memory/Projects/Silkweb/Progress/x.md").path,
            "Memory/Projects/Silkweb/Progress/x.md")
        XCTAssertNoThrow(try session.authorize(.read, path: "Notes/Private/Diary.md"))
        assertRefused(
            try session.authorize(.read, path: "Memory/Projects/Silkweb2/Leak.md"),
            .outOfScope(["Memory/Projects/Silkweb", "Notes/Private"]))
        for operation in [AgentOperation.create, .createFolder] {
            assertRefused(
                try session.authorize(operation, path: "Memory/Projects/Silkweb/Progress/New.md"),
                .createNotAllowed, operation.rawValue)
            assertRefused(try session.authorize(operation), .createNotAllowed)
        }
        XCTAssertEqual(
            AgentAccessError.createNotAllowed.message,
            "This grant is Read Only. Ask the owner to switch it to Read and Create.")
    }

    func testReadAndCreateGrantCreatesOnlyInsideCreateFolders() throws {
        try writeGrants([grant(.readCreate, extra: ["Notes/Private"])])
        let session = session()
        XCTAssertEqual(
            try session.authorize(.create, path: "Memory/Projects/Silkweb/Progress/New.md").path,
            "Memory/Projects/Silkweb/Progress/New.md")
        XCTAssertNoThrow(try session.authorize(.createFolder, path: "Memory/Projects/Silkweb/Memories/Topic"))
        let createScope = AgentAccessError.outOfScope(
            [
                "Memory/Projects/Silkweb/Memories", "Memory/Projects/Silkweb/Progress",
                "Memory/Projects/Silkweb/Handoffs",
            ], kind: "create")
        for outside in ["Notes/Private/New.md", "Memory/Projects/Silkweb/New.md", "Memory/Projects/Other/New.md"] {
            assertRefused(try session.authorize(.create, path: outside), createScope, outside)
            assertRefused(try session.authorize(.createFolder, path: outside), createScope, outside)
        }
        assertRefused(try session.authorize(.create, path: "Memory/Projects/Silkweb/Memories/AGENTS.md"), .excluded)
        assertRefused(try session.authorize(.create, path: "Memory/Projects/Silkweb/../Silkweb/x.md"), .invalidPath)
        XCTAssertEqual(
            createScope.message,
            "That location is outside this grant’s create folders (Memory › Projects › Silkweb › Memories, "
                + "Memory › Projects › Silkweb › Progress, Memory › Projects › Silkweb › Handoffs).")
    }

    func testRefusalsNameTheGrantScopeAndNeverTheTargetOrItsExistence() throws {
        try writeGrants([grant()])
        let session = session()
        let refusals = [
            "Notes/Private/Diary.md", "Notes/Private/Missing.md", "Memory/Projects/Silkweb2/Leak.md",
            "Memory/Projects/Silkweb2/Missing.md",
        ].map { path -> AgentAccessError? in
            do {
                _ = try session.authorize(.read, path: path)
                return nil
            } catch {
                return error as? AgentAccessError
            }
        }
        let expected = AgentAccessError.outOfScope(["Memory/Projects/Silkweb"])
        XCTAssertEqual(refusals, Array(repeating: expected, count: 4), "existing and missing targets look the same")
        XCTAssertEqual(
            expected.message, "That location is outside this grant’s read folders (Memory › Projects › Silkweb).")
        XCTAssertFalse(expected.message.contains("Private") || expected.message.contains("Silkweb2"))

        let invalid = [
            "Memory/Projects/Silkweb/../Other/Other.md", "/etc/passwd", ".silkweb/index.json",
            "Memory/Projects/Silkweb/.silkweb/receipts", "Memory/Projects/Silkweb/a\u{0}.md", "",
        ]
        for path in invalid {
            assertRefused(try session.authorize(.read, path: path), .invalidPath, path)
        }
        XCTAssertEqual(
            AgentAccessError.invalidPath.message,
            "Paths must stay inside the Library and can’t use “..”, links or special files.")
        XCTAssertEqual(AgentAccessError.invalidPath.code, "invalid_path")
    }

    func testClientRootsNarrowASession() throws {
        try writeGrants([grant()])
        let session = session(clientRoots: ["Memory/Projects/Silkweb/Progress", "Notes"])
        XCTAssertNoThrow(try session.authorize(.read, path: "Memory/Projects/Silkweb/Progress/a.md"))
        assertRefused(
            try session.authorize(.read, path: "Notes/Private/Diary.md"),
            .outOfScope(["Memory/Projects/Silkweb/Progress"]))
        assertRefused(
            try session.authorize(.create, path: "Memory/Projects/Silkweb/Memories/a.md"),
            .outOfScope(["Memory/Projects/Silkweb/Progress"], kind: "create"))
    }

    // MARK: Session: revocation and limits

    func testRevocationFailsClosedOnTheNextOperation() throws {
        var file = AgentGrantFile(grants: [grant()])
        try file.write(to: grantsURL)
        let session = session()
        let started = try session.authorize(.create, path: "Memory/Projects/Silkweb/Progress/In flight.md")
        XCTAssertEqual(started.grant.displayLabel, "Silkweb project")

        file.setEnabled(false, project: "Silkweb")
        try file.write(to: grantsURL)
        let revoked = AgentAccessError.grantRevoked("Silkweb project")
        XCTAssertEqual(
            revoked.message, "Agent access “Silkweb project” was turned off. Ask the owner to turn it back on.")
        for operation in AgentOperation.allCases {
            assertRefused(try session.authorize(operation), revoked, operation.rawValue)
        }
        assertRefused(try self.session().authorize(.list), revoked, "a new session is refused too")

        file.setEnabled(true, project: "Silkweb")
        try file.write(to: grantsURL)
        XCTAssertNoThrow(try session.authorize(.list), "turning access back on works without a restart")

        file.grants[0].access = .read
        try file.write(to: grantsURL)
        assertRefused(try session.authorize(.create), .createNotAllowed, "narrowing applies immediately")

        file.grants = []
        try file.write(to: grantsURL)
        assertRefused(try session.authorize(.list), revoked, "a removed grant reads as turned off")
        try FileManager.default.removeItem(at: grantsURL)
        assertRefused(try session.authorize(.list), revoked, "so does a deleted grants file")
        assertRefused(
            try self.session().authorize(.list),
            AgentAccessError(
                code: "no_grants_file", title: "No Agent Access",
                message: "There’s no grants file at “\(grantsURL.path)”."))
    }

    func testGrantFileIsReReadOnlyWhenItChanges() throws {
        try writeGrants([grant()])
        let store = AgentGrantStore(url: grantsURL)
        let first = try store.load()
        XCTAssertEqual(try store.load(), first)
        // An in-place edit in the same second with a new size is still seen.
        var edited = AgentGrantFile(grants: [grant(.read)])
        edited.grants[0].label = "Renamed"
        let data = try JSONEncoder().encode(edited)
        let handle = try FileHandle(forWritingTo: grantsURL)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: data)
        try handle.close()
        XCTAssertEqual(try store.load().grants[0].label, "Renamed")

        try Data(#"{"version":2}"#.utf8).write(to: grantsURL)
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual(($0 as? AgentAccessError)?.code, "unsupported_grants_version")
        }
    }

    func testRateLimitUsesARollingMinute() throws {
        try writeGrants([grant(limits: AgentGrantLimits(requestsPerMinute: 2))])
        final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_000) }
        let clock = Clock()
        let session = session(now: { clock.now })
        XCTAssertNoThrow(try session.authorize(.list))
        clock.now += 20
        XCTAssertNoThrow(try session.authorize(.search))
        clock.now += 10
        assertRefused(try session.authorize(.read), .rateLimited(retryAfter: 30))
        XCTAssertEqual(
            AgentAccessError.rateLimited(retryAfter: 30).message, "Too many requests. Try again in 30 seconds.")
        XCTAssertEqual(AgentAccessError.rateLimited(retryAfter: 1).message, "Too many requests. Try again in 1 second.")
        XCTAssertEqual(AgentAccessError.rateLimited(retryAfter: 1).code, "rate_limited")
        clock.now += 30.5
        XCTAssertNoThrow(try session.authorize(.read), "the first request has left the window")
    }

    // MARK: Secure files

    func testReadsRefuseLinksSpecialFilesAndOversizedDocuments() throws {
        let fm = FileManager.default
        try fm.createSymbolicLink(
            at: project.appendingPathComponent("Memories/Link.md"),
            withDestinationURL: library.appendingPathComponent("Notes/Private/Diary.md"))
        try fm.createSymbolicLink(
            at: project.appendingPathComponent("Linked"), withDestinationURL: library.appendingPathComponent("Notes"))
        XCTAssertEqual(mkfifo(project.appendingPathComponent("Memories/Pipe.md").path, 0o600), 0)

        let read = { (path: String, max: Int) in
            try AgentSecureFiles.readDocument(library: self.library, path: path, maxBytes: max)
        }
        XCTAssertEqual(try read("Memory/Projects/Silkweb/Memories/Decision.md", 100), Data("# Decision".utf8))
        for invalid in [
            "Memory/Projects/Silkweb/Memories/Link.md", "Memory/Projects/Silkweb/Linked/Private/Diary.md",
            "Memory/Projects/Silkweb/Memories/Pipe.md", "Memory/Projects/Silkweb/Memories",
            "Memory/Projects/Silkweb/Memories/Decision.md/x", "Memory/Projects/Silkweb/../Other/Other.md",
        ] {
            assertRefused(try read(invalid, 100), .invalidPath, invalid)
        }
        assertRefused(try read("Memory/Projects/Silkweb/Memories/Missing.md", 100), .notFound)
        assertRefused(try read("Memory/Projects/Silkweb/Memories/Decision.md", 4), .tooLarge(limit: 4))
        XCTAssertEqual(try read("Memory/Projects/Silkweb/Memories/Decision.md", 10).count, 10, "exactly the limit")
    }

    func testListingNeverFollowsALinkedAncestorFolder() throws {
        // `Memory` itself is a link to a folder outside the Library that has the same layout.
        let outside = root.appendingPathComponent("Outside/Memory/Projects/Silkweb/Progress")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("# outside secret".utf8).write(to: outside.appendingPathComponent("Escaped.md"))
        try FileManager.default.removeItem(at: library.appendingPathComponent("Memory"))
        try FileManager.default.createSymbolicLink(
            at: library.appendingPathComponent("Memory"),
            withDestinationURL: root.appendingPathComponent("Outside/Memory"))
        try writeGrants([grant()])

        let output = AgentHelper.run(
            ["memory", "list", "--project", "Silkweb", "--grants", grantsURL.path], home: root)
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertFalse(output.stdout.contains("Escaped"), output.stdout)
        let capabilities = AgentHelper.run(
            ["memory", "capabilities", "--project", "Silkweb", "--grants", grantsURL.path], home: root)
        XCTAssertTrue(capabilities.stdout.contains(#""project_folder_exists" : false"#), capabilities.stdout)
        assertRefused(
            try AgentSecureFiles.readDocument(
                library: library, path: "Memory/Projects/Silkweb/Progress/Escaped.md", maxBytes: 100),
            .invalidPath)
    }

    func testDocumentWalkSkipsHiddenItemsLinksAndSpecialFiles() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: project.appendingPathComponent(".silkweb"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: project.appendingPathComponent(".silkweb/Hidden.md"))
        try Data("x".utf8).write(to: project.appendingPathComponent("Memories/.Draft.md"))
        try Data("x".utf8).write(to: project.appendingPathComponent("Memories/Image.png"))
        try fm.createSymbolicLink(
            at: project.appendingPathComponent("Memories/Link.md"),
            withDestinationURL: library.appendingPathComponent("Notes/Private/Diary.md"))
        try fm.createSymbolicLink(
            at: project.appendingPathComponent("Linked"), withDestinationURL: library.appendingPathComponent("Notes"))
        XCTAssertEqual(mkfifo(project.appendingPathComponent("Progress/Pipe.md").path, 0o600), 0)

        let documents = try AgentSecureFiles.documents(library: library, under: "Memory/Projects/Silkweb")
        XCTAssertEqual(
            documents.map(\.path),
            [
                "Memory/Projects/Silkweb/Memories/Decision.md",
                "Memory/Projects/Silkweb/Progress/2026-10-07 0900 — Spike.md",
            ])
        XCTAssertEqual(documents.first?.size, "# Decision".utf8.count)
        XCTAssertEqual(try AgentSecureFiles.documents(library: library, under: "Memory/Projects/Missing"), [])
        assertRefused(
            try AgentSecureFiles.documents(library: library, under: "Memory/Projects/Silkweb/Linked"), .invalidPath)
    }

    // MARK: Helper

    func testHelperReportsRevocationAndLimits() throws {
        var file = AgentGrantFile(grants: [grant(limits: AgentGrantLimits(maxReadBytes: 4096))])
        try file.write(to: grantsURL)
        let arguments = ["memory", "capabilities", "--project", "Silkweb", "--grants", grantsURL.path]
        let output = AgentHelper.run(arguments, home: root)
        XCTAssertEqual(output.status, 0, output.stderr)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(
            json["limits"] as? [String: Int],
            ["max_read_bytes": 4096, "max_results": 200, "requests_per_minute": 120, "max_create_bytes": 262_144])

        file.setEnabled(false, project: "Silkweb")
        try file.write(to: grantsURL)
        let revoked = AgentHelper.run(arguments, home: root)
        XCTAssertEqual(revoked.status, 1)
        XCTAssertEqual(
            revoked.stdout,
            "{\n  \"error\" : {\n    \"code\" : \"grant_revoked\",\n    \"title\" : \"No Agent Access\"\n  }\n}\n")
        XCTAssertEqual(
            revoked.stderr,
            "No Agent Access: Agent access “Silkweb project” was turned off. Ask the owner to turn it back on.\n")
    }
}

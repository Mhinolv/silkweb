import Darwin
import Foundation
import XCTest

@testable import SilkwebCore

/// #229: the owner's Agent Access window changes `agent-grants.json` through `AgentGrantOwner`. Widening (a new grant,
/// more access, read folders, an agent folder, create folders, another Library, limits, Resume) needs authentication;
/// narrowing, pausing, relabelling and removing don't. Writes are atomic, keep other grants, and refuse a grant that
/// changed on disk since it was loaded. `grant init` and approval keep refusing to widen.
final class AgentGrantOwnerTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!
    private let now = Date(timeIntervalSince1970: 1_791_450_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentGrantOwner-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        library = root.appendingPathComponent("Library")
        grantsURL = root.appendingPathComponent("Support/agent-grants.json")
        for folder in ["Memory/Projects/Silkweb/Progress", "Notes/Swift", "Specs"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func grant(
        _ project: String = "Silkweb", access: AgentGrant.Access = .readCreate, extra: [String] = [],
        agentFolder: String? = nil, revoked: Date? = nil, label: String = ""
    ) -> AgentGrant {
        AgentGrant(
            project: project, library: LibraryLocation(path: library.path), access: access, extraReadFolders: extra,
            label: label, createdAt: now, revokedAt: revoked, agentFolder: agentFolder)
    }

    /// Saves `grants` and returns the file's bytes and inode.
    @discardableResult
    private func seed(_ grants: [AgentGrant]) throws -> Data {
        try AgentGrantFile(grants: grants).write(to: grantsURL)
        return try Data(contentsOf: grantsURL)
    }

    private func loaded() throws -> AgentGrantFile { try AgentGrantOwner.load(grantsURL) }

    private func inode() -> ino_t {
        var info = stat()
        stat(grantsURL.path, &info)
        return info.st_ino
    }

    private func assertFailure(_ expression: @autoclosure () throws -> Any, _ code: String, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), line: line) { error in
            XCTAssertEqual((error as? AgentGrantOwner.Failure)?.code, code, "\(error)", line: line)
        }
    }

    // MARK: Classifying

    func testWideningsNameEverythingThatGivesAgentsMore() {
        let base = grant(access: .readCreate, extra: ["Notes"], agentFolder: nil)
        XCTAssertEqual(AgentGrantOwner.widenings(from: nil, to: base), [.newGrant])
        XCTAssertEqual(AgentGrantOwner.widenings(from: base, to: base), [])

        var edited = base
        edited.access = .readCreateUpdate
        XCTAssertEqual(
            AgentGrantOwner.widenings(from: base, to: edited), [.access(from: .readCreate, to: .readCreateUpdate)])
        edited = base
        edited.extraReadFolders = ["Notes", "Notes/Swift", "Specs", "Memory/Projects/Silkweb/Progress"]
        XCTAssertEqual(
            AgentGrantOwner.widenings(from: base, to: edited), [.readFolders(["Specs"])],
            "folders already readable add nothing")
        edited = base
        edited.agentFolder = "Claude"
        XCTAssertEqual(AgentGrantOwner.widenings(from: base, to: edited), [.agentFolder("Claude")])
        let withAgent = grant(agentFolder: "Claude")
        edited = withAgent
        edited.agentFolder = "Codex"
        XCTAssertEqual(
            AgentGrantOwner.widenings(from: withAgent, to: edited), [.agentFolder("Codex")], "a change widens")
        edited = withAgent
        edited.extraReadFolders = ["Memory/Agents/Claude/Notes"]
        XCTAssertEqual(AgentGrantOwner.widenings(from: withAgent, to: edited), [], "inside the agent folder already")
        edited = base
        edited.createFolders = ["Specs"]
        XCTAssertEqual(AgentGrantOwner.widenings(from: base, to: edited), [.createFolders(["Specs"])])
        edited = base
        edited.limits.maxReadBytes += 1
        XCTAssertEqual(AgentGrantOwner.widenings(from: base, to: edited), [.limits])
        edited = base
        edited.library = LibraryLocation(path: root.path)
        XCTAssertEqual(AgentGrantOwner.widenings(from: base, to: edited), [.library])
        let paused = grant(revoked: now)
        edited = paused
        edited.revokedAt = nil
        XCTAssertEqual(AgentGrantOwner.widenings(from: paused, to: edited), [.resume])

        // Narrowing, pausing and relabelling widen nothing.
        edited = withAgent
        edited.access = .read
        edited.extraReadFolders = []
        edited.agentFolder = nil
        edited.label = "Renamed"
        edited.revokedAt = now
        XCTAssertEqual(AgentGrantOwner.widenings(from: withAgent, to: edited), [])
        // Several at once are all named.
        edited = paused
        edited.revokedAt = nil
        edited.access = .readCreateUpdate
        XCTAssertEqual(
            AgentGrantOwner.widenings(from: paused, to: edited),
            [.access(from: .readCreate, to: .readCreateUpdate), .resume])
    }

    // MARK: Saving

    func testWideningNeedsAuthenticationAndThenSavesAtomically() throws {
        let other = grant("Coffee", access: .read)
        let original = grant(access: .read)
        let before = try seed([other, original])
        var edited = original
        edited.access = .readCreateUpdate
        edited.extraReadFolders = ["Notes/Swift"]
        edited.agentFolder = "Claude"

        assertFailure(
            try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: false),
            "needs_authentication")
        XCTAssertEqual(try Data(contentsOf: grantsURL), before, "nothing is written without authentication")

        let oldInode = inode()
        let saved = try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: true)
        XCTAssertEqual(saved, edited)
        XCTAssertNotEqual(inode(), oldInode, "replaced atomically: a new file, never written in place")
        let file = try loaded()
        XCTAssertEqual(file.grants, [other, edited], "other grants and the order stay")
        XCTAssertEqual(file.version, 1)
    }

    func testNarrowingRelabellingAndRemovingFoldersSaveWithoutAuthentication() throws {
        let original = grant(access: .readCreateUpdate, extra: ["Notes/Swift", "Specs"], agentFolder: "Claude")
        try seed([original])
        var edited = original
        edited.access = .read
        edited.extraReadFolders = ["Specs"]
        edited.agentFolder = nil
        edited.label = "  Silkweb\nrepo  "
        let saved = try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: false)
        XCTAssertEqual(saved.label, "Silkweb repo", "kept on one line")
        XCTAssertEqual(saved.access, .read)
        XCTAssertEqual(saved.extraReadFolders, ["Specs"])
        XCTAssertNil(saved.agentFolder)
        XCTAssertEqual(try loaded().grants, [saved])
    }

    func testChangedOrRemovedOnDiskIsRefusedAndKeepsTheFile() throws {
        let original = grant()
        try seed([original])
        var outside = original
        outside.access = .read
        let before = try seed([outside])
        var edited = original
        edited.label = "Mine"
        assertFailure(
            try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: true), "grant_changed")
        XCTAssertEqual(try Data(contentsOf: grantsURL), before)

        try seed([])
        assertFailure(
            try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: true),
            "grant_not_found")
        var renamed = edited
        renamed.project = "Other"
        try seed([original])
        assertFailure(
            try AgentGrantOwner.save(renamed, replacing: original, in: grantsURL, authenticated: true),
            "invalid_grant")
    }

    func testNewGrantIsCheckedLikeGrantInitAndNeedsAuthentication() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))
        let made = try AgentGrantOwner.newGrant(
            library: library.path + "/./", project: "Silkweb", label: "Silkweb repo", access: .readCreate,
            agentFolder: " Claude ", now: now.addingTimeInterval(0.7))
        XCTAssertEqual(made.grant.library.path, library.path)
        XCTAssertEqual(made.grant.agentFolder, "Claude")
        XCTAssertEqual(made.grant.createdAt, now, "whole seconds, as stored")
        XCTAssertEqual(made.filesystem, AgentFilesystem.probe(library))

        assertFailure(
            try AgentGrantOwner.save(made.grant, replacing: nil, in: grantsURL, authenticated: false),
            "needs_authentication")
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path), "nothing is written")
        try AgentGrantOwner.save(made.grant, replacing: nil, in: grantsURL, authenticated: true)
        XCTAssertEqual(try loaded().grants, [made.grant])
        assertFailure(
            try AgentGrantOwner.save(made.grant, replacing: nil, in: grantsURL, authenticated: true), "grant_exists")

        // The refusals `grant init` gives, in the app's words.
        for (path, project, agent, message) in [
            (library.path, "a/b", nil, AgentGrantOwner.invalidProjectMessage),
            (library.path, "", nil, AgentGrantOwner.invalidProjectMessage),
            (library.path, "Silkweb", "..", AgentGrantOwner.invalidAgentFolderMessage),
            (root.appendingPathComponent("Missing").path, "Silkweb", nil, "That folder doesn’t exist."),
        ] as [(String, String, String?, String)] {
            XCTAssertThrowsError(
                try AgentGrantOwner.newGrant(library: path, project: project, access: .read, agentFolder: agent)
            ) { error in
                XCTAssertEqual((error as? AgentGrantOwner.Failure)?.message, message, project)
            }
        }
    }

    func testInvalidFoldersAreRefusedBeforeWriting() throws {
        let original = grant()
        let before = try seed([original])
        for folders in [["../Outside"], ["/Users"], [".silkweb"]] {
            var edited = original
            edited.extraReadFolders = folders
            assertFailure(
                try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: true),
                "invalid_grant")
        }
        var edited = original
        edited.agentFolder = "a/b"
        assertFailure(
            try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: true), "invalid_grant")
        edited = original
        edited.access = .read
        edited.createFolders = ["Specs"]
        assertFailure(
            try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: true), "invalid_grant")
        XCTAssertEqual(try Data(contentsOf: grantsURL), before)

        // Add Folder…: inside the Library only, never the Library itself.
        XCTAssertEqual(
            try AgentGrantOwner.readFolder(library.appendingPathComponent("Notes/Swift"), library: library),
            "Notes/Swift")
        for outside: URL in [root, library, root.appendingPathComponent("Library2")] {
            XCTAssertThrowsError(try AgentGrantOwner.readFolder(outside, library: library)) { error in
                XCTAssertEqual(
                    (error as? AgentScopeError)?.message,
                    "“\(AgentMemoryContract.displayPath(outside.path))” isn’t a path inside the Library.")
            }
        }
        XCTAssertEqual(AgentGrantOwner.addingReadFolder("Notes/Swift", to: grant(extra: ["Notes"])), ["Notes"])
        XCTAssertEqual(AgentGrantOwner.addingReadFolder("Notes", to: grant(extra: ["Notes/Swift"])), ["Notes"])
        XCTAssertEqual(AgentGrantOwner.addingReadFolder("Memory/Projects/Silkweb/Progress", to: grant()), [])
    }

    // MARK: Pause, Resume, Remove

    func testPauseIsFreeResumeNeedsAuthenticationAndRunningSessionsFailClosed() throws {
        try seed([grant(), grant("Coffee", access: .read)])
        let session = AgentSession(project: "Silkweb", store: AgentGrantStore(url: grantsURL))
        XCTAssertNoThrow(try session.authorize(.create, path: "Memory/Projects/Silkweb/Progress/New.md"))

        let paused = try AgentGrantOwner.setPaused(
            true, project: "Silkweb", in: grantsURL, authenticated: false, now: now.addingTimeInterval(0.5))
        XCTAssertEqual(paused.revokedAt, now)
        XCTAssertThrowsError(try session.authorize(.read)) { error in
            XCTAssertEqual((error as? AgentAccessError)?.code, "grant_revoked", "the next operation stops")
        }
        // Pausing again keeps the first date.
        XCTAssertEqual(
            try AgentGrantOwner.setPaused(
                true, project: "Silkweb", in: grantsURL, authenticated: false, now: now.addingTimeInterval(60)
            ).revokedAt, now)

        let before = try Data(contentsOf: grantsURL)
        assertFailure(
            try AgentGrantOwner.setPaused(false, project: "Silkweb", in: grantsURL, authenticated: false),
            "needs_authentication")
        XCTAssertEqual(try Data(contentsOf: grantsURL), before)
        XCTAssertNil(
            try AgentGrantOwner.setPaused(false, project: "Silkweb", in: grantsURL, authenticated: true).revokedAt)
        XCTAssertNoThrow(try session.authorize(.read))

        // Narrowing takes effect on the next operation too.
        let current = try XCTUnwrap(try loaded().grant(for: "Silkweb"))
        var narrowed = current
        narrowed.access = .read
        try AgentGrantOwner.save(narrowed, replacing: current, in: grantsURL, authenticated: false)
        XCTAssertThrowsError(try session.authorize(.create, path: "Memory/Projects/Silkweb/Progress/New.md")) {
            XCTAssertEqual(($0 as? AgentAccessError)?.code, AgentAccessError.createNotAllowed.code)
        }

        try AgentGrantOwner.remove(project: "Silkweb", in: grantsURL)
        XCTAssertEqual(try loaded().grants.map(\.project), ["Coffee"])
        XCTAssertThrowsError(try session.authorize(.read)) { error in
            XCTAssertEqual((error as? AgentAccessError)?.code, "grant_revoked", "a removed grant stops sessions")
        }
        assertFailure(try AgentGrantOwner.remove(project: "Silkweb", in: grantsURL), "grant_not_found")
        assertFailure(
            try AgentGrantOwner.setPaused(true, project: "Silkweb", in: grantsURL, authenticated: true),
            "grant_not_found")
    }

    // MARK: Files

    func testEarlierFilesLoadAndBrokenOrNewerOnesAreNeverOverwritten() throws {
        try FileManager.default.createDirectory(
            at: grantsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A #130 file: no version, no label, agent or create folders.
        try Data(
            #"{"grants":[{"project":"Silkweb","library":{"path":"\#(library.path)"},"access":"read-only","extra_read_folders":[]}]}"#
                .utf8
        ).write(to: grantsURL)
        let early = try XCTUnwrap(try loaded().grant(for: "Silkweb"))
        XCTAssertEqual(early.access, .read)
        XCTAssertEqual(early.displayLabel, "Silkweb project")
        var edited = early
        edited.label = "Silkweb repo"
        try AgentGrantOwner.save(edited, replacing: early, in: grantsURL, authenticated: false)
        XCTAssertEqual(try loaded().grant(for: "Silkweb")?.label, "Silkweb repo")

        for broken in ["not JSON", #"{"version":2,"grants":[]}"#] {
            try Data(broken.utf8).write(to: grantsURL)
            XCTAssertThrowsError(try AgentGrantOwner.load(grantsURL))
            XCTAssertThrowsError(try AgentGrantOwner.remove(project: "Silkweb", in: grantsURL))
            XCTAssertEqual(try String(contentsOf: grantsURL, encoding: .utf8), broken, "never overwritten")
        }
        try FileManager.default.removeItem(at: grantsURL)
        XCTAssertEqual(try AgentGrantOwner.load(grantsURL), AgentGrantFile(), "no file yet is an empty one")
    }

    func testCreateFoldersAndInstallBlockMatchTheHelper() {
        XCTAssertEqual(
            AgentGrantOwner.createFolders(grant(agentFolder: "Claude")),
            [
                "Memory/Projects/Silkweb/Memories", "Memory/Projects/Silkweb/Progress",
                "Memory/Projects/Silkweb/Handoffs", "Memory/Agents/Claude/Memories",
            ])
        XCTAssertEqual(AgentGrantOwner.createFolders(grant(access: .read)), [])
        XCTAssertEqual(
            AgentGrantOwner.installBlock(project: "Silkweb", library: library.path, helper: "/usr/local/bin/silkweb"),
            AgentGrantInit.installBlock(helper: "/usr/local/bin/silkweb", project: "Silkweb", library: library.path))
    }

    /// The helper's own paths still never widen (#186, #203): only `AgentGrantOwner` does, with authentication.
    func testGrantInitAndApprovalStillRefuseToWiden() throws {
        let original = grant(access: .read)
        try seed([original])
        XCTAssertThrowsError(
            try AgentGrantInit.merge(
                try loaded(), project: "Silkweb", library: library, access: .readCreate, now: now, approving: true)
        ) { error in
            XCTAssertEqual(
                (error as? AgentGrantInit.Failure)?.message,
                "The grant “Silkweb” already exists with Read Only access. Approving never widens access. "
                    + "Change the grant in Agent Access first, then approve.")
        }
        var paused = original
        paused.revokedAt = now
        try seed([paused])
        XCTAssertThrowsError(
            try AgentGrantInit.merge(try loaded(), project: "Silkweb", library: library, access: .read, now: now))
    }
}

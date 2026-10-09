import Foundation
import XCTest

@testable import SilkwebCore

/// #203: an agent asks for access (`grant request`, MCP `grant_request`) without a grant or a terminal; only the
/// owner approves (terminal, #186 merge and never-widen rules) or denies; pending requests expire; requests and
/// history share one versioned file outside the Library.
final class AgentAccessRequestsTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var library: URL!
    private var requestsURL: URL!
    private var grantsURL: URL!
    private var realRequests: URL { AgentAccessRequests.defaultURL(home: home) }
    private var realGrants: URL { AgentGrantFile.defaultURL(home: home) }
    /// 2026-10-09 14:00:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_791_554_400)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentAccessRequests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        library = root.appendingPathComponent("Writing Library")
        requestsURL = root.appendingPathComponent("requests.json")
        grantsURL = root.appendingPathComponent("grants.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Notes/Swift"), withIntermediateDirectories: true)
        try Data("# Diary\n".utf8).write(to: library.appendingPathComponent("Notes/Diary.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// `grant <arguments>` as the helper runs it. `files: false` targets the real files under the temporary home.
    private func grant(
        _ arguments: [String], answers: [String] = [], terminal: Bool = false, files: Bool = true, at date: Date? = nil
    ) -> (output: AgentHelper.Output, prompts: String) {
        var remaining = answers
        var prompts = ""
        let console = AgentGrantInit.Console(
            isTerminal: terminal, readLine: { remaining.isEmpty ? nil : remaining.removeFirst() },
            write: { prompts += $0 })
        var target: [String] = []
        if files {
            target = ["--requests", requestsURL.path]
            if ["approve", "deny"].contains(arguments.first) { target += ["--grants", grantsURL.path] }
        }
        let output = AgentGrantInit.run(
            ["grant"] + arguments + target, console: console, home: home, environment: ["PATH": "/usr/bin"],
            executable: nil, currentDirectory: root.path, now: date ?? now)
        return (output, prompts)
    }

    private func request(
        _ access: String = "read-create", folders: [String] = [], message: String? = nil, files: Bool = true,
        at date: Date? = nil
    ) -> AgentHelper.Output {
        var arguments = ["request", "--library", library.path, "--project", "Silkweb", "--access", access]
        for folder in folders { arguments += ["--folder", folder] }
        if let message { arguments += ["--message", message] }
        arguments += ["--agent", "claude-code", "--session", "s-1"]
        return grant(arguments, files: files, at: date).output
    }

    private func result(_ output: AgentHelper.Output, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: Any]
    {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any], output.stdout, file: file,
            line: line)
        XCTAssertEqual(json["ok"] as? Bool, true, output.stdout, file: file, line: line)
        return try XCTUnwrap(json["result"] as? [String: Any], file: file, line: line)
    }

    private func error(_ output: AgentHelper.Output, file: StaticString = #filePath, line: UInt = #line) throws
        -> [String: Any]
    {
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any], output.stdout, file: file,
            line: line)
        XCTAssertEqual(json["ok"] as? Bool, false, file: file, line: line)
        return try XCTUnwrap(json["error"] as? [String: Any], file: file, line: line)
    }

    private func stored(_ url: URL? = nil) throws -> [AgentAccessRequest] {
        try AgentAccessRequestStore(url: url ?? requestsURL).load().requests
    }

    private func libraryState() throws -> [String] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: library, includingPropertiesForKeys: [.contentModificationDateKey]))
        return try enumerator.compactMap { $0 as? URL }.map {
            "\($0.path) \(try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!)"
        }.sorted()
    }

    // MARK: Request

    func testRequestWithoutGrantsIsSavedOutsideTheGrantsFileAndRepeatsAreIdempotent() throws {
        let before = try libraryState()
        // No grants file, no terminal, the real requests file: an agent's situation.
        let first = request(folders: ["Notes/Swift", "Specs"], message: "Need to save\nhandoffs.", files: false)
        XCTAssertEqual(first.status, 0, first.stderr)
        let fields = try result(first)
        let id = try XCTUnwrap(fields["requestId"] as? String)
        XCTAssertTrue(id.hasPrefix("req_") && id.count == 16, id)
        XCTAssertEqual(fields["status"] as? String, "pending")
        XCTAssertEqual(fields["duplicate"] as? Bool, false)
        XCTAssertEqual(fields["expiresAt"] as? String, "2026-11-08T14:00:00Z", "30 days")
        XCTAssertEqual(
            first.stderr,
            "silkweb: Access request \(id) is waiting for the owner. They can review it in Silkweb "
                + "(Agent Activity ▸ Access Requests) or Terminal.\n")
        XCTAssertFalse(first.stderr.contains("approve"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: realGrants.path), "a request never writes grants")
        XCTAssertEqual(try libraryState(), before, "a request never writes inside the Library")

        let saved = try XCTUnwrap(try stored(realRequests).first)
        XCTAssertEqual(saved.libraryRoot, library.path)
        XCTAssertEqual(saved.project, "Silkweb")
        XCTAssertEqual(saved.profile, .readCreate)
        XCTAssertEqual(saved.readFolders, ["Notes/Swift", "Specs"])
        XCTAssertEqual(saved.message, "Need to save handoffs.", "kept on one line")
        XCTAssertEqual([saved.agent, saved.session, saved.client], ["claude-code", "s-1", "cli"])
        XCTAssertEqual(saved.status, .pending)

        // The same Library, project, profile and folder set, in any order: the same request.
        let again = request(folders: ["Specs", "Notes/Swift/", "Notes/Swift"], message: "Other words", files: false)
        XCTAssertEqual(try result(again)["requestId"] as? String, id)
        XCTAssertEqual(try result(again)["duplicate"] as? Bool, true)
        XCTAssertEqual(try stored(realRequests).count, 1)
        // Anything else is another request.
        XCTAssertNotEqual(try result(request("read", files: false))["requestId"] as? String, id)
        XCTAssertEqual(try stored(realRequests).count, 2)

        let json = try String(contentsOf: realRequests, encoding: .utf8)
        XCTAssertTrue(json.contains("\"version\" : 1"), json)
        XCTAssertTrue(json.contains("\"requestedAt\" : \"2026-10-09T14:00:00Z\""), json)
        XCTAssertFalse(FileManager.default.fileExists(atPath: realGrants.path))
    }

    func testRequestValidationAndLimits() throws {
        let cases: [([String], String)] = [
            (["--project", "Silkweb", "--access", "read"], "“grant request” needs --library."),
            (["--library", library.path, "--access", "read"], "“grant request” needs --project."),
            (
                ["--library", library.path, "--project", "a/b", "--access", "read"],
                AgentGrantInit.invalidProjectMessage
            ),
            (
                ["--library", library.path, "--project", "Silkweb", "--access", "read-create-update"],
                "The access must be read or read-create."
            ),
            (
                ["--library", library.path, "--project", "Silkweb", "--access", "read", "--folder", "../Outside"],
                "Read folders must be Library-relative folders without “..”, hidden names or control characters."
            ),
            (
                ["--library", library.path, "--project", "Silkweb", "--access", "read", "--folder", ".silkweb"],
                "Read folders must be Library-relative folders without “..”, hidden names or control characters."
            ),
            (
                ["--library", library.path, "--project", "Silkweb", "--access", "read"]
                    + (1...11).flatMap { ["--folder", "F\($0)"] }, "Ask for at most 10 read folders."
            ),
            (
                [
                    "--library", library.path, "--project", "Silkweb", "--access", "read", "--message",
                    String(repeating: "a", count: 281),
                ], "The message can be at most 280 characters."
            ),
            (
                ["--library", library.path, "--project", "Silkweb", "--access", "read", "--grant", "X"],
                "The option “--grant” isn’t valid for “grant request”."
            ),
        ]
        for (arguments, message) in cases {
            let output = grant(["request"] + arguments).output
            XCTAssertEqual(output.status, 64, "\(arguments)")
            let failure = try error(output)
            XCTAssertEqual(failure["code"] as? String, "invalid_argument")
            XCTAssertTrue((failure["message"] as? String)?.hasPrefix(message) == true, "\(failure)")
        }
        let missing = grant([
            "request", "--library", root.appendingPathComponent("nope").path, "--project", "S",
            "--access", "read",
        ]).output
        XCTAssertEqual(missing.status, 74)
        XCTAssertEqual(try error(missing)["code"] as? String, "library_not_found")
        XCTAssertFalse(FileManager.default.fileExists(atPath: requestsURL.path), "nothing was saved")

        // Exactly 280 characters and ten folders are fine; the project's own Folder doesn't count.
        let longest = request(
            folders: (1...10).map { "F\($0)" } + ["Memory/Projects/Silkweb/Memories"],
            message: String(repeating: "é", count: 280))
        XCTAssertEqual(longest.status, 0, longest.stdout)
        XCTAssertEqual(try stored().first?.readFolders.count, 10)

        // Five pending per Library, then a refusal the agent can pass on.
        for index in 1...4 { XCTAssertEqual(request(folders: ["G\(index)"]).status, 0) }
        let sixth = request(folders: ["H"])
        XCTAssertEqual(sixth.status, 69)
        let failure = try error(sixth)
        XCTAssertEqual(failure["code"] as? String, "too_many_requests")
        XCTAssertEqual(
            failure["message"] as? String,
            "There are already 5 access requests waiting for this Library. Ask the owner to review them.")
        XCTAssertEqual(try result(request(folders: ["G1"]))["duplicate"] as? Bool, true, "a repeat still answers")
    }

    func testMessageAndClaimsStayOnOneLine() {
        XCTAssertEqual(AgentAccessRequests.oneLine("  a\nb\r\n\tc\u{202E}d  "), "a b c d")
        XCTAssertEqual(AgentAccessRequests.oneLine("\u{0007}"), "")
    }

    // MARK: Owner

    func testApproveAndDenyNeedATerminalForTheRealFiles() throws {
        let id = try XCTUnwrap(try result(request(files: false))["requestId"] as? String)
        for command in [["approve", id], ["deny", id], ["deny", id, "--note", "x"]] {
            let (output, prompts) = grant(command, answers: ["y"], files: false)
            XCTAssertEqual(output.status, 77, "\(command)")
            XCTAssertEqual(
                output.stderr, "silkweb: Only the owner can approve or deny access. Run this in Terminal.\n")
            XCTAssertEqual(output.stdout, "")
            XCTAssertEqual(prompts, "", "never asks without a terminal")
        }
        // Either real file is enough to refuse: a test requests file can't approve into the real grants.
        let mixed = AgentGrantInit.run(
            ["grant", "approve", id, "--requests", realRequests.path, "--grants", grantsURL.path],
            console: .init(isTerminal: false, readLine: { "y" }, write: { _ in }), home: home, executable: nil,
            now: now)
        XCTAssertEqual(mixed.status, 77)
        XCTAssertEqual(try stored(realRequests).first?.status, .pending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: realGrants.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))

        // Listing needs no terminal.
        let list = grant(["requests"], files: false).output
        XCTAssertEqual(list.status, 0)
        XCTAssertEqual(
            list.stdout,
            "\(id)  pending  claude-code  Silkweb  Read and Create  \(library.path)  expires "
                + AgentAccessRequests.shortDate(now.addingTimeInterval(30 * 86_400)) + "\n")
    }

    func testTerminalApproveAddsTheGrantWithItsFoldersAndPrintsTheSummary() throws {
        let id = try XCTUnwrap(
            try result(request(folders: ["Notes/Swift"], message: "For handoffs"))["requestId"] as? String)
        let declined = grant(["approve", id], answers: ["n"], terminal: true)
        XCTAssertEqual(declined.output.stdout, "Nothing was saved.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))
        XCTAssertEqual(grant(["approve", id], answers: [], terminal: true).output.status, 1, "end of input cancels")
        XCTAssertEqual(try stored().first?.status, .pending)

        let later = now.addingTimeInterval(3_600)
        let (output, prompts) = grant(["approve", id], answers: ["y"], terminal: true, at: later)
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(
            prompts.hasPrefix(
                "claude-code wants Read and Create for “Silkweb”\n  Library  \(library.path)\n"
                    + "  Folders  Memory › Projects › Silkweb, Notes › Swift\n  Message  “For handoffs”\n"),
            prompts)
        XCTAssertTrue(prompts.hasSuffix("Agent and session are claimed, not verified.\nApprove this request? [y/N] "))
        XCTAssertTrue(
            output.stdout.hasPrefix("Saved agent access for “Silkweb” (Read and Create).\n  Library  \(library.path)"),
            output.stdout)
        XCTAssertTrue(output.stdout.contains("Add the MCP server (user scope):\n"), "the #186 install block")
        let saved = try XCTUnwrap(try AgentGrantStore(url: grantsURL).load().grant(for: "Silkweb"))
        XCTAssertEqual(saved.access, .readCreate)
        XCTAssertEqual(saved.extraReadFolders, ["Notes/Swift"])
        XCTAssertEqual(saved.library.path, library.path)
        let approved = try XCTUnwrap(try stored().first)
        XCTAssertEqual(approved.status, .approved)
        XCTAssertEqual(approved.decidedVia, .terminal)
        XCTAssertEqual(approved.decidedAt, later)

        // Decided requests can't be decided again.
        let again = grant(["deny", id], answers: ["y"], terminal: true).output
        XCTAssertEqual(again.status, 65)
        XCTAssertEqual(again.stderr, "silkweb: This request was already approved in Terminal.\n")
        let unknown = grant(["approve", "req_000000000000"], answers: ["y"], terminal: true).output
        XCTAssertEqual(unknown.status, 65)
        XCTAssertEqual(unknown.stderr, "silkweb: There’s no access request “req_000000000000”.\n")

        // The grant now works for the agent through the ordinary memory commands.
        let capabilities = AgentHelper.run(
            ["memory", "capabilities", "--grants", grantsURL.path], home: home, environment: [:])
        XCTAssertEqual(capabilities.status, 0, capabilities.stdout)
        XCTAssertTrue(capabilities.stdout.contains("\"Notes/Swift\""), capabilities.stdout)
    }

    func testApproveNeverWidensAndAnIdenticalGrantIsLeftAsItIs() throws {
        let existing = AgentGrant(
            project: "Silkweb", library: LibraryLocation(path: library.path), access: .read,
            extraReadFolders: ["Notes"], label: "Mine", createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try AgentGrantFile(grants: [existing]).write(to: grantsURL)
        let before = try Data(contentsOf: grantsURL)
        let cases: [(String, [String], String)] = [
            ("read-create", [], "The grant “Silkweb” already exists with Read Only access."),
            ("read", ["Specs"], "The grant “Silkweb” doesn’t include the read folder “Specs”."),
        ]
        for (access, folders, start) in cases {
            let id = try XCTUnwrap(try result(request(access, folders: folders))["requestId"] as? String)
            let (output, prompts) = grant(["approve", id], answers: ["y"], terminal: true)
            XCTAssertEqual(output.status, 77, access)
            XCTAssertEqual(
                output.stderr,
                "silkweb: " + start.dropLast()
                    + ". Approving never widens access; edit agent-grants.json to change it.\n")
            XCTAssertEqual(prompts, "", "refused before asking")
            XCTAssertEqual(try Data(contentsOf: grantsURL), before)
            XCTAssertEqual(try stored().first { $0.requestId == id }?.status, .pending, "stays pending")
        }
        // The app's path refuses the same way.
        let store = AgentAccessRequestStore(url: requestsURL)
        let widening = try XCTUnwrap(try stored().first { $0.profile == .readCreate })
        XCTAssertThrowsError(
            try store.decide(widening.requestId, approve: true, via: .app, grantsURL: grantsURL, now: now)
        ) { error in
            XCTAssertEqual((error as? AgentAccessError)?.code, "approve_would_widen")
            XCTAssertEqual((error as? AgentAccessError)?.title, "Can’t Approve This Request")
        }

        // Identical (a folder inside one the grant already reads counts): approved, the file untouched.
        let id = try XCTUnwrap(try result(request("read", folders: ["Notes/Swift"]))["requestId"] as? String)
        let decision = try store.decide(id, approve: true, via: .app, grantsURL: grantsURL, now: now)
        XCTAssertEqual(decision.outcome, .unchanged)
        XCTAssertEqual(try Data(contentsOf: grantsURL), before)
        XCTAssertEqual(try stored().first { $0.requestId == id }?.status, .approved)
        XCTAssertEqual(try stored().first { $0.requestId == id }?.decidedVia, .app)
    }

    func testDenyRecordsTheOwnersNote() throws {
        let id = try XCTUnwrap(try result(request())["requestId"] as? String)
        let (output, prompts) = grant(
            ["deny", id, "--note", "Not this\nproject"], answers: ["yes"], terminal: true)
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(prompts.hasSuffix("Deny this request? [y/N] "))
        XCTAssertEqual(output.stdout, "Denied the request from “claude-code” for “Silkweb”.\n")
        let denied = try XCTUnwrap(try stored().first)
        XCTAssertEqual(denied.status, .denied)
        XCTAssertEqual(denied.ownerNote, "Not this project")
        XCTAssertEqual(denied.decidedVia, .terminal)
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path), "a denial never writes grants")
        XCTAssertEqual(
            denied.historyLabel(now), "Denied · \(AgentAccessRequests.shortDate(now)) · in Terminal — Not this project")
        XCTAssertEqual(
            grant(["requests", "--all"]).output.stdout,
            "\(id)  denied  claude-code  Silkweb  Read and Create  \(library.path)  "
                + "\(AgentAccessRequests.shortDate(now)) in Terminal — Not this project\n")
        XCTAssertEqual(grant(["requests"]).output.stdout, "No access requests are waiting.\n")
        // A denied request doesn't block asking again.
        XCTAssertEqual(try result(request())["duplicate"] as? Bool, false)
    }

    func testPendingRequestsExpireAfterThirtyDays() throws {
        let id = try XCTUnwrap(try result(request())["requestId"] as? String)
        let request = try XCTUnwrap(try stored().first)
        XCTAssertEqual(request.expiryLabel(now), "expires in 30 days")
        XCTAssertEqual(request.expiryLabel(now.addingTimeInterval(29 * 86_400)), "expires tomorrow")
        XCTAssertEqual(request.expiryLabel(now.addingTimeInterval(29.5 * 86_400)), "expires today")
        let expired = now.addingTimeInterval(30 * 86_400)
        XCTAssertEqual(request.status(at: expired.addingTimeInterval(-1)), .pending)
        XCTAssertEqual(request.status(at: expired), .expired)

        let approve = grant(["approve", id], answers: ["y"], terminal: true, at: expired).output
        XCTAssertEqual(approve.status, 65)
        XCTAssertEqual(
            approve.stderr, "silkweb: This request expired on \(AgentAccessRequests.shortDate(expired)).\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))
        XCTAssertEqual(grant(["requests"], at: expired).output.stdout, "No access requests are waiting.\n")
        XCTAssertEqual(
            grant(["requests", "--all"], at: expired).output.stdout,
            "\(id)  expired  claude-code  Silkweb  Read and Create  \(library.path)  expired "
                + AgentAccessRequests.shortDate(expired) + "\n")
        XCTAssertEqual(request.historyLabel(expired), "Expired · " + AgentAccessRequests.shortDate(expired))

        // Asking again makes a new request; the expired one stays in history.
        let renewed = try result(self.request(at: expired))
        XCTAssertNotEqual(renewed["requestId"] as? String, id)
        XCTAssertEqual(renewed["duplicate"] as? Bool, false)
        let review = try AgentAccessRequestStore(url: requestsURL).load().review(now: expired)
        XCTAssertEqual(review.waiting.map(\.requestId), [renewed["requestId"] as? String])
        XCTAssertEqual(review.history.map(\.requestId), [id])
    }

    // MARK: Persistence

    func testFilesDecodeTolerantlyAndBrokenOrNewerOnesAreNeverOverwritten() throws {
        try Data(
            #"{"requests":[{"requestId":"req_a","libraryRoot":"/L","project":"P","status":"withdrawn","profile":"read-create-update-delete"},{"requestId":"req_b","libraryRoot":"/L","project":"P","requestedAt":"2026-10-01T00:00:00Z"}]}"#
                .utf8
        ).write(to: requestsURL)
        let file = try AgentAccessRequestStore(url: requestsURL).load()
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(file.requests.map(\.status), [.expired, .pending], "an unknown status is never approvable")
        XCTAssertEqual(file.requests[0].profile, .read, "an unknown profile reads as the narrowest")
        XCTAssertEqual(file.requests[1].readFolders, [])
        XCTAssertEqual(file.requests[1].expiresAt, ISO8601DateFormatter().date(from: "2026-10-31T00:00:00Z"), "30 days")

        for (contents, code) in [
            ("not JSON", "invalid_requests_file"), (#"{"version":2,"requests":[]}"#, "unsupported_requests_version"),
        ] {
            try Data(contents.utf8).write(to: requestsURL)
            let output = request()
            XCTAssertEqual(output.status, 77)
            XCTAssertEqual(try error(output)["code"] as? String, code)
            XCTAssertEqual(try String(contentsOf: requestsURL, encoding: .utf8), contents)
            XCTAssertEqual(grant(["requests"]).output.status, 77)
        }
    }

    func testHistoryIsCappedAndPendingIsKept() throws {
        let store = AgentAccessRequestStore(url: requestsURL)
        var file = AgentAccessRequestFile()
        for index in 0..<(AgentAccessRequests.maxHistory + 5) {
            file.requests.append(
                AgentAccessRequest(
                    requestId: "req_old\(index)", libraryRoot: "/Elsewhere", project: "P", profile: .read,
                    requestedAt: now.addingTimeInterval(Double(index)), expiresAt: now, status: .denied,
                    decidedAt: now.addingTimeInterval(Double(index))))
        }
        let encoder = JSONEncoder()
        try encoder.encode(file).write(to: requestsURL)
        _ = try result(request())
        let requests = try store.load().requests
        XCTAssertEqual(requests.count, AgentAccessRequests.maxHistory + 1)
        XCTAssertFalse(requests.contains { $0.requestId == "req_old0" }, "the oldest history goes first")
        XCTAssertTrue(requests.contains { $0.requestId == "req_old\(AgentAccessRequests.maxHistory + 4)" })
    }

    func testPresentation() throws {
        let request = AgentAccessRequest(
            requestId: "req_1", libraryRoot: library.path, project: "Silkweb", profile: .readCreate,
            readFolders: ["Notes/Swift", "Specs"], agent: "claude-code", requestedAt: now,
            expiresAt: now.addingTimeInterval(30 * 86_400))
        XCTAssertEqual(request.headline, "claude-code wants Read and Create for “Silkweb”")
        XCTAssertEqual(request.folderSummary, "Memory › Projects › Silkweb + 2 read folders: Notes › Swift, Specs")
        XCTAssertEqual(
            request.accessibilityLabel(now),
            "claude-code wants Read and Create for Silkweb, 3 folders, expires in 30 days")
        var approved = request
        approved.status = .approved
        approved.decidedAt = now
        approved.decidedVia = .app
        XCTAssertEqual(approved.historyLabel(now), "Approved · \(AgentAccessRequests.shortDate(now)) · in Silkweb")
        var anonymous = request
        anonymous.agent = " "
        anonymous.readFolders = []
        XCTAssertEqual(anonymous.headline, "Unknown agent wants Read and Create for “Silkweb”")
        XCTAssertEqual(anonymous.folderSummary, "Memory › Projects › Silkweb")
    }

    func testHelpAndUsage() {
        let help = grant(["--help"]).output
        XCTAssertEqual(help.stdout, AgentGrantInit.help)
        XCTAssertTrue(AgentGrantInit.help.contains("silkweb grant request --library <PATH>"))
        XCTAssertEqual(grant(["request", "--help"]).output.stdout, AgentGrantInit.help)
        XCTAssertEqual(grant(["approve"], terminal: true).output.status, 64)
        XCTAssertEqual(grant(["requests", "--note", "x"]).output.status, 64)
        XCTAssertEqual(grant(["approve", "req_1", "--all"], terminal: true).output.status, 64)
        XCTAssertEqual(
            grant(["withdraw"]).output.stderr,
            "silkweb: That isn’t a grant command. Use init, request, requests, approve or deny. "
                + "Run “silkweb grant init --help” for usage.\n")
    }
}

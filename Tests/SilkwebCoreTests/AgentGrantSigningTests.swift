import Foundation
import XCTest

@testable import SilkwebCore

/// #205: signed `agent-grants.json`. Sign and verify, tampered bytes, unsigned files before and after protection, a
/// lost key, keychain errors, the owner's write paths (`grant init`, `grant approve`, the app's `AgentGrantOwner`) and
/// proof that the memory commands, MCP and non-terminal paths never sign. Keys live in memory, never the keychain.
final class AgentGrantSigningTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!
    private var requestsURL: URL!
    private var keys: AgentGrantMemoryKeys!
    private var savedVerifier: (any AgentGrantVerifier)!
    private let now = Date(timeIntervalSince1970: 1_791_450_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentGrantSigning-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        library = root.appendingPathComponent("Writing")
        grantsURL = root.appendingPathComponent("agent-grants.json")
        requestsURL = root.appendingPathComponent("agent-access-requests.json")
        for folder in ["Memory/Projects/Silkweb/Memories", "Notes/Private"] {
            try FileManager.default.createDirectory(
                at: library.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data("# Diary\n\nprivate words\n".utf8).write(to: library.appendingPathComponent("Notes/Private/Diary.md"))
        keys = AgentGrantMemoryKeys()
        savedVerifier = AgentGrantKeys.verifier
    }

    override func tearDownWithError() throws {
        AgentGrantKeys.verifier = savedVerifier
        try? FileManager.default.removeItem(at: root)
    }

    private func grant(
        _ project: String = "Silkweb", access: AgentGrant.Access = .read, revoked: Date? = nil, label: String = ""
    ) -> AgentGrant {
        AgentGrant(
            project: project, library: LibraryLocation(path: library.path), access: access, label: label,
            createdAt: now, revokedAt: revoked)
    }

    /// Writes `grants` signed with `keys` (making the key), as the owner's paths do.
    private func writeSigned(_ grants: [AgentGrant]) throws {
        try AgentGrantSigning.signed(AgentGrantFile(grants: grants), with: keys).write(to: grantsURL)
    }

    private func json() throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: grantsURL)) as? [String: Any])
    }

    /// A hand edit of the raw JSON, outside Silkweb.
    private func edit(_ change: (inout [String: Any]) -> Void) throws {
        var object = try json()
        change(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: grantsURL)
    }

    private func editGrant(_ change: @escaping (inout [String: Any]) -> Void) throws {
        try edit { object in
            var grants = object["grants"] as? [[String: Any]] ?? []
            change(&grants[0])
            object["grants"] = grants
        }
    }

    private func protection(_ verifier: (any AgentGrantVerifier)? = nil) throws -> AgentGrantProtection {
        try AgentGrantStore(url: grantsURL, keys: verifier ?? keys).inspect().protection
    }

    private func loadError(_ verifier: (any AgentGrantVerifier)? = nil) -> String? {
        do {
            _ = try AgentGrantStore(url: grantsURL, keys: verifier ?? keys).load()
            return nil
        } catch {
            return (error as? AgentAccessError)?.code ?? "\(error)"
        }
    }

    private func cli(_ arguments: [String], stdin: String = "") -> AgentHelper.Output {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? pipe.fileHandleForWriting.close()
        return AgentHelper.run(
            arguments + ["--grants", grantsURL.path], home: root, environment: [:],
            standardInput: pipe.fileHandleForReading)
    }

    private func code(_ output: AgentHelper.Output) -> String? {
        let object = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any]
        return (object?["error"] as? [String: Any])?["code"] as? String
    }

    private func console(terminal: Bool, answers: [String] = []) -> (AgentGrantInit.Console, () -> String) {
        var remaining = answers
        var prompts = ""
        let console = AgentGrantInit.Console(
            isTerminal: terminal, readLine: { remaining.isEmpty ? nil : remaining.removeFirst() },
            write: { prompts += $0 })
        return (console, { prompts })
    }

    private func grantCommand(
        _ arguments: [String], terminal: Bool, answers: [String] = [], signer: (any AgentGrantSigner)? = nil
    ) -> (output: AgentHelper.Output, prompts: String) {
        let (console, prompts) = console(terminal: terminal, answers: answers)
        let output = AgentGrantInit.run(
            ["grant"] + arguments + ["--grants", grantsURL.path], console: console, home: root,
            environment: [:], executable: nil, currentDirectory: root.path, now: now, signer: signer ?? keys)
        return (output, prompts())
    }

    private func initFlags(_ project: String = "Silkweb", access: String = "read") -> [String] {
        ["init", "--library", library.path, "--project", project, "--access", access]
    }

    // MARK: Sign and verify

    func testSignedGrantsVerifyAndSurviveReformatting() throws {
        try writeSigned([grant(), grant("Coffee", access: .readCreate, revoked: now, label: "Coffee notes")])
        XCTAssertEqual(try protection(), .protected)
        let signature = try XCTUnwrap(try json()["signature"] as? [String: Any])
        XCTAssertEqual(signature["algorithm"] as? String, "ecdsa-p256-sha256")
        XCTAssertEqual((signature["key_id"] as? String)?.count, 16)
        XCTAssertEqual(try json()["version"] as? Int, 1, "the file stays version 1")
        XCTAssertEqual(try AgentGrantStore(url: grantsURL, keys: keys).load().grants.count, 2)

        // Compact, reordered and with an unknown key: the grants a reader sees are the same, so it still verifies.
        try edit { $0["note"] = "owner comment" }
        let compact = try JSONSerialization.data(withJSONObject: try json(), options: [])
        try compact.write(to: grantsURL)
        XCTAssertEqual(try protection(), .protected)
        // `read-only` decodes to `read`, so spelling the same access differently changes nothing either.
        try editGrant { $0["access"] = "read-only" }
        XCTAssertEqual(try protection(), .protected)
    }

    func testEveryChangeAReaderSeesFailsClosed() throws {
        let edits: [(String, (inout [String: Any]) -> Void)] = [
            ("access", { $0["access"] = "read-create" }),
            ("read folder", { $0["extra_read_folders"] = ["Notes/Private"] }),
            ("agent folder", { $0["agent_folder"] = "Claude" }),
            ("create folder", { $0["create_folders"] = ["Notes"] }),
            ("resume", { $0["revoked_at"] = nil }),
            ("limits", { $0["limits"] = ["max_read_bytes": 99_999_999] }),
            ("library", { $0["library"] = ["path": "/"] }),
            ("label", { $0["label"] = "Renamed" }),
        ]
        for (name, change) in edits {
            try writeSigned([grant(revoked: now)])
            try editGrant(change)
            XCTAssertEqual(try protection(), .changedOutside, name)
            XCTAssertEqual(loadError(), "invalid_grants_signature", name)
        }
        // Another grant added, the version changed, or the signature swapped for one of another file.
        try writeSigned([grant()])
        try edit { $0["grants"] = ($0["grants"] as? [Any] ?? []) + [["project": "Other", "access": "read"]] }
        XCTAssertEqual(try protection(), .changedOutside)
        try writeSigned([grant()])
        try edit { $0["version"] = 0 }
        XCTAssertEqual(try protection(), .changedOutside)
        try writeSigned([grant("Coffee")])
        let other = try json()["signature"]
        try writeSigned([grant("Coffee", access: .readCreate)])
        try edit { $0["signature"] = other }
        XCTAssertEqual(try protection(), .changedOutside)
        // A signature that isn't an object, or the wrong algorithm, never reads as unsigned.
        try writeSigned([grant()])
        try edit { $0["signature"] = "trust me" }
        XCTAssertEqual(try protection(), .changedOutside)
        XCTAssertEqual(try protection(AgentGrantNoKey()), .keyMissing)
        try writeSigned([grant()])
        try edit { object in
            var signature = object["signature"] as? [String: Any] ?? [:]
            signature["algorithm"] = "none"
            object["signature"] = signature
        }
        XCTAssertEqual(try protection(), .changedOutside)
    }

    func testUnsignedFilesLoadUntilAKeyExists() throws {
        // A legacy file, as every earlier build wrote it.
        try AgentGrantFile(grants: [grant(access: .readCreate)]).write(to: grantsURL)
        XCTAssertEqual(try protection(), .unprotected)
        XCTAssertNil(loadError())
        XCTAssertNil(loadError(AgentGrantNoKey()))
        // The owner protects grants (the key now exists): a plain write without signing is refused from then on,
        // including swapping the signed file back for an unsigned one.
        try writeSigned([grant()])
        XCTAssertEqual(try protection(), .protected)
        try AgentGrantFile(grants: [grant(access: .readCreate)]).write(to: grantsURL)
        XCTAssertEqual(try protection(), .changedOutside)
        XCTAssertEqual(loadError(), "invalid_grants_signature")
        try edit { $0.removeValue(forKey: "signature") }
        XCTAssertEqual(loadError(), "invalid_grants_signature")
        try edit { $0["signature"] = NSNull() }
        XCTAssertEqual(loadError(), "invalid_grants_signature")
    }

    func testMissingKeyAndUnreadableKeychain() throws {
        try writeSigned([grant()])
        keys.removeKey()
        XCTAssertEqual(try protection(), .keyMissing)
        XCTAssertEqual(loadError(), "grants_key_missing")
        // A keychain that can't be read: signed or unsigned, the file fails closed.
        let failing = AgentGrantMemoryKeys(hasKey: true)
        failing.fails = true
        XCTAssertEqual(try protection(failing), .keyUnreadable)
        XCTAssertEqual(loadError(failing), "grants_key_unreadable")
        try AgentGrantFile(grants: [grant()]).write(to: grantsURL)
        XCTAssertEqual(try protection(failing), .keyUnreadable)
        XCTAssertEqual(loadError(failing), "grants_key_unreadable")
        // A missing file is empty: protected once a key exists, else unprotected.
        try FileManager.default.removeItem(at: grantsURL)
        XCTAssertEqual(
            try AgentGrantSigning.inspect(grantsURL, keys: AgentGrantMemoryKeys(hasKey: true)).protection, .protected)
        XCTAssertEqual(try AgentGrantSigning.inspect(grantsURL, keys: AgentGrantNoKey()).protection, .unprotected)
    }

    func testStoreReverifiesWhenTheFileIsReplaced() throws {
        try writeSigned([grant()])
        let store = AgentGrantStore(url: grantsURL, keys: keys)
        XCTAssertEqual(try store.load().grants.first?.access, .read)
        try editGrant { $0["access"] = "read-create" }
        XCTAssertThrowsError(try store.load()) {
            XCTAssertEqual(($0 as? AgentAccessError)?.code, "invalid_grants_signature")
        }
    }

    // MARK: Agent paths

    func testCLIAndMCPRefuseTamperedGrantsAndNeverSign() throws {
        AgentGrantKeys.verifier = keys
        try writeSigned([grant()])
        XCTAssertEqual(keys.signCount, 1)
        let capabilities = cli(["memory", "capabilities", "--grant", "Silkweb"])
        XCTAssertEqual(capabilities.status, 0, capabilities.stdout)

        try editGrant {
            $0["access"] = "read-create"
            $0["extra_read_folders"] = ["Notes/Private"]
        }
        let before = try Data(contentsOf: grantsURL)
        let read = cli(["memory", "read", "Notes/Private/Diary.md", "--grant", "Silkweb"])
        XCTAssertEqual(read.status, 77)
        XCTAssertEqual(code(read), "invalid_grants_signature")
        XCTAssertTrue(
            read.stderr.contains(
                "Agent grants failed verification, so no grant is in effect. Ask the owner to review them in Silkweb."),
            read.stderr)
        let create = cli(
            [
                "memory", "create", "--grant", "Silkweb", "--folder", "memories", "--title", "Widened", "--body-file",
                "-", "--agent", "codex", "--session", "s",
            ], stdin: "Body.")
        XCTAssertEqual(code(create), "invalid_grants_signature")
        // Asking for access works without a grant and never touches the grants file.
        let request = AgentGrantInit.run(
            [
                "grant", "request", "--library", library.path, "--project", "Silkweb", "--access", "read-create",
                "--requests", requestsURL.path,
            ], console: console(terminal: false).0, home: root, executable: nil, currentDirectory: root.path,
            now: now, signer: keys)
        XCTAssertEqual(request.status, 0, request.stderr)

        // MCP: the session's store holds a verifier, never a signer.
        let store = AgentGrantStore(url: grantsURL)
        XCTAssertTrue(store.keys is AgentGrantMemoryKeys)
        let session = AgentSession(project: "Silkweb", store: store)
        XCTAssertThrowsError(try session.authorize(.read, path: "Notes/Private/Diary.md")) {
            XCTAssertEqual(($0 as? AgentAccessError)?.code, "invalid_grants_signature")
        }
        XCTAssertThrowsError(try session.authorize(.create, path: "Memory/Projects/Silkweb/Memories/A.md"))

        XCTAssertEqual(keys.signCount, 1, "no agent path signed")
        XCTAssertEqual(try Data(contentsOf: grantsURL), before, "no agent path wrote the grants file")
    }

    func testUnreadableKeychainRefusesAStrippedAndWidenedFile() throws {
        // The owner protected grants; an agent strips the signature, widens its grant and runs where the keychain
        // can't be read (a sandbox, SSH, a locked keychain).
        try writeSigned([grant()])
        try edit { $0.removeValue(forKey: "signature") }
        try editGrant {
            $0["access"] = "read-create"
            $0["extra_read_folders"] = ["Notes/Private"]
        }
        keys.fails = true
        AgentGrantKeys.verifier = keys
        let message = "Silkweb can’t check whether agent grants are protected. Run it from your normal login session."

        XCTAssertEqual(try protection(), .keyUnreadable)
        XCTAssertEqual(loadError(), "grants_key_unreadable")
        let read = cli(["memory", "read", "Notes/Private/Diary.md", "--grant", "Silkweb"])
        XCTAssertEqual(read.status, 77)
        XCTAssertEqual(code(read), "grants_key_unreadable")
        XCTAssertTrue(read.stderr.contains(message), read.stderr)
        let create = cli(
            [
                "memory", "create", "--grant", "Silkweb", "--folder", "memories", "--title", "Widened", "--body-file",
                "-", "--agent", "codex", "--session", "s",
            ], stdin: "Body.")
        XCTAssertEqual(code(create), "grants_key_unreadable")
        let session = AgentSession(project: "Silkweb", store: AgentGrantStore(url: grantsURL))
        XCTAssertThrowsError(try session.authorize(.read, path: "Notes/Private/Diary.md")) {
            XCTAssertEqual(($0 as? AgentAccessError)?.code, "grants_key_unreadable")
        }
        XCTAssertEqual(AgentHelper.exitStatus(for: "grants_key_unreadable"), 77)

        // A deleted file can't be told apart from no grants yet, so it isn't treated as unprotected either.
        try FileManager.default.removeItem(at: grantsURL)
        XCTAssertEqual(try AgentGrantSigning.inspect(grantsURL, keys: keys).protection, .keyUnreadable)

        // The keychain readable again with no key yet: an unsigned file loads as it always has.
        keys.fails = false
        keys.removeKey()
        try AgentGrantFile(grants: [grant()]).write(to: grantsURL)
        XCTAssertEqual(try protection(), .unprotected)
        XCTAssertNil(loadError())
    }

    // MARK: grant init

    func testGrantInitSignsTheFirstGrantAndAsksBeforeProtectingExistingOnes() throws {
        // Protecting is for the real grants file (under the test's home); `--grants` names it explicitly.
        grantsURL = AgentGrantFile.defaultURL(home: root)
        // A fresh file: the first grant is protected from the start.
        let first = grantCommand(initFlags(), terminal: true, answers: ["y"])
        XCTAssertEqual(first.output.status, 0, first.output.stderr)
        XCTAssertFalse(first.prompts.contains("Protect them?"))
        XCTAssertTrue(first.output.stdout.contains(AgentGrantInit.protectedNote), first.output.stdout)
        XCTAssertEqual(try protection(), .protected)

        // An unsigned file with grants: init lists them and asks.
        try FileManager.default.removeItem(at: grantsURL)
        keys.removeKey()
        try AgentGrantFile(grants: [grant("Coffee", label: "Coffee notes")]).write(to: grantsURL)
        let declined = grantCommand(initFlags(), terminal: true, answers: ["n"])
        XCTAssertEqual(declined.output.status, 0, declined.output.stderr)
        XCTAssertTrue(declined.prompts.contains("This also protects 1 existing grant:\n  Coffee notes  Read Only"))
        XCTAssertTrue(declined.prompts.hasSuffix("Protect them? [y/N] "), declined.prompts)
        XCTAssertNil(try json()["signature"], "declining keeps the file unsigned")
        XCTAssertEqual(try protection(), .unprotected)
        XCTAssertEqual(try AgentGrantOwner.load(grantsURL).grants.count, 2)

        let accepted = grantCommand(initFlags("Novel"), terminal: true, answers: ["y"])
        XCTAssertEqual(accepted.output.status, 0, accepted.output.stderr)
        XCTAssertTrue(accepted.prompts.contains("This also protects 2 existing grants:"))
        XCTAssertEqual(try protection(), .protected)
        XCTAssertEqual(
            try AgentGrantStore(url: grantsURL, keys: keys).load().grants.map(\.project),
            [
                "Coffee", "Silkweb", "Novel",
            ])

        // Protected now: a narrowing re-signs without asking.
        let narrowed = grantCommand(initFlags("Novel", access: "read"), terminal: true)
        XCTAssertEqual(narrowed.output.status, 0, narrowed.output.stderr)
        XCTAssertFalse(narrowed.prompts.contains("Protect them?"))
        XCTAssertEqual(try protection(), .protected)
    }

    func testGrantInitNeverProtectsAScratchGrantsFile() throws {
        // A `--grants` file that isn't the real one never makes the key, which would protect (and so stop) the real
        // unsigned grants.
        let scratch = grantCommand(initFlags(), terminal: true, answers: ["y"])
        XCTAssertEqual(scratch.output.status, 0, scratch.output.stderr)
        XCTAssertFalse(scratch.prompts.contains("Protect them?"))
        XCTAssertFalse(scratch.output.stdout.contains(AgentGrantInit.protectedNote))
        XCTAssertNil(try json()["signature"])
        XCTAssertEqual(keys.signCount, 0)
        XCTAssertNil(try keys.verificationKey())
        XCTAssertEqual(try protection(), .unprotected)
    }

    func testGrantInitNeverSignsWithoutATerminalAndRefusesGrantsThatNeedReview() throws {
        // Without a terminal, the signer is dropped: an unsigned file stays unsigned and no key is made.
        let unsigned = grantCommand(initFlags(), terminal: false)
        XCTAssertEqual(unsigned.output.status, 0, unsigned.output.stderr)
        XCTAssertNil(try json()["signature"])
        XCTAssertEqual(keys.signCount, 0)
        XCTAssertNil(try keys.verificationKey())

        // Once protected, a non-terminal write would leave an unsigned file: refused, nothing saved.
        try writeSigned([grant()])
        let signedBefore = try Data(contentsOf: grantsURL)
        let refused = grantCommand(initFlags("Novel"), terminal: false)
        XCTAssertEqual(refused.output.status, 77)
        XCTAssertEqual(
            refused.output.stderr,
            "silkweb: Agent grants are protected, so saving them needs Terminal. Nothing was saved.\n")
        XCTAssertEqual(try Data(contentsOf: grantsURL), signedBefore)

        // Changed outside Silkweb or the key gone: refused before any question, even in Terminal.
        try editGrant { $0["access"] = "read-create" }
        let tampered = grantCommand(["init", "--library", library.path], terminal: true, answers: ["Novel", "1"])
        XCTAssertEqual(tampered.output.status, 77)
        XCTAssertEqual(tampered.prompts, "")
        XCTAssertTrue(
            tampered.output.stderr.contains(
                "Agent grants were changed outside Silkweb. Review them in Silkweb’s Agent Access window."))
        try writeSigned([grant()])
        keys.removeKey()
        let missing = grantCommand(initFlags("Novel"), terminal: true)
        XCTAssertEqual(missing.output.status, 77)
        XCTAssertTrue(missing.output.stderr.contains("can’t find the key that protects agent grants"))
    }

    // MARK: grant approve

    private func submit(project: String = "Novel", access: String = "read") throws -> String {
        let store = AgentAccessRequestStore(url: requestsURL)
        let draft = try AgentAccessRequests.draft(
            library: library.path, project: project, access: access, readFolders: [], message: nil, agent: "codex",
            session: "s", client: "cli", currentDirectory: root.path)
        return try store.submit(draft, now: now).request.requestId
    }

    private func approve(_ id: String, terminal: Bool) -> AgentHelper.Output {
        let (console, _) = console(terminal: terminal, answers: ["y"])
        return AgentGrantInit.run(
            ["grant", "approve", id, "--grants", grantsURL.path, "--requests", requestsURL.path], console: console,
            home: root, executable: nil, currentDirectory: root.path, now: now, signer: keys)
    }

    func testTerminalApproveReSignsProtectedGrantsAndOtherwiseRefuses() throws {
        try writeSigned([grant()])
        let first = try submit()
        // Without a terminal (test files only; the real ones need Terminal anyway): refused, request still waiting.
        let refused = approve(first, terminal: false)
        XCTAssertEqual(refused.status, 77, refused.stderr)
        XCTAssertTrue(refused.stderr.contains("needs Terminal"), refused.stderr)
        XCTAssertEqual(try AgentAccessRequestStore(url: requestsURL).pending(first, now: now).requestId, first)
        XCTAssertEqual(keys.signCount, 1)

        let approved = approve(first, terminal: true)
        XCTAssertEqual(approved.status, 0, approved.stderr)
        XCTAssertEqual(try protection(), .protected)
        XCTAssertEqual(
            try AgentGrantStore(url: grantsURL, keys: keys).load().grants.map(\.project), ["Silkweb", "Novel"])

        // Changed outside Silkweb: approving is refused and the request stays pending.
        let second = try submit(project: "Coffee")
        try editGrant { $0["access"] = "read-create" }
        let tampered = approve(second, terminal: true)
        XCTAssertEqual(tampered.status, 77)
        XCTAssertTrue(tampered.stderr.contains("changed outside Silkweb"), tampered.stderr)
        XCTAssertEqual(try AgentAccessRequestStore(url: requestsURL).pending(second, now: now).requestId, second)
    }

    func testApproveNeverProtectsUnsignedGrantsOnItsOwn() throws {
        try AgentGrantFile(grants: [grant()]).write(to: grantsURL)
        let id = try submit()
        let approved = approve(id, terminal: true)
        XCTAssertEqual(approved.status, 0, approved.stderr)
        XCTAssertNil(try json()["signature"])
        XCTAssertEqual(keys.signCount, 0)
        // The app's approve, after authentication, into protected grants signs.
        try writeSigned([grant()])
        let next = try submit(project: "Coffee")
        _ = try AgentAccessRequestStore(url: requestsURL).decide(
            next, approve: true, via: .app, grantsURL: grantsURL, now: now, signer: keys)
        XCTAssertEqual(try protection(), .protected)
    }

    // MARK: The app's owner paths

    func testOwnerSavesSignAndNarrowingNeedsNoAuthentication() throws {
        try writeSigned([grant(access: .readCreate), grant("Coffee")])
        var edited = grant(access: .read, label: "Silkweb repo")
        try AgentGrantOwner.save(
            edited, replacing: grant(access: .readCreate), in: grantsURL, authenticated: false, keys: keys)
        XCTAssertEqual(try protection(), .protected)
        try AgentGrantOwner.setPaused(
            true, project: "Coffee", in: grantsURL, authenticated: false, now: now, keys: keys)
        XCTAssertEqual(try protection(), .protected)
        try AgentGrantOwner.remove(project: "Coffee", in: grantsURL, keys: keys)
        XCTAssertEqual(try protection(), .protected)

        // Widening needs authentication, then signs.
        let original = edited
        edited.access = .readCreateUpdate
        XCTAssertThrowsError(
            try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: false, keys: keys)
        ) { XCTAssertEqual($0 as? AgentGrantOwner.Failure, .needsAuthentication) }
        try AgentGrantOwner.save(edited, replacing: original, in: grantsURL, authenticated: true, keys: keys)
        XCTAssertEqual(try protection(), .protected)
        XCTAssertEqual(try AgentGrantStore(url: grantsURL, keys: keys).load().grants.first?.access, .readCreateUpdate)

        // Without a signer, protected grants can't be written at all.
        XCTAssertThrowsError(try AgentGrantOwner.remove(project: "Silkweb", in: grantsURL)) {
            XCTAssertEqual($0 as? AgentGrantOwner.Failure, .needsReview)
        }
        AgentGrantKeys.verifier = keys
        XCTAssertThrowsError(try AgentGrantOwner.remove(project: "Silkweb", in: grantsURL)) {
            XCTAssertEqual($0 as? AgentGrantOwner.Failure, .signingFailed)
        }
        XCTAssertEqual(try protection(), .protected)
    }

    func testSigningSaveOnlyReSignsPureNarrowingsWithoutAuthentication() throws {
        try writeSigned([grant(access: .readCreate)])
        let current = try AgentGrantSigning.inspect(grantsURL, keys: keys)
        var wider = current.file
        wider.grants[0].extraReadFolders = ["Notes/Private"]
        XCTAssertThrowsError(
            try AgentGrantSigning.save(wider, to: grantsURL, current: current, signer: keys, authenticated: false)
        ) { XCTAssertEqual(($0 as? AgentAccessError)?.code, "needs_authentication") }
        var added = current.file
        added.grants.append(grant("Coffee"))
        XCTAssertFalse(AgentGrantSigning.isNarrowing(from: current.file, to: added))
        var narrower = current.file
        narrower.grants[0].access = .read
        XCTAssertTrue(AgentGrantSigning.isNarrowing(from: current.file, to: narrower))
        XCTAssertTrue(AgentGrantSigning.isNarrowing(from: current.file, to: AgentGrantFile()))
        try AgentGrantSigning.save(narrower, to: grantsURL, current: current, signer: keys, authenticated: false)
        XCTAssertEqual(try protection(), .protected)
        XCTAssertThrowsError(
            try AgentGrantSigning.save(narrower, to: grantsURL, current: current, signer: nil, authenticated: true)
        ) { XCTAssertEqual(($0 as? AgentAccessError)?.code, "grants_signing_required") }
    }

    func testOwnerRefusesChangesWhileGrantsNeedReviewAndAdoptKeepsOnlyCheckedGrants() throws {
        try writeSigned([grant(), grant("Coffee")])
        try editGrant { $0["access"] = "read-create" }
        XCTAssertThrowsError(try AgentGrantOwner.remove(project: "Coffee", in: grantsURL, keys: keys)) {
            XCTAssertEqual($0 as? AgentGrantOwner.Failure, .needsReview)
        }
        XCTAssertThrowsError(
            try AgentGrantOwner.setPaused(true, project: "Coffee", in: grantsURL, authenticated: false, keys: keys)
        ) { XCTAssertEqual($0 as? AgentGrantOwner.Failure, .needsReview) }
        XCTAssertThrowsError(try AgentGrantOwner.load(grantsURL, keys: keys))

        // Review Grants…: the owner unchecks the tampered grant and signs the rest.
        let reviewed = try AgentGrantOwner.inspect(grantsURL, keys: keys)
        XCTAssertEqual(reviewed.protection, .changedOutside)
        XCTAssertEqual(reviewed.file.grants.count, 2, "the window still shows every grant on disk")
        try AgentGrantOwner.adopt(keeping: ["Coffee"], expected: reviewed.file, in: grantsURL, keys: keys)
        XCTAssertEqual(try protection(), .protected)
        XCTAssertEqual(try AgentGrantStore(url: grantsURL, keys: keys).load().grants.map(\.project), ["Coffee"])

        // Key lost: Review Grants… makes a new key and re-signs.
        keys.removeKey()
        XCTAssertEqual(try protection(), .keyMissing)
        let lost = try AgentGrantOwner.inspect(grantsURL, keys: keys)
        try AgentGrantOwner.adopt(keeping: ["Coffee"], expected: lost.file, in: grantsURL, keys: keys)
        XCTAssertEqual(try protection(), .protected)

        // The file changed while the owner reviewed it: nothing is written.
        let stale = try AgentGrantOwner.inspect(grantsURL, keys: keys).file
        try writeSigned([grant("Coffee"), grant("Novel")])
        XCTAssertThrowsError(try AgentGrantOwner.adopt(keeping: ["Coffee"], expected: stale, in: grantsURL, keys: keys))
        {
            XCTAssertEqual($0 as? AgentGrantOwner.Failure, .reviewChanged)
        }
        XCTAssertThrowsError(try AgentGrantOwner.adopt(keeping: [], expected: stale, in: grantsURL, keys: nil)) {
            XCTAssertEqual($0 as? AgentGrantOwner.Failure, .signingFailed)
        }
    }

    func testFirstAuthenticatedGrantIsProtectedAndUnsignedFilesStayUnsigned() throws {
        try AgentGrantOwner.save(grant(), replacing: nil, in: grantsURL, authenticated: true, keys: keys)
        XCTAssertEqual(try protection(), .protected, "a first grant is protected from the start")
        XCTAssertEqual(keys.signCount, 1)

        try FileManager.default.removeItem(at: grantsURL)
        keys.removeKey()
        try AgentGrantFile(grants: [grant()]).write(to: grantsURL)
        try AgentGrantOwner.save(grant("Coffee"), replacing: nil, in: grantsURL, authenticated: true, keys: keys)
        try AgentGrantOwner.setPaused(true, project: "Coffee", in: grantsURL, authenticated: false, keys: keys)
        XCTAssertNil(try json()["signature"], "existing unsigned grants are protected only after review")
        XCTAssertEqual(keys.signCount, 1, "nothing more was signed")
    }

    func testChangeSummaries() {
        let verified = grant(revoked: now)
        var changed = verified
        changed.access = .readCreate
        changed.extraReadFolders = ["Notes/Private"]
        changed.revokedAt = nil
        XCTAssertEqual(
            AgentGrantOwner.changeSummary(from: verified, to: changed),
            "Changed: access raised to Read and Create; read folder added: “Notes › Private”; resumed")
        XCTAssertNil(AgentGrantOwner.changeSummary(from: verified, to: verified))
        var relabelled = verified
        relabelled.label = "Other"
        XCTAssertEqual(AgentGrantOwner.changeSummary(from: verified, to: relabelled), "Changed: narrowed or relabelled")
        XCTAssertEqual(AgentGrantOwner.changeSummary(from: nil, to: verified), "Added outside Silkweb")
    }

    func testExitStatusesForTheNewCodes() {
        for code in ["invalid_grants_signature", "grants_key_missing", "grants_signing_required"] {
            XCTAssertEqual(AgentHelper.exitStatus(for: code), 77, code)
        }
        XCTAssertEqual(AgentHelper.exitStatus(for: "grants_signing_failed"), 74)
    }
}

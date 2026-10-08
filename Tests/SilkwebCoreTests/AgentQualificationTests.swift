import Darwin
import XCTest

@testable import SilkwebCore

/// #139: MVP qualification of agent memory. Concurrency between cooperating writers, helper failures
/// (disk full, permission denied, crashes mid-publication) and several helper processes at once. Every
/// scenario is listed in `docs/agent-memory-qualification.md`.
final class AgentQualificationTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private let project = "Memory/Projects/Silkweb"
    /// 2026-10-07 09:30:00 UTC.
    private let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    private struct Crash: Error {}

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentQualification-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(project + "/Memories"), withIntermediateDirectories: true)
        library = library.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        // Permission scenarios leave read-only Folders behind when an assertion fails.
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            while let path = walker.nextObject() as? String {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(path).path)
            }
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func service(fault: (@Sendable (AgentCreateService.Step) throws -> Void)? = nil) throws
        -> AgentCreateService
    {
        let grant = AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path))
        var service = AgentCreateService(
            library: library, grantId: "Silkweb", scope: try AgentScope(grant: grant),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        let date = fixedDate
        service.now = { date }
        service.timeZone = TimeZone(identifier: "UTC")!
        service.fault = fault
        return service
    }

    private func request(key: String = "key-1", title: String = "Helper spike") -> AgentCreateRequest {
        AgentCreateRequest(
            idempotencyKey: key, type: "progress", title: title, body: "Objective: qualify the MVP.",
            agent: "claude-code", session: "s-1")
    }

    private func url(_ path: String) -> URL { library.appendingPathComponent(path) }
    private func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url(folder).path)) ?? []).sorted()
    }

    /// Every path outside `.silkweb/`: what the sidebar, list, search and Finder can see.
    private func visibleTree() throws -> [String] {
        let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: library.path))
        return walker.compactMap { $0 as? String }.filter { !$0.hasPrefix(".silkweb") }.sorted()
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

    /// Runs `body` on its own thread, the way a second process would, and reports whether it finished.
    private final class Competitor<Value>: @unchecked Sendable {
        private let finished = DispatchSemaphore(value: 0)
        private(set) var result: Result<Value, Error>?
        private var done = false

        init(_ body: @escaping @Sendable () throws -> Value) {
            Thread {
                self.result = Result { try body() }
                self.finished.signal()
            }.start()
        }

        @discardableResult
        func wait(_ seconds: Double) -> Bool {
            if done { return true }
            done = finished.wait(timeout: .now() + seconds) == .success
            return done
        }
    }

    private final class Box<Value>: @unchecked Sendable { var value: Value? }

    // MARK: Concurrency regressions (#131, #133)

    /// Regression: a retry from a second helper session arrives while the first create of the same key is
    /// between its journal and its publish. Without the create holding the Library gate (#131 in #133), the
    /// retry's recovery abandoned the live attempt's staged file and published a second copy.
    func testRetryRacingAnInFlightCreateOfTheSameKeyPublishesOnce() throws {
        let retry = Box<Competitor<AgentCreateResult>>()
        let racing = request()
        let second = try service()
        let first = try service(fault: { step in
            guard step == .intent, retry.value == nil else { return }
            let competitor = Competitor { try second.create(racing) }
            retry.value = competitor
            competitor.wait(0.5)
        })
        let original = Result { try first.create(racing) }
        let competitor = try XCTUnwrap(retry.value)
        XCTAssertTrue(competitor.wait(5), "the retry must finish once the first create releases the gate")
        let created = try original.get()
        let replayed = try XCTUnwrap(competitor.result).get()
        XCTAssertFalse(created.replayed)
        XCTAssertTrue(replayed.replayed, "the retry is a replay of the in-flight create")
        XCTAssertEqual(replayed.receipt, created.receipt)
        XCTAssertEqual(names(project + "/Progress"), ["2026-10-07 0930 — Helper spike.md"], "one row, no “ 2” copy")
        XCTAssertEqual(names(".silkweb/agent-staging"), [])
    }

    /// Regression: the owner adds a Tag in the app while a helper create is waiting to record its identity.
    /// Without the gate around the helper's index write, one of the two commits overwrote the other.
    func testAppTagCommitDuringHelperCreateKeepsTheTagAndTheNewIdentity() async throws {
        let owner = UUID()
        try LibraryMetadataStore.save(
            LibraryMetadata(IDsByPath: ["": UUID(), project + "/Memories/Owner.md": owner]), root: library)
        try Data("# Owner\n".utf8).write(to: url(project + "/Memories/Owner.md"))
        let helper = try service()
        let request = request()
        let race = Box<Competitor<AgentCreateResult>>()
        _ = try await TagStore.update(root: library) { metadata in
            if race.value == nil {
                // The helper's create while the app is between its read and its write of the index.
                let competitor = Competitor { try helper.create(request) }
                race.value = competitor
                competitor.wait(0.5)
            }
            return TagEditor.add(["owner"], documents: [owner], metadata: metadata)
        }
        let competitor = try XCTUnwrap(race.value)
        XCTAssertTrue(competitor.wait(5))
        let created = try XCTUnwrap(competitor.result).get()
        let index = try LibraryMetadataStore.load(root: library).0
        let path = try XCTUnwrap(created.path)
        XCTAssertEqual(index.IDsByPath[path], created.receipt.documentId, "the helper's identity survived")
        let ownerTags = Set(
            index.tags.filter { (index.tagsByDocument[owner.uuidString] ?? []).contains($0.id) }.map(\.name))
        XCTAssertEqual(ownerTags, ["owner"], "the owner's Tag survived")
    }

    // MARK: Failures

    func testDiskFullBeforePublishCreatesNothingAndCanBeRetried() throws {
        for code in [ENOSPC, EDQUOT] {
            let key = "full-\(code)"
            let full = try service(fault: {
                if $0 == .stage { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            })
            XCTAssertThrowsError(try full.create(request(key: key))) { error in
                XCTAssertEqual(error as? AgentAccessError, .diskFull)
            }
            XCTAssertEqual(try visibleTree(), ["Memory", "Memory/Projects", project, project + "/Memories"])
            XCTAssertEqual(names(".silkweb/agent-staging"), [], "no partial or temporary file is left")
            XCTAssertNil(try service().receipt(try service().operationID(key)), "nothing to replay")
        }
        XCTAssertEqual(AgentAccessError.diskFull.message, "There isn’t enough space on the disk. Nothing was created.")
        XCTAssertEqual(AgentAccessError.diskFull.title, "Can’t Create Document")
        let output = AgentHelper.refusal(.diskFull)
        XCTAssertEqual(output.status, 74)
        XCTAssertTrue(output.stdout.contains(#""code":"disk_full""#), output.stdout)
        XCTAssertEqual(output.stderr, "silkweb: There isn’t enough space on the disk. Nothing was created.\n")

        // Space is freed: the same key creates the document.
        let retry = try service().create(request(key: "full-\(ENOSPC)"))
        XCTAssertEqual(retry.outcome, .created)
        XCTAssertEqual(names(project + "/Progress").count, 1)
    }

    func testPermissionDeniedCreatesNothingAndCanBeRetried() throws {
        guard geteuid() != 0 else { throw XCTSkip("root ignores Folder permissions") }
        let progress = url(project + "/Progress")
        try FileManager.default.createDirectory(at: progress, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: progress.path)
        XCTAssertEqual(code { try self.service().create(self.request()) }, "permission_denied")
        XCTAssertEqual(names(project + "/Progress"), [])
        XCTAssertEqual(names(".silkweb/agent-staging"), [], "the staged file is discarded")
        let abandoned = try XCTUnwrap(try service().receipt(try service().operationID("key-1")))
        XCTAssertEqual(abandoned.outcome, .abandoned, "recorded as never published")

        // `.silkweb/` itself can't be written: nothing is staged or published.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: progress.path)
        try FileManager.default.removeItem(at: url(".silkweb"))
        try FileManager.default.createDirectory(at: url(".silkweb"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: url(".silkweb").path)
        XCTAssertEqual(code { try self.service().create(self.request(key: "key-2")) }, "permission_denied")
        XCTAssertEqual(names(project + "/Progress"), [])
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url(".silkweb").path)

        XCTAssertEqual(
            AgentAccessError.permissionDenied.message,
            "Silkweb doesn’t have permission to write to this Library. Nothing was created.")
        XCTAssertEqual(AgentHelper.refusal(.permissionDenied).status, 74)

        // Permission restored: the abandoned key is simply retried.
        let retry = try service().create(request())
        XCTAssertFalse(retry.replayed)
        XCTAssertEqual(retry.outcome, .created)
        XCTAssertEqual(names(project + "/Progress").count, 1)
    }

    /// A crash at every step of the publication: before publish nothing is visible; after it exactly one
    /// Document is. The app's next scan shows no recovery strip and never lists `.silkweb/`, and the next
    /// create settles the journal silently.
    func testCrashMidPublicationIsInvisibleToTheAppAndSettlesOnTheNextCreate() async throws {
        let steps: [(AgentCreateService.Step, Bool)] = [
            (.intent, false), (.published, true), (.indexed, true), (.receipt, true),
        ]
        for (step, published) in steps {
            try? FileManager.default.removeItem(at: library)
            try FileManager.default.createDirectory(at: url(project + "/Memories"), withIntermediateDirectories: true)
            XCTAssertThrowsError(try service(fault: { if $0 == step { throw Crash() } }).create(request()))

            // The app opens the Library: an ordinary scan, which writes the index.
            let snapshot = try await LibraryScanner.scan(root: library)
            XCTAssertFalse(snapshot.metadataWasReset, "\(step): no recovery strip")
            XCTAssertNil(snapshot.recoveredMetadataURL, "\(step)")
            XCTAssertFalse(snapshot.documents.contains { $0.relativePath.hasPrefix(".silkweb") }, "\(step)")
            XCTAssertFalse(snapshot.folders.contains { $0.relativePath.hasPrefix(".silkweb") }, "\(step)")
            XCTAssertEqual(snapshot.documents.count, published ? 1 : 0, "\(step)")
            if published {
                // The scan learned the document before the helper recorded it: still one identity.
                XCTAssertEqual(
                    snapshot.documents.first?.relativePath, project + "/Progress/2026-10-07 0930 — Helper spike.md")
            }

            // Another session's create recovers first, then the retry replays or creates exactly once.
            _ = try service().create(request(key: "other", title: "Other session"))
            XCTAssertEqual(names(".silkweb/agent-staging"), [], "\(step)")
            let retry = try service().create(request())
            XCTAssertEqual(retry.replayed, published, "\(step)")
            XCTAssertEqual(names(project + "/Progress").count, 2, "\(step): one Document per key")
            let rescanned = try await LibraryScanner.scan(root: library, previousSnapshot: snapshot)
            XCTAssertEqual(
                rescanned.metadata.IDsByPath[try XCTUnwrap(retry.path)], retry.receipt.documentId,
                "\(step): the receipt and the app agree on the identity")
        }
    }

    // MARK: Several helper processes

    /// Six helper processes create at once, each also retrying one shared key, while the app keeps adding
    /// Tags. Every Document appears exactly once, every Tag and identity survives, and the receipts match.
    func testParallelHelperProcessesKeepDocumentsTagsAndReceipts() async throws {
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("SilkwebHelper")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("SilkwebHelper isn't built next to the test bundle")
        }
        let grants = root.appendingPathComponent("agent-grants.json")
        try Data(
            """
            {"version":1,"grants":[{"project":"Silkweb","library":{"path":"\(library.path)"},"access":"read-create",
            "limits":{"requests_per_minute":1000}}]}
            """.utf8
        ).write(to: grants)
        let body = root.appendingPathComponent("body.md")
        try Data("Checkpoint from a parallel session.".utf8).write(to: body)
        let owner = UUID()
        let ownerPath = project + "/Memories/Owner.md"
        try Data("# Owner\n".utf8).write(to: url(ownerPath))
        try LibraryMetadataStore.save(LibraryMetadata(IDsByPath: ["": UUID(), ownerPath: owner]), root: library)

        let lanes = 6
        let steps = 3
        final class Outputs: @unchecked Sendable {
            private let lock = NSLock()
            private var values: [(key: String, status: Int32, stdout: String)] = []
            func append(_ value: (String, Int32, String)) { lock.withLock { values.append(value) } }
            var all: [(key: String, status: Int32, stdout: String)] { lock.withLock { values } }
        }
        let outputs = Outputs()
        let library = library!
        let project = project
        @Sendable func run(_ key: String, title: String, lane: Int) {
            let process = Process()
            process.executableURL = binary
            process.arguments = [
                "memory", "create", "--grants", grants.path, "--folder", "memories", "--title", title,
                "--idempotency-key", key, "--agent", "qualification", "--session", "parallel",
                "--client", "lane-\(key == "shared" ? 0 : lane)", "--body-file", body.path,
            ]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = Pipe()
            do { try process.run() } catch {
                outputs.append((key, -1, "\(error)"))
                return
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            outputs.append((key, process.terminationStatus, String(decoding: data, as: UTF8.self)))
        }
        let helpers = Task.detached {
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                for step in 0..<steps {
                    // Every lane retries the shared key between its own creates.
                    run("shared", title: "Shared checkpoint", lane: lane)
                    run("lane-\(lane)-\(step)", title: "Lane \(lane) step \(step)", lane: lane)
                }
            }
        }
        // The owner keeps tagging in the app while the helpers run.
        for round in 0..<20 {
            _ = try await TagStore.update(root: library) {
                TagEditor.add(["tag \(round)"], documents: [owner], metadata: $0)
            }
        }
        await helpers.value

        let all = outputs.all
        XCTAssertEqual(all.count, lanes * steps * 2)
        for output in all { XCTAssertEqual(output.status, 0, output.stdout) }
        let results = try all.map { output -> (key: String, result: [String: Any]) in
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: Any])
            return (output.key, try XCTUnwrap(json["result"] as? [String: Any], output.stdout))
        }
        let shared = results.filter { $0.key == "shared" }
        XCTAssertEqual(
            shared.filter { $0.result["replayed"] as? Bool == false }.count, 1, "the shared key created once")
        XCTAssertEqual(
            Set(shared.compactMap { $0.result["path"] as? String }), [project + "/Memories/Shared checkpoint.md"])

        let documents = names(project + "/Memories")
        let expected =
            ["Owner.md", "Shared checkpoint.md"]
            + (0..<lanes).flatMap { lane in (0..<steps).map { "Lane \(lane) step \($0).md" } }
        XCTAssertEqual(documents, expected.sorted(), "each create is one row, with no “ 2” copy from a retry")
        XCTAssertEqual(names(".silkweb/agent-staging"), [])

        let receipts = try names(".silkweb/agent-events").filter { $0.hasSuffix(".json") }.map {
            try JSONDecoder().decode(AgentReceipt.self, from: Data(contentsOf: url(".silkweb/agent-events/" + $0)))
        }
        XCTAssertEqual(receipts.count, 1 + lanes * steps)
        XCTAssertTrue(receipts.allSatisfy { $0.outcome == .created })
        let index = try LibraryMetadataStore.load(root: library).0
        for receipt in receipts {
            let destination = try XCTUnwrap(receipt.destination)
            XCTAssertEqual(index.IDsByPath[destination], receipt.documentId, destination)
        }
        let ownerTags = Set(
            index.tags.filter { (index.tagsByDocument[owner.uuidString] ?? []).contains($0.id) }.map(\.name))
        XCTAssertEqual(ownerTags, Set((0..<20).map { "tag \($0)" }), "every Tag the owner added survived")
        XCTAssertEqual(index.IDsByPath[ownerPath], owner)

        // The helper's activity and the app's Agent Activity count the same Documents.
        XCTAssertEqual(try service().activity(limit: 100).total, receipts.count)
        let snapshot = try await LibraryScanner.scan(root: library)
        XCTAssertEqual(AgentActivity.load(root: library).entries(in: snapshot).count, receipts.count)
        XCTAssertEqual(snapshot.documents.count, documents.count)
    }
}

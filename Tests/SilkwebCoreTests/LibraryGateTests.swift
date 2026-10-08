import Darwin
import XCTest

@testable import SilkwebCore

private final class ResultBox<T>: @unchecked Sendable { var result: Result<T, Error>? }

/// #131: the cross-process mutation gate. Each `LibraryGate` lease is its own open file, so two leases
/// in this process exclude each other exactly as the app and the `silkweb` helper do.
final class LibraryGateTests: XCTestCase {
    private var root: URL!
    private var recovery: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        recovery = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: recovery)
    }

    private func write(_ text: String, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func index() throws -> LibraryMetadata { try LibraryMetadataStore.load(root: root).0 }

    private func tagNames(_ document: UUID, in metadata: LibraryMetadata) -> Set<String> {
        let ids = metadata.tagsByDocument[document.uuidString] ?? []
        return Set(metadata.tags.filter { ids.contains($0.id) }.map(\.name))
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

    /// Runs async work to completion on the calling (non-cooperative) thread.
    private static func blocking<T>(_ body: @escaping @Sendable () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let finished = DispatchSemaphore(value: 0)
        Task.detached {
            do { box.result = .success(try await body()) } catch { box.result = .failure(error) }
            finished.signal()
        }
        finished.wait()
        return try box.result!.get()
    }

    // MARK: - The gate

    func testGateExcludesOtherHoldersUntilReleasedAndTimesOutAsBusy() throws {
        let gate = LibraryGate(root: root)
        let held = try XCTUnwrap(gate.tryAcquire())
        XCTAssertTrue(held.isExclusive)
        XCTAssertEqual(gate.lockURL.path, root.appendingPathComponent(".silkweb/library.lock").path)
        XCTAssertNil(try LibraryGate(root: root).tryAcquire(), "A second holder must wait")
        let started = ContinuousClock.now
        XCTAssertThrowsError(try gate.acquire(timeout: .milliseconds(150))) { error in
            XCTAssertEqual(error as? LibraryGateError, .busy(retryAfter: 1))
            XCTAssertEqual(
                error.localizedDescription,
                "Another Silkweb process is updating this library. Silkweb will try again.")
        }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - started, .milliseconds(150))
        held.release()
        held.release() // Idempotent.
        let next = try gate.acquire(timeout: .milliseconds(150))
        XCTAssertNil(next.staleHolder, "A clean release leaves no holder behind")
        next.release()
        // The lock file stays (empty) under `.silkweb`, which the watcher ignores; nothing else is created.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [".silkweb"])
        XCTAssertEqual(try Data(contentsOf: gate.lockURL), Data())
    }

    func testWaitingHolderGetsTheGateAsSoonAsItIsReleased() async throws {
        let gate = LibraryGate(root: root)
        let held = try XCTUnwrap(gate.tryAcquire())
        let waiter = Task { try await LibraryGate(root: root).acquire(timeout: .seconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        held.release()
        let lease = try await waiter.value
        XCTAssertTrue(lease.isExclusive)
        lease.release()
    }

    /// Crash recovery: the kernel drops the dead holder's lock, so nothing waits for a lease to expire.
    /// The pid it left behind is reported once as a stale takeover (diagnostics only).
    func testCrashedHolderProcessReleasesTheGateAndIsReportedAsStale() throws {
        let perl = URL(fileURLWithPath: "/usr/bin/perl")
        guard FileManager.default.isExecutableFile(atPath: perl.path) else { throw XCTSkip("perl is unavailable") }
        let gate = LibraryGate(root: root)
        try FileManager.default.createDirectory(
            at: gate.lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let holder = Process()
        holder.executableURL = perl
        holder.arguments = [
            "-e",
            """
            use Fcntl qw(:flock); use IO::Handle;
            open(my $f, '+>>', $ARGV[0]) or die; flock($f, LOCK_EX) or die;
            truncate($f, 0); print $f "$$\\n"; $f->flush;
            print "locked\\n"; STDOUT->flush; sleep 60;
            """,
            gate.lockURL.path,
        ]
        let output = Pipe()
        holder.standardOutput = output
        try holder.run()
        defer { if holder.isRunning { holder.terminate() } }
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        XCTAssertEqual(line, "locked\n")
        XCTAssertNil(try gate.tryAcquire(), "A live holder in another process excludes this one")
        XCTAssertThrowsError(try gate.acquire(timeout: .milliseconds(100)))
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        let lease = try gate.acquire(timeout: .milliseconds(500))
        XCTAssertEqual(lease.staleHolder, holder.processIdentifier)
        lease.release()
        XCTAssertNil(try gate.acquire(timeout: .milliseconds(100)).staleHolder, "Reported once, then cleared")
    }

    func testLeftoverPidWithoutALockIsTakenOverSilently() throws {
        let gate = LibraryGate(root: root)
        try FileManager.default.createDirectory(
            at: gate.lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("99999\n".utf8).write(to: gate.lockURL)
        let lease = try gate.acquire(timeout: .milliseconds(100))
        XCTAssertEqual(lease.staleHolder, 99999)
        XCTAssertEqual(try text(gate.lockURL), "\(getpid())\n")
        lease.release()
        XCTAssertEqual(try text(gate.lockURL), "")
    }

    func testReadOnlyLibraryGetsANonExclusiveLeaseAndNoLockFile() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        let lease = try XCTUnwrap(LibraryGate(root: root).tryAcquire())
        XCTAssertFalse(lease.isExclusive)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".silkweb").path))
    }

    func testLinkedSilkwebFolderIsRefused() throws {
        let elsewhere = recovery!
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".silkweb"), withDestinationURL: elsewhere)
        XCTAssertThrowsError(try LibraryGate(root: root).tryAcquire())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    // MARK: - Document replacement

    /// Regression (#131): another cooperating writer saved between this save's revision check and its
    /// replace. Before the gate both reported success and the other writer's text was silently lost.
    func testCooperatingReplacementCannotCommitBetweenRevisionCheckAndReplace() throws {
        let url = try write("original", "Note.md")
        let root = self.root!
        let base = try DocumentStore(root: root).load(url).revision
        final class Race: @unchecked Sendable { var competitor: Competitor<DocumentRevision>? }
        struct RacingFileSystem: DocumentFileSystem {
            let race: Race
            let root: URL
            let base: DocumentRevision
            let disk = DiskDocumentFileSystem()
            func read(_ url: URL) throws -> Data { try disk.read(url) }
            func stage(_ data: Data, at url: URL) throws { try disk.stage(data, at: url) }
            func replace(_ destination: URL, with staging: URL) throws {
                // The helper commits from the same base revision right after this save's check passed.
                let competitor = Competitor {
                    try DocumentStore(root: root).save("helper text", to: destination, expectedRevision: base)
                }
                race.competitor = competitor
                competitor.wait(0.5)
                try disk.replace(destination, with: staging)
            }
            func remove(_ url: URL) throws { try disk.remove(url) }
        }
        let race = Race()
        let store = DocumentStore(fileSystem: RacingFileSystem(race: race, root: root, base: base), root: root)
        let mine = Result { try store.save("app text", to: url, expectedRevision: base) }
        let competitor = try XCTUnwrap(race.competitor)
        XCTAssertTrue(competitor.wait(5), "The waiting writer must finish once the gate is released")
        let theirs = try XCTUnwrap(competitor.result)
        XCTAssertNoThrow(try mine.get())
        guard case .failure(DocumentStoreError.conflict) = theirs else {
            return XCTFail(
                "Both writers committed from one base revision; final text \(try text(url)) lost the other. "
                    + "Competitor: \(theirs)")
        }
        XCTAssertEqual(try text(url), "app text")
    }

    // MARK: - Metadata

    /// Regression (#131): a tag committed by the helper during the app's read-modify-write of
    /// `index.json` was overwritten by the app's stale copy (last writer wins).
    func testConcurrentTagCommitsPreserveIndependentFields() async throws {
        let (first, second) = (UUID(), UUID())
        try LibraryMetadataStore.save(
            LibraryMetadata(IDsByPath: ["": UUID(), "First.md": first, "Second.md": second]), root: root)
        let root = self.root!
        final class Box: @unchecked Sendable { var competitor: Competitor<LibraryMetadata>? }
        let box = Box()
        _ = try await TagStore.update(root: root) { metadata in
            if box.competitor == nil {
                // The helper's commit while the app is between its read and its write.
                let competitor = Competitor {
                    try Self.blocking {
                        try await TagStore.update(root: root) {
                            TagEditor.add(["helper"], documents: [second], metadata: $0)
                        }
                    }
                }
                box.competitor = competitor
                competitor.wait(0.5)
            }
            return TagEditor.add(["app"], documents: [first], metadata: metadata)
        }
        let competitor = try XCTUnwrap(box.competitor)
        XCTAssertTrue(competitor.wait(5))
        XCTAssertNoThrow(try XCTUnwrap(competitor.result).get())
        let saved = try index()
        XCTAssertEqual(tagNames(first, in: saved), ["app"])
        XCTAssertEqual(tagNames(second, in: saved), ["helper"], "The helper's tag must survive the app's commit")
    }

    /// App tag edits and helper creates, interleaved freely: every tag and every new ID survives.
    func testInterleavedAppTagEditsAndHelperCreatesLoseNothing() async throws {
        let document = UUID()
        try LibraryMetadataStore.save(LibraryMetadata(IDsByPath: ["": UUID(), "Note.md": document]), root: root)
        _ = try write("", "Note.md")
        let root = self.root!
        let helper = try LibraryMutations(root: root)
        let rounds = 20
        try await withThrowingTaskGroup(of: Void.self) { group in
            for round in 0..<rounds {
                group.addTask {
                    _ = try await TagStore.update(root: root) {
                        TagEditor.add(["tag \(round)"], documents: [document], metadata: $0)
                    }
                }
                group.addTask { _ = try await helper.createDocument(named: "Created \(round).md") }
            }
            try await group.waitForAll()
        }
        let saved = try index()
        XCTAssertEqual(tagNames(document, in: saved), Set((0..<rounds).map { "tag \($0)" }))
        for round in 0..<rounds { XCTAssertNotNil(saved.IDsByPath["Created \(round).md"], "Created \(round)") }
        XCTAssertEqual(saved.IDsByPath["Note.md"], document)
    }

    func testMutationsWaitForTheGateAndReportBusyWithTheOperationsAlert() async throws {
        let holder = try XCTUnwrap(LibraryGate(root: root).tryAcquire())
        let mutations = try LibraryMutations(root: root, gateTimeout: .milliseconds(150))
        do {
            _ = try await mutations.createFolder(named: "Drafts")
            XCTFail("Expected the busy failure")
        } catch let error as LibraryMutationError {
            XCTAssertEqual(error.errorDescription, "“Drafts” couldn’t be created.")
            XCTAssertEqual(
                error.recoverySuggestion, "Another Silkweb process is updating this library. Silkweb will try again.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Drafts").path))
        // Ordinary contention just waits.
        let waiting = Task { try await LibraryMutations(root: root).createFolder(named: "Drafts") }
        try await Task.sleep(for: .milliseconds(100))
        holder.release()
        let changes = try await waiting.value
        XCTAssertEqual(try index().IDsByPath["Drafts"], changes.changes.first?.id)
    }

    // MARK: - Scans

    /// The app scan enumerates outside the gate; if the index changed meanwhile it scans again rather
    /// than committing over the other writer's tags and IDs.
    func testScanRetriesAfterStaleSnapshotInsteadOfDroppingTheOtherWritersTag() async throws {
        _ = try write("", "Indexed.md")
        let first = try await LibraryScanner.scan(root: root)
        let indexed = try XCTUnwrap(first.documents.first).id
        _ = try write("", "New.md")
        let root = self.root!
        final class Attempts: @unchecked Sendable { var seen: [Int] = [] }
        let attempts = Attempts()
        let snapshot = try await LibraryScanner.scan(
            root: root, previousSnapshot: first, writesMetadata: true, progress: nil, gateTimeout: .seconds(5)
        ) { attempt in
            attempts.seen.append(attempt)
            guard attempt == 1 else { return }
            try? LibraryGate(root: root).withLease {
                let current = try LibraryMetadataStore.load(root: root).0
                try LibraryMetadataStore.save(
                    TagEditor.add(["helper"], documents: [indexed], metadata: current), root: root)
            }
        }
        XCTAssertEqual(attempts.seen, [1, 2])
        let saved = try index()
        XCTAssertEqual(tagNames(indexed, in: saved), ["helper"])
        XCTAssertEqual(tagNames(indexed, in: snapshot.metadata), ["helper"])
        let created = try XCTUnwrap(snapshot.documents.first { $0.relativePath == "New.md" })
        XCTAssertEqual(saved.IDsByPath["New.md"], created.id, "The retried scan commits its identities")
        XCTAssertEqual(saved.IDsByPath["Indexed.md"], indexed)
    }

    func testScanUnderSteadyChangeEnumeratesInsideTheGateOnItsLastAttempt() async throws {
        _ = try write("", "Indexed.md")
        let first = try await LibraryScanner.scan(root: root)
        let indexed = try XCTUnwrap(first.documents.first).id
        _ = try write("", "New.md")
        let root = self.root!
        final class Attempts: @unchecked Sendable { var seen: [Int] = [] }
        let attempts = Attempts()
        let snapshot = try await LibraryScanner.scan(
            root: root, previousSnapshot: first, writesMetadata: true, progress: nil, gateTimeout: .seconds(5)
        ) { attempt in
            attempts.seen.append(attempt)
            guard let lease = try? LibraryGate(root: root).tryAcquire() else { return }
            defer { lease.release() }
            let current = try! LibraryMetadataStore.load(root: root).0
            try! LibraryMetadataStore.save(
                TagEditor.add(["round \(attempt)"], documents: [indexed], metadata: current), root: root)
        }
        XCTAssertEqual(attempts.seen, [1, 2, 3])
        XCTAssertEqual(tagNames(indexed, in: try index()), ["round 1", "round 2"], "Round 3 found the gate held")
        XCTAssertEqual(try index(), snapshot.metadata)
        XCTAssertNotNil(snapshot.metadata.IDsByPath["New.md"])
    }

    /// Headless reads (#131): no recovery rename, no index repair or identity write, no lock file.
    func testHeadlessScanNeverWritesRepairsOrLocks() async throws {
        _ = try write("", "Notes/One.md")
        // No `.silkweb` at all: a headless scan must not create it.
        var snapshot = try await LibraryScanner.scan(root: root, writesMetadata: false)
        XCTAssertEqual(snapshot.documents.map(\.relativePath), ["Notes/One.md"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".silkweb").path))

        // A valid index missing a document's identity is not updated.
        _ = try await LibraryScanner.scan(root: root)
        _ = try write("", "Notes/Two.md")
        let indexFile = root.appendingPathComponent(".silkweb/index.json")
        try? FileManager.default.removeItem(at: LibraryGate(root: root).lockURL)
        let before = try Data(contentsOf: indexFile)
        let modified = try FileManager.default.attributesOfItem(atPath: indexFile.path)[.modificationDate] as? Date
        snapshot = try await LibraryScanner.scan(root: root, writesMetadata: false)
        XCTAssertEqual(snapshot.documents.count, 2)
        XCTAssertEqual(try Data(contentsOf: indexFile), before)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: indexFile.path)[.modificationDate] as? Date, modified)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: indexFile.deletingLastPathComponent().path),
            ["index.json"])

        // An undecodable index stays exactly where it is; recovery is left to the app.
        try Data("{ not json".utf8).write(to: indexFile)
        snapshot = try await LibraryScanner.scan(root: root, writesMetadata: false)
        XCTAssertTrue(snapshot.metadataWasReset)
        XCTAssertNil(snapshot.recoveredMetadataURL)
        XCTAssertEqual(snapshot.documents.count, 2)
        XCTAssertEqual(try text(indexFile), "{ not json")
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: indexFile.deletingLastPathComponent().path),
            ["index.json"])

        // The app's next scan still recovers it, as before.
        snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertTrue(snapshot.metadataWasReset)
        let recovered = try XCTUnwrap(snapshot.recoveredMetadataURL)
        XCTAssertEqual(try text(recovered), "{ not json")
    }

    func testHeadlessScanNeverWaitsForTheGate() async throws {
        _ = try write("", "One.md")
        let holder = try XCTUnwrap(LibraryGate(root: root).tryAcquire())
        defer { holder.release() }
        let started = ContinuousClock.now
        let snapshot = try await LibraryScanner.scan(root: root, writesMetadata: false)
        XCTAssertEqual(snapshot.documents.count, 1)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(2))
    }

    // MARK: - Saving from the app

    func testAutosaveWaitsQuietlyAndSavesEditsTypedDuringTheWait() async throws {
        let url = try write("original", "Note.md")
        let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: recovery)
        _ = try await coordinator.open(url)
        try await coordinator.edit("first", at: url)
        final class States: @unchecked Sendable { var values: [DocumentSaveState] = [] }
        let states = States()
        let stream = await coordinator.states(for: url)
        let observer = Task { for await state in stream { states.values.append(state) } }
        let holder = try XCTUnwrap(LibraryGate(root: root).tryAcquire())
        let saving = Task { await coordinator.save(url) }
        try await Task.sleep(for: .milliseconds(200))
        let waiting = await coordinator.state(for: url)
        XCTAssertEqual(waiting, .saving, "Waiting reads as Edited, never Not Saved")
        try await coordinator.edit("first and second", at: url)
        XCTAssertEqual(try text(url), "original")
        holder.release()
        let result = await saving.value
        XCTAssertEqual(result, .clean)
        XCTAssertEqual(try text(url), "first and second", "Edits typed during the wait join the same commit")
        try await Task.sleep(for: .milliseconds(50))
        observer.cancel()
        for state in states.values {
            if case .failed = state { XCTFail("Contention must not report a failure: \(state)") }
            if case .conflict = state { XCTFail("Contention must never be a conflict: \(state)") }
        }
    }

    func testBusyTimeoutIsASaveFailureNeverAConflictAndRetriesOnItsOwn() async throws {
        let url = try write("original", "Note.md")
        let coordinator = SaveCoordinator(
            store: DocumentStore(root: root, gateTimeout: .milliseconds(150)), recoveryDirectory: recovery,
            busyRetryDelay: .milliseconds(100))
        _ = try await coordinator.open(url)
        try await coordinator.edit("mine", at: url)
        let holder = try XCTUnwrap(LibraryGate(root: root).tryAcquire())
        let state = await coordinator.save(url)
        guard case .failed(let failure, let attempt)? = state else {
            return XCTFail("Expected failure, got \(String(describing: state))")
        }
        XCTAssertEqual(attempt, 1)
        XCTAssertEqual(failure.reason, .libraryBusy)
        XCTAssertEqual(
            failure.localizedDescription, "Another Silkweb process is updating this library. Silkweb will try again.")
        XCTAssertEqual(try text(url), "original")
        let draft = try await coordinator.pendingRecoveryDrafts().first
        XCTAssertEqual(draft?.text, "mine", "The buffer is kept for recovery like any failed save")
        holder.release()
        let deadline = ContinuousClock.now + .seconds(5)
        while await coordinator.state(for: url) != .clean, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let settled = await coordinator.state(for: url)
        XCTAssertEqual(settled, .clean)
        XCTAssertEqual(try text(url), "mine")
    }

    func testRealRevisionMismatchWhileWaitingIsStillAConflict() async throws {
        let url = try write("original", "Note.md")
        let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: recovery)
        _ = try await coordinator.open(url)
        try await coordinator.edit("mine", at: url)
        let holder = try XCTUnwrap(LibraryGate(root: root).tryAcquire())
        let saving = Task { await coordinator.save(url) }
        try await Task.sleep(for: .milliseconds(100))
        try Data("theirs".utf8).write(to: url, options: .atomic)
        holder.release()
        guard case .conflict? = await saving.value else { return XCTFail("A changed revision is a conflict") }
        XCTAssertEqual(try text(url), "theirs")
    }

    // MARK: - Helper copy

    func testHelperReportsBusyAndStaleSnapshotWithStableCodes() {
        let busy = AgentAccessError(LibraryGateError.busy(retryAfter: 1))
        XCTAssertEqual(busy, .libraryBusy(retryAfter: 1))
        XCTAssertEqual(busy.code, "library_busy")
        XCTAssertEqual(busy.message, "Silkweb is updating this library. Try again in a moment.")
        let output = AgentHelper.refusal(busy)
        XCTAssertEqual(output.status, 1)
        let json = try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8)) as? [String: [String: Any]]
        XCTAssertEqual(json?["error"]?["code"] as? String, "library_busy")
        XCTAssertEqual(json?["error"]?["retry_after"] as? Int, 1)
        XCTAssertEqual(output.stderr, "Library Busy: Silkweb is updating this library. Try again in a moment.\n")
        XCTAssertEqual(AgentAccessError.staleSnapshot.code, "stale_snapshot")
        XCTAssertEqual(AgentAccessError.staleSnapshot.message, "The library changed while this request ran. Try again.")
        XCTAssertNil(AgentHelper.refusal(.staleSnapshot).stdout.range(of: "retry_after"))
    }
}

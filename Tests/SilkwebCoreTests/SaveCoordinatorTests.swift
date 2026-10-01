import XCTest
import Darwin
@testable import SilkwebCore

final class SaveCoordinatorTests: XCTestCase {
    private var root: URL!
    private var recovery: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        recovery = root.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func document(_ name: String = "Note.md", text: String = "original") throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    private struct FailingFileSystem: DocumentFileSystem {
        enum Point { case stage, replace }
        let point: Point
        let code: Int
        private let disk = DiskDocumentFileSystem()
        func read(_ url: URL) throws -> Data { try disk.read(url) }
        func stage(_ data: Data, at url: URL) throws {
            // Include partial staging writes, not just failure before any IO.
            if point == .stage {
                try disk.stage(Data(data.prefix(3)), at: url)
                throw NSError(domain: NSPOSIXErrorDomain, code: code)
            }
            try disk.stage(data, at: url)
        }
        func replace(_ destination: URL, with staging: URL) throws {
            throw NSError(domain: NSPOSIXErrorDomain, code: code)
        }
        func remove(_ url: URL) throws { try disk.remove(url) }
    }

    func testFailureSweepRetainsOriginalDraftAndRecoveryAcrossLaunches() async throws {
        for point in [FailingFileSystem.Point.stage, .replace] {
            for code in [ENOSPC, EACCES, ENODEV, EIO] {
                for text in ["", "日本語 🕸\n", String(repeating: "x", count: 1_000_000)] {
                    let url = try document("\(UUID()).md")
                    let coordinator = SaveCoordinator(
                        store: DocumentStore(fileSystem: FailingFileSystem(point: point, code: Int(code))),
                        recoveryDirectory: recovery)
                    _ = try await coordinator.open(url)
                    try await coordinator.edit(text, at: url)
                    for attempt in 1...2 {
                        let state = await coordinator.save(url)
                        guard case .failed(let error, let actualAttempt) = state else {
                            return XCTFail("Expected failure, got \(String(describing: state))")
                        }
                        XCTAssertEqual(actualAttempt, attempt)
                        let expectedReason: DocumentSaveFailure.Reason
                        switch code {
                        case ENOSPC: expectedReason = .diskFull
                        case EACCES: expectedReason = .permission
                        case ENODEV: expectedReason = .volumeUnavailable
                        default: expectedReason = .other(NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription)
                        }
                        XCTAssertEqual(error.reason, expectedReason)
                        XCTAssertTrue(error.localizedDescription.hasSuffix("Your text is safe in this window."))
                        XCTAssertTrue(state!.isDirty)
                        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
                        let draft = await coordinator.draft(for: url)
                        XCTAssertEqual(draft, text)
                    }
                    let restarted = SaveCoordinator(recoveryDirectory: recovery)
                    let drafts = try await restarted.pendingRecoveryDrafts()
                    let draft = try XCTUnwrap(drafts.first { $0.documentURL == url })
                    XCTAssertEqual(draft.text, text)
                    await restarted.restore(draft)
                    let state = await restarted.state(for: url)
                    XCTAssertEqual(state, .dirty)
                    let saved = await restarted.save(url)
                    XCTAssertEqual(saved, .clean)
                    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
                    let remaining = try await restarted.pendingRecoveryDrafts()
                    XCTAssertFalse(remaining.contains { $0.documentURL == url })
                }
            }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix(".silkweb-save-") })
    }

    func testLegacyMarkdownLoadsAndStreamClearsDirtyOnlyAfterCommit() async throws {
        for name in ["empty.md", "old.markdown", "UPPER.MD"] {
            let text = name == "empty.md" ? "" : "# Old document\nCafé\r\n"
            let url = try document(name, text: text)
            let coordinator = SaveCoordinator(recoveryDirectory: recovery)
            let loaded = try await coordinator.open(url)
            XCTAssertEqual(loaded.text, text)
            let stream = await coordinator.states(for: url)
            var states = stream.makeAsyncIterator()
            let clean = await states.next()
            XCTAssertEqual(clean, .clean)
            try await coordinator.edit(text + "new", at: url)
            let dirty = await states.next()
            XCTAssertEqual(dirty, .dirty)
            let reopened = try await coordinator.open(url)
            XCTAssertEqual(reopened.text, text + "new")
            let result = await coordinator.save(url)
            XCTAssertEqual(result, .clean)
            let saving = await states.next()
            let saved = await states.next()
            XCTAssertEqual(saving, .saving)
            XCTAssertTrue(saving!.isDirty)
            XCTAssertEqual(saved, .clean)
            let disk = try DocumentStore().load(url)
            XCTAssertNotEqual(disk.revision, loaded.revision)
            XCTAssertEqual(disk.text, text + "new")
            let repeated = await coordinator.save(url)
            XCTAssertEqual(repeated, .clean)
        }
    }

    func testConcurrentDocumentsAndSameDocumentKeepLatestEdits() async throws {
        let coordinator = SaveCoordinator(recoveryDirectory: recovery)
        var urls: [URL] = []
        for index in 0..<40 { urls.append(try document("\(index).md")) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask {
                    _ = try await coordinator.open(url)
                    for iteration in 0..<10 {
                        try await coordinator.edit("\(index):\(iteration)", at: url)
                        let result = await coordinator.save(url)
                        XCTAssertEqual(result, .clean)
                    }
                }
            }
            try await group.waitForAll()
        }
        for (index, url) in urls.enumerated() {
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\(index):9")
        }
        let url = urls[0]
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<30 {
                group.addTask {
                    try await coordinator.edit("contender-\(index)", at: url)
                    _ = await coordinator.save(url)
                }
            }
            try await group.waitForAll()
        }
        let concurrentDraft = await coordinator.draft(for: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), concurrentDraft)
        try await coordinator.edit("latest", at: url)
        let dirty = await coordinator.state(for: url)
        XCTAssertEqual(dirty, .dirty)
        let saved = await coordinator.save(url)
        XCTAssertEqual(saved, .clean)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "latest")
    }

    func testConflictAndExternalDeletionPreserveTextWithoutOverwriting() async throws {
        let url = try document()
        let coordinator = SaveCoordinator(recoveryDirectory: recovery)
        _ = try await coordinator.open(url)
        try await coordinator.edit("my draft", at: url)
        try Data("external".utf8).write(to: url, options: .atomic)
        let state = await coordinator.save(url)
        XCTAssertEqual(state, .conflict(diskRevision: try DocumentStore().load(url).revision))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external")
        try FileManager.default.removeItem(at: url)
        let deleted = await coordinator.save(url)
        XCTAssertEqual(deleted, .conflict(diskRevision: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let draft = await coordinator.draft(for: url)
        XCTAssertEqual(draft, "my draft")
        let drafts = try await coordinator.pendingRecoveryDrafts()
        XCTAssertEqual(drafts.first?.text, "my draft")
    }

    func testChangeDuringStagingIsCheckedBeforeReplacement() throws {
        struct ChangingFileSystem: DocumentFileSystem {
            let destination: URL
            let disk = DiskDocumentFileSystem()
            func read(_ url: URL) throws -> Data { try disk.read(url) }
            func stage(_ data: Data, at url: URL) throws {
                try disk.stage(data, at: url)
                try Data("external during staging".utf8).write(to: destination, options: .atomic)
            }
            func replace(_ destination: URL, with staging: URL) throws { try disk.replace(destination, with: staging) }
            func remove(_ url: URL) throws { try disk.remove(url) }
        }
        let url = try document()
        let store = DocumentStore(fileSystem: ChangingFileSystem(destination: url))
        let original = try store.load(url)
        XCTAssertThrowsError(try store.save("my text", to: url, expectedRevision: original.revision)) { error in
            guard case DocumentStoreError.conflict = error else { return XCTFail("Expected revision conflict") }
        }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "external during staging")
    }

    func testQuitRecoveryAndUnwritableRecoveryKeepBuffer() async throws {
        let url = try document()
        let blocked = try document("blocked.md")
        let coordinator = SaveCoordinator(recoveryDirectory: blocked)
        _ = try await coordinator.open(url)
        try await coordinator.edit("unsaved", at: url)
        do {
            try await coordinator.preserveUnsavedDrafts()
            XCTFail("Expected recovery failure")
        } catch {}
        let text = await coordinator.draft(for: url)
        let state = await coordinator.state(for: url)
        XCTAssertEqual(text, "unsaved")
        XCTAssertEqual(state, .dirty)
        let failing = SaveCoordinator(
            store: DocumentStore(fileSystem: FailingFileSystem(point: .replace, code: Int(ENOSPC))),
            recoveryDirectory: blocked)
        _ = try await failing.open(url)
        try await failing.edit("both writes failed", at: url)
        let failed = await failing.save(url)
        XCTAssertTrue(failed!.isDirty)
        let recoveryError = await failing.recoveryFailure(for: url)
        XCTAssertNotNil(recoveryError)
        let buffer = await failing.draft(for: url)
        XCTAssertEqual(buffer, "both writes failed")
        let working = SaveCoordinator(recoveryDirectory: recovery)
        _ = try await working.open(url)
        try await working.edit("quit draft", at: url)
        try await working.preserveUnsavedDrafts()
        let drafts = try await working.pendingRecoveryDrafts()
        XCTAssertEqual(drafts.first?.text, "quit draft")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testDebounceReplacesDeadlineAndFlushCancelsPendingSave() async throws {
        let url = try document()
        let coordinator = SaveCoordinator(recoveryDirectory: recovery)
        _ = try await coordinator.open(url)
        try await coordinator.edit("first", at: url)
        await coordinator.scheduleSave(url, delay: .milliseconds(200))
        try await Task.sleep(for: .milliseconds(50))
        try await coordinator.edit("latest 日本語", at: url)
        await coordinator.scheduleSave(url, delay: .milliseconds(400))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "latest 日本語")
        try await coordinator.edit("explicit flush", at: url)
        await coordinator.scheduleSave(url, delay: .seconds(60))
        let saved = await coordinator.save(url)
        XCTAssertEqual(saved, .clean)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "explicit flush")
        let closed = await coordinator.close(url)
        XCTAssertTrue(closed)
        try Data("fresh disk".utf8).write(to: url, options: .atomic)
        let reopened = try await coordinator.open(url)
        XCTAssertEqual(reopened.text, "fresh disk")
    }

    func testCloseFlushSweepAndDiscardRecovery() async throws {
        for text in ["", "🕸 日本語\n", String(repeating: "x", count: 1_000_000)] {
            for scheduled in [false, true] {
                let url = try document("\(UUID()).md")
                let coordinator = SaveCoordinator(recoveryDirectory: recovery)
                _ = try await coordinator.open(url)
                try await coordinator.edit(text, at: url)
                if scheduled { await coordinator.scheduleSave(url, delay: .seconds(60)) }
                let closed = await coordinator.close(url)
                XCTAssertTrue(closed)
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
                let evicted = await coordinator.draft(for: url)
                XCTAssertNil(evicted)
            }
        }
        let url = try document()
        let failed = SaveCoordinator(store: DocumentStore(fileSystem: FailingFileSystem(point: .replace, code: Int(ENOSPC))), recoveryDirectory: recovery)
        _ = try await failed.open(url)
        try await failed.edit("retained", at: url)
        let closed = await failed.close(url)
        XCTAssertFalse(closed)
        let retained = await failed.draft(for: url)
        XCTAssertEqual(retained, "retained")
        let restarted = SaveCoordinator(recoveryDirectory: recovery)
        let drafts = try await restarted.pendingRecoveryDrafts()
        let draft = try XCTUnwrap(drafts.first)
        await restarted.restore(draft)
        try await restarted.discardRecovery(url)
        let remaining = try await restarted.pendingRecoveryDrafts()
        XCTAssertTrue(remaining.isEmpty)
        let disk = try await restarted.open(url)
        XCTAssertEqual(disk.text, "original")
    }

    func testZeroDelayAndScheduledFailureKeepBuffer() async throws {
        for failing in [false, true] {
            let url = try document("\(UUID()).md")
            let store = failing ? DocumentStore(fileSystem: FailingFileSystem(point: .stage, code: Int(EACCES))) : DocumentStore()
            let coordinator = SaveCoordinator(store: store, recoveryDirectory: recovery)
            _ = try await coordinator.open(url)
            let stream = await coordinator.states(for: url)
            var iterator = stream.makeAsyncIterator()
            _ = await iterator.next()
            try await coordinator.edit("scheduled", at: url)
            _ = await iterator.next()
            await coordinator.scheduleSave(url, delay: .zero)
            let saving = await iterator.next()
            XCTAssertEqual(saving, .saving)
            let result = await iterator.next()
            XCTAssertEqual(result?.isDirty, failing)
            let buffer = await coordinator.draft(for: url)
            XCTAssertEqual(buffer, "scheduled")
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), failing ? "original" : "scheduled")
        }
    }

    func testLibraryWithSymlinkedAncestorAndInternalLinks() async throws {
        let actual = root.appendingPathComponent("Actual/Library")
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual.deletingLastPathComponent())
        let aliasedRoot = alias.appendingPathComponent("Library")
        try Data("old".utf8).write(to: actual.appendingPathComponent("Note.md"))
        let snapshot = try await LibraryScanner.scan(root: aliasedRoot)
        XCTAssertEqual(snapshot.rootURL, actual.resolvingSymlinksInPath())
        XCTAssertEqual(snapshot.documents.count, 1)
        let store = DocumentStore(root: aliasedRoot)
        let url = snapshot.rootURL.appendingPathComponent("Note.md")
        let loaded = try store.load(url)
        _ = try store.save("new", to: url, expectedRevision: loaded.revision)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        let linkedFolder = snapshot.rootURL.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: snapshot.rootURL)
        XCTAssertThrowsError(try store.load(linkedFolder.appendingPathComponent("Note.md")))
        let rescan = try await LibraryScanner.scan(root: aliasedRoot)
        XCTAssertEqual(rescan.documents.count, 1)
    }

    func testRecoveryTolerantDefaultsAndFutureVersionRejection() throws {
        let url = root.appendingPathComponent("old.md")
        let data = try JSONSerialization.data(withJSONObject: ["documentURL": url.absoluteString, "text": "old draft"])
        let decoded = try JSONDecoder().decode(RecoveryDraft.self, from: data)
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertNil(decoded.revision)
        XCTAssertEqual(decoded.text, "old draft")
        let future = try JSONSerialization.data(withJSONObject: ["formatVersion": 2, "documentURL": url.absoluteString, "text": "future"])
        XCTAssertThrowsError(try JSONDecoder().decode(RecoveryDraft.self, from: future))
    }

    func testRejectsInvalidUTF8AndSymlinksAndPreservesPermissions() throws {
        let url = try document()
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
        let store = DocumentStore()
        let loaded = try store.load(url)
        _ = try store.save("new", to: url, expectedRevision: loaded.revision)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o640)
        let alias = root.appendingPathComponent("Alias.md")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        XCTAssertThrowsError(try store.load(alias))
        XCTAssertThrowsError(try store.save("unsafe", to: alias, expectedRevision: loaded.revision))
        try Data([0xff]).write(to: url)
        XCTAssertThrowsError(try store.load(url))
    }
}

import XCTest
@testable import SilkwebCore

final class LibraryReconcilerTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testCleanDirtyResolutionSweepAndLegacyFiles() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        // Plain Markdown from earlier versions needs no migration.
        for mine in ["", "日本語 👩🏽‍💻\n", String(repeating: "x", count: 1_000_000)] {
            for keepMine in [false, true] {
                let url = root.appendingPathComponent("\(UUID()).markdown")
                try Data("original".utf8).write(to: url)
                let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: root.appendingPathComponent(".recovery"))
                _ = try await coordinator.open(url)
                try Data("clean reload".utf8).write(to: url, options: .atomic)
                let reload = try await coordinator.reconcile(url)
                XCTAssertEqual(reload?.text, "clean reload")
                let cleanState = await coordinator.state(for: url)
                XCTAssertEqual(cleanState, .clean)
                try await coordinator.edit(mine, at: url)
                await coordinator.scheduleSave(url, delay: .milliseconds(20))
                try Data("disk version".utf8).write(to: url, options: .atomic)
                _ = try await coordinator.reconcile(url)
                try await coordinator.edit(mine + " newer", at: url)
                let blocked = await coordinator.save(url)
                guard case .conflict = blocked else { return XCTFail("Conflict must block explicit save and subsequent edits") }
                try await Task.sleep(for: .milliseconds(40))
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "disk version")
                // Resolve against another edit, rather than a stale comparison snapshot.
                try Data("latest disk".utf8).write(to: url, options: .atomic)
                let copy = try await coordinator.resolve(url, keepMine: keepMine, root: root, date: Date(timeIntervalSince1970: 0))
                XCTAssertFalse(copy.lastPathComponent.contains(":"))
                XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), keepMine ? mine + " newer" : "latest disk")
                XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), keepMine ? "latest disk" : mine + " newer")
            }
        }
    }

    func testDeletionRetainsCleanAndDirtyDraftsAndRecreatesWithoutOverwrite() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for dirty in [false, true] {
            let url = root.appendingPathComponent("\(UUID()).md")
            try Data("original".utf8).write(to: url)
            let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: root.appendingPathComponent(".recovery"))
            _ = try await coordinator.open(url)
            if dirty { try await coordinator.edit("draft", at: url) }
            try FileManager.default.removeItem(at: url)
            _ = try await coordinator.reconcile(url)
            let state = await coordinator.state(for: url)
            XCTAssertEqual(state, .conflict(diskRevision: nil))
            let draft = await coordinator.draft(for: url)
            XCTAssertEqual(draft, dirty ? "draft" : "original")
            let recovery = try await coordinator.pendingRecoveryDrafts()
            XCTAssertTrue(recovery.contains { $0.documentURL == url && $0.text == draft })
            try Data("competing file".utf8).write(to: url)
            let target = try await coordinator.recreate(url, root: root)
            XCTAssertNotEqual(target, url)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "competing file")
            XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), draft)
        }
    }

    func testRecoveryWriteFailureStillPublishesConflict() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = root.appendingPathComponent("blocked")
        try Data().write(to: recovery)
        let url = root.appendingPathComponent("Note.md")
        try Data("original".utf8).write(to: url)
        let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: recovery)
        _ = try await coordinator.open(url)
        try await coordinator.edit("mine", at: url)
        try Data("disk".utf8).write(to: url, options: .atomic)
        _ = try await coordinator.reconcile(url)
        let state = await coordinator.state(for: url)
        guard case .conflict = state else { return XCTFail("Recovery failure must not suppress conflict") }
        let failure = await coordinator.recoveryFailure(for: url)
        XCTAssertNotNil(failure)
        let draft = await coordinator.draft(for: url)
        XCTAssertEqual(draft, "mine")
    }

    func testSaveAgainRestoresDeletedAncestors() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("Parent/Child")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let url = parent.appendingPathComponent("Note.md")
        try Data("original".utf8).write(to: url)
        let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: root.appendingPathComponent(".recovery"))
        _ = try await coordinator.open(url)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Parent"))
        _ = try await coordinator.reconcile(url)
        let recreated = try await coordinator.recreate(url, root: root)
        XCTAssertEqual(recreated, url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    func testMoveAndReplacementAtOldPathKeepsOriginalIdentity() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("A.md")
        try Data("original".utf8).write(to: original)
        let old = try await LibraryScanner.scan(root: root)
        try FileManager.default.moveItem(at: original, to: root.appendingPathComponent("Z.md"))
        try Data("replacement".utf8).write(to: original)
        let new = try await LibraryScanner.scan(root: root, previousSnapshot: old)
        XCTAssertEqual(new.documents.first { $0.name == "Z.md" }?.id, old.documents.first?.id)
        XCTAssertNotEqual(new.documents.first { $0.name == "A.md" }?.id, old.documents.first?.id)
    }

    func testFinderMovesSelectionFallbackAndSymlinkBoundaries() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createFolder(named: "Parent")
        _ = try await engine.createFolder(named: "Child", in: "Parent")
        _ = try await engine.createDocument(named: "Note.md", in: "Parent/Child", text: "text")
        let old = try await LibraryScanner.scan(root: root)
        var session = LibrarySession()
        session.selectedFolder = "Parent/Child"
        session.selectedDocuments = ["Parent/Child/Note.md"]
        session.expandedFolders = ["", "Parent", "Parent/Child"]
        try FileManager.default.moveItem(at: root.appendingPathComponent("Parent"), to: root.appendingPathComponent("Moved"))
        let moved = try await LibraryScanner.scan(root: root, previousSnapshot: old)
        XCTAssertEqual(moved.documents.first?.id, old.documents.first?.id)
        let remapped = LibraryReconciler.session(session, from: old, to: moved)
        XCTAssertEqual(remapped.selectedFolder, "Moved/Child")
        XCTAssertEqual(remapped.selectedDocuments, ["Moved/Child/Note.md"])
        XCTAssertEqual(remapped.expandedFolders, ["", "Moved", "Moved/Child"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("Moved/Child"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("cycle"), withDestinationURL: root)
        let deleted = try await LibraryScanner.scan(root: root, previousSnapshot: moved)
        XCTAssertEqual(LibraryReconciler.session(remapped, from: moved, to: deleted).selectedFolder, "Moved")
        XCTAssertFalse(deleted.folders.contains { $0.name == "cycle" })
        let outside = try fixture()
        defer { try? FileManager.default.removeItem(at: outside) }
        let linked = root.appendingPathComponent("escape.md")
        let outsideNote = outside.appendingPathComponent("Note.md")
        try Data("outside".utf8).write(to: outsideNote)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: outsideNote)
        XCTAssertThrowsError(try DocumentStore(root: root).load(linked))
        let scan = try await LibraryScanner.scan(root: root)
        XCTAssertFalse(scan.documents.contains { $0.name == "escape.md" })
    }
}

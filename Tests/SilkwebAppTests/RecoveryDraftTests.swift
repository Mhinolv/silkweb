import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

/// silkweb-1.70: recovery drafts never block opening, never autosave before Keep,
/// and drafts for notes deleted outside Silkweb stay reachable.
@MainActor
final class RecoveryDraftTests: XCTestCase {
    private var container: URL!
    private var root: URL { container.appendingPathComponent("Library") }
    private var recovery: URL { container.appendingPathComponent("Recovery") }

    override func setUp() async throws {
        _ = NSApplication.shared
        container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("healthy on disk".utf8).write(to: root.appendingPathComponent("Notes/Healthy.md"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: container) }

    private func workspace() throws -> LibraryWorkspace {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SilkwebRecovery-\(UUID().uuidString)"))
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.recoveryDirectory = recovery
        return workspace
    }

    private func open(_ workspace: LibraryWorkspace) async throws {
        workspace.open(root)
        for _ in 0..<500 {
            if workspace.error != nil || (!workspace.loading && workspace.snapshot != nil) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(workspace.error)
        XCTAssertNotNil(workspace.snapshot)
    }

    /// Writes a draft exactly as a previous launch would have on quit.
    private func writeDraft(for url: URL, text: String) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("on disk".utf8).write(to: url)
        let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: recovery)
        _ = try await coordinator.open(url)
        try await coordinator.edit(text, at: url)
        try await coordinator.preserveUnsavedDrafts()
    }

    private func labels(in view: NSView) -> [String] {
        StatusBarCountsTests.accessibilityTree(view).compactMap { StatusBarCountsTests.label($0) }
    }

    private func settle(_ host: NSView) async throws {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testUnreadableRecoveryFileNeverBlocksOpeningDocuments() async throws {
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        let bad = recovery.appendingPathComponent("corrupt.json")
        try Data("{ not json".utf8).write(to: bad)
        let workspace = try workspace()
        try await open(workspace)
        workspace.navigate(folder: "Notes", documents: ["Notes/Healthy.md"], pinned: true)
        await workspace.waitForNavigation()
        let editor = workspace.editor
        XCTAssertEqual(editor.url, root.appendingPathComponent("Notes/Healthy.md"))
        XCTAssertFalse(editor.readOnly, "A corrupt recovery file must not make documents read-only")
        XCTAssertEqual(editor.text, "healthy on disk")
        XCTAssertNil(editor.error)
        XCTAssertNil(editor.banner)
        editor.edit("edited")
        XCTAssertEqual(editor.text, "edited")
        XCTAssertFalse(FileManager.default.fileExists(atPath: bad.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("Unreadable/corrupt.json").path))

        _ = await editor.flush()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/Healthy.md"), encoding: .utf8), "edited")

        // A later bad file is set aside too (the strip itself: UnreadableRecoveryBannerTests).
        try Data("{".utf8).write(to: recovery.appendingPathComponent("second.json"))
        let again = try self.workspace()
        try await open(again)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recovery.appendingPathComponent("second.json").path))
        await workspace.didCloseWindow()
        await again.didCloseWindow()
    }

    func testRecoveredDraftIsNotWrittenBeforeKeep() async throws {
        let url = root.appendingPathComponent("Notes/Drafted.md")
        try await writeDraft(for: url, text: "recovered text")
        let bytes = try Data(contentsOf: url)
        let workspace = try workspace()
        try await open(workspace)
        let editor = workspace.editor
        XCTAssertEqual(editor.url, url)
        XCTAssertTrue(editor.recovered)
        XCTAssertEqual(editor.text, "recovered text")
        XCTAssertEqual(editor.banner, "Silkweb recovered unsaved changes to this document.")
        // Watcher ticks with an unchanged disk revision must not commit the recovered buffer.
        for _ in 0..<3 { await workspace.reconcileFinderChanges() }
        editor.edit("recovered text, edited")
        await workspace.reconcileFinderChanges()
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertEqual(try Data(contentsOf: url), bytes, "Disk is untouched until Keep")
        XCTAssertTrue(editor.recovered, "The banner stays while the choice is pending")
        editor.keepRecovery()
        for _ in 0..<300 where editor.state != .clean { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(editor.recovered)
        XCTAssertEqual(editor.state, .clean)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "recovered text, edited")
        await workspace.didCloseWindow()
    }

    func testDraftForDeletedNoteOpensEditableWithSaveAgainAndSaveCopy() async throws {
        let url = root.appendingPathComponent("Gone/Deleted Note.md")
        try await writeDraft(for: url, text: "orphaned words")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Gone"))
        let workspace = try workspace()
        try await open(workspace)
        let editor = workspace.editor
        XCTAssertEqual(workspace.tabs.count, 1)
        XCTAssertEqual(editor.url, url)
        XCTAssertEqual(editor.name, "Deleted Note")
        XCTAssertEqual(editor.text, "orphaned words")
        XCTAssertFalse(editor.readOnly)
        XCTAssertTrue(editor.externalDeleted)
        XCTAssertEqual(editor.banner, "“Deleted Note” was moved to the Trash or deleted outside Silkweb.")

        StatusBarCountsTests.exposeAccessibility(true)
        defer { StatusBarCountsTests.exposeAccessibility(false) }
        let host = NSHostingView(rootView: EditorBanner(session: editor, workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        XCTAssertTrue(labels(in: host).contains("Save Again"), "\(labels(in: host))")
        XCTAssertTrue(labels(in: host).contains("Save a Copy…"))
        XCTAssertFalse(labels(in: host).contains("Close"), "An orphan draft can't be closed away by accident")

        // Editable but never autosaved.
        editor.edit("orphaned words, edited")
        try await Task.sleep(for: .milliseconds(1300))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        // Closing the tab keeps the (latest) draft for next time.
        let closed = await workspace.closeTab(try XCTUnwrap(workspace.activeTabID))
        XCTAssertTrue(closed)
        XCTAssertTrue(workspace.tabs.isEmpty)
        let kept = try await SaveCoordinator(recoveryDirectory: recovery).pendingRecoveryDrafts()
        XCTAssertEqual(kept.map(\.text), ["orphaned words, edited"])

        let reopened = try self.workspace()
        try await open(reopened)
        XCTAssertEqual(reopened.editor.text, "orphaned words, edited")
        XCTAssertTrue(reopened.editor.externalDeleted)
        // Save Again recreates the folder and file, and the note appears in the list.
        await reopened.editor.saveAgain()
        await reopened.reconcileFinderChanges()
        XCTAssertFalse(reopened.editor.externalDeleted)
        XCTAssertEqual(reopened.editor.url, url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "orphaned words, edited")
        let document = try XCTUnwrap(reopened.snapshot?.documents.first { $0.relativePath == "Gone/Deleted Note.md" })
        XCTAssertEqual(reopened.tabs.map(\.id), [document.id], "The tab follows the recreated note")
        let remaining = try await SaveCoordinator(recoveryDirectory: recovery).pendingRecoveryDrafts()
        XCTAssertTrue(remaining.isEmpty)
        await workspace.didCloseWindow()
        await reopened.didCloseWindow()
    }
}

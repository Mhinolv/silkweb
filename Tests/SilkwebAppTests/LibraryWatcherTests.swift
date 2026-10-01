import AppKit
import XCTest
import SilkwebCore
@testable import Silkweb

final class LibraryWatcherTests: XCTestCase {
    @MainActor
    func testWatcherDebouncesBatchesAndCancelsOnStop() async throws {
        var calls = 0
        let watcher = LibraryWatcher(delay: .milliseconds(20)) { calls += 1 }
        for _ in 0..<100 { watcher.notifyChange() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, 1)
        watcher.notifyChange()
        watcher.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testRecursiveFilesystemNotifications() async throws {
        if ProcessInfo.processInfo.environment["CODEX_SANDBOX"] == "seatbelt" {
            throw XCTSkip("Managed seatbelt sandbox does not deliver FSEvents; debounce and reconciliation are tested separately.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/watcher-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("nested/deep")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var notifications = 0
        let watcher = LibraryWatcher(root: root, delay: .milliseconds(20)) { notifications += 1 }
        defer { watcher.stop() }
        // Let stream startup finish before modifying a descendant, not the root.
        try await Task.sleep(for: .milliseconds(200))
        notifications = 0
        let url = nested.appendingPathComponent("Note.md")
        try Data("created".utf8).write(to: url, options: .atomic)
        for _ in 0..<100 {
            if notifications > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(notifications, 0)
        notifications = 0
        try Data("replaced".utf8).write(to: url, options: .atomic)
        for _ in 0..<100 {
            if notifications > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertGreaterThan(notifications, 0)
    }

    @MainActor
    func testWorkspaceCleanReloadDirtyConflictRenameAndDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Note.md")
        try Data("original".utf8).write(to: url)
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedDocuments = ["Note.md"]
        await workspace.editor.configure(root: root, recoveryDirectory: root.appendingPathComponent(".recovery"))
        _ = await workspace.editor.open(url, readOnly: false)
        try Data("reload".utf8).write(to: url, options: .atomic)
        await workspace.reconcileFinderChanges()
        XCTAssertEqual(workspace.editor.text, "reload")
        let moved = root.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: url, to: moved)
        await workspace.reconcileFinderChanges()
        XCTAssertEqual(workspace.editor.url, moved)
        XCTAssertEqual(workspace.session.selectedDocuments, ["Renamed.md"])
        workspace.editor.edit("mine")
        try Data("disk".utf8).write(to: moved, options: .atomic)
        await workspace.reconcileFinderChanges()
        XCTAssertTrue(workspace.editor.externalConflict, "state: \(workspace.editor.state), error: \(String(describing: workspace.editor.error)), url: \(String(describing: workspace.editor.url))")
        XCTAssertEqual(workspace.editor.text, "mine")
        workspace.editor.edit("mine continued")
        await workspace.editor.resolveConflict(keepMine: false)
        XCTAssertEqual(workspace.editor.text, "disk")
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(workspace.editor.conflictCopy), encoding: .utf8), "mine continued")
        try FileManager.default.removeItem(at: moved)
        await workspace.reconcileFinderChanges()
        XCTAssertTrue(workspace.editor.externalDeleted, "state: \(workspace.editor.state), error: \(String(describing: workspace.editor.error))")
        XCTAssertEqual(workspace.editor.text, "disk")
        await workspace.editor.saveAgain()
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "disk")
    }

    @MainActor
    func testOffscreenReloadAndComparisonResizeSweep() throws {
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        for width in [1.0, 420, 1200, 4096] {
            scroll.setFrameSize(NSSize(width: width, height: 520))
            for value in ["", "👩🏽‍💻", String(repeating: "line\n", count: 1000)] {
                MarkdownTextView.reload(text, in: scroll, value: value, selection: NSRange(location: 100000, length: 1000), position: NSPoint(x: 0, y: 100000))
                scroll.layoutSubtreeIfNeeded()
                XCTAssertEqual(text.string, value)
                XCTAssertEqual(text.selectedRange().location, (value as NSString).length)
            }
        }
        let comparison = ConflictComparisonViews()
        for value in ["", "x", String(repeating: "日本語\n", count: 1000)] {
            comparison.load(mine: value, disk: value + "\nend")
            for width in [1.0, 400, 760, 4096] {
                comparison.stack.setFrameSize(NSSize(width: width, height: 400))
                comparison.stack.layoutSubtreeIfNeeded()
                for pane in comparison.panes {
                    pane.tile()
                    (pane.documentView as? PlainMarkdownTextView)?.layoutEditor()
                    pane.documentView?.viewDidMoveToWindow()
                }
                comparison.synchronize(from: 0)
                comparison.synchronize(from: 1)
                XCTAssertEqual((comparison.panes[0].documentView as? NSTextView)?.string, value)
                XCTAssertFalse((comparison.panes[1].documentView as! NSTextView).isEditable)
            }
        }
    }
}

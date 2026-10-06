import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

final class AssetMigrationWorkspaceTests: XCTestCase {
    @MainActor
    func testOpeningLibraryAutomaticallyMigratesBeforeSettling() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".silkweb-assets/id"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent(".silkweb-assets/id/image.png"))
        try Data("![x](.silkweb-assets/id/image.png)".utf8).write(to: root.appendingPathComponent("note.md"))
        let defaults = disposableDefaults("MigrationOpen")
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.open(root)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if workspace.snapshot != nil, !workspace.loading, !workspace.mediaMigrationRunning,
                !FileManager.default.fileExists(atPath: root.appendingPathComponent(".silkweb-assets").path)
            {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(workspace.error)
        XCTAssertFalse(workspace.mediaBannerVisible, "Fast migration stays silent")
        XCTAssertTrue(workspace.mediaFailures.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8), "![x](media/id/image.png)")
        XCTAssertFalse(workspace.snapshot!.folders.contains { $0.relativePath == "media" })
        await workspace.didCloseWindow()
    }

    @MainActor
    func testPendingAssetInsertionIsSavedBeforeMigrationRewrite() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".silkweb-assets/id"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent(".silkweb-assets/id/old.png"))
        let document = root.appendingPathComponent("note.md")
        try Data("![old](.silkweb-assets/id/old.png)".utf8).write(to: document)
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        _ = await workspace.openTab(workspace.snapshot!.documents[0], pinned: true)
        let session = workspace.editor
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let native = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let coordinator = MarkdownTextView.Coordinator(session: session)
        coordinator.textView = native
        native.delegate = coordinator
        native.configureAssetInsertion(session: session, workspace: workspace)
        native.string = session.text
        native.setSelectedRange(NSRange(location: native.string.utf16.count, length: 0))
        workspace.preview.editor = native
        XCTAssertTrue(native.assetHandler.add([.init(name: "new.png", isImage: true, data: Data([2]))]))
        XCTAssertTrue(native.assetHandler.busy)
        await workspace.migrateMedia()
        XCTAssertFalse(native.assetHandler.busy)
        XCTAssertTrue(workspace.mediaFailures.isEmpty)
        XCTAssertTrue(session.text.contains("new.png"))
        XCTAssertTrue(session.text.contains("media/id/old.png"))
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), session.text)
        await workspace.didCloseWindow()
    }

    @MainActor
    func testMigrationSavesDirtyTabsAndReloadsRealEditorAndBanners() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".silkweb-assets/id"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent(".silkweb-assets/id/image.png"))
        for name in ["A", "B"] {
            try Data("![x](.silkweb-assets/id/image.png)".utf8).write(to: root.appendingPathComponent(name + ".md"))
        }
        let defaults = disposableDefaults("Migration")
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        for document in workspace.snapshot!.documents { _ = await workspace.openTab(document, pinned: true) }
        let dirty = workspace.tabs[0].editor
        dirty.edit("dirty " + dirty.text)
        let host = NSHostingController(rootView: DocumentDetail(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = host.view
        await workspace.migrateMedia()
        XCTAssertTrue(workspace.mediaFailures.isEmpty)
        XCTAssertFalse(workspace.mutating)
        XCTAssertTrue(dirty.text.hasPrefix("dirty "))
        for tab in workspace.tabs {
            XCTAssertFalse(tab.editor.loading)
            XCTAssertTrue(tab.editor.text.contains("media/id/image.png"))
            XCTAssertFalse(tab.editor.text.contains(".silkweb-assets"))
            XCTAssertEqual(try String(contentsOf: tab.editor.url!, encoding: .utf8), tab.editor.text)
        }
        for failure in [false, true] {
            workspace.mediaBannerVisible = true
            workspace.mediaProgress = ("media", 1, 2)
            workspace.mediaFailures = failure ? [.init(name: "image.png", reason: "Locked")] : []
            for width in [420.0, 650, 1200] {
                host.view.setFrameSize(NSSize(width: width, height: 700))
                host.view.layoutSubtreeIfNeeded()
                for tab in workspace.tabs { workspace.activateTab(tab.id); host.view.layoutSubtreeIfNeeded() }
                XCTAssertTrue(host.view.fittingSize.width.isFinite)
            }
        }
        await workspace.didCloseWindow()
        window.contentView = nil
    }
}

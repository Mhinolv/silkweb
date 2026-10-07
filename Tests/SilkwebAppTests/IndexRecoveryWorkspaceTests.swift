import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #107: when the index-recovery strip appears and how long it stays (the strip itself: IndexRecoveryBannerTests).
@MainActor
final class IndexRecoveryWorkspaceTests: XCTestCase {
    private func makeLibrary(index: String?) throws -> URL {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebIndexWorkspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".silkweb"), withIntermediateDirectories: true)
        try Data("# Note\n".utf8).write(to: root.appendingPathComponent("Note.md"))
        if let index { try Data(index.utf8).write(to: root.appendingPathComponent(".silkweb/index.json")) }
        return root
    }

    private func open(_ root: URL, in workspace: LibraryWorkspace? = nil) async throws -> LibraryWorkspace {
        let workspace = workspace ?? LibraryWorkspace(defaults: disposableDefaults("IndexWorkspace"))
        workspace.canSaveWindowSession = false
        workspace.recoveryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebIndexWorkspaceDrafts-" + UUID().uuidString)
        workspace.open(root)
        try await Task.sleep(for: .milliseconds(10))
        for _ in 0..<500 {
            if workspace.error != nil || (!workspace.loading && workspace.snapshot?.rootURL != nil) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(workspace.snapshot)
        return workspace
    }

    func testBackupStripShowsOncePerBackupAndNewCorruptionShowsAgain() async throws {
        let root = try makeLibrary(index: "{\"tags\":{}}")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await open(root)
        let backup = try XCTUnwrap(workspace.indexRecovery?.backup)
        XCTAssertTrue(backup.lastPathComponent.hasPrefix("index.corrupt-"))
        XCTAssertEqual(workspace.indexRecovery?.root, workspace.snapshot?.rootURL)

        // A Finder reconcile with a healthy rebuilt index keeps the strip; ✕ hides it for the launch.
        try Data("# Other\n".utf8).write(to: root.appendingPathComponent("Other.md"))
        await workspace.reconcileFinderChanges()
        XCTAssertEqual(workspace.snapshot?.documents.count, 2)
        XCTAssertEqual(workspace.indexRecovery?.backup, backup)
        workspace.indexRecovery = nil
        await workspace.reconcileFinderChanges()
        XCTAssertNil(workspace.indexRecovery)
        let reopened = try await open(root)
        XCTAssertNil(reopened.indexRecovery)

        // A new corrupt file later in the session is a new backup and a new strip.
        try Data("not JSON".utf8).write(to: root.appendingPathComponent(".silkweb/index.json"))
        try Data("# Third\n".utf8).write(to: root.appendingPathComponent("Third.md"))
        await workspace.reconcileFinderChanges()
        let second = try XCTUnwrap(workspace.indexRecovery?.backup)
        XCTAssertNotEqual(second, backup)
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "not JSON")
        await workspace.didCloseWindow()
        await reopened.didCloseWindow()
    }

    func testNoCopyStripShowsOncePerLibraryAndSwitchingLibrariesClearsIt() async throws {
        let root = try makeLibrary(index: "not JSON")
        let directory = root.appendingPathComponent(".silkweb")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        let healthy = try makeLibrary(index: nil)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: healthy)
        }
        let workspace = try await open(root)
        XCTAssertNotNil(workspace.indexRecovery)
        XCTAssertNil(workspace.indexRecovery?.backup)
        workspace.indexRecovery = nil
        // Every rescan rereads the same unreadable index; it must not come back after ✕.
        if let snapshot = workspace.snapshot { workspace.install(snapshot) }
        XCTAssertNil(workspace.indexRecovery)
        let again = try await open(root)
        XCTAssertNil(again.indexRecovery)

        let other = try makeLibrary(index: "not JSON")
        defer { try? FileManager.default.removeItem(at: other) }
        let switching = try await open(other)
        XCTAssertNotNil(switching.indexRecovery?.backup)
        _ = try await open(healthy, in: switching)
        XCTAssertEqual(switching.snapshot?.rootURL, healthy.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertNil(switching.indexRecovery)
        for item in [workspace, again, switching] { await item.didCloseWindow() }
    }

    func testRevealHidesWhenTheBackupIsGone() async throws {
        let root = try makeLibrary(index: "not JSON")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await open(root)
        let backup = try XCTUnwrap(workspace.indexRecovery?.backup)
        try FileManager.default.removeItem(at: backup)
        StatusBarCountsTests.exposeAccessibility(true)
        defer { StatusBarCountsTests.exposeAccessibility(false) }
        let host = NSHostingView(rootView: IndexRecoveryBanner(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        func settle() async throws {
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await settle()
        XCTAssertGreaterThanOrEqual(host.fittingSize.height, 36)
        let reveal = try XCTUnwrap(StatusBarCountsTests.element("Reveal in Finder", in: host))
        XCTAssertEqual(reveal.accessibilityPerformPress?(), true)
        try await settle()
        XCTAssertNil(StatusBarCountsTests.element("Reveal in Finder", in: host))
        let remaining = StatusBarCountsTests.accessibilityTree(host).flatMap {
            [StatusBarCountsTests.label($0), StatusBarCountsTests.value($0)].compactMap { $0 }
        }
        XCTAssertTrue(remaining.contains(IndexRecoveryBanner.backupMessage), "\(remaining)")
        XCTAssertTrue(remaining.contains("Dismiss message"), "\(remaining)")
        workspace.indexRecovery = nil
        try await settle()
        XCTAssertEqual(host.fittingSize.height, 0, accuracy: 0.5)
        await workspace.didCloseWindow()
    }
}

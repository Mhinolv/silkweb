import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #107: a corrupt `.silkweb/index.json` resets tags; the detail column says so and can reveal the saved copy.
/// Strings are literal so this file also builds against the pre-fix code it must fail on.
@MainActor
final class IndexRecoveryBannerTests: XCTestCase {
    static let backupMessage =
        "Silkweb couldn’t read this library’s index, so tags were reset. A copy of the old index was saved."
    static let noCopyMessage =
        "Silkweb couldn’t read this library’s index, so tags were reset. No copy could be saved because the library can’t be changed."

    private func makeLibrary(index: String) throws -> URL {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebIndexRecovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".silkweb"), withIntermediateDirectories: true)
        try Data("# Note\n".utf8).write(to: root.appendingPathComponent("Note.md"))
        try Data(index.utf8).write(to: root.appendingPathComponent(".silkweb/index.json"))
        return root
    }

    private func open(_ root: URL) async throws -> LibraryWorkspace {
        let workspace = LibraryWorkspace(defaults: disposableDefaults("IndexRecovery"))
        workspace.canSaveWindowSession = false
        workspace.recoveryDirectory = root.deletingLastPathComponent().appendingPathComponent(
            "SilkwebIndexRecoveryDrafts-" + UUID().uuidString)
        workspace.open(root)
        for _ in 0..<500 {
            if workspace.error != nil || (!workspace.loading && workspace.snapshot != nil) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        return workspace
    }

    /// Hosts the real detail column (empty “No Document Selected” state) and returns its accessibility strings.
    private func detailLabels(_ workspace: LibraryWorkspace, widths: [CGFloat] = [1400, 900, 420]) async throws
        -> [[String]]
    {
        StatusBarCountsTests.exposeAccessibility(true)
        defer { StatusBarCountsTests.exposeAccessibility(false) }
        let host = NSHostingView(rootView: DocumentDetail(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        var result: [[String]] = []
        for width in widths {
            window.setContentSize(NSSize(width: width, height: 500))
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
            result.append(
                StatusBarCountsTests.accessibilityTree(host).flatMap {
                    [StatusBarCountsTests.label($0), StatusBarCountsTests.value($0)].compactMap { $0 }
                })
        }
        return result
    }

    func testCorruptIndexShowsRecoveryStripWithRevealInFinder() async throws {
        let root = try makeLibrary(index: "not JSON")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await open(root)
        XCTAssertNil(workspace.error)
        let backup = try XCTUnwrap(workspace.snapshot?.recoveredMetadataURL)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "not JSON")
        for found in try await detailLabels(workspace) {
            XCTAssertTrue(found.contains(Self.backupMessage), "\(found)")
            XCTAssertTrue(found.contains("Reveal in Finder"), "\(found)")
            XCTAssertTrue(found.contains("Dismiss message"), "\(found)")
            XCTAssertTrue(found.contains("No Document Selected"), "\(found)")
        }
        await workspace.didCloseWindow()
    }

    func testUnwritableIndexFolderShowsNoCopyStripWithoutReveal() async throws {
        let root = try makeLibrary(index: "not JSON")
        let directory = root.appendingPathComponent(".silkweb")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: root)
        }
        let workspace = try await open(root)
        XCTAssertNil(workspace.error)
        XCTAssertNil(workspace.snapshot?.recoveredMetadataURL)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("index.json"), encoding: .utf8), "not JSON")
        for found in try await detailLabels(workspace, widths: [1400, 420]) {
            XCTAssertTrue(found.contains(Self.noCopyMessage), "\(found)")
            XCTAssertFalse(found.contains("Reveal in Finder"), "\(found)")
            XCTAssertTrue(found.contains("Dismiss message"), "\(found)")
        }
        await workspace.didCloseWindow()
    }

    func testNewerIndexFormatShowsReadableErrorAndKeepsFile() async throws {
        let json = "{\"formatVersion\":999,\"tags\":[]}"
        let root = try makeLibrary(index: json)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await open(root)
        XCTAssertEqual(workspace.errorTitle, "Can’t Open Library")
        XCTAssertEqual(
            workspace.error,
            "This library was last used with a newer version of Silkweb. Update Silkweb to open it. Nothing in the library was changed."
        )
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent(".silkweb/index.json")), Data(json.utf8))
        await workspace.didCloseWindow()
    }

    func testHealthyIndexShowsNoStrip() async throws {
        let root = try makeLibrary(index: "{\"formatVersion\":2,\"IDsByPath\":{}}")
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = try await open(root)
        XCTAssertNil(workspace.snapshot?.recoveredMetadataURL)
        for found in try await detailLabels(workspace, widths: [900]) {
            XCTAssertFalse(found.contains(Self.backupMessage), "\(found)")
            XCTAssertFalse(found.contains(Self.noCopyMessage), "\(found)")
            XCTAssertTrue(found.contains("No Document Selected"), "\(found)")
        }
        await workspace.didCloseWindow()
    }
}

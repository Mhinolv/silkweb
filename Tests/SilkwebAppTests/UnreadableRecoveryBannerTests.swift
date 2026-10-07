import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// silkweb-1.70: the workspace strip for a recovery file that was set aside.
@MainActor
final class UnreadableRecoveryBannerTests: XCTestCase {
    func testStripShowsOncePerLaunchWithRevealInFinderAndDismiss() async throws {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        let root = container.appendingPathComponent("Library")
        let recovery = container.appendingPathComponent("Recovery")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        try Data("text".utf8).write(to: root.appendingPathComponent("Note.md"))
        try Data("{".utf8).write(to: recovery.appendingPathComponent("bad.json"))
        LibraryWorkspace.unreadableRecoveryShown = false

        func open() async throws -> LibraryWorkspace {
            let defaults = disposableDefaults("Unreadable")
            let workspace = LibraryWorkspace(defaults: defaults)
            workspace.recoveryDirectory = recovery
            workspace.open(root)
            for _ in 0..<500 {
                if workspace.error != nil || (!workspace.loading && workspace.snapshot != nil) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(workspace.snapshot)
            return workspace
        }
        let workspace = try await open()
        let quarantined = recovery.appendingPathComponent("Unreadable/bad.json")
        XCTAssertEqual(workspace.unreadableRecoveryFile, quarantined)

        StatusBarCountsTests.exposeAccessibility(true)
        defer { StatusBarCountsTests.exposeAccessibility(false) }
        let host = NSHostingView(rootView: UnreadableRecoveryBanner(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 40), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func labels() async throws -> [String] {
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
            return StatusBarCountsTests.accessibilityTree(host).flatMap {
                [StatusBarCountsTests.label($0), StatusBarCountsTests.value($0)].compactMap { $0 }
            }
        }
        for width: CGFloat in [1400, 900, 420] {
            window.setContentSize(NSSize(width: width, height: 40))
            let found = try await labels()
            XCTAssertTrue(found.contains(UnreadableRecoveryBanner.message), "\(width): \(found)")
            XCTAssertTrue(found.contains("Reveal in Finder"), "\(width): \(found)")
            XCTAssertTrue(found.contains("Dismiss message"), "\(width): \(found)")
            XCTAssertGreaterThanOrEqual(host.fittingSize.height, 36)
        }
        workspace.unreadableRecoveryFile = nil
        let dismissed = try await labels()
        XCTAssertFalse(dismissed.contains(UnreadableRecoveryBanner.message))
        XCTAssertEqual(host.fittingSize.height, 0, accuracy: 0.5)

        // Once per launch: another unreadable file later is set aside quietly.
        try Data("null".utf8).write(to: recovery.appendingPathComponent("worse.json"))
        let again = try await open()
        XCTAssertNil(again.unreadableRecoveryFile)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: recovery.appendingPathComponent("Unreadable/worse.json").path))
        await workspace.didCloseWindow()
        await again.didCloseWindow()
    }
}

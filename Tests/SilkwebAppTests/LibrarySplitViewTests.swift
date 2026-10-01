import AppKit
import XCTest
import SilkwebCore
@testable import Silkweb

final class LibrarySplitViewTests: XCTestCase {
    @MainActor
    private func layout(_ controller: LibrarySplitViewController, width: CGFloat = 1200, height: CGFloat = 760) {
        controller.view.setFrameSize(NSSize(width: width, height: height))
        controller.view.layoutSubtreeIfNeeded()
    }

    @MainActor
    private func widths(_ controller: LibrarySplitViewController) -> [CGFloat] {
        controller.navigationController.splitView.arrangedSubviews.map { $0.frame.width } + [controller.splitView.arrangedSubviews[1].frame.width]
    }

    @MainActor
    private func clearAutosave(_ name: String) {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(name) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    @MainActor
    func testOffscreenAutosaveRestoreAndSidebarCommands() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = LibraryWorkspace()
        workspace.root = root
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot)
        let name = "Silkweb.Tests." + UUID().uuidString
        defer { clearAutosave(name) }
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
        var controller: LibrarySplitViewController? = LibrarySplitViewController(workspace: workspace, autosaveName: name)
        container.addSubview(controller!.view)
        layout(controller!)
        await Task.yield()
        layout(controller!)
        let navigation = controller!.navigationController.splitView
        let dividerSpace = navigation.bounds.width - widths(controller!).prefix(2).reduce(0, +)
        controller!.splitView.setPosition(260 + dividerSpace + 380, ofDividerAt: 0)
        layout(controller!)
        controller!.navigationController.splitView.setPosition(260, ofDividerAt: 0)
        layout(controller!)
        let saved = widths(controller!)
        XCTAssertEqual(saved[0], 260, accuracy: 1)
        XCTAssertEqual(saved[1], 380, accuracy: 1)
        try await Task.sleep(for: .milliseconds(100))
        controller!.view.removeFromSuperview()
        controller = nil

        let restored = LibrarySplitViewController(workspace: workspace, autosaveName: name)
        container.addSubview(restored.view)
        layout(restored)
        for (actual, expected) in zip(widths(restored), saved) {
            XCTAssertEqual(actual, expected, accuracy: 1)
        }
        for column in 0...2 {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            workspace.sidebarToggleRequest += 1
            restored.updateRequests()
            NSAnimationContext.endGrouping()
            layout(restored)
            XCTAssertTrue(restored.sidebarItem.isCollapsed)
            workspace.focus(column)
            restored.updateRequests()
            layout(restored)
            XCTAssertFalse(restored.sidebarItem.isCollapsed)
            XCTAssertEqual(widths(restored)[0], saved[0], accuracy: 1)
        }
        // Refreshes without new requests must not toggle the sidebar a second time.
        restored.updateRequests()
        XCTAssertFalse(restored.sidebarItem.isCollapsed)
        // Loading and empty content use the same real hosting/controller lifecycle.
        workspace.snapshot = nil
        workspace.loading = true
        await Task.yield()
        for width: CGFloat in [0, 1, 900, 1200, 4096] {
            layout(restored, width: width)
            XCTAssertTrue(widths(restored).allSatisfy { $0.isFinite && $0 >= 0 })
        }
        workspace.install(snapshot)
        workspace.loading = false
        await Task.yield()
        layout(restored)
    }

    @MainActor
    func testOffscreenDividersAndWindowResize() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Split layout\n\nDocument content".utf8).write(to: root.appendingPathComponent("Note.md"))
        let workspace = LibraryWorkspace()
        workspace.root = root
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot)
        _ = await workspace.editor.open(root.appendingPathComponent("Note.md"), readOnly: false)
        let name = "Silkweb.Tests." + UUID().uuidString
        defer { clearAutosave(name) }
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: name)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        container.addSubview(controller.view)
        layout(controller)
        await Task.yield()
        layout(controller)

        let split = controller.splitView
        let navigation = controller.navigationController.splitView
        let navigationDividerSpace = navigation.bounds.width - widths(controller).prefix(2).reduce(0, +)
        split.setPosition(220 + navigationDividerSpace + 300, ofDividerAt: 0)
        layout(controller)
        navigation.setPosition(220, ofDividerAt: 0)
        layout(controller)
        let initial = widths(controller)
        XCTAssertEqual(initial[0], 220, accuracy: 1)
        XCTAssertEqual(initial[1], 300, accuracy: 1)

        for listWidth: CGFloat in [240, 300, 480, 260] {
            split.setPosition(initial[0] + navigationDividerSpace + listWidth, ofDividerAt: 0)
            layout(controller)
            XCTAssertEqual(widths(controller)[0], initial[0], accuracy: 1)
            XCTAssertEqual(widths(controller)[1], listWidth, accuracy: 1)
        }
        for position: CGFloat in [0, 1, 4096] {
            split.setPosition(position, ofDividerAt: 0)
            layout(controller)
            XCTAssertEqual(widths(controller)[0], initial[0], accuracy: 1)
            XCTAssertTrue((239...481).contains(widths(controller)[1]))
        }

        split.setPosition(initial[0] + navigationDividerSpace + 300, ofDividerAt: 0)
        layout(controller)
        let before = widths(controller)
        for sidebarWidth: CGFloat in [180, 260, 220] {
            navigation.setPosition(sidebarWidth, ofDividerAt: 0)
            layout(controller)
            let current = widths(controller)
            XCTAssertEqual(current[0], sidebarWidth, accuracy: 1)
            XCTAssertEqual(current[0] + current[1], before[0] + before[1], accuracy: 1)
            XCTAssertEqual(current[2], before[2], accuracy: 1)
        }

        let fixed = widths(controller)
        let dividerSpace = split.bounds.width - fixed.reduce(0, +)
        for width: CGFloat in [1600, 1000, 960, 4096, 1200] {
            layout(controller, width: width)
            let current = widths(controller)
            XCTAssertEqual(current[0], fixed[0], accuracy: 1)
            XCTAssertEqual(current[1], fixed[1], accuracy: 1)
            XCTAssertEqual(current[2], width - fixed[0] - fixed[1] - dividerSpace, accuracy: 1)
        }
        // Below the editor minimum, the list yields before the sidebar.
        layout(controller, width: 900)
        XCTAssertEqual(widths(controller)[0], fixed[0], accuracy: 1)
        XCTAssertGreaterThanOrEqual(widths(controller)[2], 419)

        // Exercise both collapsed states and the actual request handler over extreme sizes.
        for collapsed in [false, true, false] {
            controller.sidebarItem.isCollapsed = collapsed
            for width: CGFloat in [0, 1, 900, 1200, 4096] {
                for height: CGFloat in [0, 1, 560, 2160] {
                    layout(controller, width: width, height: height)
                    XCTAssertTrue(widths(controller).allSatisfy { $0.isFinite && $0 >= 0 })
                }
            }
        }
        layout(controller)
        controller.sidebarItem.isCollapsed = true
        workspace.focus(0)
        controller.updateRequests()
        layout(controller)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        controller.view.removeFromSuperview()
        container.addSubview(controller.view)
        layout(controller)
    }
}

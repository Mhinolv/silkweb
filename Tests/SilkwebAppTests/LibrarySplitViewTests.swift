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
            workspace.toggleSidebars()
            restored.updateRequests()
            NSAnimationContext.endGrouping()
            layout(restored)
            XCTAssertTrue(restored.navigationItem.isCollapsed)
            if column == 2 {
                workspace.focus(column)
                restored.updateRequests()
                XCTAssertTrue(restored.navigationItem.isCollapsed)
                workspace.toggleSidebars()
            } else { workspace.focus(column) }
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
    func testBothSidebarsToggleInRealHierarchyWithLongDocument() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "Silkweb.Sidebars." + UUID().uuidString
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); clearAutosave(name) }
        try LongEditorFixture.document.write(to: root.appendingPathComponent("Long.md"), atomically: true, encoding: .utf8)
        let workspace = LibraryWorkspace(columnAutosaveName: name)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let opened = await workspace.openTab(try XCTUnwrap(workspace.snapshot?.documents.first), pinned: true)
        XCTAssertTrue(opened)
        workspace.preview.showsOutline = true
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: name)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        func settle() async throws {
            controller.updateRequests()
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(350))
            controller.view.layoutSubtreeIfNeeded()
        }
        try await settle()
        controller.splitView.setPosition(640 + controller.navigationController.splitView.dividerThickness, ofDividerAt: 0)
        controller.navigationController.splitView.setPosition(260, ofDividerAt: 0)
        try await settle()
        let saved = widths(controller)
        let editor = try XCTUnwrap(workspace.preview.editor)
        let inspectorWidth = controller.splitView.arrangedSubviews[1].frame.width - (editor.enclosingScrollView?.frame.width ?? 0)
        XCTAssertGreaterThan(inspectorWidth, 150)
        let selection = NSRange(location: 100, length: 0)
        editor.setSelectedRange(selection)
        let focusField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        controller.navigationController.view.addSubview(focusField)
        window.makeFirstResponder(focusField)
        workspace.toggleSidebars()
        try await settle()
        // On the pre-fix implementation the document list remains on screen.
        XCTAssertTrue(controller.splitViewItems[0].isCollapsed)
        XCTAssertEqual(controller.splitView.arrangedSubviews[1].frame.width, controller.view.bounds.width, accuracy: 2)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(workspace.preview.showsOutline)
        XCTAssertEqual(try XCTUnwrap(editor.enclosingScrollView).frame.width, controller.view.bounds.width - inspectorWidth, accuracy: 2)
        workspace.toggleSidebars()
        try await settle()
        for (actual, expected) in zip(widths(controller), saved) { XCTAssertEqual(actual, expected, accuracy: 1) }
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        let end = editor.string.utf16.count
        for _ in 0...end {
            let previous = editor.selectedRange().location
            editor.moveDown(nil)
            if editor.selectedRange().location == previous || editor.selectedRange().location == end { break }
        }
        XCTAssertEqual(editor.selectedRange().location, end, "caret reaches text beyond the former scroll cap")
        editor.scrollRangeToVisible(editor.selectedRange())
        XCTAssertGreaterThan(scroll.documentVisibleRect.maxY, 10000)
        XCTAssertEqual(try XCTUnwrap(scroll.verticalScroller).frame.height, scroll.bounds.height, accuracy: 1)
        workspace.toggleSidebars()
        try await settle()
        for width: CGFloat in [1, 420, 900, 1400, 4096] {
            window.setContentSize(NSSize(width: width, height: 900))
            for mode in [DocumentViewMode.editor, .split, .preview] {
                workspace.preview.mode = mode
                try await settle()
                XCTAssertTrue(controller.splitViewItems[0].isCollapsed)
                XCTAssertEqual(workspace.preview.mode, mode)
                XCTAssertTrue(widths(controller).allSatisfy { $0.isFinite && $0 >= 0 })
                XCTAssertEqual(controller.splitView.arrangedSubviews[1].frame.width, controller.view.bounds.width, accuracy: 2)
                if mode != .preview {
                    let text = try XCTUnwrap(workspace.preview.editor)
                    let scroll = try XCTUnwrap(text.enclosingScrollView)
                    let manager = try XCTUnwrap(text.layoutManager)
                    let container = try XCTUnwrap(text.textContainer)
                    manager.ensureLayout(for: container)
                    XCTAssertGreaterThanOrEqual(text.frame.height, manager.usedRect(for: container).maxY + text.textContainerOrigin.y)
                    text.setSelectedRange(NSRange(location: text.string.utf16.count, length: 0))
                    text.scrollRangeToVisible(text.selectedRange())
                    XCTAssertGreaterThan(scroll.documentVisibleRect.maxY, 10000)
                }
            }
        }
        window.setContentSize(NSSize(width: 1400, height: 900))
        workspace.preview.mode = .editor
        workspace.focus(2)
        try await settle()
        XCTAssertTrue(workspace.sidebarsHidden)
        for column in [0, 1] {
            workspace.focus(column)
            try await settle()
            XCTAssertFalse(controller.splitViewItems[0].isCollapsed)
            XCTAssertFalse(controller.sidebarItem.isCollapsed)
            workspace.toggleSidebars()
            try await settle()
        }
        workspace.toggleSidebars()
        try await settle()
        controller.sidebarItem.isCollapsed = true
        try await settle()
        workspace.toggleSidebars()
        try await settle()
        XCTAssertFalse(controller.splitViewItems[0].isCollapsed)
        XCTAssertFalse(controller.sidebarItem.isCollapsed)
        workspace.toggleSidebars()
        try await settle()
        await workspace.saveSessionNow()
        let loadedSession = try await WindowSessionMetadata.load(root: root)
        let savedSession = try XCTUnwrap(loadedSession)
        XCTAssertTrue(savedSession.sidebarsHidden)
        let restoredWorkspace = LibraryWorkspace(columnAutosaveName: name)
        restoredWorkspace.root = root
        restoredWorkspace.install(try await LibraryScanner.scan(root: root))
        await restoredWorkspace.restoreTabs(savedSession)
        let restored = LibrarySplitViewController(workspace: restoredWorkspace, autosaveName: name)
        layout(restored, width: 1400, height: 900)
        restored.updateRequests()
        layout(restored, width: 1400, height: 900)
        XCTAssertTrue(restored.splitViewItems[0].isCollapsed)
        XCTAssertFalse(window.isVisible)
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

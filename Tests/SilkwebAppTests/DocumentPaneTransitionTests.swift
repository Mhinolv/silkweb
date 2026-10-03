import AppKit
import XCTest
import SilkwebCore
@testable import Silkweb

final class DocumentPaneTransitionTests: XCTestCase {
    @MainActor
    func testModeSwitchCommitsPaneGeometryBeforeReturning() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "# Transition\n\n" + String(repeating: "A non-empty paragraph.\n", count: 500)
        let url = root.appendingPathComponent("Note.md")
        try Data(source.utf8).write(to: url)
        let otherURL = root.appendingPathComponent("Other.md")
        try Data("# Other tab".utf8).write(to: otherURL)
        let suite = "Silkweb.PaneTransition." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.navigate(folder: nil, documents: ["Other.md"], pinned: true)
        await workspace.waitForNavigation()
        let otherID = try XCTUnwrap(workspace.activeTabID)
        workspace.navigate(folder: nil, documents: ["Note.md"], pinned: true)
        await workspace.waitForNavigation()
        let documentID = try XCTUnwrap(workspace.activeTabID)
        workspace.preview.mode = .editor
        let controller = DocumentPanesController(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for _ in 0..<10 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let editor = try XCTUnwrap(workspace.preview.editor)
        XCTAssertTrue(descendants(controller.view).contains { $0 === editor })
        let selection = NSRange(location: 20, length: 4)
        editor.setSelectedRange(selection)
        let undo = editor.undoManager
        var frames: [String] = []
        func record(_ mode: DocumentViewMode, phase: String) {
            let items = controller.splitViewItems
            let views = items.map { $0.viewController.view }
            let visible = views.map { !$0.isHiddenOrHasHiddenAncestor && $0.frame.width > 0 }
            let placeholder = editor.string.isEmpty && editor.placeholderEnabled
            let log = "\(mode) \(phase): collapsed=\(items.map(\.isCollapsed)), visible=\(visible), frames=\(views.map(\.frame)), placeholder=\(placeholder)"
            frames.append(log)
            let expected = [mode != .preview, mode != .editor]
            XCTAssertEqual(items.map { !$0.isCollapsed }, expected, log)
            XCTAssertEqual(visible, expected, log)
            if mode != .split {
                let view = views[mode == .editor ? 0 : 1]
                XCTAssertEqual(view.frame.minX, 0, accuracy: 0.5, log)
                XCTAssertEqual(view.frame.width, controller.splitView.bounds.width, accuracy: 0.5, log)
            }
            XCTAssertFalse(placeholder, log)
            XCTAssertEqual(editor.string, source, log)
            XCTAssertEqual(editor.selectedRange(), selection, log)
            XCTAssertTrue(editor.undoManager === undo, log)
        }
        // Include both reported transitions into Editor, then every mode pair.
        let modes: [DocumentViewMode] = [.preview, .editor, .split, .preview, .editor, .split, .editor,
                                         .preview, .split, .preview]
        for width: CGFloat in [1, 420, 600, 1000, 4096] {
            window.setContentSize(NSSize(width: width, height: 700))
            controller.view.layoutSubtreeIfNeeded()
            // Below the two 280-point minimums AppKit may legitimately collapse
            // a split pane. Exercise the single-pane transitions at those sizes.
            for mode in width < 561 ? [.preview, .editor, .preview, .editor] : modes {
                workspace.preview.mode = mode
                controller.updateMode()
                // No forced layout here: a mode change must commit the new geometry
                // before AppKit can display a stale half-width or empty pane.
                record(mode, phase: "returned")
                for turn in 0..<5 {
                    controller.view.layoutSubtreeIfNeeded()
                    controller.view.displayIfNeeded()
                    try await Task.sleep(for: .milliseconds(10))
                    record(mode, phase: "turn \(turn)")
                }
            }
        }
        print("Pane transition frame log:\n" + frames.joined(separator: "\n"))
        workspace.preview.mode = .editor
        controller.updateMode()
        workspace.activateTab(otherID)
        for _ in 0..<5 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(workspace.preview.editor?.string, "# Other tab")
        workspace.activateTab(documentID)
        for _ in 0..<5 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(workspace.preview.editor === editor)
        record(.editor, phase: "tab restored")
        XCTAssertFalse(window.isVisible)
        await workspace.didCloseWindow()
    }
}

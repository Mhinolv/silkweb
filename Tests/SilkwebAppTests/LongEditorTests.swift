import AppKit
import XCTest
import SilkwebCore
@testable import Silkweb

enum LongEditorFixture {
    static let document = (0..<400).map {
        "## Paragraph \($0)\n\nA long paragraph with Unicode café 日本語 and enough words to wrap in split mode.\n\n- First item\n- Second item\n\n![Image](missing.png)\n\n"
    }.joined() + "FINAL LINE"
}

final class LongEditorTests: XCTestCase {

    @MainActor
    func testLongDocumentInRealDetailWithTabs() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Silkweb.LongEditor." + UUID().uuidString
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try LongEditorFixture.document.write(to: root.appendingPathComponent("Long.md"), atomically: true, encoding: .utf8)
        try "Short".write(to: root.appendingPathComponent("Short.md"), atomically: true, encoding: .utf8)
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let documents = try XCTUnwrap(workspace.snapshot).documents
        let openedLong = await workspace.openTab(try XCTUnwrap(documents.first { $0.relativePath == "Long.md" }), pinned: true)
        XCTAssertTrue(openedLong)
        let longID = try XCTUnwrap(workspace.activeTabID)
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: suite)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.setFrameSize(NSSize(width: 1400, height: 900))
        defer { window.contentViewController = nil; window.close() }
        func settle() async throws {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            controller.view.layoutSubtreeIfNeeded()
        }
        try await settle()
        let editor = try XCTUnwrap(workspace.tabs.first { $0.id == longID }?.textView as? PlainMarkdownTextView)
        try assertReachable(editor)
        let openedShort = await workspace.openTab(try XCTUnwrap(documents.first { $0.relativePath == "Short.md" }), pinned: true)
        XCTAssertTrue(openedShort)
        try await settle()
        workspace.activateTab(longID, syncSelection: false)
        try await settle()
        XCTAssertTrue(workspace.preview.editor === editor)
        try assertReachable(editor)
        for mode in [DocumentViewMode.split, .preview, .editor, .split, .editor] {
            workspace.preview.mode = mode
            try await settle()
            if mode != .preview { try assertReachable(editor) }
        }
        for height: CGFloat in [560, 1200, 900] {
            window.setContentSize(NSSize(width: 1400, height: height))
            try await settle()
            try assertReachable(editor)
        }
        let previousHeight = editor.frame.height
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("\n\n" + String(repeating: "Appended paragraph\n\n", count: 100) + "NEW FINAL LINE", replacementRange: editor.selectedRange())
        try await settle()
        XCTAssertGreaterThan(editor.frame.height, previousHeight)
        try assertReachable(editor)
        await workspace.editor.flush()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Long.md"), encoding: .utf8), editor.string)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    private func assertReachable(_ editor: PlainMarkdownTextView, file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try XCTUnwrap(editor.textContainer)
        let layout = try XCTUnwrap(editor.layoutManager)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let initialHeight = editor.frame.height
        layout.ensureLayout(for: container)
        XCTAssertGreaterThanOrEqual(initialHeight, layout.usedRect(for: container).maxY + editor.textContainerOrigin.y, "extent before test forces layout", file: file, line: line)
        let used = layout.usedRect(for: container)
        XCTAssertGreaterThanOrEqual(editor.frame.height, used.maxY + editor.textContainerOrigin.y, "frame extent", file: file, line: line)
        let end = editor.string.utf16.count
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        for _ in 0..<(end + 1) {
            let before = editor.selectedRange().location
            editor.moveDown(nil)
            if editor.selectedRange().location == before || editor.selectedRange().location == end { break }
        }
        XCTAssertEqual(editor.selectedRange().location, end, "Down arrow cannot reach end", file: file, line: line)
        editor.scrollToEndOfDocument(nil)
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.scrollRangeToVisible(editor.selectedRange())
        let glyph = layout.glyphIndexForCharacter(at: end - 1)
        var lastLine = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        lastLine.origin.y += editor.textContainerOrigin.y
        XCTAssertGreaterThanOrEqual(scroll.documentVisibleRect.maxY, lastLine.maxY - 1, "last line visible", file: file, line: line)
        XCTAssertLessThanOrEqual(scroll.documentVisibleRect.minY, lastLine.minY + 1, file: file, line: line)
        // Scroll past the end: the clip view must clamp at the actual document bottom.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: editor.frame.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThanOrEqual(scroll.documentVisibleRect.maxY, editor.frame.height - 1, "true bottom", file: file, line: line)
        XCTAssertLessThan(try XCTUnwrap(scroll.verticalScroller).knobProportion, 0.1, file: file, line: line)
    }
}

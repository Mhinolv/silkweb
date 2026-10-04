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
        try await assertReachable(editor)
        let openedShort = await workspace.openTab(try XCTUnwrap(documents.first { $0.relativePath == "Short.md" }), pinned: true)
        XCTAssertTrue(openedShort)
        try await settle()
        workspace.activateTab(longID, syncSelection: false)
        try await settle()
        XCTAssertTrue(workspace.preview.editor === editor)
        try await assertReachable(editor)
        for mode in [DocumentViewMode.split, .preview, .editor, .split, .editor] {
            workspace.preview.mode = mode
            try await settle()
            if mode != .preview { try await assertReachable(editor) }
        }
        for height: CGFloat in [560, 1200, 900] {
            window.setContentSize(NSSize(width: 1400, height: height))
            try await settle()
            try await assertReachable(editor)
        }
        let previousHeight = editor.frame.height
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText("\n\n" + String(repeating: "Appended paragraph\n\n", count: 100) + "NEW FINAL LINE", replacementRange: editor.selectedRange())
        try await settle()
        XCTAssertGreaterThan(editor.frame.height, previousHeight)
        try await assertReachable(editor)
        await workspace.editor.flush()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Long.md"), encoding: .utf8), editor.string)
        XCTAssertFalse(window.isVisible)
    }

    /// #51 regression: a runner too slow to finish sizing within the old 400 ms settle, simulated by giving
    /// the editor no grace period at all. The frame extent is asserted once the editor's own sizing is done.
    @MainActor
    func testLongDocumentExtentWithoutSettleDelay() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Silkweb.LongEditorNoSettle." + UUID().uuidString
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
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let documents = try XCTUnwrap(workspace.snapshot).documents
        let opened = await workspace.openTab(try XCTUnwrap(documents.first { $0.relativePath == "Long.md" }), pinned: true)
        XCTAssertTrue(opened)
        let id = try XCTUnwrap(workspace.activeTabID)
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: suite)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.setFrameSize(NSSize(width: 1400, height: 900))
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        let editor = try XCTUnwrap(workspace.tabs.first { $0.id == id }?.textView as? PlainMarkdownTextView)
        try await assertReachable(editor)
        // A width change re-fits the text and the reserved image space again.
        workspace.preview.mode = .split
        controller.view.layoutSubtreeIfNeeded()
        try await assertReachable(editor)
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testFullHeightScrollerAndEndMarginInRealDetail() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Silkweb.Scroller." + UUID().uuidString
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
        defer { window.contentViewController = nil; window.close() }
        func settle() async throws {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(400))
            controller.view.layoutSubtreeIfNeeded()
        }
        try await settle()
        let editor = try XCTUnwrap(workspace.preview.editor)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        try await settle()
        for height: CGFloat in [560, 900, 1200] {
            window.setContentSize(NSSize(width: 1400, height: height))
            for mode in [DocumentViewMode.editor, .split, .editor] {
                workspace.preview.mode = mode
                try await settle()
                XCTAssertTrue(workspace.preview.editor === editor)
                editor.scrollToEndOfDocument(nil)
                scroll.reflectScrolledClipView(scroll.contentView)
                let scroller = try XCTUnwrap(scroll.verticalScroller)
                XCTAssertFalse(scroller.isHidden)
                XCTAssertEqual(scroller.frame.height, scroll.bounds.height, accuracy: 1,
                               "full-height track at window height \(height), mode \(mode)")
                XCTAssertEqual(scroller.frame.minY, 0, accuracy: 1)
                XCTAssertGreaterThan(scroller.rect(for: .knob).height, 0)
                XCTAssertGreaterThan(scroller.rect(for: .knobSlot).height, 0)
                XCTAssertEqual(scroller.rect(for: .knob).maxY, scroller.rect(for: .knobSlot).maxY,
                               accuracy: 2, "thumb at bottom of track")
                try assertEndMargin(editor)
            }
        }
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.insertText(" appended", replacementRange: editor.selectedRange())
        try await settle()
        try assertEndMargin(editor)
        editor.insertNewline(nil)
        try await settle()
        try assertEndMargin(editor)
        // The sizing debounce must not snap an earlier caret to the bottom.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.scrollToBeginningOfDocument(nil)
        editor.insertText("Start ", replacementRange: editor.selectedRange())
        try await settle()
        XCTAssertEqual(scroll.documentVisibleRect.minY, 0, accuracy: 2)
        let openedShort = await workspace.openTab(try XCTUnwrap(documents.first { $0.relativePath == "Short.md" }), pinned: true)
        XCTAssertTrue(openedShort)
        try await settle()
        let short = try XCTUnwrap(workspace.preview.editor)
        let shortScroll = try XCTUnwrap(short.enclosingScrollView)
        shortScroll.scrollerStyle = .legacy
        // Keep production autohiding for the fitting note.
        for height: CGFloat in [560, 900, 1200] {
            window.setContentSize(NSSize(width: 1400, height: height))
            try await settle()
            short.scrollToEndOfDocument(nil)
            XCTAssertEqual(shortScroll.documentVisibleRect.minY, 0, accuracy: 1, "short note must not scroll")
            XCTAssertEqual(short.frame.height, shortScroll.contentSize.height, accuracy: 1)
            XCTAssertTrue(try XCTUnwrap(shortScroll.verticalScroller).isHidden)
        }
        workspace.activateTab(longID, syncSelection: false)
        try await settle()
        XCTAssertTrue(workspace.preview.editor === editor)
        editor.scrollToEndOfDocument(nil)
        try assertEndMargin(editor)
        // Exercise generic inset cancellation for future typewriter composition.
        for top: CGFloat in [0, 40, 300] {
            scroll.contentInsets = NSEdgeInsets(top: top, left: 3, bottom: 0, right: 5)
            editor.layoutEditor()
            XCTAssertEqual(scroll.scrollerInsets.top, -top)
            XCTAssertEqual(scroll.scrollerInsets.left, -3)
            XCTAssertEqual(scroll.scrollerInsets.bottom, 0)
            XCTAssertEqual(scroll.scrollerInsets.right, -5)
        }
        scroll.contentInsets = NSEdgeInsetsZero
        editor.layoutEditor()
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    private func assertEndMargin(_ editor: PlainMarkdownTextView, file: StaticString = #filePath, line: UInt = #line) throws {
        let container = try XCTUnwrap(editor.textContainer)
        let layout = try XCTUnwrap(editor.layoutManager)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        layout.ensureLayout(for: container)
        let usedBottom = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        let bottom = usedBottom + editor.textContainerOrigin.y + editor.textContainerInset.height
        XCTAssertEqual(scroll.contentInsets.bottom, 0, "no bottom overscroll", file: file, line: line)
        XCTAssertEqual(scroll.documentVisibleRect.maxY, bottom, accuracy: 2,
                       "last line plus matching bottom margin", file: file, line: line)
    }

    /// #51: the frame is fitted asynchronously (restyle, inline-image pass, then a debounced fit to the full
    /// text), which a slow CI runner did not finish within a fixed settle. Wait until the editor reports no
    /// sizing work pending, without forcing layout; the extent check below then still sees the app's own result.
    @MainActor
    private func waitForContentSizing(_ editor: PlainMarkdownTextView, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(15)
        while editor.isContentSizingPending, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(editor.isContentSizingPending, "editor sizing still pending after 15 s", file: file, line: line)
    }

    @MainActor
    private func assertReachable(_ editor: PlainMarkdownTextView, file: StaticString = #filePath, line: UInt = #line) async throws {
        let container = try XCTUnwrap(editor.textContainer)
        let layout = try XCTUnwrap(editor.layoutManager)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        try await waitForContentSizing(editor, file: file, line: line)
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

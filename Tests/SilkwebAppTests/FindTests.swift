import AppKit
import XCTest
@testable import Silkweb

final class FindTests: XCTestCase {
    @MainActor
    func testNativeFindBarNavigationDismissalAndResizeSweep() throws {
        _ = NSApplication.shared
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.makeFirstResponder(text)
        XCTAssertTrue(text.usesFindBar)
        XCTAssertTrue(text.isIncrementalSearchingEnabled)
        XCTAssertEqual(scroll.findBarPosition, .aboveContent)
        for source in ["", "x", "日本語 👩🏽‍💻 日本語", String(repeating: "match paragraph\n", count: 1000)] {
            text.string = source
            let length = source.hasPrefix("日本") ? 3 : min(1, source.utf16.count)
            text.setSelectedRange(NSRange(location: 0, length: length))
            text.find(.showFindInterface)
            XCTAssertTrue(scroll.isFindBarVisible)
            XCTAssertNotNil(scroll.findBarView)
            if length > 0 {
                // The managed sandbox has no find-pasteboard service. Enter the query
                // into the native field just as a user would, without a second engine.
                let query = (source as NSString).substring(with: text.selectedRange())
                try enter(query, in: XCTUnwrap(scroll.findBarView), index: 0)
                XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: length))
            }
            for width: CGFloat in [0, 1, 80, 320, 900, 4096, 320] {
                for height: CGFloat in [0, 1, 200, 760, 2160] {
                    scroll.setFrameSize(NSSize(width: width, height: height))
                    scroll.tile()
                    scroll.layoutSubtreeIfNeeded()
                    text.layoutEditor()
                    XCTAssertTrue(text.frame.height.isFinite)
                    XCTAssertEqual(text.string, source)
                }
            }
            if length > 0 {
                text.find(.nextMatch)
                XCTAssertEqual(text.selectedRange().length, length)
                text.find(.previousMatch)
                XCTAssertEqual(text.selectedRange().location, 0)
            }
            let match = text.selectedRange()
            scroll.cancelOperation(nil)
            XCTAssertFalse(scroll.isFindBarVisible)
            XCTAssertTrue(window.firstResponder === text)
            XCTAssertEqual(text.selectedRange(), match)
            text.find(.showReplaceInterface)
            XCTAssertTrue(scroll.isFindBarVisible)
            text.find(.hideFindInterface)
            XCTAssertFalse(scroll.isFindBarVisible)
            XCTAssertTrue(window.firstResponder === text)
        }
    }

    @MainActor
    func testWorkspaceRoutingAndModeReadOnlyEnablement() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("document.md")
        try Data("match and match".utf8).write(to: url)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.FindTests." + UUID().uuidString))
        let workspace = LibraryWorkspace(defaults: defaults)
        XCTAssertFalse(workspace.canFind)
        await workspace.editor.configure(root: root)
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSView(frame: window.contentView!.bounds)
        let other = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        host.addSubview(other)
        host.addSubview(scroll)
        window.contentView = host
        workspace.preview.editor = text
        for readOnly in [false, true] {
            _ = await workspace.editor.open(nil, readOnly: false)
            _ = await workspace.editor.open(url, readOnly: readOnly)
            text.string = workspace.editor.text
            text.isEditable = !readOnly
            for mode in DocumentViewMode.allCases {
                workspace.preview.mode = mode
                XCTAssertEqual(workspace.canFind, mode != .preview)
                window.makeFirstResponder(other)
                workspace.find(.showFindInterface)
                XCTAssertEqual(scroll.isFindBarVisible, mode != .preview)
                if mode != .preview {
                    scroll.cancelOperation(nil)
                    XCTAssertTrue(window.firstResponder === text)
                    workspace.find(.showReplaceInterface)
                    XCTAssertEqual(scroll.isFindBarVisible, !readOnly)
                    scroll.isFindBarVisible = false
                    workspace.jumpToSelection()
                    XCTAssertTrue(window.firstResponder === text)
                }
            }
        }
    }

    @MainActor
    private func enter(_ value: String, in bar: NSView, index: Int) throws {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let fields = descendants(bar).compactMap { $0 as? NSTextField }.filter { $0.isEditable }
        let field = try XCTUnwrap(fields.indices.contains(index) ? fields[index] : nil)
        field.stringValue = value
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    }

    @MainActor
    func testNativeReplacementUndo() throws {
        _ = NSApplication.shared
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        scroll.setFrameSize(NSSize(width: 900, height: 600))
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        window.makeFirstResponder(text)
        let delegate = FindUndoDelegate()
        text.delegate = delegate
        delegate.manager.groupsByEvent = false
        text.string = "日本語 and 日本語"
        text.setSelectedRange(NSRange(location: 0, length: 3))
        text.find(.setSearchString)
        text.find(.showReplaceInterface)
        let bar = try XCTUnwrap(scroll.findBarView)
        for count in [1, 2, 1000] {
            for replacement in ["", "café 👩🏽‍💻"] {
                for action in [NSTextFinder.Action.replace, .replaceAll] {
                    let original = Array(repeating: "日本語", count: count).joined(separator: " and ")
                    text.string = original
                    text.setSelectedRange(NSRange(location: 0, length: 3))
                    try enter("日本語", in: bar, index: 0)
                    try enter(replacement, in: bar, index: 1)
                    delegate.manager.removeAllActions()
                    delegate.manager.beginUndoGrouping()
                    text.find(action)
                    delegate.manager.endUndoGrouping()
                    let changed = text.string
                    let expected = action == .replace ? replacement + String(original.dropFirst(3)) : Array(repeating: replacement, count: count).joined(separator: " and ")
                    XCTAssertEqual(changed, expected)
                    if action == .replaceAll { XCTAssertEqual(delegate.manager.undoActionName, "Replace All") }
                    XCTAssertTrue(delegate.manager.canUndo)
                    delegate.manager.undo()
                    XCTAssertEqual(text.string, original)
                    XCTAssertFalse(delegate.manager.canUndo)
                    delegate.manager.redo()
                    XCTAssertEqual(text.string, changed)
                }
            }
        }
        text.string = "no matches"
        delegate.manager.removeAllActions()
        text.find(.replaceAll)
        XCTAssertEqual(text.string, "no matches")
        if delegate.manager.canUndo { delegate.manager.undo() }
        XCTAssertEqual(text.string, "no matches")
    }
}

@MainActor private final class FindUndoDelegate: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

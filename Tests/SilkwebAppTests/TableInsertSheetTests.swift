import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

final class TableInsertSheetTests: XCTestCase {
    @MainActor func testFormValidationAndHosting() {
        let form = TableInsertForm(options: TableOptions())
        form.columns = "invalid"
        XCTAssertNil(form.options)
        XCTAssertFalse(form.commit(columns: true))
        form.columns = "200"
        form.rows = "-2"
        XCTAssertFalse(form.commit(columns: true))
        XCTAssertFalse(form.commit(columns: false))
        XCTAssertEqual(form.options, TableOptions(columns: 20, rows: 1))
        let host = NSHostingView(rootView: TableInsertSheet(form: form, cancel: {}, insert: { _ in }))
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
        parent.addSubview(host)
        for alignment in TableAlignment.allCases {
            form.alignment = alignment
            for width: CGFloat in [360, 600, 360] {
                host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(host.fittingSize.height.isFinite)
                XCTAssertLessThan(host.fittingSize.height, 500)
            }
        }
    }
    @MainActor func testInsertionUndoReadOnlyAndEditorLifecycle() throws {
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        parent.addSubview(scroll)
        let delegate = TableUndoDelegate()
        delegate.manager.groupsByEvent = false
        text.delegate = delegate
        for alignment in TableAlignment.allCases {
            for options in [TableOptions(columns: 1, rows: 1, alignment: alignment), TableOptions(columns: 20, rows: 100, alignment: alignment)] {
                text.string = "before 日本語 after"
                text.styler.reload()
                let original = text.string
                text.setSelectedRange((original as NSString).range(of: "日本語"))
                delegate.manager.removeAllActions()
                text.insertTable(options)
                let inserted = text.string
                XCTAssertEqual((inserted as NSString).substring(with: text.selectedRange()), "Column 1")
                XCTAssertEqual(delegate.manager.undoActionName, "Insert Table")
                delegate.manager.undo()
                XCTAssertEqual(text.string, original)
                XCTAssertFalse(delegate.manager.canUndo)
                delegate.manager.redo()
                XCTAssertEqual(text.string, inserted)
                for width: CGFloat in [1, 80, 360, 1200, 4096] {
                    scroll.setFrameSize(NSSize(width: width, height: 900))
                    scroll.tile(); text.layoutEditor()
                    XCTAssertEqual(text.string, inserted)
                    XCTAssertTrue(text.frame.height.isFinite)
                }
                scroll.removeFromSuperview(); parent.addSubview(scroll)
                text.viewDidMoveToWindow()
                text.isEditable = false
                text.insertTable(options)
                XCTAssertEqual(text.string, inserted)
                text.isEditable = true
            }
        }
    }
}

@MainActor private final class TableUndoDelegate: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

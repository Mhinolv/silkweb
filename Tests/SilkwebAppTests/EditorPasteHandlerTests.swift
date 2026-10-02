import AppKit
import XCTest
import SilkwebCore
@testable import Silkweb

final class EditorPasteHandlerTests: XCTestCase {
    private let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a6XcAAAAASUVORK5CYII=")!

    @MainActor func testPasteboardPrecedenceAndImageFileFiltering() throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        text.assetHandler.readContent = { _ in EditorPasteContent(plainText: "plain text", png: self.png) }
        XCTAssertTrue(text.assetHandler.paste(from: board))
        XCTAssertEqual(text.string, "plain text")
        text.setMarkedText("日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: text.selectedRange())
        XCTAssertFalse(text.assetHandler.paste(from: board))
        text.unmarkText()
        text.isEditable = false
        XCTAssertFalse(text.assetHandler.paste(from: board))
        let content = EditorPasteContent(fileURLs: [URL(fileURLWithPath: "/tmp/image.heic"), URL(fileURLWithPath: "/tmp/report.pdf")])
        XCTAssertEqual(EditorPasteHandler.files(in: content, imagesOnly: true).map(\.name), ["image.heic"])
        XCTAssertEqual(EditorPasteHandler.files(in: content, imagesOnly: false).map(\.isImage), [true, false])
    }

    @MainActor func testRawPasteDropUndoRedoAndResizeOffscreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("old.md")
        try "before".write(to: doc, atomically: true, encoding: .utf8)
        let session = DocumentSession()
        session.url = doc
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let delegate = AssetUndoDelegate()
        delegate.manager.groupsByEvent = false
        text.delegate = delegate
        text.session = session
        text.assetHandler.root = root
        let id = UUID()
        text.assetHandler.documentID = id
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32))
        bitmap.setColor(.red, atX: 0, y: 0)
        let tiff = try XCTUnwrap(bitmap.tiffRepresentation)
        let encodedPNG = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        for type in [NSPasteboard.PasteboardType("public.png"), .tiff] {
            text.string = "before"
            text.setSelectedRange(NSRange(location: 6, length: 0))
            delegate.manager.removeAllActions()
            text.assetHandler.readContent = { _ in
                type == .tiff ? EditorPasteContent(tiff: tiff) : EditorPasteContent(png: encodedPNG)
            }
            XCTAssertTrue(text.assetHandler.paste(from: board))
            try await finish(text.assetHandler)
            XCTAssertNil(session.assetMessage)
            let inserted = text.string
            XCTAssertTrue(inserted.hasPrefix("before\n![image](.silkweb-assets/"))
            XCTAssertEqual((inserted as NSString).substring(with: text.selectedRange()), "image")
            XCTAssertEqual(delegate.manager.undoActionName, "Insert Image")
            delegate.manager.undo()
            XCTAssertEqual(text.string, "before")
            delegate.manager.redo()
            XCTAssertEqual(text.string, inserted)
            for width: CGFloat in [0, 1, 80, 320, 1200, 4096] {
                scroll.setFrameSize(NSSize(width: width, height: 200))
                scroll.tile()
                text.viewDidMoveToWindow()
                text.layoutEditor()
                text.layoutManager?.ensureLayout(for: text.textContainer!)
                XCTAssertEqual(text.string, inserted)
            }
        }
        let directory = root.appendingPathComponent(".silkweb-assets/\(id.uuidString)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        let file = root.appendingPathComponent("report.pdf")
        try Data([1, 2]).write(to: file)
        text.string = ""
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.assetHandler.readContent = { _ in EditorPasteContent(fileURLs: [file]) }
        XCTAssertTrue(text.readSelection(from: board, type: .fileURL))
        try await finish(text.assetHandler)
        XCTAssertTrue(text.string.hasPrefix("[report.pdf](.silkweb-assets/"))
        XCTAssertEqual(delegate.manager.undoActionName, "Insert Attachment")
        delegate.manager.undo()
        XCTAssertEqual(text.string, "")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("report.pdf")), Data([1, 2]))
    }

    @MainActor func testPartialFailureAndNavigationDoesNotInsertInAnotherDocument() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let session = DocumentSession()
        session.url = root.appendingPathComponent("doc.md")
        text.session = session
        text.assetHandler.root = root
        text.assetHandler.documentID = UUID()
        XCTAssertTrue(text.assetHandler.add([.init(name: "good.png", isImage: true, data: png), .init(name: "bad.png", isImage: true, file: root.appendingPathComponent("missing"))]))
        XCTAssertFalse(text.assetHandler.add([.init(name: "overlap.png", isImage: true, data: png)]))
        try await finish(text.assetHandler)
        XCTAssertTrue(text.string.contains("![good]"))
        XCTAssertEqual(session.assetFailures.count, 1)
        XCTAssertEqual(session.assetMessage, "1 of 2 files couldn’t be added.")
        XCTAssertTrue(text.assetHandler.add([.init(name: "other.png", isImage: true, data: png)]))
        session.url = root.appendingPathComponent("other.md")
        text.string = "different document"
        try await finish(text.assetHandler)
        XCTAssertEqual(text.string, "different document")
        XCTAssertTrue(text.isEditable)
        XCTAssertTrue(text.assetHandler.paste(EditorPasteContent(tiff: Data([0, 1, 2]))))
        try await finish(text.assetHandler)
        XCTAssertEqual(session.assetMessage, "Silkweb couldn’t add “image”.")
        XCTAssertEqual(text.string, "different document")
    }

    @MainActor private func finish(_ handler: EditorPasteHandler) async throws {
        for _ in 0..<500 {
            if !handler.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Asset insertion timed out")
    }
}

@MainActor private final class AssetUndoDelegate: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

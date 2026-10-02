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
        text.assetHandler.readContent = { _ in EditorPasteContent(plainText: "plain text") }
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

    @MainActor func testLateSnapshotImagePasteAndFinderPrecedenceOffscreen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("restored.md")
        try "before".write(to: doc, atomically: true, encoding: .utf8)
        let image = root.appendingPathComponent("Finder image.PNG")
        try png.write(to: image)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 4, bitsPerPixel: 32))
        bitmap.setColor(.red, atX: 0, y: 0)
        let tiff = try XCTUnwrap(bitmap.tiffRepresentation)
        let contents = [
            EditorPasteContent(plainText: image.lastPathComponent, fileURLs: [image]),
            EditorPasteContent(plainText: "clipboard filename", png: png),
            EditorPasteContent(plainText: "clipboard filename", tiff: tiff)
        ]
        for content in contents {
            let workspace = LibraryWorkspace()
            workspace.root = root
            let session = workspace.editor
            session.url = doc
            let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
            let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
            let coordinator = MarkdownTextView.Coordinator(session: session)
            coordinator.textView = text
            text.delegate = coordinator
            text.configureAssetInsertion(session: session, workspace: workspace)
            text.string = "before"
            text.setSelectedRange(NSRange(location: 6, length: 0))
            XCTAssertNil(workspace.snapshot)
            workspace.install(try await LibraryScanner.scan(root: root))
            // No reconfiguration/reselection after the snapshot arrives.
            text.assetHandler.readContent = { _ in content }
            text.paste(nil)
            try await finish(text.assetHandler)
            XCTAssertNil(session.assetMessage)
            XCTAssertEqual(session.text, text.string)
            XCTAssertTrue(text.string.hasPrefix("before\n!["))
            let id = try XCTUnwrap(workspace.snapshot?.documents.first { $0.relativePath == "restored.md" }?.id)
            XCTAssertTrue(text.string.contains("media/\(id.uuidString)/"))
            let directory = root.appendingPathComponent("media/\(id.uuidString)")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            for width: CGFloat in [0, 1, 80, 320, 1200, 4096] {
                scroll.setFrameSize(NSSize(width: width, height: 200))
                scroll.tile()
                text.viewDidMoveToWindow()
                text.layoutManager?.ensureLayout(for: text.textContainer!)
                XCTAssertTrue(text.frame.height.isFinite)
                XCTAssertEqual(session.text, text.string)
            }
        }
    }

    @MainActor func testUnresolvedDocumentReportsAssetBannerForPasteAndDrop() async throws {
        let workspace = LibraryWorkspace()
        let session = workspace.editor
        workspace.root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        session.url = workspace.root?.appendingPathComponent("missing.md")
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        text.configureAssetInsertion(session: session, workspace: workspace)
        // A stale cached ID must not bypass the current snapshot's missing ID.
        text.assetHandler.documentID = UUID()
        text.string = "unchanged"
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        for content in [EditorPasteContent(plainText: "filename", png: png),
                        EditorPasteContent(fileURLs: [URL(fileURLWithPath: "/tmp/missing.png")])] {
            session.assetMessage = nil
            text.assetHandler.readContent = { _ in content }
            XCTAssertFalse(text.assetHandler.paste(from: board))
            XCTAssertNotNil(session.assetMessage)
            XCTAssertNil(session.banner)
            XCTAssertEqual(text.string, "unchanged")
            XCTAssertFalse(text.assetHandler.busy)
            XCTAssertTrue(text.isEditable)
        }
        session.assetMessage = nil
        XCTAssertFalse(text.readSelection(from: board, type: .fileURL))
        XCTAssertNotNil(session.assetMessage)
        session.assetMessage = nil
        XCTAssertFalse(text.assetHandler.add([.init(name: "image.png", isImage: true, data: png)]))
        XCTAssertNotNil(session.assetMessage)
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
            XCTAssertTrue(inserted.hasPrefix("before\n![image](media/"))
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
        let directory = root.appendingPathComponent("media/\(id.uuidString)")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        let file = root.appendingPathComponent("report.pdf")
        try Data([1, 2]).write(to: file)
        text.string = ""
        text.setSelectedRange(NSRange(location: 0, length: 0))
        text.assetHandler.readContent = { _ in EditorPasteContent(fileURLs: [file]) }
        XCTAssertTrue(text.readSelection(from: board, type: .fileURL))
        try await finish(text.assetHandler)
        XCTAssertTrue(text.string.hasPrefix("[report.pdf](media/"))
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

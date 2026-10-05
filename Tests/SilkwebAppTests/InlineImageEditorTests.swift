import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import SilkwebCore
@testable import Silkweb

final class InlineImageEditorTests: XCTestCase {
    /// Uses only the pre-existing editor API so the Orchestrator can run this
    /// unchanged on the pre-fix tree: it must fail at the image-view count.
    @MainActor
    func testRealEditorInlineImagesAcrossResizeEditsModesAndTabs() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = disposableDefaults("InlineImages")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        let url = root.appendingPathComponent("Document.md")
        let source = "Before\n![Small](small.png)\nAfter\n![Remote](https://example.invalid/no.png)\n![Missing](missing.png)\n"
        let bytes = Data(source.utf8)
        try bytes.write(to: url)
        try Data("Other document".utf8).write(to: root.appendingPathComponent("Other.md"))
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent("small.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false; workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let documents = try XCTUnwrap(workspace.snapshot).documents
        let opened = await workspace.openTab(try XCTUnwrap(documents.first { $0.relativePath == "Document.md" }), pinned: true)
        XCTAssertTrue(opened)
        let tabID = try XCTUnwrap(workspace.activeTabID)
        let controller = LibrarySplitViewController(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        func settle() async throws {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            controller.view.layoutSubtreeIfNeeded()
        }
        try await settle()
        let editor = try XCTUnwrap(workspace.preview.editor)
        func views() -> [NSView] { editor.subviews.filter { $0.identifier?.rawValue == "inline-image" } }
        XCTAssertEqual(views().count, 3, "must fail before inline-image implementation")
        let range = (source as NSString).lineRange(for: (source as NSString).range(of: "![Small]"))
        for size in [NSSize(width: 900, height: 560), NSSize(width: 1400, height: 1200), NSSize(width: 1100, height: 900)] {
            window.setContentSize(size)
            for mode in [DocumentViewMode.split, .preview, .editor] {
                workspace.preview.mode = mode
                try await settle()
                if mode == .preview { continue }
                let view = try XCTUnwrap(views().first)
                XCTAssertLessThanOrEqual(view.frame.width, try XCTUnwrap(editor.textContainer).containerSize.width)
                XCTAssertEqual(view.frame.width, 40, accuracy: 0.01)
                XCTAssertEqual(view.frame.height, 20, accuracy: 0.01)
                let layout = try XCTUnwrap(editor.layoutManager)
                let glyph = layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
                let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
                XCTAssertEqual(view.frame.minY, line.maxY + editor.textContainerOrigin.y + 6, accuracy: 0.01)
                let nextGlyph = layout.glyphIndexForCharacter(at: NSMaxRange(range))
                let nextLine = layout.lineFragmentUsedRect(forGlyphAt: nextGlyph, effectiveRange: nil)
                XCTAssertGreaterThanOrEqual(nextLine.minY + editor.textContainerOrigin.y, view.frame.maxY + 10)
                XCTAssertEqual(editor.string, source)
                await workspace.editor.flush()
                XCTAssertEqual(try Data(contentsOf: url), bytes)
            }
        }
        XCTAssertTrue(views()[1].accessibilityLabel()!.hasPrefix("Remote image not loaded"))
        XCTAssertEqual(views()[2].accessibilityLabel(), "Missing image: missing.png")
        editor.setSelectedRange(NSRange(location: range.location, length: 0))
        editor.moveDown(nil)
        XCTAssertEqual((editor.string as NSString).lineRange(for: editor.selectedRange()).location, NSMaxRange(range))
        editor.moveUp(nil)
        XCTAssertEqual((editor.string as NSString).lineRange(for: editor.selectedRange()).location, range.location)
        editor.setSelectedRange(NSRange(location: 0, length: 0)); editor.insertText("Start ", replacementRange: editor.selectedRange())
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0)); editor.insertText("End", replacementRange: editor.selectedRange())
        try await settle()
        XCTAssertEqual(editor.string, "Start " + source + "End")
        await workspace.editor.flush()
        XCTAssertEqual(try Data(contentsOf: url), Data(("Start " + source + "End").utf8))
        let otherOpened = await workspace.openTab(try XCTUnwrap(documents.first { $0.relativePath == "Other.md" }), pinned: true)
        XCTAssertTrue(otherOpened)
        try await settle()
        XCTAssertFalse(workspace.preview.editor?.subviews.contains { $0.identifier?.rawValue == "inline-image" } ?? true)
        workspace.activateTab(tabID, syncSelection: false)
        try await settle()
        XCTAssertTrue(workspace.preview.editor === editor)
        XCTAssertEqual(views().count, 3)
        XCTAssertFalse(window.isVisible)
    }
    /// 1.81: both scroll bar styles, never the machine's setting. Under legacy scroll bars the trailing
    /// images used to toggle the scroller and the frame shrank back below them on every sizing pass.
    @MainActor
    func testLargeImageStackAtEndAndCacheInvalidation() async throws {
        for style in [NSScroller.Style.legacy, .overlay] {
            try await largeImageStackAtEndAndCacheInvalidation(scrollerStyle: style)
        }
    }

    @MainActor
    private func largeImageStackAtEndAndCacheInvalidation(scrollerStyle: NSScroller.Style) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.png")
        func writeImage(width: Int, height: Int) throws {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try writeImage(width: 1600, height: 800)
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        scroll.scrollerStyle = scrollerStyle
        let editor = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        editor.inlineImages.configure(root: root, document: root.appendingPathComponent("Document.md"))
        editor.string = "~~~\n![Code](large.png)\n~~~\n\n![First](large.png) ![Second](large.png)"
        editor.styler.reload(); editor.inlineImages.schedule()
        func settle() async throws {
            editor.layoutEditor()
            try await Task.sleep(for: .milliseconds(500))
            editor.inlineImages.positionViews()
        }
        for size in [NSSize(width: 120, height: 100), NSSize(width: 800, height: 600), NSSize(width: 500, height: 150)] {
            window.setContentSize(size); try await settle()
            let views = editor.inlineImages.imageViews
            XCTAssertEqual(views.count, 2)
            guard views.count == 2 else { return }
            XCTAssertEqual(views[0].frame.width / views[0].frame.height, 2, accuracy: 0.01)
            XCTAssertLessThanOrEqual(views[0].frame.width, try XCTUnwrap(editor.textContainer).containerSize.width)
            XCTAssertLessThanOrEqual(views[0].frame.height, scroll.contentSize.height * 0.7 + 0.01)
            XCTAssertEqual(views[1].frame.minY, views[0].frame.maxY + 8, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(editor.frame.height, views[1].frame.maxY + 10, "\(size) style \(scrollerStyle.rawValue)")
            // Settled: another sizing pass leaves the frame and the images where they are.
            let settled = (editor.frame, views.map(\.frame))
            try await settle()
            XCTAssertEqual(editor.frame, settled.0, "\(size) style \(scrollerStyle.rawValue)")
            XCTAssertEqual(editor.inlineImages.imageViews.map(\.frame), settled.1, "\(size) style \(scrollerStyle.rawValue)")
            let bitmap = try XCTUnwrap(views[0].content.bitmap)
            XCTAssertLessThanOrEqual(bitmap.width, 1440, "ImageIO downsampled below the natural 1600 pixels")
        }
        let originalView = try XCTUnwrap(editor.inlineImages.imageViews.first)
        editor.inlineImages.schedule(); try await settle()
        XCTAssertTrue(editor.inlineImages.imageViews.first === originalView, "no-op refresh must not redraw/recreate images")
        try writeImage(width: 800, height: 1600)
        editor.inlineImages.schedule(); try await settle()
        let changed = try XCTUnwrap(editor.inlineImages.imageViews.first)
        XCTAssertEqual(changed.frame.width / changed.frame.height, 0.5, accuracy: 0.01)
        try FileManager.default.removeItem(at: file)
        editor.inlineImages.schedule(); try await settle()
        XCTAssertEqual(editor.inlineImages.imageViews.first?.content.message, "Missing image: large.png")
        XCTAssertFalse(window.isVisible)
    }

}

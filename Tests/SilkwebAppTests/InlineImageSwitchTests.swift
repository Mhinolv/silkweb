import AppKit
import ImageIO
import SilkwebCore
import UniformTypeIdentifiers
import XCTest

@testable import Silkweb

/// silkweb-1.79: switching or renaming the editor's document must drop the previous
/// note's image views and reserved line heights. Uses only pre-existing editor API.
final class InlineImageSwitchTests: XCTestCase {
    @MainActor
    func testDocumentSwitchClearsPreviousImageViewsAndHeights() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("photo.png")
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(image as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let editor = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        let images = "# Images\n\n![One](photo.png)\n\n![Two](photo.png)\n\nEnd"
        func load(_ name: String, _ text: String) {
            editor.inlineImages.configure(root: root, document: root.appendingPathComponent(name))
            editor.string = text
            editor.styler.reload(); editor.inlineImages.schedule()
        }
        func settle() async throws {
            editor.layoutEditor()
            try await Task.sleep(for: .milliseconds(500))
            editor.inlineImages.positionViews()
        }
        func subviews() -> [NSView] { editor.subviews.filter { $0.identifier?.rawValue == "inline-image" } }
        func lineHeight() throws -> CGFloat {
            let layout = try XCTUnwrap(editor.layoutManager)
            layout.ensureLayout(for: try XCTUnwrap(editor.textContainer))
            return layout.usedRect(for: try XCTUnwrap(editor.textContainer)).height
        }

        for size in [NSSize(width: 800, height: 600), NSSize(width: 320, height: 240)] {
            window.setContentSize(size)
            load("Images.md", images); try await settle()
            XCTAssertEqual(editor.inlineImages.imageViews.count, 2)
            XCTAssertEqual(subviews().count, 2)
            let withImages = try lineHeight()

            load("Plain.md", "# Plain\n\nNo pictures here.\n\n\nEnd"); try await settle()
            XCTAssertEqual(editor.inlineImages.imageViews.count, 0, "previous note's image views survived the switch")
            XCTAssertEqual(subviews().count, 0)
            let plain = try lineHeight()
            XCTAssertLessThan(plain, withImages - 100, "previous note's image heights survived the switch")

            // Back and forth repeatedly: never accumulates views.
            for _ in 0..<3 {
                load("Images.md", images); try await settle()
                XCTAssertEqual(subviews().count, 2)
                load("Plain.md", "Plain"); try await settle()
                XCTAssertEqual(subviews().count, 0)
            }

            // Rename keeps the same text: the images return without duplicates.
            load("Images.md", images); try await settle()
            load("Renamed.md", images); try await settle()
            XCTAssertEqual(editor.inlineImages.imageViews.count, 2)
            XCTAssertEqual(subviews().count, 2)
            XCTAssertTrue(editor.inlineImages.imageViews.allSatisfy { !$0.isHidden })
        }
        XCTAssertFalse(window.isVisible)
    }
}

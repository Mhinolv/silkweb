import AppKit
import XCTest
@testable import Silkweb

final class MarkdownTextViewTests: XCTestCase {
    @MainActor
    func testOffscreenEditorDocumentAndResizeSweep() async throws {
        let style = EditorStyle()
        let scroll = MarkdownTextView.makeEditorScrollView(style: style)
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let container = try XCTUnwrap(text.textContainer)
        XCTAssertFalse(container.widthTracksTextView)
        XCTAssertFalse(container.heightTracksTextView)

        let paragraph = "A Markdown paragraph with Unicode: café, 日本語, 👩🏽‍💻.\n\n"
        let documents = ["", "x", String(repeating: paragraph, count: 100)]
        let boundary = style.maximumWidth + 2 * style.horizontalInset
        let widths: [CGFloat] = [0, 1, 39, 79, 80, 81, 320, boundary - 1, boundary, boundary + 1, 1200, 4096]
        let heights: [CGFloat] = [0, 1, 24, 200, 760, 2160]
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        host.addSubview(scroll)

        for document in documents {
            text.string = document
            text.setSelectedRange(NSRange(location: (document as NSString).length, length: 0))
            // Grow and shrink, as when the sidebar or full-screen mode changes the viewport.
            for width in widths + widths.reversed() {
                for height in heights {
                    scroll.setFrameSize(NSSize(width: width, height: height))
                    scroll.tile()
                    scroll.layoutSubtreeIfNeeded()
                    text.layoutManager?.ensureLayout(for: container)
                    text.layoutEditor()
                    let viewport = scroll.contentSize
                    let expectedWidth = max(1, min(style.maximumWidth, viewport.width - 80))
                    XCTAssertEqual(container.containerSize.width, expectedWidth, accuracy: 0.001)
                    XCTAssertEqual(text.textContainerInset.width, max(40, (viewport.width - expectedWidth) / 2), accuracy: 0.001)
                    XCTAssertEqual(text.textContainerInset.height, 24)
                    XCTAssertEqual(scroll.contentInsets.bottom, viewport.height / 2, accuracy: 0.001)
                    XCTAssertEqual(text.minSize.height, viewport.height, accuracy: 0.001)
                    XCTAssertTrue(text.frame.height.isFinite)
                    XCTAssertEqual(text.string, document)
                    let geometry = container.containerSize
                    text.layoutEditor()
                    XCTAssertEqual(container.containerSize, geometry)
                }
            }
        }
        // Exercise reattachment and the window lifecycle hook without showing a window.
        scroll.removeFromSuperview()
        host.addSubview(scroll)
        text.viewDidMoveToWindow()
        text.layoutEditor()
        XCTAssertNil(scroll.window)
    }

    @MainActor
    func testGeometryCallbackCannotReenterAndUnchangedLayoutDoesNotWrite() async throws {
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        scroll.setFrameSize(NSSize(width: 1200, height: 760))
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let container = ReentrantTextContainer(size: .zero)
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        text.replaceTextContainer(container)
        container.containerSize = .zero
        container.geometryWrites = 0
        let originalInset = text.textContainerInset
        text.style.topInset = 48
        container.onGeometryChange = { [weak text] in
            text?.layoutEditor()
            // A nested layout must return before writing the remaining geometry.
            XCTAssertEqual(text?.textContainerInset, originalInset)
        }
        text.layoutEditor()
        XCTAssertEqual(container.geometryWrites, 1)
        XCTAssertEqual(text.textContainerInset.height, 48)
        let inset = text.textContainerInset
        let minimum = text.minSize
        let contentInsets = scroll.contentInsets
        for _ in 0..<100 { text.layoutEditor() }
        XCTAssertEqual(container.geometryWrites, 1)
        XCTAssertEqual(text.textContainerInset, inset)
        XCTAssertEqual(text.minSize, minimum)
        XCTAssertEqual(scroll.contentInsets.bottom, contentInsets.bottom)
        XCTAssertEqual(scroll.contentInsets.top, contentInsets.top)
        XCTAssertEqual(scroll.contentInsets.left, contentInsets.left)
        XCTAssertEqual(scroll.contentInsets.right, contentInsets.right)
    }
}

/// Simulates the synchronous geometry callback responsible for the original stack overflow.
private final class ReentrantTextContainer: NSTextContainer {
    var geometryWrites = 0
    var onGeometryChange: (() -> Void)?
    override var containerSize: NSSize {
        didSet {
            geometryWrites += 1
            onGeometryChange?()
        }
    }
}

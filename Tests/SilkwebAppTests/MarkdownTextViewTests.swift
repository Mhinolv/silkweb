import AppKit
import SilkwebCore
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
        let widths: [CGFloat] = [0, 1, 39, 47, 95, 96, 97, 320, boundary - 1, boundary, boundary + 1, 1200, 4096]
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
                    let expectedWidth = max(1, min(style.maximumWidth, viewport.width - 2 * style.horizontalInset))
                    XCTAssertEqual(container.containerSize.width, expectedWidth, accuracy: 0.001)
                    XCTAssertEqual(
                        text.textContainerInset.width, max(style.horizontalInset, (viewport.width - expectedWidth) / 2),
                        accuracy: 0.001)
                    XCTAssertEqual(text.textContainerInset.height, 16)
                    XCTAssertEqual(scroll.contentInsets.bottom, 0, accuracy: 0.001)
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

extension MarkdownTextViewTests {
    @MainActor
    func testFormattingUndoIMEAndIndentOffscreen() throws {
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let delegate = FormattingUndoDelegate()
        text.delegate = delegate
        delegate.manager.groupsByEvent = false
        for command in [
            MarkdownCommand.bold, .italic, .strike, .inlineCode, .link, .heading(0), .heading(1), .heading(6), .quote,
            .bullet, .numbered, .task, .codeBlock, .indent, .outdent,
        ] {
            text.string = "    日本語 👩🏽‍💻\nsecond"
            text.styler.reload()
            let original = text.string
            text.setSelectedRange(NSRange(location: 4, length: original.utf16.count - 4))
            delegate.manager.removeAllActions()
            text.format(command)
            text.styler.restyle()
            let formatted = text.string
            XCTAssertTrue(delegate.manager.canUndo)
            XCTAssertEqual(delegate.manager.undoActionName, command.name)
            delegate.manager.undo()
            XCTAssertEqual(text.string, original)
            XCTAssertFalse(delegate.manager.canUndo)
            delegate.manager.redo()
            XCTAssertEqual(text.string, formatted)
            for width: CGFloat in [0, 1, 80, 320, 1200, 4096] {
                scroll.setFrameSize(NSSize(width: width, height: 760))
                scroll.tile()
                text.layoutEditor()
                text.layoutManager?.ensureLayout(for: text.textContainer!)
                XCTAssertEqual(text.string, formatted)
            }
        }
        delegate.manager.groupsByEvent = true
        text.string = "- item"
        text.setSelectedRange(NSRange(location: 6, length: 0))
        text.insertNewline(nil)
        XCTAssertEqual(text.string, "- item\n- ")
        text.insertNewline(nil)
        XCTAssertEqual(text.string, "- item\n")
        text.string = "plain"
        text.setSelectedRange(NSRange(location: 5, length: 0))
        text.insertTab(nil)
        XCTAssertEqual(text.string, "plain    ")
        text.string = "- item"
        text.setSelectedRange(NSRange(location: 6, length: 0))
        text.insertTab(nil)
        XCTAssertEqual(text.string, "    - item")
        text.insertBacktab(nil)
        XCTAssertEqual(text.string, "- item")
        text.insertLineBreak(nil)
        XCTAssertEqual(text.string, "- item\n")

        text.string = "IME"
        text.setMarkedText(
            "日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 0, length: 3))
        XCTAssertTrue(text.hasMarkedText())
        let marked = text.string
        text.format(.bold)
        XCTAssertEqual(text.string, marked)
        text.unmarkText()
        text.isEditable = false
        text.format(.bold)
        XCTAssertEqual(text.string, marked)
    }

    @MainActor
    func testIncrementalStylingDoesNotChangeTextOrUndoAndPropagatesFences() throws {
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let storage = try XCTUnwrap(text.textStorage)
        let delegate = FormattingUndoDelegate()
        text.delegate = delegate
        text.string =
            "# Title\n**bold** and `code`\n```\nfenced\n```\nafter\n" + String(repeating: "plain\n", count: 1000)
        text.styler.reload()
        let original = text.string
        let font = try XCTUnwrap(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, 15)
        let code = (original as NSString).range(of: "fenced").location
        XCTAssertNil(storage.attribute(.backgroundColor, at: code, effectiveRange: nil))
        delegate.manager.removeAllActions()
        text.setSelectedRange(NSRange(location: 2, length: 1))
        text.insertText("X", replacementRange: text.selectedRange())
        text.styler.restyle()
        XCTAssertLessThan(text.styler.lastStyledRange.length, 60)
        XCTAssertEqual(
            text.string, (original as NSString).replacingCharacters(in: NSRange(location: 2, length: 1), with: "X"))
        let opening = (text.string as NSString).range(of: "```\n")
        text.insertText("", replacementRange: opening)
        text.styler.restyle()
        let newCode = (text.string as NSString).range(of: "fenced").location
        let after = (text.string as NSString).range(of: "after").location
        XCTAssertNil(storage.attribute(.backgroundColor, at: newCode, effectiveRange: nil))
        XCTAssertEqual(
            storage.attribute(.foregroundColor, at: after, effectiveRange: nil) as? NSColor, .secondaryLabelColor)
        let saved = text.string
        text.styler.reload()
        XCTAssertEqual(text.string, saved)
        scroll.setFrameSize(NSSize(width: 1, height: 1))
        text.layoutEditor()
        text.viewDidMoveToWindow()
        XCTAssertTrue(text.frame.height.isFinite)
    }
}

@MainActor private final class FormattingUndoDelegate: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

extension MarkdownTextViewTests {
    @MainActor
    func testSourceTypographyAcrossHeadingLevelsAppearancesAndResize() throws {
        for size in [1.0, 15, 72] {
            var preferences = WritingPreferences()
            preferences.fontSize = size
            let style = EditorStyle(preferences: preferences)
            let scroll = MarkdownTextView.makeEditorScrollView(style: style)
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 1400, height: 900))
            host.addSubview(scroll)
            let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
            let storage = try XCTUnwrap(text.textStorage)
            XCTAssertEqual(style.bodyFont.fontName, "Menlo-Regular")
            XCTAssertEqual(style.lineHeight, 1.6)
            XCTAssertEqual(style.paragraphStyle.paragraphSpacing, 0)
            XCTAssertEqual(
                style.paragraphStyle.defaultTabInterval,
                4 * (" " as NSString).size(withAttributes: [.font: style.bodyFont]).width)
            let source =
                (1...6).map { String(repeating: "#", count: $0) + " Heading \($0)" }.joined(separator: "\n")
                + "\nBody **bold** *italic* `code`\n```swift\nfenced\n```\n"
            for appearance in [
                NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            ] {
                host.appearance = NSAppearance(named: appearance)
                text.string = source
                text.styler.reload()
                for level in 1...6 {
                    let location = (source as NSString).range(of: "Heading \(level)").location
                    let font = try XCTUnwrap(storage.attribute(.font, at: location, effectiveRange: nil) as? NSFont)
                    XCTAssertEqual(font.pointSize, style.bodyFont.pointSize)
                    XCTAssertTrue(NSFontManager.shared.traits(of: font).contains(.boldFontMask))
                    XCTAssertEqual(
                        storage.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor,
                        .editorHeading)
                    for marker in (location - level - 1)..<location {
                        XCTAssertEqual(
                            storage.attribute(.foregroundColor, at: marker, effectiveRange: nil) as? NSColor,
                            .tertiaryLabelColor)
                        XCTAssertEqual(
                            storage.attribute(.font, at: marker, effectiveRange: nil) as? NSFont, style.bodyFont)
                    }
                }
                let body = (source as NSString).range(of: "Body").location
                XCTAssertEqual(storage.attribute(.font, at: body, effectiveRange: nil) as? NSFont, style.bodyFont)
                let code = (source as NSString).range(of: "code").location
                XCTAssertNotNil(storage.attribute(.backgroundColor, at: code, effectiveRange: nil))
                let fenced = (source as NSString).range(of: "fenced").location
                XCTAssertNil(storage.attribute(.backgroundColor, at: fenced, effectiveRange: nil))
                for width: CGFloat in [0, 1, 80, 320, 800, 1400, 4096, 320] {
                    scroll.setFrameSize(NSSize(width: width, height: 900))
                    scroll.tile()
                    text.layoutEditor()
                    text.layoutManager?.ensureLayout(for: text.textContainer!)
                    XCTAssertTrue(text.frame.height.isFinite)
                    XCTAssertEqual(text.string, source)
                }
            }
            scroll.removeFromSuperview()
            host.addSubview(scroll)
            text.viewDidMoveToWindow()
        }
    }

    @MainActor
    func testSavedWritingPreferencesFeedEditorMetrics() throws {
        let defaults = disposableDefaults("TypographyTests")
        XCTAssertEqual(WritingPreferences.load(from: defaults), WritingPreferences())
        defaults.set(
            Data(
                "{\"fontFamily\":\"Helvetica\",\"fontSize\":21,\"lineHeight\":1.75,\"maximumWidth\":900,\"future\":true}"
                    .utf8), forKey: "writingPreferences")
        let style = EditorStyle(preferences: WritingPreferences.load(from: defaults))
        XCTAssertEqual(style.bodyFont.familyName, "Helvetica")
        XCTAssertEqual(style.bodyFont.pointSize, 21)
        XCTAssertEqual(style.lineHeight, 1.75)
        XCTAssertEqual(style.maximumWidth, 900)
        let scroll = MarkdownTextView.makeEditorScrollView(style: style)
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        text.string = "# Title\nBody"
        text.styler.reload()
        XCTAssertEqual((text.textStorage?.attribute(.font, at: 2, effectiveRange: nil) as? NSFont)?.pointSize, 21)
    }
}

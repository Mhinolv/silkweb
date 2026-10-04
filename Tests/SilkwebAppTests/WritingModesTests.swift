import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import SilkwebCore
@testable import Silkweb

/// silkweb-1.27: Focus and Typewriter modes in the real detail hierarchy (split view
/// controller, tabs, editor/split/preview switches), offscreen.
final class WritingModesTests: XCTestCase {
    static let focusDocument = """
    # Focus Fixture

    First paragraph with **bold** and `code` text.

    ## Heading two

    Active paragraph line one with *italic*
    active paragraph line two.

    ![Figure](figure.png)

    - item one
    - item two

    ```swift
    let fenced = true
    ```

    Closing paragraph.
    """

    @MainActor
    private final class Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let workspace: LibraryWorkspace
        let controller: LibrarySplitViewController
        let window: NSWindow
        init(files: [String: String], open: String) async throws {
            _ = NSApplication.shared
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            suite = "Silkweb.WritingModes." + UUID().uuidString
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            for (name, text) in files { try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8) }
            let context = try XCTUnwrap(CGContext(data: nil, width: 600, height: 300, bitsPerComponent: 8, bytesPerRow: 2400,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.systemTeal.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent("figure.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
            workspace.canSaveWindowSession = false
            workspace.root = root
            workspace.install(try await LibraryScanner.scan(root: root))
            let opened = await workspace.openTab(try XCTUnwrap(workspace.snapshot?.documents.first { $0.relativePath == open }), pinned: true)
            XCTAssertTrue(opened)
            controller = LibrarySplitViewController(workspace: workspace, autosaveName: suite)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(NSSize(width: 1400, height: 900))
        }
        func settle(_ milliseconds: Int = 400) async throws {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(milliseconds))
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        func close() {
            window.contentViewController = nil
            window.close()
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    @MainActor
    private func capture(_ editor: PlainMarkdownTextView) throws -> NSBitmapImageRep {
        let rect = editor.visibleRect
        let bitmap = try XCTUnwrap(editor.bitmapImageRepForCachingDisplay(in: rect))
        editor.cacheDisplay(in: rect, to: bitmap)
        return bitmap
    }

    /// The storage with every attribute, so toggling can be shown not to touch 1.12 styling.
    @MainActor
    private func styling(_ editor: PlainMarkdownTextView) -> NSAttributedString {
        NSAttributedString(attributedString: editor.textStorage ?? NSTextStorage())
    }

    /// Layout-manager temporary attributes (spelling marks etc.) at sampled offsets.
    @MainActor
    private func temporaryAttributes(_ editor: PlainMarkdownTextView) -> [String] {
        guard let layout = editor.layoutManager else { return [] }
        return stride(from: 0, to: editor.string.utf16.count, by: 7).map { index in
            layout.temporaryAttributes(atCharacterIndex: index, effectiveRange: nil).keys.map(\.rawValue).sorted().joined(separator: ",")
        }
    }

    @MainActor
    private func key(_ editor: PlainMarkdownTextView, _ code: UInt16, _ characters: String, modifiers: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                   windowNumber: editor.window?.windowNumber ?? 0, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        editor.keyDown(with: event)
    }

    @MainActor
    func testFocusDimsOtherParagraphsAndImagesWithoutTouchingStyling() async throws {
        let fixture = try await Fixture(files: ["Focus.md": Self.focusDocument], open: "Focus.md")
        defer { fixture.close() }
        let workspace = fixture.workspace
        try await fixture.settle()
        let editor = try XCTUnwrap(workspace.preview.editor)
        let layout = try XCTUnwrap(editor.layoutManager)
        let source = editor.string as NSString
        for _ in 0..<40 where !(editor.inlineImages.imageViews.first?.content.bitmap != nil) { try await fixture.settle(100) }
        let image = try XCTUnwrap(editor.inlineImages.imageViews.first)
        XCTAssertNotNil(image.content.bitmap, "inline image decoded")
        let dimmed = WritingModeController.dimmedOpacity
        XCTAssertTrue(dimmed == 0.30 || dimmed == 0.55)

        editor.setSelectedRange(NSRange(location: source.range(of: "line one").location, length: 0))
        try await fixture.settle()
        let before = try capture(editor)
        let styled = styling(editor)
        let temporary = temporaryAttributes(editor)
        let canUndo = editor.undoManager?.canUndo
        XCTAssertEqual(image.alphaValue, 1)

        workspace.setWritingModes(focus: true)
        XCTAssertTrue(workspace.focusMode)
        try await fixture.settle()
        XCTAssertTrue(workspace.menuState.value.focusMode, "View menu checkmark follows")
        XCTAssertFalse(editor.writingModes.isFading, "the 150 ms fade has finished")
        let active = try XCTUnwrap(editor.writingModes.activeRange)
        XCTAssertEqual(source.substring(with: active), "Active paragraph line one with *italic*\nactive paragraph line two.\n")
        XCTAssertTrue(styling(editor).isEqual(to: styled), "1.12 styling attributes untouched")
        XCTAssertEqual(editor.string, Self.focusDocument)
        XCTAssertEqual(editor.undoManager?.canUndo, canUndo, "no undo registration")
        // Spelling marks may arrive asynchronously; Focus itself adds no colour.
        XCTAssertEqual(temporaryAttributes(editor).filter { $0.contains("NSColor") }, temporary.filter { $0.contains("NSColor") })
        for index in stride(from: 0, to: source.length, by: 7) {
            XCTAssertNil(layout.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil))
        }
        XCTAssertEqual(image.alphaValue, dimmed, accuracy: 0.001, "image in a dimmed paragraph matches the text")

        // Pixels: the active band is unchanged; everything else is blended toward the surface.
        let after = try capture(editor)
        let band = try XCTUnwrap(editor.writingModes.band(for: active))
        let visible = editor.visibleRect
        let scale = CGFloat(after.pixelsHigh) / visible.height
        let surface = try XCTUnwrap(before.colorAt(x: 2, y: 2))
        var checkedDim = 0, checkedText = 0, checkedActive = 0
        for row in stride(from: 0, to: after.pixelsHigh, by: 3) {
            let y = visible.minY + (CGFloat(row) + 0.5) / scale
            // Skip a pixel either side of the band edges.
            if abs(y - band.top) < 2 || abs(y - band.bottom) < 2 { continue }
            if image.frame.insetBy(dx: -2, dy: -2).contains(NSPoint(x: image.frame.midX, y: y)) { continue }
            let inside = y >= band.top && y < band.bottom
            for column in stride(from: 0, to: after.pixelsWide, by: 5) {
                guard let a = before.colorAt(x: column, y: row), let b = after.colorAt(x: column, y: row) else { continue }
                if inside {
                    XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 1.5 / 255)
                    XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 1.5 / 255)
                    checkedActive += 1
                } else {
                    let expected = a.redComponent * dimmed + surface.redComponent * (1 - dimmed)
                    XCTAssertEqual(b.redComponent, expected, accuracy: 3 / 255, "row \(row) column \(column)")
                    XCTAssertEqual(b.blueComponent, a.blueComponent * dimmed + surface.blueComponent * (1 - dimmed), accuracy: 3 / 255)
                    checkedDim += 1
                    if abs(a.redComponent - surface.redComponent) > 0.25 { checkedText += 1 }
                }
            }
        }
        XCTAssertGreaterThan(checkedActive, 100)
        XCTAssertGreaterThan(checkedDim, 1000)
        XCTAssertGreaterThan(checkedText, 20, "dimmed text pixels (heading, body, code) were compared")

        // Off restores the exact pixels and image opacity.
        workspace.setWritingModes(focus: false)
        try await fixture.settle()
        XCTAssertNil(editor.writingModes.activeRange)
        XCTAssertEqual(image.alphaValue, 1)
        let restored = try capture(editor)
        XCTAssertEqual(restored.tiffRepresentation, before.tiffRepresentation, "focus off draws exactly as before")

        // Caret in the image paragraph lights its source line, never the image (1.68); other paragraphs stay dim.
        workspace.setWritingModes(focus: true)
        try await fixture.settle()
        editor.setSelectedRange(NSRange(location: source.range(of: "![Figure]").location, length: 0))
        try await fixture.settle()
        XCTAssertEqual(source.substring(with: try XCTUnwrap(editor.writingModes.activeRange)), "![Figure](figure.png)\n")
        XCTAssertEqual(image.alphaValue, dimmed, accuracy: 0.001)
        XCTAssertEqual(editor.writingModes.opacity(at: try XCTUnwrap(editor.writingModes.band(for: NSRange(location: 0, length: 1))).top + 1), dimmed, accuracy: 0.001)

        // Fenced block and list item units; a multi-paragraph selection lights every touched paragraph.
        editor.setSelectedRange(NSRange(location: source.range(of: "let fenced").location, length: 0))
        try await fixture.settle()
        XCTAssertEqual(source.substring(with: try XCTUnwrap(editor.writingModes.activeRange)), "```swift\nlet fenced = true\n```\n")
        editor.setSelectedRange(NSRange(location: source.range(of: "item two").location, length: 0))
        try await fixture.settle()
        XCTAssertEqual(source.substring(with: try XCTUnwrap(editor.writingModes.activeRange)), "- item two\n")
        let from = source.range(of: "First paragraph").location
        let to = source.range(of: "line one").location
        editor.setSelectedRange(NSRange(location: from, length: to - from))
        try await fixture.settle()
        let spanning = source.substring(with: try XCTUnwrap(editor.writingModes.activeRange))
        XCTAssertTrue(spanning.hasPrefix("First paragraph") && spanning.hasSuffix("line two.\n"), spanning)
        XCTAssertEqual(image.alphaValue, dimmed, accuracy: 0.001)

        // Editing in Focus: styling continues (1.12) and the image overlay stays put (1.60).
        let frame = image.frame
        let end = source.range(of: "line two.").location + 9
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.insertText(" **typed**", replacementRange: editor.selectedRange())
        try await fixture.settle(700)
        let typed = (editor.string as NSString).range(of: "typed")
        let font = try XCTUnwrap(editor.textStorage?.attribute(.font, at: typed.location, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), "styler still styles typed text")
        XCTAssertTrue(editor.inlineImages.imageViews.first === image, "overlay view reused, no flash")
        XCTAssertEqual(image.frame.size, frame.size)
        XCTAssertEqual(image.frame.minY, frame.minY, accuracy: 1, "same line count, same slot")
        XCTAssertFalse(image.isHidden)
        XCTAssertEqual(image.alphaValue, dimmed, accuracy: 0.001)
        XCTAssertTrue(source.substring(with: try XCTUnwrap(editor.writingModes.activeRange)).hasSuffix("**typed**\n"))

        // Preview-only disables the items but keeps the state; the editor returns still focused.
        workspace.preview.mode = .preview
        try await fixture.settle()
        XCTAssertFalse(workspace.canToggleWritingModes)
        XCTAssertTrue(workspace.focusMode)
        for mode in [DocumentViewMode.split, .editor] {
            workspace.preview.mode = mode
            try await fixture.settle()
            XCTAssertTrue(workspace.canToggleWritingModes)
            XCTAssertTrue(try XCTUnwrap(workspace.preview.editor).writingModes.focus, "\(mode)")
            XCTAssertEqual(image.alphaValue, dimmed, accuracy: 0.001)
        }
        // The window session carries the modes (per window, restored on relaunch).
        let metadata = workspace.windowMetadata()
        XCTAssertTrue(metadata.focusMode)
        XCTAssertFalse(metadata.typewriterMode)
        workspace.setWritingModes(focus: false)
        try await fixture.settle()
        XCTAssertEqual(image.alphaValue, 1)
        await workspace.restoreTabs(metadata)
        try await fixture.settle()
        XCTAssertTrue(workspace.focusMode)
        XCTAssertTrue(try XCTUnwrap(workspace.preview.editor).writingModes.focus)
        XCTAssertFalse(fixture.window.isVisible)
    }

    static let adjacentDocument = """
    # Adjacent Fixture

    Intro paragraph above the figure.

    ![Figure](figure.png)
    ![Missing](missing.png)
    Caption typed directly under the images.

    Other paragraph below.
    """

    /// silkweb-1.68: images are never part of the bright unit, even when the caret's
    /// paragraph (no blank line) contains their source lines.
    @MainActor
    func testFocusKeepsImagesDimmedInTheActiveParagraph() async throws {
        let fixture = try await Fixture(files: ["Adjacent.md": Self.adjacentDocument], open: "Adjacent.md")
        defer { fixture.close() }
        let workspace = fixture.workspace
        try await fixture.settle()
        let editor = try XCTUnwrap(workspace.preview.editor)
        func source() -> NSString { editor.string as NSString }
        for _ in 0..<40 where !(editor.inlineImages.imageViews.count == 2 && editor.inlineImages.imageViews[0].content.bitmap != nil) {
            try await fixture.settle(100)
        }
        let images = editor.inlineImages.imageViews
        XCTAssertEqual(images.count, 2, "decoded bitmap and missing-file placeholder")
        XCTAssertNotNil(images.first?.content.bitmap, "inline image decoded")
        XCTAssertNil(images.last?.content.bitmap, "placeholder chip")
        let dimmed = WritingModeController.dimmedOpacity
        func assertDimmed(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
            for view in editor.inlineImages.imageViews {
                XCTAssertFalse(view.isHidden, message, file: file, line: line)
                XCTAssertEqual(view.alphaValue, dimmed, accuracy: 0.001, "\(view.content.reference.alt): \(message)", file: file, line: line)
            }
        }
        /// The source glyphs follow paragraph focus: bright at the caret line.
        func assertCaretLineBright(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let caret = try XCTUnwrap(editor.writingModes.caretLine(at: editor.selectedRange().location))
            XCTAssertEqual(editor.writingModes.opacity(at: caret.midY), 1, accuracy: 0.001, message, file: file, line: line)
        }

        for typewriter in [false, true] {
            workspace.setWritingModes(focus: false, typewriter: typewriter)
            try await fixture.settle()
            XCTAssertTrue(editor.inlineImages.imageViews.allSatisfy { $0.alphaValue == 1 }, "focus off restores alpha 1")
            editor.setSelectedRange(NSRange(location: source().range(of: "Caption").location + 7, length: 0))
            workspace.setWritingModes(focus: true)
            try await fixture.settle()
            XCTAssertFalse(editor.writingModes.isFading)
            let active = source().substring(with: try XCTUnwrap(editor.writingModes.activeRange))
            XCTAssertTrue(active.hasPrefix("![Figure]") && active.contains("Caption"), "images share the caret's paragraph: \(active)")
            let slot = try XCTUnwrap(images.first).frame.midY
            let band = try XCTUnwrap(editor.writingModes.band(for: try XCTUnwrap(editor.writingModes.activeRange)))
            XCTAssertTrue(slot > band.top && slot < band.bottom, "the image slot lies inside the bright band")
            assertDimmed("caret in the caption, before typing (typewriter \(typewriter))")
            try assertCaretLineBright("caption line bright")

            // Typing in the caption: dimmed on the same turn, while scheduled updates run, and after.
            editor.insertText(" typed", replacementRange: editor.selectedRange())
            assertDimmed("during insertText")
            try await fixture.settle(50)
            assertDimmed("after the focus update")
            try await fixture.settle(400)
            assertDimmed("after the image reparse")
            XCTAssertTrue(editor.inlineImages.imageViews.first === images.first, "overlay view reused (1.60)")
            try assertCaretLineBright("caption line bright after typing")

            // Caret on the image source line: its glyphs are bright, the bitmap below stays dim.
            editor.setSelectedRange(NSRange(location: source().range(of: "![Figure]").location + 3, length: 0))
            try await fixture.settle()
            assertDimmed("caret on the image source line")
            try assertCaretLineBright("source line bright")

            // A different paragraph: still dimmed, including while the paragraph-change fade runs.
            editor.setSelectedRange(NSRange(location: source().range(of: "Other paragraph").location, length: 0))
            try await Task.sleep(for: .milliseconds(20))
            assertDimmed("during the paragraph-change fade")
            editor.setSelectedRange(NSRange(location: source().range(of: "Intro paragraph").location, length: 0))
            try await Task.sleep(for: .milliseconds(20))
            assertDimmed("moving back across the images")
            try await fixture.settle()
            assertDimmed("caret in another paragraph")
            XCTAssertEqual(source().substring(with: try XCTUnwrap(editor.writingModes.activeRange)), "Intro paragraph above the figure.\n")
        }
        workspace.setWritingModes(focus: false, typewriter: false)
        try await fixture.settle()
        XCTAssertTrue(editor.inlineImages.imageViews.allSatisfy { $0.alphaValue == 1 })
        XCTAssertFalse(fixture.window.isVisible)
    }

    @MainActor
    func testFocusFadeRunsOnToggleAndParagraphChangeOnly() async throws {
        let fixture = try await Fixture(files: ["Focus.md": Self.focusDocument], open: "Focus.md")
        defer { fixture.close() }
        try await fixture.settle()
        let editor = try XCTUnwrap(fixture.workspace.preview.editor)
        let source = editor.string as NSString
        editor.setSelectedRange(NSRange(location: source.range(of: "line one").location, length: 0))
        try await fixture.settle()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fixture.workspace.setWritingModes(focus: true)
        XCTAssertEqual(editor.writingModes.isFading, !reduceMotion, "toggle fades (instant under Reduce Motion)")
        try await fixture.settle(300)
        XCTAssertFalse(editor.writingModes.isFading)
        // Moving within the paragraph changes nothing animated.
        editor.setSelectedRange(NSRange(location: source.range(of: "line two").location, length: 0))
        try await fixture.settle(50)
        XCTAssertFalse(editor.writingModes.isFading)
        // A different paragraph fades; a further change snaps it and starts again.
        editor.setSelectedRange(NSRange(location: source.range(of: "First paragraph").location, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(editor.writingModes.isFading, !reduceMotion)
        editor.setSelectedRange(NSRange(location: source.range(of: "Closing").location, length: 0))
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(source.substring(with: try XCTUnwrap(editor.writingModes.activeRange)), "Closing paragraph.")
        // Scrolling lands a running fade at once.
        if editor.writingModes.isFading, let scroll = editor.enclosingScrollView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY + 5))
            try await Task.sleep(for: .milliseconds(40))
            XCTAssertFalse(editor.writingModes.isFading)
        }
        try await fixture.settle(300)
        XCTAssertFalse(editor.writingModes.isFading)
    }

    @MainActor
    func testTypewriterAnchorsCaretLineAndOwnsPairedInsets() async throws {
        let fixture = try await Fixture(files: ["Long.md": LongEditorFixture.document], open: "Long.md")
        defer { fixture.close() }
        let workspace = fixture.workspace
        try await fixture.settle()
        let editor = try XCTUnwrap(workspace.preview.editor)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        try await fixture.settle()
        let clip = scroll.contentView
        XCTAssertEqual(scroll.contentInsets.top, 0)
        XCTAssertEqual(scroll.contentInsets.bottom, 0)
        // 1.54 caret geometry before the mode, for comparison.
        let probe = (editor.string as NSString).range(of: "Paragraph 3\n").location + 3
        let caretBefore = editor.textHeightInsertionRect(for: editor.lineFragmentCaretRect(at: probe))
        let fragmentBefore = editor.lineFragmentCaretRect(at: probe)

        func screenY(_ location: Int) throws -> CGFloat {
            try XCTUnwrap(editor.writingModes.caretLine(at: location)).midY - clip.bounds.minY
        }
        func assertAnchored(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try screenY(editor.selectedRange().location), WritingModeController.anchor * scroll.contentSize.height,
                           accuracy: 1.5, message, file: file, line: line)
        }
        func assertInsets(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let height = scroll.contentSize.height
            let font = editor.style.bodyFont
            let half = (try XCTUnwrap(editor.layoutManager).defaultLineHeight(for: font) * editor.style.lineHeight) / 2
            XCTAssertEqual(scroll.contentInsets.top, (0.4 * height - half).rounded(), accuracy: 0.5, message, file: file, line: line)
            XCTAssertEqual(scroll.contentInsets.bottom, (0.6 * height - half).rounded(), accuracy: 0.5, message, file: file, line: line)
            XCTAssertEqual(scroll.scrollerInsets.top, -scroll.contentInsets.top, message, file: file, line: line)
            XCTAssertEqual(scroll.scrollerInsets.bottom, -scroll.contentInsets.bottom, message, file: file, line: line)
            let scroller = try XCTUnwrap(scroll.verticalScroller)
            XCTAssertEqual(scroller.frame.height, scroll.bounds.height, accuracy: 1, "full-height track: " + message, file: file, line: line)
        }

        fixture.window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        workspace.setWritingModes(typewriter: true)
        try await fixture.settle()
        XCTAssertTrue(editor.writingModes.typewriter)
        try assertInsets("on")
        try assertAnchored("first line reaches the anchor at the top")
        XCTAssertLessThan(clip.bounds.minY, 0, "top overscroll in use")

        // Keyboard caret movement and typing re-anchor.
        for step in 0..<25 {
            let before = editor.selectedRange().location
            try key(editor, 125, "\u{F701}")
            XCTAssertGreaterThan(editor.selectedRange().location, before, "the arrow key moved the caret")
            try assertAnchored("down arrow \(step)")
        }
        XCTAssertGreaterThan(clip.bounds.minY, 0, "the document scrolled under the anchor")
        // Text input (insertText is what a typed key ends in) re-anchors on the same turn.
        let typedAt = editor.selectedRange().location
        clip.scroll(to: NSPoint(x: 0, y: clip.bounds.minY + 200))
        editor.insertText("a", replacementRange: editor.selectedRange())
        XCTAssertEqual((editor.string as NSString).substring(with: NSRange(location: typedAt, length: 1)), "a")
        try await fixture.settle(50)
        try assertAnchored("typing")
        editor.insertNewline(nil)
        try await fixture.settle()
        try assertAnchored("return and the sizing pass")

        // Clicking or trackpad scrolling never jumps; the next keystroke re-anchors.
        let middle = (editor.string as NSString).range(of: "## Paragraph 150").location
        let resting = clip.bounds.minY
        editor.setSelectedRange(NSRange(location: middle, length: 0))
        try await fixture.settle()
        XCTAssertEqual(clip.bounds.minY, resting, accuracy: 0.5, "a click does not scroll")
        clip.scroll(to: NSPoint(x: 0, y: resting + 700))
        scroll.reflectScrolledClipView(clip)
        try await fixture.settle()
        XCTAssertEqual(clip.bounds.minY, resting + 700, accuracy: 0.5, "trackpad scroll is free")
        try key(editor, 124, "\u{F703}")
        try assertAnchored("next keystroke after scrolling")

        // The last line reaches the anchor (bottom overscroll).
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        try key(editor, 124, "\u{F703}")
        XCTAssertEqual(editor.selectedRange().location, editor.string.utf16.count)
        try assertAnchored("end of document")
        try await fixture.settle()
        try assertAnchored("end of document after the sizing pass")

        // Find (1.13) and Outline (1.18) jumps land on the anchor.
        let match = (editor.string as NSString).range(of: "## Paragraph 200")
        editor.setSelectedRange(match)
        editor.showFindIndicator(for: match)
        XCTAssertEqual(try screenY(match.location), 0.4 * scroll.contentSize.height, accuracy: 1.5, "find")
        let heading = try XCTUnwrap(MarkdownParser.parse(editor.string).headings.first { $0.text == "Paragraph 300" })
        workspace.preview.navigate(heading)
        XCTAssertEqual(try screenY(heading.sourceRange.location), 0.4 * scroll.contentSize.height, accuracy: 1.5, "outline")

        // Resize and mode sweep: insets follow the height; the anchor holds.
        for height: CGFloat in [560, 1200, 900] {
            fixture.window.setContentSize(NSSize(width: 1400, height: height))
            for mode in [DocumentViewMode.split, .editor] {
                workspace.preview.mode = mode
                try await fixture.settle()
                XCTAssertTrue(workspace.preview.editor === editor)
                try assertInsets("height \(height) \(mode)")
                try key(editor, 126, "\u{F700}")
                try assertAnchored("height \(height) \(mode)")
            }
        }
        // 1.54: the caret keeps its text height; Typewriter changes scroll insets only, never caret geometry.
        let caret = editor.selectedRange().location
        let caretOn = editor.textHeightInsertionRect(for: editor.lineFragmentCaretRect(at: caret))
        // Whole-point rounding (1.54) varies by a point with the line's fractional position.
        XCTAssertEqual(caretOn.height, caretBefore.height, accuracy: 1)
        XCTAssertLessThan(caretOn.height, fragmentBefore.height, "text height, not the 1.6× line fragment")

        // Off: both inset pairs return to 0 and the caret line stays where it is on screen.
        let screen = try screenY(caret)
        workspace.setWritingModes(typewriter: false)
        XCTAssertEqual(editor.textHeightInsertionRect(for: editor.lineFragmentCaretRect(at: caret)), caretOn)
        try await fixture.settle()
        XCTAssertEqual(scroll.contentInsets.top, 0)
        XCTAssertEqual(scroll.contentInsets.bottom, 0)
        XCTAssertEqual(scroll.scrollerInsets.top, 0)
        XCTAssertEqual(scroll.scrollerInsets.bottom, 0)
        XCTAssertEqual(try screenY(editor.selectedRange().location), screen, accuracy: 1, "no jump on exit")
        // 1.48 reachability and end margin restored.
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        editor.scrollToEndOfDocument(nil)
        scroll.reflectScrolledClipView(clip)
        XCTAssertEqual(scroll.documentVisibleRect.maxY, editor.frame.height, accuracy: 2)
        XCTAssertEqual(try XCTUnwrap(scroll.verticalScroller).frame.height, scroll.bounds.height, accuracy: 1)
        try key(editor, 126, "\u{F700}")
        XCTAssertLessThan(editor.selectedRange().location, editor.string.utf16.count)
        XCTAssertEqual(scroll.documentVisibleRect.maxY, editor.frame.height, accuracy: 2, "keystrokes no longer anchor")

        // Exit near the top clamps into the inset-free range.
        workspace.setWritingModes(typewriter: true)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try key(editor, 126, "\u{F700}")
        XCTAssertLessThan(clip.bounds.minY, 0)
        workspace.setWritingModes(typewriter: false)
        XCTAssertEqual(clip.bounds.minY, 0, accuracy: 0.5)
        XCTAssertFalse(workspace.windowMetadata().typewriterMode)
        XCTAssertFalse(fixture.window.isVisible)
    }

    @MainActor
    func testStatusChipTitles() {
        XCTAssertNil(WritingModesChip.title(focus: false, typewriter: false))
        XCTAssertEqual(WritingModesChip.title(focus: true, typewriter: false), "Focus")
        XCTAssertEqual(WritingModesChip.title(focus: false, typewriter: true), "Typewriter")
        XCTAssertEqual(WritingModesChip.title(focus: true, typewriter: true), "Focus · Typewriter")
    }
}

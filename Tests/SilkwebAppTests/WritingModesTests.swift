import AppKit
import ImageIO
import ObjectiveC
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

    /// The editor's own drawing of its visible rect, without subviews (what its backing store holds).
    @MainActor
    private func ownDrawing(_ editor: PlainMarkdownTextView) throws -> Data {
        let rect = editor.visibleRect
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bitmapContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        let cg = bitmapContext.cgContext
        cg.translateBy(x: 0, y: rect.height)
        cg.scaleBy(x: 1, y: -1)
        cg.translateBy(x: -rect.minX, y: -rect.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        editor.effectiveAppearance.performAsCurrentDrawingAppearance { editor.draw(rect) }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.tiffRepresentation)
    }

    /// #65: Focus dimming is composited over the text by strip layers, never blended into the
    /// editor's own drawing: a translucent fill in the editor's backing store made every
    /// scrolled frame's Core Animation commit about 3× dearer (p95 over 4 ms under load). The
    /// strips follow the bright band through resizes, Typewriter insets and mode switches, sit
    /// under inline images and pass clicks through to the text.
    @MainActor
    func testFocusDimmingIsCompositedOverTheEditorNotDrawnIntoIt() async throws {
        let fixture = try await Fixture(files: ["Focus.md": Self.focusDocument], open: "Focus.md")
        defer { fixture.close() }
        let workspace = fixture.workspace
        try await fixture.settle()
        var editor = try XCTUnwrap(workspace.preview.editor)
        for _ in 0..<40 where !(editor.inlineImages.imageViews.first?.content.bitmap != nil) { try await fixture.settle(100) }
        let source = editor.string as NSString
        let dimmed = WritingModeController.dimmedOpacity
        editor.setSelectedRange(NSRange(location: source.range(of: "line one").location, length: 0))
        try await fixture.settle()
        let plain = try ownDrawing(editor)

        workspace.setWritingModes(focus: true)
        try await fixture.settle()
        XCTAssertFalse(editor.writingModes.isFading)
        XCTAssertEqual(try ownDrawing(editor), plain, "Focus leaves the editor's own drawing (its backing store) untouched")

        func strips() -> [NSView] { editor.subviews.filter { $0.identifier?.rawValue == "focus-dim" } }
        func assertStripsFollowBand(_ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let band = try XCTUnwrap(editor.writingModes.band(for: try XCTUnwrap(editor.writingModes.activeRange)), message, file: file, line: line)
            let views = strips()
            XCTAssertEqual(views.count, 2, "above and below the bright unit: \(message)", file: file, line: line)
            XCTAssertEqual(views.map(\.frame.minY).min() ?? -1, 0, accuracy: 0.001, message, file: file, line: line)
            XCTAssertEqual(views.map(\.frame.maxY).max() ?? -1, editor.bounds.height, accuracy: 0.001, message, file: file, line: line)
            for view in views {
                XCTAssertEqual(view.frame.minX, 0, message, file: file, line: line)
                XCTAssertEqual(view.frame.width, editor.bounds.width, accuracy: 0.001, message, file: file, line: line)
                XCTAssertFalse(view.isAccessibilityElement(), message, file: file, line: line)
            }
            XCTAssertEqual(editor.writingModes.opacity(at: band.top - 1), dimmed, accuracy: 0.001, message, file: file, line: line)
            XCTAssertEqual(editor.writingModes.opacity(at: band.top + 1), 1, accuracy: 0.001, message, file: file, line: line)
            XCTAssertEqual(editor.writingModes.opacity(at: band.bottom - 1), 1, accuracy: 0.001, message, file: file, line: line)
            XCTAssertEqual(editor.writingModes.opacity(at: band.bottom + 1), dimmed, accuracy: 0.001, message, file: file, line: line)
            // Under inline images (dimmed on their own, 1.68) and transparent to clicks.
            let order = editor.subviews
            for image in editor.inlineImages.imageViews {
                for view in views {
                    XCTAssertLessThan(try XCTUnwrap(order.firstIndex(of: view)), try XCTUnwrap(order.firstIndex(of: image)), message, file: file, line: line)
                }
            }
            let dimPoint = NSPoint(x: editor.bounds.midX, y: band.bottom + 4)
            XCTAssertTrue(editor.hitTest(editor.convert(dimPoint, to: editor.superview)) === editor, "clicks reach the text: \(message)", file: file, line: line)
        }
        try assertStripsFollowBand("focus on")

        // Resize sweep: the strips span the new width and the band re-measures after reflow.
        for width in [1100, 900, 1600, 1400] {
            fixture.window.setContentSize(NSSize(width: CGFloat(width), height: 900))
            try await fixture.settle(150)
            try assertStripsFollowBand("window width \(width)")
        }
        // Typewriter moves the text container origin; a different unit moves the band.
        workspace.setWritingModes(typewriter: true)
        try await fixture.settle()
        try assertStripsFollowBand("typewriter on")
        editor.setSelectedRange(NSRange(location: source.range(of: "item two").location, length: 0))
        try await fixture.settle()
        try assertStripsFollowBand("list item unit")
        // Typing above the band shifts it before the next frame.
        editor.setSelectedRange(NSRange(location: source.range(of: "First paragraph").location, length: 0))
        try await fixture.settle()
        editor.insertText("A longer opening sentence that wraps onto a second line in the column. ", replacementRange: editor.selectedRange())
        try await fixture.settle()
        try assertStripsFollowBand("after typing")
        workspace.setWritingModes(typewriter: false)
        try await fixture.settle()
        // Mode switches keep a laid-out, dimmed editor.
        for mode in [DocumentViewMode.split, .editor] {
            workspace.preview.mode = mode
            try await fixture.settle()
            editor = try XCTUnwrap(workspace.preview.editor)
            try assertStripsFollowBand("\(mode)")
        }
        let focused = try ownDrawing(editor)

        // Off removes every strip; the editor's own pixels never changed.
        workspace.setWritingModes(focus: false)
        try await fixture.settle()
        XCTAssertEqual(try ownDrawing(editor), focused, "Focus on and off draw the same editor pixels")
        XCTAssertTrue(strips().isEmpty, "focus off leaves no strips behind")
        XCTAssertEqual(editor.writingModes.opacity(at: 1), 1)
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

    static let headingDocument = """
    # Heading Fixture

    First body paragraph with enough words to sample its dimmed glyphs.

    Second body paragraph with enough words to sample its dimmed glyphs.

    Third body paragraph with enough words to sample its dimmed glyphs.
    """

    /// silkweb-1.80: typing in a heading never undims other paragraphs. Sampled in the
    /// editor's real draw callback (the frame the user sees, as in 1.60), after every keystroke
    /// and again after the queued styler / Focus updates run. Invariant: the dim strips laid
    /// over each body line (#65, re-measured in viewWillDraw) leave exactly `dimmedOpacity`
    /// (`opacity(at:)`), and no glyphs are drawn outside `draw(_:)`.
    @MainActor
    func testTypingInHeadingKeepsBodyDimmedAtEveryDisplay() async throws {
        let fixture = try await Fixture(files: ["Heading.md": Self.headingDocument], open: "Heading.md")
        defer { fixture.close() }
        let workspace = fixture.workspace
        try await fixture.settle()
        let editor = try XCTUnwrap(workspace.preview.editor)
        let dimmed = WritingModeController.dimmedOpacity
        func source() -> NSString { editor.string as NSString }
        /// Mid-line y of each body paragraph's first line, from already-computed layout.
        func bodyLines() -> [(String, CGFloat)] {
            ["Intro paragraph", "First body", "Second body", "Third body"].compactMap { phrase in
                let location = source().range(of: phrase).location
                guard location != NSNotFound, let line = editor.writingModes.caretLine(at: location) else { return nil }
                return (phrase, line.midY)
            }
        }

        var phase = ""
        var sampling = false
        var samples = 0
        var violations: [String] = []
        func sampleDisplay(_ editor: PlainMarkdownTextView, _ rect: NSRect) {
            guard sampling, editor.window != nil else { return }
            samples += 1
            let heading = source().lineRange(for: source().range(of: "Heading Fixture"))
            if NSLocationInRange(editor.selectedRange().location, heading),
               let caret = editor.writingModes.caretLine(at: editor.selectedRange().location),
               abs(editor.writingModes.opacity(at: caret.midY) - 1) > 0.001 {
                violations.append("[\(phase)] heading dimmed: \(editor.writingModes.opacity(at: caret.midY))")
            }
            for (phrase, y) in bodyLines() where y >= rect.minY && y < rect.maxY {
                let opacity = editor.writingModes.opacity(at: y)
                if abs(opacity - dimmed) > 3.0 / 255 { violations.append("[\(phase)] \(phrase) drawn at \(opacity)") }
            }
        }
        var restores: [(Method, IMP, IMP)] = []
        defer { for (method, old, replacement) in restores.reversed() { method_setImplementation(method, old); imp_removeBlock(replacement) } }
        let drawSelector = #selector(NSView.draw(_:))
        let inherited = try XCTUnwrap(class_getInstanceMethod(PlainMarkdownTextView.self, drawSelector))
        class_addMethod(PlainMarkdownTextView.self, drawSelector, method_getImplementation(inherited), method_getTypeEncoding(inherited))
        let method = try XCTUnwrap(class_getInstanceMethod(PlainMarkdownTextView.self, drawSelector))
        let drawIMP = method_getImplementation(method)
        var inDraw = false
        let replacement = imp_implementationWithBlock({ (editor: PlainMarkdownTextView, rect: NSRect) in
            inDraw = true
            unsafeBitCast(drawIMP, to: (@convention(c) (AnyObject, Selector, NSRect) -> Void).self)(editor, drawSelector, rect)
            inDraw = false
            sampleDisplay(editor, rect)
        } as @convention(block) (PlainMarkdownTextView, NSRect) -> Void)
        method_setImplementation(method, replacement)
        restores.append((method, drawIMP, replacement))
        let layoutClass: AnyClass = try XCTUnwrap(object_getClass(try XCTUnwrap(editor.layoutManager)))
        for name in ["drawGlyphsForGlyphRange:atPoint:", "drawBackgroundForGlyphRange:atPoint:"] {
            let selector = NSSelectorFromString(name)
            let inheritedGlyphs = try XCTUnwrap(class_getInstanceMethod(layoutClass, selector))
            class_addMethod(layoutClass, selector, method_getImplementation(inheritedGlyphs), method_getTypeEncoding(inheritedGlyphs))
            let glyphMethod = try XCTUnwrap(class_getInstanceMethod(layoutClass, selector))
            let glyphIMP = method_getImplementation(glyphMethod)
            let glyphReplacement = imp_implementationWithBlock({ (layout: NSLayoutManager, range: NSRange, point: NSPoint) in
                // Glyphs drawn outside draw(_:) would get no Focus overlay painted over them.
                if sampling, !inDraw, layout === editor.layoutManager { violations.append("[\(phase)] \(name) \(range) outside draw(_:)") }
                unsafeBitCast(glyphIMP, to: (@convention(c) (AnyObject, Selector, NSRange, NSPoint) -> Void).self)(layout, selector, range, point)
            } as @convention(block) (NSLayoutManager, NSRange, NSPoint) -> Void)
            method_setImplementation(glyphMethod, glyphReplacement)
            restores.append((glyphMethod, glyphIMP, glyphReplacement))
        }
        // Offscreen text views do not invalidate themselves on edits as on screen: dirty the
        // visible rect so each sample is the whole frame the user would see.
        func redraw() {
            editor.setNeedsDisplay(editor.visibleRect)
            fixture.controller.view.layoutSubtreeIfNeeded()
            fixture.window.displayIfNeeded()
        }

        fixture.window.makeFirstResponder(editor)
        // Blank line under the heading (Test_Library style), and body copy directly under a
        // heading that has a paragraph above it.
        let documents = [Self.headingDocument, "Intro paragraph above the heading.\n" + Self.headingDocument.replacingOccurrences(of: "Fixture\n\n", with: "Fixture\n")]
        for (variant, document) in documents.enumerated() {
            for typewriter in [false, true] {
                for level in ["#", "##", "######"] {
                    workspace.setWritingModes(focus: false, typewriter: false)
                    try await fixture.settle()
                    let text = document.replacingOccurrences(of: "# Heading Fixture", with: "\(level) Heading Fixture")
                    editor.insertText(text, replacementRange: NSRange(location: 0, length: source().length))
                    let heading = source().lineRange(for: source().range(of: "Heading Fixture"))
                    editor.setSelectedRange(NSRange(location: NSMaxRange(heading) - 1, length: 0))
                    workspace.setWritingModes(focus: true, typewriter: typewriter)
                    try await fixture.settle()
                    XCTAssertFalse(editor.writingModes.isFading)
                    XCTAssertEqual(source().substring(with: try XCTUnwrap(editor.writingModes.activeRange)), "\(level) Heading Fixture\n")
                    XCTAssertEqual(bodyLines().count, 3 + variant, "every non-active paragraph is visible")
                    sampling = true
                    for (index, text) in ["a", "b", "c", " typed", "d", "", "", "e"].enumerated() {
                        phase = "document \(variant) \(level) typewriter=\(typewriter) keystroke \(index) \(text.debugDescription)"
                        if text.isEmpty { try key(editor, 51, "\u{7F}") }
                        else if text.count == 1 { try key(editor, 0, text) }
                        else { editor.insertText(text, replacementRange: editor.selectedRange()) }
                        // The very next frame, before the queued styler / Focus updates run.
                        redraw()
                        await Task.yield()
                        redraw()
                        // Typing pace: the 150 ms content-sizing pass runs between keystrokes.
                        for _ in 0..<5 {
                            try await Task.sleep(for: .milliseconds(40))
                            fixture.window.displayIfNeeded()
                        }
                        redraw()
                        XCTAssertFalse(editor.writingModes.isFading, "no fade restarts per keystroke: \(phase)")
                    }
                    sampling = false
                    try await fixture.settle()
                    XCTAssertEqual(source().substring(with: try XCTUnwrap(editor.writingModes.activeRange)), "\(level) Heading Fixtureabc typee\n")
                }
            }
        }
        XCTAssertGreaterThan(samples, 150, "draw callbacks were sampled")
        XCTAssertTrue(violations.isEmpty, "\(violations.count) undimmed body samples:\n" + violations.prefix(20).joined(separator: "\n"))
        workspace.setWritingModes(focus: false, typewriter: false)
        XCTAssertFalse(fixture.window.isVisible)
    }

    /// silkweb-1.80: the bright unit follows each edit until the queued update recomputes it.
    @MainActor
    func testActiveRangeShiftsWithEdits() {
        // "# Title\nBody\n" with the heading unit {0, 8}; `after` is the text once edited.
        func shift(_ edited: NSRange, _ delta: Int, _ after: String, _ range: NSRange = NSRange(location: 0, length: 8)) -> NSRange? {
            WritingModeController.shift(range, editedRange: edited, delta: delta, in: after as NSString)
        }
        XCTAssertEqual(shift(NSRange(location: 7, length: 1), 1, "# Titlex\nBody\n"), NSRange(location: 0, length: 9), "typing at the end")
        XCTAssertEqual(shift(NSRange(location: 0, length: 1), 1, "x# Title\nBody\n"), NSRange(location: 0, length: 9), "typing at the start")
        XCTAssertEqual(shift(NSRange(location: 6, length: 0), -1, "# Titl\nBody\n"), NSRange(location: 0, length: 7), "⌫ stays on the heading")
        XCTAssertEqual(shift(NSRange(location: 2, length: 3), 0, "# Abcle\nBody\n"), NSRange(location: 0, length: 8), "replacement inside")
        XCTAssertEqual(shift(NSRange(location: 8, length: 1), 1, "# Title\nxBody\n"), NSRange(location: 0, length: 8), "next line's start is not the unit")
        XCTAssertEqual(shift(NSRange(location: 10, length: 2), 2, "# Title\nBoxxdy\n"), NSRange(location: 0, length: 8), "edits below")
        let body = NSRange(location: 8, length: 5)
        XCTAssertEqual(shift(NSRange(location: 2, length: 1), 1, "# xTitle\nBody\n", body), NSRange(location: 9, length: 5), "edits above shift")
        XCTAssertEqual(shift(NSRange(location: 1, length: 0), -1, "#Title\nBody\n", body), NSRange(location: 7, length: 5))
        XCTAssertEqual(shift(NSRange(location: 4, length: 1), 1, "Body!", NSRange(location: 0, length: 4)), NSRange(location: 0, length: 5),
                       "a last paragraph without a newline grows at its end")
        XCTAssertEqual(shift(NSRange(location: 7, length: 0), -1, "# TitleBody\n", body), NSRange(location: 7, length: 5), "⌫ at the line start")
        XCTAssertNil(shift(NSRange(location: 6, length: 0), -3, "# Titlody\n", body), "deleting across the boundary")
        XCTAssertNil(shift(NSRange(location: 0, length: 12), 0, "Replaced all", body), "a reload crosses the boundary")
        XCTAssertEqual(shift(NSRange(location: 0, length: 0), -8, "Body\n"), NSRange(location: 0, length: 0), "deleting the whole unit")
    }

    @MainActor
    func testStatusChipTitles() {
        XCTAssertNil(WritingModesChip.title(focus: false, typewriter: false))
        XCTAssertEqual(WritingModesChip.title(focus: true, typewriter: false), "Focus")
        XCTAssertEqual(WritingModesChip.title(focus: false, typewriter: true), "Typewriter")
        XCTAssertEqual(WritingModesChip.title(focus: true, typewriter: true), "Focus · Typewriter")
    }
}

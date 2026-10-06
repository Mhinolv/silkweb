import AppKit
import SilkwebCore
import XCTest

@testable import Silkweb

extension PlainMarkdownTextView {
    /// The rect TextKit 1 hands `drawInsertionPoint`: caret x, the full line fragment height.
    func lineFragmentCaretRect(at location: Int) -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return .zero }
        layout.ensureLayout(for: container)
        let origin = textContainerOrigin
        let source = string as NSString
        let fragment: NSRect
        let x: CGFloat
        if location == source.length, source.length == 0 || source.character(at: source.length - 1) == 0x0A {
            fragment = layout.extraLineFragmentRect
            x = fragment.minX
        } else if location < source.length {
            let glyph = layout.glyphIndexForCharacter(at: location)
            fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = fragment.minX + layout.location(forGlyphAt: glyph).x
        } else {
            let glyph = layout.glyphIndexForCharacter(at: location - 1)
            fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            x = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).maxX
        }
        return NSRect(x: x + origin.x, y: fragment.minY + origin.y, width: 1, height: fragment.height)
    }

    /// Draws the caret through the production override in the current graphics context.
    func drawCaret(at location: Int, color: NSColor) {
        if !hasMarkedText() { setSelectedRange(NSRange(location: location, length: 0)) }
        drawInsertionPoint(in: lineFragmentCaretRect(at: location), color: color, turnedOn: true)
    }
}

final class EditorCaretTests: XCTestCase {
    /// Rows (in flipped editor points) the caret actually painted, measured from pixels.
    @MainActor
    private func paintedRows(_ editor: PlainMarkdownTextView, at location: Int) throws -> ClosedRange<Int>? {
        // Only a window around the line; long documents are far taller than a bitmap should be.
        let fragment = editor.lineFragmentCaretRect(at: location)
        let top = floor(fragment.minY) - 20, left = floor(fragment.minX) - 10
        let height = Int(ceil(fragment.height)) + 40, width = 40
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: CGFloat(height))
        context.cgContext.scaleBy(x: 1, y: -1)
        context.cgContext.translateBy(x: -left, y: -top)
        editor.drawCaret(at: location, color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        NSGraphicsContext.restoreGraphicsState()
        var rows: [Int] = []
        // Bitmap row 0 is the top, matching the flipped editor.
        for y in 0..<height {
            for x in 0..<width where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) >= 0.5 {
                rows.append(y + Int(top))
                break
            }
        }
        guard let first = rows.first, let last = rows.last else { return nil }
        return first...last
    }

    @MainActor
    private func makeEditor(_ source: String, preferences: WritingPreferences = WritingPreferences())
        throws -> (NSScrollView, PlainMarkdownTextView)
    {
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle(preferences: preferences))
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        scroll.tile()
        let editor = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        editor.layoutEditor()
        editor.string = source
        editor.styler.reload()
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        editor.sizeToFit()
        return (scroll, editor)
    }

    /// Text baseline at the caret, independent of the production rect computation.
    @MainActor
    private func baseline(_ editor: PlainMarkdownTextView, at location: Int, font: NSFont) -> (CGFloat, NSRect) {
        let layout = editor.layoutManager!
        let source = editor.string as NSString
        let origin = editor.textContainerOrigin
        if location == source.length, source.length == 0 || source.character(at: source.length - 1) == 0x0A {
            let extra = layout.extraLineFragmentRect.offsetBy(dx: origin.x, dy: origin.y)
            return (extra.maxY - abs(font.descender), extra)
        }
        let character = min(location, source.length - 1)
        let glyph = layout.glyphIndexForCharacter(at: character)
        let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).offsetBy(
            dx: origin.x, dy: origin.y)
        // A visible glyph reports its own baseline; an empty line's newline glyph does not,
        // so it sits like the extra fragment, with the leading above.
        if source.character(at: character) == 0x0A, character == 0 || source.character(at: character - 1) == 0x0A {
            return (fragment.maxY - abs(font.descender), fragment)
        }
        return (fragment.minY + layout.location(forGlyphAt: glyph).y, fragment)
    }

    @MainActor
    private func assertTextHeightCaret(
        _ editor: PlainMarkdownTextView, at location: Int, _ label: String,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let rows = try XCTUnwrap(
            try paintedRows(editor, at: location), "no caret painted for \(label)", file: file, line: line)
        let font = editor.typingAttributes[.font] as? NSFont ?? editor.style.bodyFont
        let height = CGFloat(rows.count)
        let limit = font.ascender + abs(font.descender) + 2
        XCTAssertLessThanOrEqual(
            height, limit, "\(label): caret \(height)pt spans the line gap", file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            height, editor.style.bodyFont.pointSize, "\(label): caret too short", file: file, line: line)
        let (base, fragment) = baseline(editor, at: location, font: font)
        // Touches the baseline: ascender above it, descender below it, inside the fragment.
        XCTAssertEqual(
            CGFloat(rows.lowerBound), base - font.ascender, accuracy: 1.5, "\(label): caret top", file: file, line: line
        )
        XCTAssertEqual(
            CGFloat(rows.upperBound + 1), base + abs(font.descender), accuracy: 2.5, "\(label): caret bottom",
            file: file, line: line)
        XCTAssertGreaterThanOrEqual(CGFloat(rows.lowerBound), floor(fragment.minY), label, file: file, line: line)
        XCTAssertLessThanOrEqual(CGFloat(rows.upperBound + 1), ceil(fragment.maxY), label, file: file, line: line)
    }

    @MainActor
    func testCaretIsTextHeightOnBodyHeadingEmptyAndLastLines() throws {
        let headings = (1...6).map { String(repeating: "#", count: $0) + " Heading \($0)" }.joined(separator: "\n")
        let source = headings + "\nBody line with café 日本語\n\n**bold** last line"
        for size in [15.0, 9, 28] {
            var preferences = WritingPreferences()
            preferences.fontSize = size
            let (_, editor) = try makeEditor(source, preferences: preferences)
            let text = source as NSString
            for level in 1...6 {
                let heading = text.range(of: "Heading \(level)")
                try assertTextHeightCaret(editor, at: heading.location, "H\(level) start, \(size)pt")
                try assertTextHeightCaret(editor, at: NSMaxRange(heading), "H\(level) end, \(size)pt")
            }
            let body = text.range(of: "Body line")
            try assertTextHeightCaret(editor, at: body.location + 4, "body, \(size)pt")
            try assertTextHeightCaret(editor, at: text.range(of: "\n\n").location + 1, "empty line, \(size)pt")
            try assertTextHeightCaret(editor, at: text.length, "last line end, \(size)pt")
            try assertTextHeightCaret(editor, at: text.range(of: "last").location, "last line, \(size)pt")
        }
        // Empty document and the line after a trailing newline use the extra line fragment.
        let (_, empty) = try makeEditor("")
        try assertTextHeightCaret(empty, at: 0, "empty document")
        let (_, trailing) = try makeEditor("Body\n")
        try assertTextHeightCaret(trailing, at: 5, "after trailing newline")
        // IME marked text keeps the same rule.
        let (_, marked) = try makeEditor("IME")
        marked.setSelectedRange(NSRange(location: 3, length: 0))
        marked.setMarkedText(
            "日本", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: 3, length: 0))
        XCTAssertTrue(marked.hasMarkedText())
        // The marked run's font (CJK fallback included) sets the height, not the fragment.
        let markedRows = try XCTUnwrap(try paintedRows(marked, at: 5))
        let markedFont = try XCTUnwrap(marked.typingAttributes[.font] as? NSFont)
        XCTAssertLessThanOrEqual(CGFloat(markedRows.count), markedFont.ascender + abs(markedFont.descender) + 2)
        XCTAssertLessThan(CGFloat(markedRows.count), marked.lineFragmentCaretRect(at: 5).height)
        marked.unmarkText()
    }

    @MainActor
    func testShortCaretEraseLeavesNoPixelsAndNeverGrows() throws {
        let (_, editor) = try makeEditor("First line\nSecond line")
        for location in [0, 5, 10, 11, 22] {
            let original = editor.lineFragmentCaretRect(at: location)
            let rows = try XCTUnwrap(try paintedRows(editor, at: location))
            XCTAssertGreaterThanOrEqual(CGFloat(rows.lowerBound), original.minY, "caret must stay within AppKit's rect")
            XCTAssertLessThanOrEqual(
                CGFloat(rows.upperBound + 1), original.maxY, "caret must stay within AppKit's rect")
            XCTAssertLessThan(CGFloat(rows.count), original.height)
        }
        // Empty-document placeholder survives a blink cycle with the shortened rect.
        let (_, empty) = try makeEditor("")
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 200,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.cgContext.translateBy(x: 0, y: 200)
        context.cgContext.scaleBy(x: 1, y: -1)
        empty.drawBackground(in: NSRect(x: 0, y: 0, width: 900, height: 200))
        let before = Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let caret = empty.lineFragmentCaretRect(at: 0)
        for _ in 0..<3 {
            empty.drawInsertionPoint(in: caret, color: empty.insertionPointColor, turnedOn: true)
            empty.drawInsertionPoint(in: caret, color: empty.insertionPointColor, turnedOn: false)
        }
        let after = Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let changed = zip(before, after).enumerated().filter { $0.element.0 != $0.element.1 }
            .map { ($0.offset % bitmap.bytesPerRow / 4, $0.offset / bitmap.bytesPerRow) }
        XCTAssertEqual(
            before, after,
            "caret erase left stale pixels over the placeholder: \(caret); x \(changed.map(\.0).min() ?? -1)...\(changed.map(\.0).max() ?? -1), y \(changed.map(\.1).min() ?? -1)...\(changed.map(\.1).max() ?? -1)"
        )
    }

    @MainActor
    func testCaretColorFollowsTextColorInEveryAppearance() throws {
        let (_, editor) = try makeEditor("Body")
        XCTAssertEqual(editor.insertionPointColor, NSColor.textColor)
        for name in [
            NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
        ] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var caret: NSColor?, text: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                caret = editor.insertionPointColor.usingColorSpace(.sRGB)
                text = NSColor.textColor.usingColorSpace(.sRGB)
            }
            let resolved = try XCTUnwrap(caret)
            XCTAssertEqual(resolved, text, "\(name.rawValue)")
            let dark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
            // White in Dark Mode, near-black in Light Mode: never the blue accent.
            XCTAssertEqual(resolved.redComponent, dark ? 1 : 0, accuracy: 0.15, "\(name.rawValue)")
            XCTAssertEqual(resolved.blueComponent, resolved.redComponent, accuracy: 0.05, "\(name.rawValue)")
        }
    }

    @MainActor
    func testLongDocumentCaretAtEndStaysTextHeightAfterScrollToEnd() throws {
        let (scroll, editor) = try makeEditor(LongEditorFixture.document)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        host.addSubview(scroll)
        let end = (editor.string as NSString).length
        editor.setSelectedRange(NSRange(location: end, length: 0))
        editor.scrollToEndOfDocument(nil)
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertTrue(
            editor.visibleRect.intersects(editor.lineFragmentCaretRect(at: end)), "end caret scrolled out of view")
        try assertTextHeightCaret(editor, at: end, "long document end")
        let rows = try XCTUnwrap(try paintedRows(editor, at: end))
        XCTAssertGreaterThanOrEqual(CGFloat(rows.lowerBound), editor.visibleRect.minY, "end caret is not visible")
        XCTAssertLessThanOrEqual(CGFloat(rows.upperBound + 1), editor.visibleRect.maxY, "end caret is not visible")
    }
}

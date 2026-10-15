import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #243: a plain click in the left margin or on a line's first glyph puts the caret at the line start
/// on the first try, on every visual line; other clicks keep AppKit's behaviour.
final class LineStartClickTests: XCTestCase {
    static let paragraph = Array(repeating: "Wrapping words fill this paragraph", count: 12).joined(separator: " ")
    static let document = "# Heading one\n- list item\n> quote line\n\(paragraph)\nLast line\n"

    private struct Harness {
        let window: NSWindow
        let editor: PlainMarkdownTextView
        let sidebar: NSView
    }

    @MainActor
    private func makeHarness() throws -> Harness {
        _ = NSApplication.shared
        let window = ClickTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 700))
        let sidebar = FocusableView(frame: NSRect(x: 0, y: 0, width: 200, height: 700))
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle(preferences: WritingPreferences()))
        scroll.frame = NSRect(x: 200, y: 0, width: 800, height: 700)
        content.addSubview(sidebar)
        content.addSubview(scroll)
        window.contentView = content
        window.makeKey() // Never ordered on screen.
        let editor = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        editor.layoutEditor()
        editor.string = Self.document
        editor.styler.reload()
        editor.isEditable = true
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        editor.sizeToFit()
        window.displayIfNeeded()
        return Harness(window: window, editor: editor, sidebar: sidebar)
    }

    /// Sends a click (or a press, drag and release) through the window the way AppKit delivers it.
    @MainActor
    private func click(
        _ harness: Harness, at point: NSPoint, count: Int = 1, flags: NSEvent.ModifierFlags = [],
        dragTo end: NSPoint? = nil
    ) throws {
        let window = harness.window, editor = harness.editor
        let location = editor.convert(point, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ at: NSPoint, _ offset: TimeInterval, _ number: Int) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: at, modifierFlags: flags, timestamp: time + offset,
                    windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: count,
                    pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try event(.leftMouseDown, location, 0, 1)
        let release = end.map { editor.convert($0, to: nil) } ?? location
        let up = try event(.leftMouseUp, release, 0.1, 3)
        // The text view's tracking loop takes the queued events in order.
        NSApp.postEvent(up, atStart: true)
        if end != nil { NSApp.postEvent(try event(.leftMouseDragged, release, 0.05, 2), atStart: true) }
        window.sendEvent(down)
        // Hidden windows may not dispatch the click; drive the text view as NSWindow would.
        if NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: false) != nil {
            XCTAssertTrue(window.makeFirstResponder(editor), "the editor takes focus on a click")
            editor.mouseDown(with: down)
        }
        let leftovers: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged]
        while NSApp.nextEvent(matching: leftovers, until: Date(), inMode: .default, dequeue: true) != nil {}
    }

    /// The first glyph of `location`'s visual line and that line's fragment, in editor coordinates.
    @MainActor
    private func geometry(_ editor: PlainMarkdownTextView, at location: Int) -> (glyph: NSRect, line: NSRect) {
        let layout = editor.layoutManager!, container = editor.textContainer!
        layout.ensureLayout(for: container)
        let origin = editor.textContainerOrigin
        let glyph = layout.glyphIndexForCharacter(at: location)
        let line = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let box = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        return (box.offsetBy(dx: origin.x, dy: origin.y), line.offsetBy(dx: origin.x, dy: origin.y))
    }

    @MainActor
    private func resetCaret(_ harness: Harness) {
        let end = (harness.editor.string as NSString).length
        harness.editor.setSelectedRange(NSRange(location: end, length: 0))
    }

    @MainActor
    func testClicksNearLineStartPlaceCaretAtLineStart() throws {
        let harness = try makeHarness()
        defer { harness.window.close() }
        let editor = harness.editor
        let text = editor.string as NSString
        let paragraphStart = text.range(of: "Wrapping").location

        // The second visual line of the wrapped paragraph.
        let layout = editor.layoutManager!
        var firstLine = NSRange()
        _ = layout.lineFragmentRect(
            forGlyphAt: layout.glyphIndexForCharacter(at: paragraphStart), effectiveRange: &firstLine)
        let continuation = layout.characterIndexForGlyph(at: NSMaxRange(firstLine))
        XCTAssertGreaterThan(continuation, paragraphStart, "the paragraph wraps")
        XCTAssertLessThan(continuation, text.range(of: "Last line").location, "the paragraph wraps")

        let lines: [(String, Int)] = [
            ("heading #", 0),
            ("list -", text.range(of: "- list").location),
            ("quote >", text.range(of: "> quote").location),
            ("paragraph start", paragraphStart),
            ("wrapped continuation", continuation),
        ]
        var failures: [String] = []
        for (name, start) in lines {
            let (glyph, line) = geometry(editor, at: start)
            let cases: [(String, NSPoint)] = [
                ("right half of the first glyph", NSPoint(x: glyph.minX + glyph.width * 0.75, y: line.midY)),
                ("first glyph trailing edge", NSPoint(x: glyph.maxX - 0.5, y: line.midY)),
                ("line spacing above the glyphs", NSPoint(x: glyph.minX + glyph.width * 0.75, y: line.minY + 1)),
                ("bottom of the fragment band", NSPoint(x: glyph.minX + glyph.width * 0.75, y: line.maxY - 1)),
                ("left margin", NSPoint(x: editor.bounds.minX + 2, y: line.midY)),
            ]
            for (label, point) in cases {
                resetCaret(harness)
                // The first click after another pane had focus both focuses and places the caret.
                harness.window.makeFirstResponder(harness.sidebar)
                try click(harness, at: point)
                if harness.window.firstResponder !== editor { failures.append("\(name), \(label): not focused") }
                let selection = editor.selectedRange()
                if selection != NSRange(location: start, length: 0) {
                    failures.append("\(name), \(label): caret at \(selection.location), expected \(start)")
                } else if name == "wrapped continuation", editor.selectionAffinity != .downstream {
                    failures.append("\(name), \(label): upstream affinity draws the caret on the line above")
                }
            }
        }
        XCTAssertEqual(failures, [], "clicks near a line start")
    }

    @MainActor
    func testOtherClicksKeepAppKitBehaviour() throws {
        let harness = try makeHarness()
        defer { harness.window.close() }
        let editor = harness.editor
        let text = editor.string as NSString
        let (hash, line) = geometry(editor, at: 0)
        let (space, _) = geometry(editor, at: 1)

        // Past the first glyph: the nearest edge, as before.
        resetCaret(harness)
        try click(harness, at: NSPoint(x: space.minX + space.width * 0.75, y: line.midY))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 2, length: 0), "right half of the second glyph")

        // Shift-click extends to AppKit's nearest edge.
        let end = text.range(of: "Heading one").location + 4
        editor.setSelectedRange(NSRange(location: end, length: 0))
        try click(harness, at: NSPoint(x: hash.minX + hash.width * 0.75, y: line.midY), flags: .shift)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: 1, length: end - 1), "shift-click is not snapped")

        // Double-click still selects a word.
        resetCaret(harness)
        let (h, _) = geometry(editor, at: 2)
        try click(harness, at: NSPoint(x: h.minX + h.width * 0.75, y: line.midY), count: 2)
        XCTAssertEqual(editor.selectedRange(), text.range(of: "Heading"), "double-click selects the word")

        // A drag that starts in the zone anchors at the line start.
        resetCaret(harness)
        let list = text.range(of: "- list").location
        let (dash, listLine) = geometry(editor, at: list)
        let (target, _) = geometry(editor, at: list + 6)
        try click(
            harness, at: NSPoint(x: dash.minX + dash.width * 0.75, y: listLine.midY),
            dragTo: NSPoint(x: target.minX + 1, y: listLine.midY))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: list, length: 6), "drag from the snap zone")

        // A click that jitters across the marker is still a caret at the line start.
        resetCaret(harness)
        try click(
            harness, at: NSPoint(x: dash.minX + dash.width * 0.25, y: listLine.midY),
            dragTo: NSPoint(x: dash.minX + dash.width * 0.9, y: listLine.midY + 1))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: list, length: 0), "jittered click")
    }

    /// #250: a plain click on an empty line showed the whole line in the selection color for a moment.
    /// The press snapped to the newline glyph's leading edge, and AppKit's tracking loop selected the
    /// newline up to the real release point before the caret came back. Every range is recorded.
    @MainActor
    func testEmptyLineClickNeverSelects() throws {
        let harness = try makeHarness()
        defer { harness.window.close() }
        let editor = harness.editor
        editor.string = "First line\n\nThird line\n"
        editor.styler.reload()
        let recorder = SelectionRecorder()
        editor.delegate = recorder
        defer { editor.delegate = nil }
        let empty = 11
        let (newline, line) = geometry(editor, at: empty)
        var failures: [String] = []
        for (label, x) in [
            ("left margin", editor.bounds.minX + 2), ("line start", newline.minX + 1),
            ("mid line", line.midX), ("past the newline", newline.maxX + 20),
        ] {
            for jitter in [false, true] {
                let place = "\(label)\(jitter ? ", jittered" : "")"
                // Come back from another line, as the owner did.
                editor.setSelectedRange(NSRange(location: 3, length: 0))
                recorder.ranges = []
                let point = NSPoint(x: x, y: line.midY)
                try click(harness, at: point, dragTo: jitter ? NSPoint(x: x + 1, y: line.midY + 1) : nil)
                if let wide = recorder.ranges.first(where: { $0.length > 0 }) {
                    failures.append("\(place): selected \(wide) during the click")
                }
                if editor.selectedRange() != NSRange(location: empty, length: 0) {
                    failures.append("\(place): caret at \(editor.selectedRange()), expected \(empty)")
                }
            }
        }
        XCTAssertEqual(failures, [], "clicks on an empty line")

        // A real drag from the empty line still selects.
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        let (third, thirdLine) = geometry(editor, at: empty + 1 + 5)
        try click(
            harness, at: NSPoint(x: line.midX, y: line.midY), dragTo: NSPoint(x: third.minX + 1, y: thirdLine.midY))
        XCTAssertEqual(editor.selectedRange(), NSRange(location: empty, length: 6), "drag from an empty line")
    }

    /// The app's hierarchy: the tab stack hosted in SwiftUI, in a window wide enough that the text
    /// column is centred in a wide gutter. Clicks go through the window's own hit testing, which the
    /// tests above bypass; the text view leaves its container inset to the clip view, so gutter
    /// clicks reached nothing with Typewriter Mode off.
    @MainActor
    func testGutterClicksThroughWindowHitTesting() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B", "C"] {
            try Data(Self.document.utf8).write(to: root.appendingPathComponent(name + ".md"))
        }
        let workspace = LibraryWorkspace(defaults: disposableDefaults("LineStart243"))
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        // The list pane sits left of the editor, so the pane's edge is not the window's resize border.
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1800, height: 900))
        let sidebar = FocusableView(frame: NSRect(x: 0, y: 0, width: 200, height: 900))
        let host = NSHostingView(rootView: TabEditorContent(workspace: workspace))
        host.sizingOptions = []
        host.frame = NSRect(x: 200, y: 0, width: 1600, height: 900)
        content.addSubview(sidebar)
        content.addSubview(host)
        let window = ClickTestWindow(
            contentRect: content.frame, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = content
        window.makeKey() // Never ordered on screen.
        defer {
            window.contentView = nil
            window.close()
        }
        func settle() async throws {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }

        var failures: [String] = []
        for tabs in [["A"], ["B", "C"]] {
            for name in tabs {
                workspace.navigate(folder: "", documents: [name + ".md"], pinned: true)
                await workspace.waitForNavigation()
            }
            try await settle()
            let editor = try XCTUnwrap(workspace.tabs.first { $0.id == workspace.activeTabID }?.textView)
            let text = editor.string as NSString
            for typewriter in [false, true] {
                workspace.setWritingModes(typewriter: typewriter)
                try await settle()
                let mode = "\(workspace.tabs.count) tab(s), Typewriter \(typewriter ? "on" : "off")"
                let origin = editor.textContainerOrigin
                XCTAssertGreaterThan(origin.x, 300, "\(mode): the column is centred in a wide gutter")
                let layout = editor.layoutManager!
                var firstLine = NSRange()
                let paragraphStart = text.range(of: "Wrapping").location
                _ = layout.lineFragmentRect(
                    forGlyphAt: layout.glyphIndexForCharacter(at: paragraphStart), effectiveRange: &firstLine)
                let lines: [(String, Int)] = [
                    ("heading #", 0), ("list -", text.range(of: "- list").location),
                    ("wrapped continuation", layout.characterIndexForGlyph(at: NSMaxRange(firstLine))),
                ]
                for (line, start) in lines {
                    // The first glyph is a control: the text view's own frame got it before the fix.
                    for (label, x) in [
                        ("pane edge", CGFloat(2)), ("mid gutter", origin.x / 2), ("next to the text", origin.x - 2),
                        ("first glyph", geometry(editor, at: start).glyph.midX),
                    ] {
                        editor.setSelectedRange(NSRange(location: text.length, length: 0))
                        window.makeFirstResponder(sidebar)
                        try await settle()
                        let point = NSPoint(x: x, y: geometry(editor, at: start).line.midY)
                        let place = "\(mode), \(line), \(label)"
                        guard editor.visibleRect.contains(point) else {
                            failures.append("\(place): line not visible")
                            continue
                        }
                        try windowClick(window, at: editor.convert(point, to: nil))
                        if window.firstResponder !== editor { failures.append("\(place): not focused") }
                        let selection = editor.selectedRange()
                        if selection != NSRange(location: start, length: 0) {
                            failures.append("\(place): caret at \(selection.location), expected \(start)")
                        }
                    }
                }
            }
            workspace.setWritingModes(typewriter: false)
        }
        XCTAssertEqual(failures, [], "gutter clicks through window hit testing")
    }

    /// A press and release through `NSWindow.sendEvent`. An unordered window in a sandboxed host may
    /// drop it; then the press goes where NSWindow sends it: the view its frame view hit-tests at
    /// `location`, focused first when it accepts focus. Never straight to the text view.
    @MainActor
    private func windowClick(_ window: NSWindow, at location: NSPoint) throws {
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ offset: TimeInterval, _ number: Int) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [], timestamp: time + offset,
                    windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try event(.leftMouseDown, 0, 1)
        NSApp.postEvent(try event(.leftMouseUp, 0.1, 2), atStart: true)
        window.sendEvent(down)
        if NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: false) != nil {
            let frame = try XCTUnwrap(window.contentView?.superview)
            if let hit = frame.hitTest(location) {
                if hit.acceptsFirstResponder { window.makeFirstResponder(hit) }
                hit.mouseDown(with: down)
            }
        }
        while NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {}
    }
}

private final class ClickTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}
private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
/// Every selection the text view takes, including the ones its tracking loop sets while the button is down.
private final class SelectionRecorder: NSObject, NSTextViewDelegate {
    var ranges: [NSRange] = []
    func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRanges old: [NSValue],
        toCharacterRanges new: [NSValue]
    ) -> [NSValue] {
        ranges += new.map(\.rangeValue)
        return new
    }
}

import AppKit
import SilkwebCore
import XCTest

@testable import Silkweb

/// #244: a selection drag scrolls only past the editor pane's top or bottom edge (from 4 pt inside it),
/// gradually and at a time-based speed, in default editing, Typewriter Mode and Focus · Typewriter.
/// A drag of a line or two inside the pane never scrolls.
final class DragAutoscrollTests: XCTestCase {
    static let document = (1...200).map { "Line \($0) of a long document with some words in it." }
        .joined(separator: "\n")

    private struct Harness {
        let window: NSWindow
        let editor: PlainMarkdownTextView
        let clip: NSClipView
        let lineHeight: CGFloat
    }

    @MainActor
    private func makeHarness(typewriter: Bool, focus: Bool = false) throws -> Harness {
        _ = NSApplication.shared
        let window = DragTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle(preferences: WritingPreferences()))
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        window.contentView = scroll
        window.makeKey() // Never ordered on screen.
        let editor = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        editor.layoutEditor()
        editor.string = Self.document
        editor.styler.reload()
        editor.isEditable = true
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        editor.sizeToFit()
        window.makeFirstResponder(editor)
        editor.writingModes.set(focus: focus, typewriter: typewriter)
        // Caret in the middle of the document, Typewriter-anchored when the mode is on.
        let middle = (editor.string as NSString).range(of: "Line 100 ").location
        editor.setSelectedRange(NSRange(location: middle, length: 0))
        if typewriter {
            editor.writingModes.anchorCaret()
        } else {
            editor.writingModes.reveal(middle)
        }
        window.displayIfNeeded()
        return Harness(
            window: window, editor: editor, clip: scroll.contentView,
            lineHeight: editor.writingModes.lineHeight(editor))
    }

    /// Press at `start` (clip-view coordinates), then drag along `path` (clip-view points with event
    /// times in seconds after the press) and release at the last point. Returns how far the clip view scrolled.
    @MainActor
    private func drag(_ harness: Harness, from start: NSPoint, path: [(NSPoint, TimeInterval)]) throws -> CGFloat {
        let window = harness.window, editor = harness.editor, clip = harness.clip
        let before = clip.bounds.minY
        // Window coordinates, fixed before any scrolling moves the clip view's bounds.
        func location(_ point: NSPoint) -> NSPoint { clip.convert(point, to: nil) }
        let time = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, _ at: NSPoint, _ offset: TimeInterval, _ number: Int) throws -> NSEvent {
            try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: at, modifierFlags: [], timestamp: time + offset,
                    windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1))
        }
        let down = try event(.leftMouseDown, location(start), 0, 1)
        var queued: [NSEvent] = []
        for (index, (point, offset)) in path.enumerated() {
            queued.append(try event(.leftMouseDragged, location(point), offset, index + 2))
            // AppKit auto-scrolls on the tracking loop's periodic ticks, not on the drag events themselves.
            queued.append(
                try XCTUnwrap(
                    NSEvent.otherEvent(
                        with: .periodic, location: .zero, modifierFlags: [], timestamp: time + offset + 0.001,
                        windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)))
        }
        let last = path.last.map { (location($0.0), $0.1 + 0.01) } ?? (location(start), 0.01)
        queued.append(try event(.leftMouseUp, last.0, last.1, path.count + 2))
        // The text view's tracking loop takes the queued events in order.
        for event in queued.reversed() { NSApp.postEvent(event, atStart: true) }
        window.sendEvent(down)
        // Hidden windows may not dispatch the press; drive the text view as NSWindow would.
        if NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: false) != nil {
            editor.mouseDown(with: down)
        }
        let leftovers: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDragged, .periodic]
        while NSApp.nextEvent(matching: leftovers, until: Date(), inMode: .default, dequeue: true) != nil {}
        return clip.bounds.minY - before
    }

    /// Steps from `from` to `to` over `duration`, then holds at `to` for `hold` seconds, one event per
    /// `frame`, with times starting `after` seconds past the press.
    private func path(
        from: NSPoint, to: NSPoint, duration: TimeInterval, hold: TimeInterval = 0, after: TimeInterval = 0,
        frame: TimeInterval = 1.0 / 60
    ) -> [(NSPoint, TimeInterval)] {
        let moves = max(1, Int((duration / frame).rounded()))
        var result: [(NSPoint, TimeInterval)] = (1...moves).map { step in
            let t = CGFloat(step) / CGFloat(moves)
            let point = NSPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
            return (point, after + Double(step) * frame)
        }
        let holds = Int((hold / frame).rounded())
        if holds > 0 {
            for step in 1...holds { result.append((to, after + Double(moves + step) * frame)) }
        }
        return result
    }

    /// Default editing, the owner's usual Typewriter Mode, and Focus · Typewriter.
    static let modes: [(focus: Bool, typewriter: Bool)] = [(false, false), (false, true), (true, true)]

    private func name(_ mode: (focus: Bool, typewriter: Bool)) -> String {
        WritingModesChip.title(focus: mode.focus, typewriter: mode.typewriter) ?? "Default"
    }

    @MainActor
    private func restore(_ harness: Harness, _ origin: NSPoint) {
        harness.clip.scroll(to: origin)
        harness.clip.enclosingScrollView?.reflectScrolledClipView(harness.clip)
    }

    @MainActor
    func testShortDragsInsideThePaneNeverScroll() throws {
        var failures: [String] = []
        for mode in Self.modes {
            let harness = try makeHarness(typewriter: mode.typewriter, focus: mode.focus)
            defer { harness.window.close() }
            let visible = harness.clip.bounds
            let x = harness.editor.textContainerOrigin.x + 40
            // From the Typewriter anchor (40%) and from all over the pane, 1-2 lines either way.
            for fraction in [0.1, 0.2, 0.4, 0.75, 0.9] {
                for lines in [-2.0, -1.0, 1.0, 2.0] {
                    let y = visible.minY + visible.height * fraction
                    let start = NSPoint(x: x, y: y)
                    let end = NSPoint(x: x + 30, y: y + lines * harness.lineHeight)
                    let scrolled = try drag(
                        harness, from: start, path: path(from: start, to: end, duration: 0.3, hold: 0.5))
                    let label = "\(name(mode)), \(fraction) of the pane, \(lines) lines"
                    if abs(scrolled) > 0.5 { failures.append("\(label): scrolled \(scrolled) pt") }
                    if harness.editor.selectedRange().length == 0 { failures.append("\(label): nothing selected") }
                    restore(harness, visible.origin)
                }
            }
        }
        XCTAssertEqual(failures, [], "short drags inside the pane")
    }

    @MainActor
    func testDragPastTheEdgeScrollsGradually() throws {
        var failures: [String] = []
        for mode in Self.modes {
            let harness = try makeHarness(typewriter: mode.typewriter, focus: mode.focus)
            defer { harness.window.close() }
            let x = harness.editor.textContainerOrigin.x + 40
            let origin = harness.clip.bounds.origin
            // (distance past the pane edge, expected lines per second); -2 is inside the 4 pt margin.
            let speeds: [(CGFloat, Double)] = [(-2, 2), (0, 2), (24, 5), (48, 9.5), (72, 14), (144, 30), (300, 30)]
            // A trackpad-rate and a coarse tick rate scroll at the same speed.
            for frame in [1.0 / 60, 1.0 / 20] {
                for (past, speed) in speeds {
                    for down in [true, false] {
                        let visible = harness.clip.bounds
                        let start = NSPoint(x: x, y: visible.midY)
                        // The clip view is flipped: its maxY is the pane's bottom edge.
                        let end = NSPoint(x: x, y: down ? visible.maxY + past : visible.minY - past)
                        let hold = 1.0
                        let scrolled = try drag(
                            harness, from: start,
                            path: path(from: start, to: end, duration: 0.1, hold: hold, frame: frame))
                        let lines = abs(scrolled) / harness.lineHeight
                        let label =
                            "\(name(mode)), \(Int(1 / frame)) Hz, \(down ? "down" : "up") \(past) pt past the edge"
                        if (scrolled > 0) != down { failures.append("\(label): scrolled \(scrolled) pt the wrong way") }
                        // About `speed` lines in one second of holding, plus at most the short approach.
                        if lines < speed * hold * 0.85 || lines > speed * (hold + 0.1) * 1.15 + 0.5 {
                            let value = String(format: "%.1f", lines)
                            failures.append("\(label): \(value) lines in \(hold) s, expected about \(speed)")
                        }
                        // The selection follows the scrolled text out to the pointer.
                        let selection = harness.editor.selectedRange()
                        let edge = NSPoint(x: x, y: down ? harness.clip.bounds.maxY - 1 : harness.clip.bounds.minY + 1)
                        let pointer = harness.editor.characterIndexForInsertion(
                            at: harness.editor.convert(edge, from: harness.clip))
                        let reaches = down ? NSMaxRange(selection) >= pointer - 80 : selection.location <= pointer + 80
                        if !reaches { failures.append("\(label): selection \(selection) stops short of \(pointer)") }
                        restore(harness, origin)
                    }
                }
            }

            // Back inside the pane, scrolling stops at once: no momentum.
            let visible = harness.clip.bounds
            let start = NSPoint(x: x, y: visible.midY)
            let outside = NSPoint(x: x, y: visible.maxY + 24)
            let scrolled = try drag(
                harness, from: start,
                path: path(from: start, to: outside, duration: 0.1, hold: 0.5)
                    + path(from: outside, to: start, duration: 0.1, hold: 1, after: 0.6))
            let lines = scrolled / harness.lineHeight
            if lines < 5 * 0.5 * 0.85 || lines > 5 * 0.7 * 1.15 + 0.5 {
                failures.append("\(name(mode)): \(String(format: "%.1f", lines)) lines after coming back inside")
            }
            restore(harness, origin)
        }
        XCTAssertEqual(failures, [], "drag auto-scroll speed")
    }

    /// Focus Mode settles on the final selection's unit after the release.
    @MainActor
    func testFocusSettlesAfterDrag() async throws {
        let harness = try makeHarness(typewriter: true, focus: true)
        defer { harness.window.close() }
        let visible = harness.clip.bounds
        let x = harness.editor.textContainerOrigin.x + 40
        let start = NSPoint(x: x, y: visible.midY)
        let end = NSPoint(x: x, y: visible.maxY + 24)
        let scrolled = try drag(harness, from: start, path: path(from: start, to: end, duration: 0.2, hold: 0.5))
        XCTAssertGreaterThan(scrolled, 0)
        try await Task.sleep(for: .milliseconds(100))
        let settled = harness.editor.writingModes.activeRange
        XCTAssertNotNil(settled)
        harness.editor.writingModes.updateActiveRange()
        XCTAssertEqual(harness.editor.writingModes.activeRange, settled, "the bright unit matches the final selection")
    }
}

private final class DragTestWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

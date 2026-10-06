import AppKit
import SilkwebCore
import XCTest

@testable import Silkweb

/// #89: with Typewriter on, a heading jump (Outline click, a click on a heading line in the text,
/// a jump back) must leave a visible caret in the editor that takes typing, with Focus off and on.
final class TypewriterHeadingJumpTests: XCTestCase {
    static let document = (1...40).map {
        "## Section \($0)\n\nBody text for section \($0) with enough words to fill a line.\n\nA second paragraph under section \($0).\n\n"
    }.joined()

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    func testOutlineClickAndTextClickLeaveWorkingCaretInTypewriterMode() async throws {
        for focus in [false, true] { try await run(focus: focus) }
    }

    @MainActor
    private func run(focus: Bool) async throws {
        _ = NSApplication.shared
        let mode = focus ? "Focus · Typewriter" : "Typewriter"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences = TestPreferences("TypewriterHeadingJump")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            preferences.remove()
        }
        try Data(Self.document.utf8).write(to: root.appendingPathComponent("Long.md"))
        let workspace = LibraryWorkspace(defaults: preferences.defaults)
        workspace.canSaveWindowSession = false; workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let opened = await workspace.openTab(try XCTUnwrap(workspace.snapshot?.documents.first), pinned: true)
        XCTAssertTrue(opened)
        workspace.preview.showsOutline = true
        let controller = LibrarySplitViewController(workspace: workspace)
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 1400, height: 900))
        controller.view.setFrameSize(NSSize(width: 1400, height: 900))
        window.makeKey() // Never ordered on screen.
        defer { window.contentViewController = nil; window.close() }

        func settle(_ turns: Int = 5) async throws {
            for _ in 0..<turns {
                controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
            }
            window.displayIfNeeded()
        }
        var table: NSTableView?
        for _ in 0..<150 where table == nil {
            try await settle(1)
            let count = workspace.preview.outlineItems.count
            table = descendants(controller.view).compactMap { $0 as? NSTableView }
                .first { !($0 is DocumentTableView) && count == 40 && [count, count + 1].contains($0.numberOfRows) }
        }
        let outline = try XCTUnwrap(table, "\(mode): no Outline table")
        let items = workspace.preview.outlineItems
        let offset = outline.numberOfRows - items.count
        let editor = try XCTUnwrap(workspace.preview.editor)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let clip = scroll.contentView

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(editor)
        workspace.setWritingModes(focus: focus, typewriter: true)
        try await settle(10)
        XCTAssertTrue(editor.writingModes.typewriter)

        func click(_ view: NSView, at point: NSPoint) throws {
            let location = view.convert(point, to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            let down = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.05,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            let content = try XCTUnwrap(window.contentView)
            let frameView = content.superview ?? content
            let hit = try XCTUnwrap(frameView.hitTest(frameView.convert(location, from: nil)), "No view at \(location)")
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            // Hidden windows may not dispatch the click; drive the hit-tested view as well.
            if hit.isDescendant(of: editor) {
                // The text view's tracking loop takes the queued mouse-up, so only click if nothing did.
                let pending = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: false)
                if pending != nil {
                    // What NSWindow does for a click on a view that accepts first responder.
                    XCTAssertTrue(window.makeFirstResponder(editor), "the editor takes focus on a click")
                    editor.mouseDown(with: down)
                }
            } else if hit !== view {
                hit.mouseDown(with: down); hit.mouseUp(with: up)
            }
            window.sendEvent(up)
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
        }
        func clickOutline(_ index: Int) async throws {
            outline.scrollRowToVisible(offset + index)
            try await settle()
            let rect = outline.rect(ofRow: offset + index)
            try click(outline, at: NSPoint(x: rect.midX, y: rect.midY))
            try await settle()
        }
        func press(_ characters: String, _ code: UInt16) async throws {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.sendEvent(event)
            try await settle(3)
        }
        func headingLocation(_ number: Int) -> Int {
            (editor.string as NSString).range(of: "## Section \(number)\n").location
        }
        func screenY(_ location: Int) throws -> CGFloat {
            try XCTUnwrap(editor.writingModes.caretLine(at: location)).midY - clip.bounds.minY
        }
        /// The caret is in the editor at `location`, drawn inside the visible clip, undimmed, and takes typing.
        func assertWorkingCaret(
            at location: Int, anchored: Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line
        ) async throws {
            let context = "\(mode), \(message)"
            XCTAssertTrue(
                window.firstResponder === editor,
                "\(context): editor is first responder, not \(String(describing: window.firstResponder))",
                file: file, line: line)
            XCTAssertEqual(
                editor.selectedRange(), NSRange(location: location, length: 0), context, file: file, line: line)
            XCTAssertTrue(editor.isEditable, context, file: file, line: line)
            XCTAssertTrue(editor.shouldDrawInsertionPoint, "\(context): insertion point drawn", file: file, line: line)
            let caret = try XCTUnwrap(editor.writingModes.caretLine(at: location))
            let visible = clip.bounds
            XCTAssertTrue(
                caret.minY >= visible.minY && caret.maxY <= visible.maxY,
                "\(context): caret line \(caret) inside the visible clip \(visible)", file: file, line: line)
            if anchored {
                XCTAssertEqual(
                    try screenY(location), WritingModeController.anchor * scroll.contentSize.height, accuracy: 1.5,
                    "\(context): Typewriter anchor", file: file, line: line)
            }
            if focus {
                for _ in 0..<20 where editor.writingModes.isFading { try await settle(1) }
                XCTAssertEqual(
                    editor.writingModes.opacity(at: caret.midY), 1, accuracy: 0.001, "\(context): caret line is bright",
                    file: file, line: line)
            }
            let before = clip.bounds.minY
            try await press("x", 7)
            XCTAssertEqual(
                (editor.string as NSString).substring(with: NSRange(location: location, length: 1)), "x",
                "\(context): typed character lands at the caret", file: file, line: line)
            XCTAssertEqual(editor.selectedRange().location, location + 1, context, file: file, line: line)
            XCTAssertEqual(
                try screenY(location), WritingModeController.anchor * scroll.contentSize.height, accuracy: 1.5,
                "\(context): the keystroke anchors the line (was at \(before))", file: file, line: line)
            try await press("\u{7F}", 51) // ⌫ keeps the fixture text unchanged for the next jump.
            XCTAssertEqual(editor.string, Self.document, context, file: file, line: line)
        }

        // Path A: an Outline click jumps and focuses the editor (owner decision, reverses #72).
        try await clickOutline(11)
        XCTAssertEqual(items[11].sourceRange.location, headingLocation(12))
        try await assertWorkingCaret(at: headingLocation(12), anchored: true, "Outline click")
        XCTAssertEqual(outline.selectedRow, offset + 11, "\(mode): the clicked row stays selected for ↑/↓ later")

        // Path B: a click on another heading line in the text; no scroll until the first keystroke.
        // The line sits under Typewriter's bottom inset, where AppKit kept clicks for the scroll view.
        for _ in 0..<50 where editor.isContentSizingPending { try await settle(1) }
        let target = headingLocation(13)
        let line = try XCTUnwrap(editor.writingModes.caretLine(at: target))
        XCTAssertTrue(clip.bounds.contains(NSPoint(x: line.minX, y: line.midY)), "\(mode): Section 13 is on screen")
        let resting = clip.bounds.minY
        try click(editor, at: NSPoint(x: editor.textContainerOrigin.x + 1, y: line.midY))
        try await settle()
        XCTAssertEqual(clip.bounds.minY, resting, accuracy: 0.5, "\(mode): a click in the text does not scroll")
        try await assertWorkingCaret(at: target, anchored: false, "text click")

        // Back to the first heading, then a second Outline jump.
        try await clickOutline(0)
        try await assertWorkingCaret(at: headingLocation(1), anchored: true, "Outline click back")
        try await clickOutline(30)
        try await assertWorkingCaret(at: headingLocation(31), anchored: true, "second Outline click")

        // Return in a focused Outline navigates but keeps the Outline focused; Esc returns to the editor.
        window.makeFirstResponder(outline)
        try await settle()
        let row = outline.selectedRow
        try await press("\u{F701}", 125)
        XCTAssertEqual(outline.selectedRow, row + 1, "\(mode): ↓ in the focused Outline")
        let returned = try XCTUnwrap(
            items.indices.contains(outline.selectedRow - offset) ? outline.selectedRow - offset : nil)
        try await press("\r", 36)
        XCTAssertEqual(editor.selectedRange().location, headingLocation(returned + 1), "\(mode): Return navigates")
        XCTAssertTrue(
            (window.firstResponder as? NSView).map { $0 === outline || $0.isDescendant(of: outline) } ?? false,
            "\(mode): Return keeps the Outline focused")
        try await press("\u{1B}", 53)
        try await assertWorkingCaret(at: headingLocation(returned + 1), anchored: true, "Esc from the Outline")
        XCTAssertFalse(window.isVisible)
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

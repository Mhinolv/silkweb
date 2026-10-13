import AppKit
import SilkwebCore
import XCTest

@testable import Silkweb

/// #246: with Focus + Typewriter on, Editor view and the Outline showing, typing must never move the Outline's
/// caret-following capsule (no Alpha -> Beta -> Alpha while the outline catches up), and keystrokes must not
/// re-evaluate the detail, Inspector, status bar or document list bodies.
final class OutlineTypingStabilityTests: XCTestCase {
    static let document = """
        # Title

        Intro paragraph.

        ## Alpha

        Alpha body line with some words in it.
        ## Beta

        Beta body line with some words in it.

        ## Gamma

        Gamma body.

        """

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    func testTypingNeverMovesTheOutlineCapsuleOrReevaluatesTheWindow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences = TestPreferences("OutlineTypingStability")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            preferences.remove()
        }
        try Data(Self.document.utf8).write(to: root.appendingPathComponent("Note.md"))
        try Data("# Other\n\nText.\n".utf8).write(to: root.appendingPathComponent("Other.md"))
        let workspace = LibraryWorkspace(defaults: preferences.defaults)
        workspace.canSaveWindowSession = false; workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let note = try XCTUnwrap(workspace.snapshot?.documents.first { $0.name == "Note.md" })
        workspace.session.selectedDocuments = [note.relativePath]
        let opened = await workspace.openTab(note, pinned: true)
        XCTAssertTrue(opened)
        workspace.preview.mode = .editor
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
                .first { !($0 is DocumentTableView) && count == 4 && [count, count + 1].contains($0.numberOfRows) }
        }
        XCTAssertNotNil(table, "no Outline table")
        XCTAssertGreaterThan(workspace.bodyCounts["DocumentRow"] ?? 0, 0, "the document list is on screen")
        let editor = try XCTUnwrap(workspace.preview.editor)
        window.makeFirstResponder(editor)
        workspace.setWritingModes(focus: true, typewriter: true)
        try await settle(10)

        func press(_ characters: String, _ code: UInt16) throws {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
            window.sendEvent(event)
        }
        /// Rows by position: typing on a heading line renames its row without moving the capsule.
        func name(_ row: Int?) -> String { row.map { ["Title", "Alpha", "Beta", "Gamma", "D"][$0] } ?? "none" }
        /// The capsule's rows, one entry per move.
        func moves() -> [String] {
            workspace.outlineCurrentLog.map(name).reduce(into: []) { if $0.last != $1 { $0.append($1) } }
        }
        let keyGap = 2 // 40 ms per key: continuous typing, inside the 250 ms outline debounce.

        /// Places the caret, lets the outline settle, then types `keys` and waits for the outline to catch up.
        func type(_ keys: [(String, UInt16)], at location: Int, expect: String, _ context: String) async throws {
            workspace.outlineCurrentLog = []
            editor.setSelectedRange(NSRange(location: location, length: 0))
            try await settle(25)
            XCTAssertEqual(moves().last, expect, "\(context): the caret move shows its section: \(moves())")
            workspace.outlineCurrentLog = []
            for (characters, code) in keys {
                try press(characters, code)
                try await settle(keyGap)
            }
            try await settle(30) // The debounced outline republishes.
            XCTAssertEqual(moves().filter { $0 != expect }, [], "\(context): the capsule left \(expect): \(moves())")
        }

        let text = { editor.string as NSString }
        // Section boundary: the end of Alpha's last line sits right before "## Beta".
        let boundary = text().range(of: "in it.\n## Beta").location + "in it.".count
        try await type(
            Array(repeating: ("x", 7), count: 4) + [("\r", 36), ("y", 16), ("\r", 36), ("w", 13)], at: boundary,
            expect: "Alpha", "section boundary")
        // On a heading line, Beta (typing renames the row; the capsule stays on it).
        let heading = text().range(of: "## Beta").location + "## Beta".count
        try await type(Array(repeating: ("q", 12), count: 5), at: heading, expect: "Beta", "heading line")
        // Mid-section in Alpha.
        let middle = text().range(of: "Alpha body").location + 6
        try await type(Array(repeating: ("z", 6), count: 5), at: middle, expect: "Alpha", "mid-section")

        // Continuous typing re-evaluates none of the window's bodies, not even the Outline rows.
        workspace.outlineCurrentLog = []
        editor.setSelectedRange(NSRange(location: text().range(of: "Gamma body").location + 5, length: 0))
        try await settle(30)
        XCTAssertEqual(moves(), ["Gamma"], "a real caret move moves the capsule once")
        try press("v", 9)
        try await settle(keyGap) // The first key turns Saved into Edited.
        workspace.bodyCounts = [:]
        for _ in 0..<8 {
            try press("v", 9)
            try await settle(keyGap)
        }
        for view in ["DocumentDetail", "InspectorView", "Outline", "DocumentStatusBar", "DocumentList", "DocumentRow"] {
            XCTAssertEqual(workspace.bodyCounts[view] ?? 0, 0, "\(view) body re-evaluated while typing")
        }

        // A newly typed heading takes the capsule once, after the outline republishes.
        try await settle(30)
        workspace.outlineCurrentLog = []
        for (characters, code) in [("\r", 36), ("#", 20), ("#", 20), (" ", 49), ("D", 2)] as [(String, UInt16)] {
            try press(characters, code)
            try await settle(keyGap)
        }
        try await settle(30)
        XCTAssertEqual(workspace.preview.outlineItems.count, 5)
        XCTAssertEqual(moves(), ["Gamma", "D"], "the new heading's row")
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

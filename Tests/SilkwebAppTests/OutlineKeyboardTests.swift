import AppKit
import XCTest
import SilkwebCore
@testable import Silkweb

final class OutlineKeyboardTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    /// Owner GUI check on fec8ed0: clicking an Outline row navigated but left the
    /// List without focus, so ↑/↓ never reached it.
    @MainActor
    func testClickFocusesOutlineAndRealKeysMoveThroughHeadingsAndImages() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Silkweb.OutlineKeyboard." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let source = "# Settling In\n###### Jamestown\n![Camp](camp.png)\n### Building\n###### Lake Erie\n![](https://example.invalid/erie.png)\nTail\n"
        try Data(source.utf8).write(to: root.appendingPathComponent("Document.md"))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false; workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let opened = await workspace.openTab(try XCTUnwrap(workspace.snapshot?.documents.first), pinned: true)
        XCTAssertTrue(opened)
        workspace.preview.showsOutline = true
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: suite)
        let window = KeyableWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 1400, height: 900))
        controller.view.setFrameSize(NSSize(width: 1400, height: 900))
        window.makeKey() // Never ordered on screen.
        defer { window.contentViewController = nil; window.close() }
        var table: NSTableView?
        for _ in 0..<150 where table == nil {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
            let count = workspace.preview.outlineItems.count
            table = descendants(controller.view).compactMap { $0 as? NSTableView }
                .first { !($0 is DocumentTableView) && count == 6 && [count, count + 1].contains($0.numberOfRows) }
        }
        let items = workspace.preview.outlineItems
        XCTAssertEqual(items.map(\.label), ["Settling In", "Jamestown", "Camp", "Building", "Lake Erie", "erie.png"])
        let outline = try XCTUnwrap(table, "Tables: \(descendants(controller.view).compactMap { $0 as? NSTableView }.map { "\(type(of: $0)) \($0.numberOfRows)" })")
        let offset = outline.numberOfRows - items.count // Section header row.
        let editor = try XCTUnwrap(workspace.preview.editor)
        editor.setSelectedRange(NSRange(location: source.utf16.count, length: 0))
        window.makeFirstResponder(editor)

        // A real click on the "Jamestown" row: native window dispatch first; hidden
        // windows may not dispatch to List rows, so also drive the hit-tested view.
        let rect = outline.rect(ofRow: offset + 1)
        let location = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.05,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        let content = try XCTUnwrap(window.contentView)
        let frameView = content.superview ?? content
        let hit = try XCTUnwrap(frameView.hitTest(frameView.convert(location, from: nil)),
            "No view at \(location); content \(content.frame); row \(outline.convert(rect, to: nil)); visible \(outline.visibleRect)")
        NSApp.postEvent(up, atStart: true)
        window.sendEvent(down)
        if hit !== outline { hit.mouseDown(with: down); hit.mouseUp(with: up) }
        window.sendEvent(up)
        _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
        for _ in 0..<5 { controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(editor.selectedRange().location, items[1].sourceRange.location, "Click navigates the editor")
        let responder = window.firstResponder as? NSView
        XCTAssertTrue(responder.map { $0 === outline || $0.isDescendant(of: outline) } ?? false,
                      "Click leaves the Outline focused, not \(String(describing: window.firstResponder))")
        XCTAssertEqual(outline.selectedRow, offset + 1)

        func press(_ key: String, _ code: UInt16) async throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            window.sendEvent(event)
            for _ in 0..<3 { controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        }
        let down_ = "\u{f701}", up_ = "\u{f700}"
        try await press(down_, 125)
        XCTAssertEqual(outline.selectedRow, offset + 2, "↓ selects the image row")
        try await press(down_, 125)
        XCTAssertEqual(outline.selectedRow, offset + 3, "↓ selects the next heading")
        try await press(up_, 126)
        XCTAssertEqual(outline.selectedRow, offset + 2, "↑ returns to the image row")
        XCTAssertEqual(editor.selectedRange().location, items[1].sourceRange.location, "Moving the selection does not navigate")
        try await press("\r", 36)
        XCTAssertEqual(editor.selectedRange().location, items[2].sourceRange.location, "Return navigates to the image line")
        XCTAssertTrue((window.firstResponder as? NSView).map { $0 === outline || $0.isDescendant(of: outline) } ?? false,
                      "Return keeps focus in the Outline")
        for _ in 0..<8 { try await press(down_, 125) }
        XCTAssertEqual(outline.selectedRow, offset + items.count - 1, "No wrap at the last row")
        try await press("\r", 36)
        XCTAssertEqual(editor.selectedRange().location, items[5].sourceRange.location)
        XCTAssertFalse(window.isVisible)
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

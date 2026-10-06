import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #90: the Outline paints one capsule, always the user's Accent-derived `SilkwebSelection` in the key window
/// (`SilkwebSelectionInactive` otherwise): on the keyboard selection while the Outline is focused, on the caret's
/// section otherwise. The List's own (system accent) fill never shows.
final class OutlineSelectionColorTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }

    @MainActor
    func testOneAccentCapsuleFollowsKeyboardThenCaret() async throws {
        _ = NSApplication.shared
        let oldPreferences = LivePreferences.shared.current
        let oldAppearance = NSApp.appearance
        defer {
            LivePreferences.shared.current = oldPreferences
            ColorRevision.shared.bump()
            NSApp.appearance = oldAppearance
        }
        // The owner's amber Accent (Settings ▸ Appearance), in both colour sets.
        var preferences = oldPreferences
        preferences.colors.light.accent = HexColor(0xC77C1A)
        preferences.colors.dark.accent = HexColor(0xE39A3B)
        LivePreferences.shared.current = preferences
        ColorRevision.shared.bump()

        let defaults = disposableDefaults("OutlineSelectionColor")
        let workspace = LibraryWorkspace(defaults: defaults)
        let source = "# One\n## Two\n## Three\n# Four\n"
        let items = OutlineItem.parse(source)
        workspace.preview.headings = MarkdownParser.parse(source).headings
        workspace.preview.outlineItems = items
        func caret(at row: Int) { workspace.editor.caretLocation = items[row].sourceRange.location }
        caret(at: 0)

        let host = NSHostingView(rootView: AnyView(InspectorView(workspace: workspace)))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        // Stands in for the editor: focus leaves the Outline for it.
        let editor = NSTextView(frame: NSRect(x: 260, y: 0, width: 200, height: 400))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 400))
        container.addSubview(host); container.addSubview(editor)
        let window = KeyWindow(
            contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.makeKey() // Never ordered on screen.
        defer { window.contentView = nil; window.close() }

        func settle() async throws {
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        }
        func outlineTable() async throws -> NSTableView {
            var found: NSTableView?
            for _ in 0..<100 where found == nil {
                try await settle()
                found = descendants(host).compactMap { $0 as? NSTableView }.first { $0.numberOfRows >= items.count }
            }
            let table = try XCTUnwrap(found, "Outline List missing")
            XCTAssertEqual(table.numberOfRows, items.count)
            return table
        }
        func press(_ key: String, _ code: UInt16) async throws {
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code))
            window.sendEvent(event)
            try await settle()
        }

        /// Which rows carry a capsule; each must be the expected Silkweb fill.
        func capsules(_ label: String, table: NSTableView, key: Bool) throws -> [Int] {
            let scale: CGFloat = 2
            let rep = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(table.bounds.width * scale),
                    pixelsHigh: Int(table.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            rep.size = table.bounds.size
            table.cacheDisplay(in: table.bounds, to: rep)
            var pane = NSColor.white, fill = NSColor.white
            // The capsule fades to the inactive fill only when the window is not key (#90 decision 2).
            let token: NSColor = key ? .silkwebSelection : .silkwebSelectionInactive
            table.effectiveAppearance.performAsCurrentDrawingAppearance {
                pane = NSColor.silkwebPaneBackground.usingColorSpace(.sRGB) ?? .white
                fill = token.usingColorSpace(.sRGB) ?? .white
            }
            func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
                max(
                    abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent),
                    abs(a.blueComponent - b.blueComponent))
            }
            var rows: [Int] = []
            for row in 0..<table.numberOfRows {
                let rect = table.rect(ofRow: row)
                // Right of the short titles and clear of the thread guides.
                let x = Int((rect.maxX - 30) * scale), y = Int(rect.midY * scale)
                let color = try XCTUnwrap(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                if color.alphaComponent < 0.1 || distance(color, pane) < 0.02 { continue }
                rows.append(row)
                XCTAssertLessThan(
                    distance(color, fill), 0.04, "\(label): row \(row) is \(color), not the Silkweb selection \(fill)")
            }
            return rows
        }

        // An offscreen window is never key, so the key window's state is also forced through the environment.
        for (forceKey, dark) in [(false, false), (false, true), (true, false), (true, true)] {
            let key = forceKey || window.isKeyWindow
            let inspector = InspectorView(workspace: workspace)
            host.rootView = forceKey ? AnyView(inspector.environment(\.controlActiveState, .key)) : AnyView(inspector)
            let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
            NSApp.appearance = appearance
            window.appearance = appearance
            window.makeFirstResponder(editor)
            caret(at: 0)
            let table = try await outlineTable()
            let mode = (dark ? "dark" : "light") + (key ? " key" : " inactive")
            XCTAssertEqual(
                try capsules("\(mode) unfocused", table: table, key: key), [0], "\(mode): the current section only")

            // Tab into the Outline: the capsule stays on the current row, then follows ↓.
            window.makeFirstResponder(table)
            try await settle()
            XCTAssertEqual(table.selectedRow, 0, mode)
            XCTAssertEqual(
                try capsules("\(mode) focused", table: table, key: key), [0], "\(mode): focusing keeps one capsule")
            try await press("\u{f701}", 125)
            XCTAssertEqual(table.selectedRow, 1, mode)
            XCTAssertEqual(
                try capsules("\(mode) arrowed", table: table, key: key), [1], "\(mode): the keyboard selection only")

            // Focus returns to the editor: the keyboard selection is dropped, the capsule is the caret's.
            window.makeFirstResponder(editor)
            try await settle()
            XCTAssertEqual(
                try capsules("\(mode) focus left", table: table, key: key), [0], "\(mode): back on the current section")

            // The caret moves in the editor: still one capsule, on its new section.
            caret(at: 3)
            try await settle()
            XCTAssertEqual(
                try capsules("\(mode) caret moved", table: table, key: key), [3], "\(mode): follows the caret")
        }
        XCTAssertFalse(window.isVisible)
    }
}

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

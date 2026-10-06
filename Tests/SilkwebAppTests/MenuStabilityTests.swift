import AppKit
import Observation
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// Counts invalidations of production menu dependencies without launching a scene
/// or entering AppKit's modal event loop. Rearming models SwiftUI rebuilding after a change.
private final class CommandInvalidations: @unchecked Sendable {
    private let lock = NSLock()
    private var changes = 0
    private var needsBuild = true
    var count: Int { lock.withLock { changes } }

    @MainActor func buildIfNeeded(_ body: () -> Void) {
        guard
            lock.withLock({
                if !needsBuild { return false }
                needsBuild = false
                return true
            })
        else { return }
        withObservationTracking(
            body,
            onChange: { [self] in
                lock.withLock {
                    changes += 1; needsBuild = true
                }
            })
    }
}

final class MenuStabilityTests: XCTestCase {
    @MainActor
    func testMenuBarCommandsDuringTwoSecondsOfIdleEditingActivity() async throws {
        _ = NSApplication.shared
        let workspace = LibraryWorkspace(defaults: disposableDefaults("MenuStability"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Menu.md")
        try "# Heading\nBody".write(to: file, atomically: true, encoding: .utf8)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedDocuments = ["Menu.md"]
        await workspace.editor.configure(root: root, recoveryDirectory: root.appendingPathComponent("recovery"))
        _ = await workspace.editor.open(file, readOnly: false)
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let editor = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll // never ordered on screen
        editor.string = "# Heading\nBody"
        editor.isEditable = true
        let target = FormattingTarget.shared
        target.editor = editor
        target.refresh()
        defer { target.editor = nil; target.refresh(); window.contentView = nil }

        // The main group covers File, Edit, View and Go, and also builds FormatCommands, so
        // its invalidations rebuilt the Format menu too (pre-fix: 40); the separate groups cover
        // Format (including Heading), Window, File's print/export, and Edit's Find.
        let bodies: [(String, () -> Void)] = [
            ("File/Edit/View/Go", { _ = WorkspaceCommands(workspace: workspace).body }),
            (
                "Format",
                {
                    _ = FormatCommands().body
                    // CommandGroup evaluates its content lazily. Register the exact
                    // enabled dependency read by its buttons while a menu is tracking.
                    _ = target.enabled
                }
            ),
            (
                "Window/Save",
                {
                    _ = TabCommands(workspace: workspace).body
                    _ = workspace.tabs; _ = workspace.activeTabID
                    _ = workspace.editor.url; _ = workspace.editor.readOnly
                }
            ),
            (
                "Print",
                {
                    _ = PrintCommands(workspace: workspace).body; _ = workspace.menuState.value.canPrint
                }
            ),
            ("Export", { _ = ExportMenu(workspace: workspace, state: workspace.menuState.value).body }),
            ("Find", { _ = FindMenu(workspace: workspace, state: workspace.menuState.value).body }),
        ]
        let probes = bodies.map { _ in CommandInvalidations() }
        // Explicit offscreen NSMenu.update loop instead of an on-screen tracking loop.
        // Count the SwiftUI dependencies above, rather than claiming these native
        // menus are SwiftUI's private rendered menu hierarchy.
        let menus = ["File", "Edit", "View", "Format", "Go", "Window"].map { NSMenu(title: $0) }
        for (index, entry) in bodies.enumerated() { probes[index].buildIfNeeded(entry.1) }
        for tick in 0..<40 {
            // Same kinds of publishes as autosave completion, caret movement and
            // index progress. No document/menu capability changes in this interval.
            workspace.editor.state = tick.isMultiple(of: 2) ? .dirty : .clean
            workspace.install(try XCTUnwrap(workspace.snapshot))
            workspace.editor.caretLocation = tick % editor.string.utf16.count
            editor.setSelectedRange(NSRange(location: workspace.editor.caretLocation, length: 0))
            workspace.search.state = .building(indexed: tick, total: 40)
            // updateNSView refreshes the target after session publishes; didChangeText
            // and IME callbacks use this same production path as well.
            target.refresh()
            for menu in menus { menu.update() }
            try await Task.sleep(for: .milliseconds(50))
            for (index, entry) in bodies.enumerated() { probes[index].buildIfNeeded(entry.1) }
        }
        for (index, entry) in bodies.enumerated() {
            print("Menu dependency invalidations: \(entry.0) = \(probes[index].count)")
            XCTAssertLessThanOrEqual(probes[index].count, 1, entry.0)
        }
    }

    @MainActor
    func testCachedMenuStateFollowsRealChangesAndMenuOpen() async throws {
        _ = NSApplication.shared
        let workspace = LibraryWorkspace(defaults: disposableDefaults("MenuStability"))
        let state = workspace.menuState
        XCTAssertFalse(state.value.hasLibrary)
        XCTAssertFalse(state.value.canPrint)
        XCTAssertFalse(state.value.canExport)
        XCTAssertEqual(state.value.sidebarsTitle, workspace.sidebarsTitle)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Menu.md")
        try "Body".write(to: file, atomically: true, encoding: .utf8)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedDocuments = ["Menu.md"]
        await workspace.editor.configure(root: root, recoveryDirectory: root.appendingPathComponent("recovery"))
        _ = await workspace.editor.open(file, readOnly: false)
        await Task.yield()
        XCTAssertTrue(state.value.hasLibrary)
        XCTAssertEqual(state.value.canPrint, workspace.canPrint)
        XCTAssertEqual(state.value.canExport, workspace.canExport)
        XCTAssertEqual(state.value.canFind, workspace.canFind)

        for (hidden, title) in [(true, "Show Sidebars"), (false, "Hide Sidebars")] {
            workspace.sidebarsHidden = hidden
            await Task.yield()
            XCTAssertEqual(state.value.sidebarsTitle, title)
        }
        for mode in [DocumentViewMode.preview, .split, .editor] {
            workspace.preview.mode = mode
            await Task.yield()
            XCTAssertEqual(state.value.previewMode, mode)
            XCTAssertEqual(state.value.canFind, workspace.canFind, "Find gating follows view mode")
        }
        // ⌘7/⌘8 checkmarks follow the visible Inspector segment only (#69).
        workspace.preview.showsOutline = false
        for (segment, expected) in [
            (LibraryWorkspace.InspectorSegment.info, LibraryWorkspace.InspectorSegment?.some(.info)),
            (.outline, .outline), (.outline, nil), (.outline, .outline), (.info, .info), (.info, nil),
        ] {
            workspace.toggleInspector(segment)
            await Task.yield()
            XCTAssertEqual(state.value.inspectorSegment, expected, "\(segment)")
        }

        // Opening any menu resamples AppKit-owned state without needing a workspace publish.
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        XCTAssertEqual(state.value, MenuCommandValues(workspace: workspace))
    }

    @MainActor
    func testFormatCapabilitiesChangeImmediatelyButRepeatedRefreshDoesNotPublish() throws {
        _ = NSApplication.shared
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let editor = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        let otherScroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let other = try XCTUnwrap(otherScroll.documentView as? PlainMarkdownTextView)
        let target = FormattingTarget.shared
        defer { target.editor = nil; target.refresh() }
        let probe = CommandInvalidations()
        for editable in [false, true] {
            target.editor = editor
            editor.isEditable = editable
            target.refresh()
            XCTAssertEqual(target.enabled, editable)
            probe.buildIfNeeded {
                _ = FormatCommands().body; _ = target.enabled
            }
            let before = probe.count
            for _ in 0..<10 { target.refresh() }
            XCTAssertEqual(probe.count, before)
        }
        let before = probe.count
        editor.isEditable = false
        target.refresh()
        XCTAssertFalse(target.enabled)
        XCTAssertEqual(probe.count, before + 1, "real capability change invalidates commands")
        other.isEditable = true
        target.editor = other
        target.refresh()
        XCTAssertTrue(target.enabled)
        target.editor = nil
        target.refresh()
        XCTAssertFalse(target.enabled)
        target.editor = editor
        editor.isEditable = true
        editor.setMarkedText(
            "あ", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: 0, length: 0))
        target.refresh()
        XCTAssertFalse(target.enabled, "IME composition disables formatting")
        editor.unmarkText()
        XCTAssertTrue(target.enabled)
    }
}

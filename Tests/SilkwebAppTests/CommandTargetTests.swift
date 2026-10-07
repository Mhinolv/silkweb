import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// An offscreen window is never key; this one reports the key state a test assigns, so a second
/// window (Settings) can be "in front" without ordering anything on screen.
final class KeyedTestWindow: NSWindow {
    var key = true
    override var isKeyWindow: Bool { key }
}

extension LibraryWorkspace {
    /// Windowless fixtures: gives the sidebar (`column` 0) or list keyboard focus in a key window,
    /// as a click there would, so the menu-bar Rename/Move/Trash paths are enabled (#104).
    @MainActor func focusLibraryPaneForTesting(_ column: Int) -> NSWindow {
        let window = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        let view: NSTableView
        if column == 0 {
            let outline = SidebarOutlineView()
            sidebarOutline = outline
            view = outline
        } else {
            let table = DocumentTableView()
            documentTable = table
            view = table
        }
        view.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pane")))
        window.contentView = view // Never ordered on screen.
        window.makeFirstResponder(view)
        focusColumn = column
        return window
    }
}

/// #104: menu commands act only on what has focus in the key window. Format and Close Tab need the
/// library window key; Rename, Move To… and Move to Trash need the sidebar or list first responder.
@MainActor
final class CommandTargetTests: XCTestCase {
    private struct Library {
        let root: URL, workspace: LibraryWorkspace, window: KeyedTestWindow
        @MainActor func cleanUp() {
            window.contentViewController = nil
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func library() async throws -> Library {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebTarget-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Coffee"), withIntermediateDirectories: true)
        try Data("# Pour-Over\n\n## Grind\n\nMedium-fine.\n\n## Water\n\nHot.\n".utf8).write(
            to: root.appendingPathComponent("Coffee/Pour-Over.md"))
        try Data("# Cold Brew\n\nSteep overnight.".utf8).write(to: root.appendingPathComponent("Coffee/Cold Brew.md"))
        let workspace = LibraryWorkspace(defaults: disposableDefaults("CommandTarget"))
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        let window = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: AnyView(LibraryWorkspaceView(workspace: workspace)))
        controller.sizingOptions = []
        window.contentViewController = controller // Never ordered on screen.
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        let fixture = Library(root: root, workspace: workspace, window: window)
        try await settle(window)
        workspace.session.selectedFolder = "Coffee"
        workspace.selectDocuments(["Coffee/Pour-Over.md"])
        await workspace.waitForNavigation()
        try await settle(window)
        return fixture
    }

    private func settle(_ window: NSWindow, _ rounds: Int = 4) async throws {
        for _ in 0..<rounds {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func list(_ window: NSWindow) throws -> DocumentTableView {
        try XCTUnwrap(Self.descendants(window.contentView!).compactMap { $0 as? DocumentTableView }.first)
    }

    /// Settings in front of the library: the editor never resigns first responder, so a target
    /// that only checks the editor kept ⌘B pointed at the hidden document.
    func testSettingsKeyDisablesFormatForTheHiddenEditor() async throws {
        let fixture = try await library()
        defer { fixture.cleanUp() }
        let (workspace, window) = (fixture.workspace, fixture.window)
        let target = FormattingTarget.shared
        defer { target.editor = nil; target.refresh() }
        let editor = try XCTUnwrap(workspace.preview.editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        try await settle(window, 2)
        target.refresh()
        XCTAssertTrue(target.enabled, "library key, editor first responder: Format as today")

        // Settings becomes key; the library editor stays its window's first responder.
        window.key = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        target.refresh()
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertFalse(target.enabled, "Format must not reach the editor behind Settings")
        let before = editor.string
        target.perform { $0.format(.bold) }
        XCTAssertEqual(editor.string, before, "⌘B inserted markup into the hidden document")

        // The library becomes key again: Format re-enables without a click.
        window.key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(target.enabled)
    }

    /// ⌘W with Settings key closes the front window, never the library tab behind it.
    func testSettingsKeyCloseCommandLeavesLibraryTabsAlone() async throws {
        let fixture = try await library()
        defer { fixture.cleanUp() }
        let (workspace, window) = (fixture.workspace, fixture.window)
        XCTAssertEqual(workspace.tabs.count, 1)
        workspace.menuState.refresh()
        XCTAssertTrue(workspace.menuState.libraryKey)

        window.key = false
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        XCTAssertFalse(workspace.menuState.libraryKey, "Close Tab title and tab items follow the key window")
        var closedFront = false
        workspace.performCloseCommand { closedFront = true }
        try await settle(window, 2)
        XCTAssertTrue(closedFront, "⌘W closes the front window")
        XCTAssertEqual(workspace.tabs.count, 1, "the library tab behind Settings stays open")

        // Library key: ⌘W closes the active tab as today.
        window.key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        XCTAssertTrue(workspace.menuState.libraryKey)
        closedFront = false
        workspace.performCloseCommand { closedFront = true }
        for _ in 0..<100 where !workspace.tabs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(closedFront)
        XCTAssertTrue(workspace.tabs.isEmpty)
    }

    /// The Outline (an AppKit-backed List) or the search field has focus while the list row still
    /// looks selected: Rename, Move To… and Move to Trash are off and their menu-bar paths no-op.
    func testOutlineOrSearchFocusDisablesLibraryMutationCommands() async throws {
        let fixture = try await library()
        defer { fixture.cleanUp() }
        let (workspace, window) = (fixture.workspace, fixture.window)
        let file = fixture.root.appendingPathComponent("Coffee/Pour-Over.md")

        // List focused: the commands target the list selection as today.
        XCTAssertTrue(window.makeFirstResponder(try list(window)))
        workspace.focusColumn = 1
        workspace.menuState.refresh()
        XCTAssertTrue(workspace.menuState.value.canTrash)
        XCTAssertTrue(workspace.menuState.value.canMove)
        XCTAssertTrue(workspace.menuState.value.canRename)

        // Outline focused (Tab from the editor); focusColumn still says "list".
        workspace.toggleInspector(.outline)
        try await settle(window)
        let rows = workspace.preview.outlineItems.count
        XCTAssertGreaterThan(rows, 0)
        let outline = try XCTUnwrap(
            Self.descendants(window.contentView!).compactMap { $0 as? NSTableView }
                .first {
                    !($0 is DocumentTableView) && !($0 is SidebarOutlineView)
                        && [rows, rows + 1].contains($0.numberOfRows)
                })
        XCTAssertTrue(window.makeFirstResponder(outline))
        try await settle(window, 2)
        XCTAssertEqual(workspace.session.selectedDocuments, ["Coffee/Pour-Over.md"])
        workspace.menuState.refresh()
        XCTAssertFalse(workspace.menuState.value.canTrash, "⌘⌫ would trash the hidden list selection")
        XCTAssertFalse(workspace.menuState.value.canMove)
        XCTAssertFalse(workspace.menuState.value.canRename)
        XCTAssertEqual(workspace.menuState.value.trashTitle, "Move to Trash")
        workspace.requestTrash()
        workspace.requestMove()
        workspace.beginRename()
        try await settle(window, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Outline focus trashed the document")
        XCTAssertNil(workspace.trashPlan)
        XCTAssertNil(workspace.moveRequest)
        XCTAssertNil(workspace.rename)
        XCTAssertFalse(workspace.mutating)

        // Search Library field focused.
        let field = try XCTUnwrap(
            Self.descendants(window.contentView!).compactMap { $0 as? NSTextField }
                .first { $0.isEditable && $0.placeholderString == "Search Library" })
        XCTAssertTrue(window.makeFirstResponder(field))
        workspace.menuState.refresh()
        XCTAssertFalse(workspace.menuState.value.canTrash)
        XCTAssertFalse(workspace.menuState.value.canMove)
        XCTAssertFalse(workspace.menuState.value.canRename)

        // Back to the list: enabled again, and a key window is required.
        XCTAssertTrue(window.makeFirstResponder(try list(window)))
        try await settle(window, 2)
        XCTAssertTrue(workspace.menuState.value.canTrash, "list focus re-enables Move to Trash")
        XCTAssertTrue(workspace.canTrashSelection)
        window.key = false
        XCTAssertFalse(workspace.canTrashSelection, "a library list behind Settings is not a trash target")
    }
}

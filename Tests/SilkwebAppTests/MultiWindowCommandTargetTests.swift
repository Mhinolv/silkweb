import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #194 → #195: two Libraries open as sidebar sections of one window, each with its own `LibraryWorkspace`. The
/// app's commands act on the current Library (the section holding the selection) and never mutate the other.
@MainActor
final class MultiLibraryCommandTargetTests: XCTestCase {
    private var cleanUps: [@MainActor () async -> Void] = []

    override func tearDown() async throws {
        for cleanUp in cleanUps.reversed() { await cleanUp() }
        cleanUps = []
        try await super.tearDown()
    }

    /// Two sections in the real library window, each with `Notes/<document>.md` open in a tab.
    private func twoLibraries() async throws -> (LibraryWindowRegistry, KeyedTestWindow, [URL]) {
        _ = NSApplication.shared
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebMultiLibrary-" + UUID().uuidString)
        let defaults = disposableDefaults("MultiLibrary")
        let registry = LibraryWindowRegistry(defaults: defaults) {
            let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: nil)
            workspace.canSaveWindowSession = false
            workspace.recoveryDirectory = temporary.appendingPathComponent(".recovery")
            return workspace
        }
        var roots: [URL] = []
        for (name, document) in [("A", "Alpha"), ("B", "Beta")] {
            let root = temporary.appendingPathComponent(name)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
            try Data("# \(document)\n\nBody of \(name).\n".utf8).write(
                to: root.appendingPathComponent("Notes/\(document).md"))
            roots.append(root.standardizedFileURL.resolvingSymlinksInPath())
        }
        let window = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: LibraryWindow(registry: registry))
        controller.sizingOptions = []
        window.contentViewController = controller // Never ordered on screen.
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        cleanUps.append { @MainActor in
            for workspace in registry.workspaces { await workspace.releaseLibrary() }
            window.contentViewController = nil
            window.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        for (root, document) in zip(roots, ["Alpha", "Beta"]) {
            let workspace = try await added(registry, root)
            try await settle(window)
            workspace.session.selectedFolder = "Notes"
            workspace.selectDocuments(["Notes/\(document).md"])
            await workspace.waitForNavigation()
        }
        try await settle(window)
        return (registry, window, roots)
    }

    private func added(_ registry: LibraryWindowRegistry, _ url: URL) async throws -> LibraryWorkspace {
        let workspace = await registry.add(url)
        return try XCTUnwrap(workspace)
    }

    private func settle(_ window: NSWindow, _ rounds: Int = 3) async throws {
        for _ in 0..<rounds {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func focusList(_ window: NSWindow, _ workspace: LibraryWorkspace) throws {
        let list = try XCTUnwrap(Self.descendants(window.contentView!).compactMap { $0 as? DocumentTableView }.first)
        XCTAssertTrue(window.makeFirstResponder(list))
        workspace.focusColumn = 1
    }

    private func markdownFiles(_ root: URL) -> Set<String> {
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Notes").path)) ?? []
        return Set(names.filter { $0.hasSuffix(".md") })
    }

    private func waitIdle(_ workspace: LibraryWorkspace) async throws {
        for _ in 0..<200 where workspace.mutating { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(workspace.mutating)
    }

    func testFileCommandsMutateOnlyTheCurrentLibrary() async throws {
        let (registry, window, roots) = try await twoLibraries()
        let (a, b) = (registry.sections[0], registry.sections[1])
        let (aFiles, bFiles) = (markdownFiles(roots[0]), markdownFiles(roots[1]))

        // A current: the commands' target is A; B's selection is no Rename/Move/Trash target.
        registry.focus(a)
        try await settle(window)
        try focusList(window, a)
        a.menuState.refresh()
        b.menuState.refresh()
        XCTAssertTrue(registry.target === a)
        XCTAssertTrue(registry.target.menuState.value.canTrash)
        XCTAssertEqual(registry.target.menuState.value.trashTitle, "Move “Alpha” to Trash")
        XCTAssertFalse(b.canTrashSelection, "B's selection is not a Trash target")
        registry.target.create(folder: false)
        try await waitIdle(a)
        XCTAssertEqual(markdownFiles(roots[0]).count, aFiles.count + 1, "New Document lands in A")
        XCTAssertEqual(markdownFiles(roots[1]), bFiles, "New Document with A current wrote into B")
        // The menu-bar paths of B no-op while A is current.
        b.requestTrash()
        b.requestMove()
        XCTAssertNil(b.trashPlan)
        XCTAssertNil(b.moveRequest)

        // B current: everything follows B, and A is left alone.
        registry.focus(b)
        try await settle(window)
        try focusList(window, b)
        b.menuState.refresh()
        XCTAssertEqual(registry.target.menuState.value.trashTitle, "Move “Beta” to Trash")
        XCTAssertFalse(a.canTrashSelection)
        let aAfter = markdownFiles(roots[0])
        registry.target.create(folder: false)
        try await waitIdle(b)
        XCTAssertEqual(markdownFiles(roots[1]).count, bFiles.count + 1, "New Document lands in B")
        XCTAssertEqual(markdownFiles(roots[0]), aAfter, "New Document with B current wrote into A")
    }

    /// #197: a tab belonging to A, chosen in the one strip while B is current, makes A current: New Document, Move
    /// To…, Move to Trash, Save and Format then act on A only, and the same for B's tab.
    func testATabFromAnotherLibraryRetargetsTheCommands() async throws {
        let (registry, window, roots) = try await twoLibraries()
        let (a, b) = (registry.sections[0], registry.sections[1])
        XCTAssertTrue(registry.current === b)
        let strip = registry.stripTabs
        XCTAssertEqual(strip.count, 2)
        let aTab = try XCTUnwrap(strip.first { $0.workspace === a })
        let bTab = try XCTUnwrap(strip.first { $0.workspace === b })

        for (tab, library, other, root, otherRoot, name) in [
            (aTab, a, b, roots[0], roots[1], "Alpha"), (bTab, b, a, roots[1], roots[0], "Beta"),
        ] {
            registry.activate(tab)
            try await settle(window)
            XCTAssertTrue(registry.target === library, "\(name)'s tab makes its Library current")
            XCTAssertEqual(library.activeTabID, tab.tab.id)
            XCTAssertEqual(library.breadcrumb.crumbs.first?.title, root.lastPathComponent, "status bar path root")
            // Save and Format: the active tab's editor, in the right Library.
            XCTAssertEqual(registry.target.editor.url?.lastPathComponent, "\(name).md")
            let editor = try XCTUnwrap(library.preview.editor)
            XCTAssertTrue(editor.workspace === library)
            XCTAssertTrue(window.makeFirstResponder(editor))
            let format = FormattingTarget.shared
            format.editor = editor
            format.refresh()
            XCTAssertTrue(format.enabled)
            XCTAssertFalse(other.libraryHasFocus)
            format.editor = nil
            format.refresh()
            // Move To… and Move to Trash follow the list of the current Library only.
            try focusList(window, library)
            library.menuState.refresh()
            XCTAssertEqual(library.menuState.value.trashTitle, "Move “\(name)” to Trash")
            XCTAssertTrue(library.menuState.value.canMove)
            XCTAssertFalse(other.canTrashSelection)
            let (before, otherBefore) = (markdownFiles(root), markdownFiles(otherRoot))
            registry.target.create(folder: false)
            try await waitIdle(library)
            XCTAssertEqual(markdownFiles(root).count, before.count + 1, "New Document lands in \(name)'s Library")
            XCTAssertEqual(markdownFiles(otherRoot), otherBefore)
        }
    }

    /// ⌘W and the tab items act on the current Library's tabs only.
    func testTabCommandsFollowTheCurrentLibrary() async throws {
        let (registry, window, _) = try await twoLibraries()
        let (a, b) = (registry.sections[0], registry.sections[1])
        XCTAssertEqual(a.tabs.count, 1)
        XCTAssertEqual(b.tabs.count, 1)
        registry.focus(b)
        try await settle(window)
        XCTAssertTrue(registry.target.menuState.libraryKey)
        registry.target.performCloseCommand()
        for _ in 0..<100 where !b.tabs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(b.tabs.isEmpty)
        XCTAssertEqual(a.tabs.count, 1, "⌘W in B closed A's tab")
    }
}

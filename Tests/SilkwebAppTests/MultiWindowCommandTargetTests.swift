import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #194: two library windows, each with its own `LibraryWorkspace` from the registry. The app's commands resolve
/// the key library window (or the last-active one while Settings is key) and never mutate the other Library.
@MainActor
final class MultiWindowCommandTargetTests: XCTestCase {
    private struct Library {
        let root: URL, workspace: LibraryWorkspace, window: KeyedTestWindow
    }

    private var cleanUps: [@MainActor () async -> Void] = []

    override func tearDown() async throws {
        for cleanUp in cleanUps.reversed() { await cleanUp() }
        cleanUps = []
        FormattingTarget.shared.editor = nil
        FormattingTarget.shared.refresh()
        try await super.tearDown()
    }

    private func makeRegistry(autosaveBase: String? = nil) -> LibraryWindowRegistry {
        LibraryWindowRegistry(columnAutosaveBase: autosaveBase) { [unowned self] name in
            let workspace = LibraryWorkspace(defaults: disposableDefaults("MultiWindow"), columnAutosaveName: name)
            workspace.canSaveWindowSession = false
            return workspace
        }
    }

    /// A window as the app builds it: adopted from the registry, real `LibraryWorkspaceView`, registered on attach.
    private func library(_ name: String, document: String, in registry: LibraryWindowRegistry) async throws -> Library {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebMultiWindow-\(name)-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("# \(document)\n\nBody of \(name).\n".utf8).write(
            to: root.appendingPathComponent("Notes/\(document).md"))
        let workspace = registry.adopt()
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        let window = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.key = false
        let controller = NSHostingController(rootView: AnyView(LibraryWorkspaceView(workspace: workspace)))
        controller.sizingOptions = []
        window.contentViewController = controller // Never ordered on screen.
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        registry.register(workspace, window: window)
        cleanUps.append { @MainActor in
            await workspace.didCloseWindow()
            window.contentViewController = nil
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        try await settle(window)
        workspace.session.selectedFolder = "Notes"
        workspace.selectDocuments(["Notes/\(document).md"])
        await workspace.waitForNavigation()
        try await settle(window)
        return Library(root: root, workspace: workspace, window: window)
    }

    private func settle(_ window: NSWindow, _ rounds: Int = 4) async throws {
        for _ in 0..<rounds {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    /// Makes `window` key, as clicking it would: the previous key window resigns first.
    private func makeKey(_ window: KeyedTestWindow, others: [KeyedTestWindow]) {
        for other in others where other.key {
            other.key = false
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: other)
        }
        window.key = true
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
    }

    private func bareWindow() -> KeyedTestWindow {
        let window = KeyedTestWindow()
        window.isReleasedWhenClosed = false
        window.key = false
        return window
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func focusList(_ library: Library) throws {
        let list = try XCTUnwrap(
            Self.descendants(library.window.contentView!).compactMap { $0 as? DocumentTableView }.first)
        XCTAssertTrue(library.window.makeFirstResponder(list))
        library.workspace.focusColumn = 1
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

    func testFileCommandsMutateOnlyTheKeyLibraryWindow() async throws {
        let registry = makeRegistry()
        let a = try await library("A", document: "Alpha", in: registry)
        let b = try await library("B", document: "Beta", in: registry)
        XCTAssertFalse(a.workspace === b.workspace)
        try focusList(a)
        try focusList(b)
        let (aFiles, bFiles) = (markdownFiles(a.root), markdownFiles(b.root))

        // A key: the commands' target is A; B's selection is no Rename/Move/Trash target.
        makeKey(a.window, others: [b.window])
        XCTAssertTrue(registry.target === a.workspace)
        a.workspace.menuState.refresh()
        b.workspace.menuState.refresh()
        XCTAssertTrue(registry.target.menuState.value.canTrash)
        XCTAssertTrue(registry.target.menuState.value.canRename)
        XCTAssertTrue(registry.target.menuState.value.canMove)
        XCTAssertEqual(registry.target.menuState.value.trashTitle, "Move “Alpha” to Trash")
        XCTAssertFalse(b.workspace.canTrashSelection, "B's list behind A is not a Trash target")
        XCTAssertFalse(b.workspace.menuState.value.canRename)
        registry.target.create(folder: false)
        try await waitIdle(a.workspace)
        XCTAssertEqual(markdownFiles(a.root).count, aFiles.count + 1, "New Document lands in A")
        XCTAssertEqual(markdownFiles(b.root), bFiles, "New Document with A key wrote into B")
        try focusList(a)
        registry.target.requestMove()
        XCTAssertNotNil(a.workspace.moveRequest)
        XCTAssertNil(b.workspace.moveRequest)
        a.workspace.moveRequest = nil
        // The menu-bar paths of B no-op while A is key.
        b.workspace.requestTrash()
        b.workspace.requestMove()
        b.workspace.beginRename()
        try await settle(b.window, 2)
        XCTAssertNil(b.workspace.trashPlan)
        XCTAssertNil(b.workspace.moveRequest)
        XCTAssertNil(b.workspace.rename)
        XCTAssertFalse(b.workspace.mutating)

        // B key: everything follows B, and A is left alone.
        try focusList(b)
        makeKey(b.window, others: [a.window])
        XCTAssertTrue(registry.target === b.workspace)
        b.workspace.menuState.refresh()
        XCTAssertEqual(registry.target.menuState.value.trashTitle, "Move “Beta” to Trash")
        XCTAssertFalse(a.workspace.canTrashSelection)
        let aAfter = markdownFiles(a.root)
        registry.target.create(folder: false)
        try await waitIdle(b.workspace)
        XCTAssertEqual(markdownFiles(b.root).count, bFiles.count + 1, "New Document lands in B")
        XCTAssertEqual(markdownFiles(a.root), aAfter, "New Document with B key wrote into A")
        try focusList(b)
        registry.target.requestMove()
        XCTAssertNotNil(b.workspace.moveRequest)
        XCTAssertNil(a.workspace.moveRequest)
        b.workspace.moveRequest = nil
    }

    /// Tab items and Save follow the key library window; with Settings key the last-active window stays the
    /// library-wide target, but its tab items are off and ⌘W closes Settings.
    func testTabCommandsFollowTheKeyLibraryWindowNotSettings() async throws {
        let registry = makeRegistry()
        let a = try await library("A", document: "Alpha", in: registry)
        let b = try await library("B", document: "Beta", in: registry)
        let settings = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        settings.isReleasedWhenClosed = false
        settings.key = false
        defer { settings.close() }
        XCTAssertEqual(a.workspace.tabs.count, 1)
        XCTAssertEqual(b.workspace.tabs.count, 1)

        makeKey(a.window, others: [b.window, settings])
        XCTAssertTrue(registry.target === a.workspace)
        XCTAssertTrue(a.workspace.menuState.libraryKey)
        XCTAssertFalse(b.workspace.menuState.libraryKey)

        // Settings in front: A is still the last-active target, but no library window is key.
        makeKey(settings, others: [a.window, b.window])
        XCTAssertTrue(registry.target === a.workspace, "Settings is not a library window")
        XCTAssertFalse(registry.target.menuState.libraryKey, "Close Tab, Save and tab items are off")
        var closedFront = false
        registry.target.performCloseCommand { closedFront = true }
        XCTAssertTrue(closedFront, "⌘W closes Settings")
        XCTAssertEqual(a.workspace.tabs.count, 1)
        XCTAssertEqual(b.workspace.tabs.count, 1)

        // B key: ⌘W closes B's tab only.
        makeKey(b.window, others: [a.window, settings])
        XCTAssertTrue(registry.target === b.workspace)
        XCTAssertTrue(b.workspace.menuState.libraryKey)
        XCTAssertFalse(a.workspace.menuState.libraryKey)
        closedFront = false
        registry.target.performCloseCommand { closedFront = true }
        for _ in 0..<100 where !b.workspace.tabs.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(closedFront)
        XCTAssertTrue(b.workspace.tabs.isEmpty)
        XCTAssertEqual(a.workspace.tabs.count, 1, "⌘W in B closed A's tab")

        // Settings again: the last-active window is now B.
        makeKey(settings, others: [a.window, b.window])
        XCTAssertTrue(registry.target === b.workspace)
    }

    /// Both editors stay first responder in their own windows. Coming back to A must point Format at A's editor,
    /// not leave it on B's (no `becomeFirstResponder` happens on a window switch).
    func testFormatFollowsTheKeyLibraryWindowsEditor() async throws {
        let registry = makeRegistry()
        let a = try await library("A", document: "Alpha", in: registry)
        let b = try await library("B", document: "Beta", in: registry)
        let target = FormattingTarget.shared
        let editorA = try XCTUnwrap(a.workspace.preview.editor)
        let editorB = try XCTUnwrap(b.workspace.preview.editor)
        XCTAssertFalse(editorA === editorB)

        makeKey(a.window, others: [b.window])
        XCTAssertTrue(a.window.makeFirstResponder(editorA))
        target.refresh()
        XCTAssertTrue(target.enabled)
        makeKey(b.window, others: [a.window])
        XCTAssertTrue(b.window.makeFirstResponder(editorB))
        target.refresh()
        XCTAssertTrue(target.editor === editorB)

        // Back to A by clicking its title bar: A's editor never re-becomes first responder.
        makeKey(a.window, others: [b.window])
        XCTAssertTrue(a.window.firstResponder === editorA)
        XCTAssertTrue(target.enabled, "Format stayed on B's editor behind A")
        let (beforeA, beforeB) = (editorA.string, editorB.string)
        editorA.setSelectedRange(NSRange(location: 2, length: 5))
        target.perform { $0.format(.bold) }
        XCTAssertNotEqual(editorA.string, beforeA, "⌘B did nothing in the key window")
        XCTAssertEqual(editorB.string, beforeB, "⌘B reached the background window's document")
    }

    /// Quit flushes every open workspace, not just the first window's.
    func testQuitSavesEveryOpenWorkspace() async throws {
        let registry = makeRegistry()
        let a = try await library("A", document: "Alpha", in: registry)
        let b = try await library("B", document: "Beta", in: registry)
        makeKey(a.window, others: [b.window])
        a.workspace.editor.edit("# Alpha\n\nEdited in A.\n")
        b.workspace.editor.edit("# Beta\n\nEdited in B.\n")
        XCTAssertTrue(a.workspace.editor.state.isDirty)
        XCTAssertTrue(b.workspace.editor.state.isDirty)
        let quit = await registry.prepareToQuit()
        XCTAssertTrue(quit)
        XCTAssertEqual(
            try String(contentsOf: a.root.appendingPathComponent("Notes/Alpha.md"), encoding: .utf8),
            "# Alpha\n\nEdited in A.\n")
        XCTAssertEqual(
            try String(contentsOf: b.root.appendingPathComponent("Notes/Beta.md"), encoding: .utf8),
            "# Beta\n\nEdited in B.\n", "the second window's unsaved text was not saved on Quit")
    }

    /// Window by window, the key (last-active) one first; a refusal stops the quit before the next window.
    func testQuitAsksKeyWindowFirstAndCancelStops() async throws {
        let registry = makeRegistry()
        let a = registry.adopt()
        let b = registry.adopt()
        let (windowA, windowB) = (bareWindow(), bareWindow())
        defer { windowA.close(); windowB.close() }
        registry.register(a, window: windowA)
        registry.register(b, window: windowB)
        makeKey(windowB, others: [windowA])

        var asked: [ObjectIdentifier] = []
        let permitted = await registry.prepareToQuit { workspace in
            asked.append(ObjectIdentifier(workspace))
            return false
        }
        XCTAssertFalse(permitted)
        XCTAssertEqual(asked, [ObjectIdentifier(b)], "Cancel in the first window must stop the quit")

        makeKey(windowA, others: [windowB])
        asked = []
        let all = await registry.prepareToQuit { workspace in
            asked.append(ObjectIdentifier(workspace))
            return true
        }
        XCTAssertTrue(all)
        XCTAssertEqual(asked, [ObjectIdentifier(a), ObjectIdentifier(b)])
    }

    /// The first window keeps the legacy column autosave name; later windows get their own.
    func testColumnAutosaveNamesArePerWindow() async throws {
        XCTAssertEqual(
            AppDefaults.windowColumnAutosaveName(base: "Silkweb.LibraryColumns", slot: 0), "Silkweb.LibraryColumns")
        XCTAssertEqual(
            AppDefaults.windowColumnAutosaveName(base: "Silkweb.LibraryColumns", slot: 1),
            "Silkweb.LibraryColumns.Window2")
        XCTAssertNil(AppDefaults.windowColumnAutosaveName(base: nil, slot: 3))

        let base = disposableAutosaveName("MultiWindowColumns")
        let registry = makeRegistry(autosaveBase: base)
        let a = registry.adopt()
        let b = registry.adopt()
        XCTAssertEqual(a.columnAutosaveName, base)
        XCTAssertEqual(b.columnAutosaveName, base + ".Window2")

        // Real split views on the two names save their own widths.
        func columns(_ workspace: LibraryWorkspace, sidebar: CGFloat) async throws -> (
            LibrarySplitViewController, NSWindow
        ) {
            let controller = LibrarySplitViewController(
                workspace: workspace, autosaveName: workspace.columnAutosaveName)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable],
                backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
            controller.view.layoutSubtreeIfNeeded()
            controller.navigationController.splitView.setPosition(sidebar, ofDividerAt: 0)
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            return (controller, window)
        }
        let (columnsA, windowA) = try await columns(a, sidebar: 190)
        let (columnsB, windowB) = try await columns(b, sidebar: 300)
        defer {
            for window in [windowA, windowB] { window.contentViewController = nil; window.close() }
        }
        let frames = { (name: String) in UserDefaults.standard.array(forKey: "NSSplitView Subview Frames \(name)") }
        let savedA = try XCTUnwrap(frames(base + ".Navigation"), "A saved its sidebar width")
        let savedB = try XCTUnwrap(frames(base + ".Window2.Navigation"), "B saved its sidebar width")
        XCTAssertNotEqual(savedA as? [String], savedB as? [String])
        XCTAssertEqual(columnsA.sidebarItem.viewController.view.frame.width, 190, accuracy: 1)
        XCTAssertEqual(columnsB.sidebarItem.viewController.view.frame.width, 300, accuracy: 1)
    }

    /// Closing one of two windows drops only that workspace; closing the last keeps it for the next window, as a
    /// Dock click reopened the single window before. Slots are reused; lookup is by canonical Library path.
    func testRegistryLifecycleAndLookup() async throws {
        let registry = makeRegistry()
        let launch = registry.target
        let a = registry.adopt()
        XCTAssertTrue(a === launch, "the first window adopts the launch workspace")
        XCTAssertTrue(a.restoresLastLibrary)
        let b = registry.adopt()
        XCTAssertFalse(b.restoresLastLibrary, "only one window restores the last-opened Library")
        XCTAssertEqual(registry.slot(of: a), 0)
        XCTAssertEqual(registry.slot(of: b), 1)
        let (windowA, windowB) = (bareWindow(), bareWindow())
        defer { windowA.close(); windowB.close() }
        registry.register(a, window: windowA)
        registry.register(b, window: windowB)
        XCTAssertTrue(registry.target === a)
        XCTAssertTrue(a.libraryWindow === windowA)

        let root = URL(fileURLWithPath: "/tmp/SilkwebLookup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        b.root = root
        XCTAssertTrue(registry.workspace(for: URL(fileURLWithPath: "/private" + root.path)) === b)
        XCTAssertTrue(registry.workspace(for: root.appendingPathComponent("x/..")) === b)
        XCTAssertNil(registry.workspace(for: URL(fileURLWithPath: "/tmp/elsewhere")))

        makeKey(windowB, others: [windowA])
        XCTAssertTrue(registry.target === b)
        registry.close(b)
        XCTAssertTrue(registry.target === a, "closing B leaves A as the target")
        XCTAssertNil(registry.slot(of: b))
        XCTAssertNil(registry.workspace(for: root))
        let c = registry.adopt()
        XCTAssertFalse(c === b, "a closed second window's workspace is gone")
        XCTAssertEqual(registry.slot(of: c), 1, "its column slot is reused")

        registry.close(a)
        XCTAssertTrue(registry.workspaces.isEmpty)
        XCTAssertTrue(registry.target === a, "the last closed window's Library stays the target")
        XCTAssertTrue(registry.adopt() === a, "the next window reopens it")
    }
}

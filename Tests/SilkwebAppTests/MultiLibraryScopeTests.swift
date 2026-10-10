import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #197: with several Library sections in one window, the tab strip spans Libraries and names each tab's Library,
/// Search Library and Quick Open search the current Library unless All Libraries is chosen, per-Library state stays
/// with its Library, and a collapsed section builds no folder tree until it expands.
@MainActor
final class MultiLibraryScopeTests: XCTestCase {
    private var cleanUps: [@MainActor () async -> Void] = []
    private var temporary: URL!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebMultiScope-" + UUID().uuidString)
    }

    override func tearDown() async throws {
        for cleanUp in cleanUps.reversed() { await cleanUp() }
        cleanUps = []
        try? FileManager.default.removeItem(at: temporary)
        try await super.tearDown()
    }

    /// A Library with `Notes/<name>.md` for each document; every body mentions “kiwi”.
    private func library(_ name: String, _ documents: [String]) throws -> URL {
        let root = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        for document in documents {
            try Data("# \(document)\n\nA kiwi from \(name).\n".utf8).write(
                to: root.appendingPathComponent("Notes/\(document).md"))
        }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func registry(_ defaults: UserDefaults? = nil) -> LibraryWindowRegistry {
        let defaults = defaults ?? disposableDefaults("MultiScope")
        let recovery = temporary.appendingPathComponent(".recovery")
        let registry = LibraryWindowRegistry(defaults: defaults) {
            let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: nil)
            workspace.canSaveWindowSession = false
            workspace.recoveryDirectory = recovery
            return workspace
        }
        registry.presentAlert = { _, _ in
            XCTFail("unexpected alert"); return false
        }
        return registry
    }

    /// The real library window, never ordered on screen.
    private func window(_ registry: LibraryWindowRegistry) -> KeyedTestWindow {
        let window = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: LibraryWindow(registry: registry))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        cleanUps.append { @MainActor in
            for workspace in registry.workspaces { await workspace.releaseLibrary() }
            window.contentViewController = nil
            window.close()
        }
        return window
    }

    /// Alpha (`Notes/Apple.md`, `Notes/Avocado.md`) and Beta (`Notes/Banana.md`), each with one document open;
    /// Beta is current.
    private func twoLibraries() async throws -> (
        LibraryWindowRegistry, KeyedTestWindow, LibraryWorkspace,
        LibraryWorkspace
    ) {
        let registry = registry()
        let window = window(registry)
        var opened: [LibraryWorkspace] = []
        for (name, documents) in [("Alpha", ["Apple", "Avocado"]), ("Beta", ["Banana"])] {
            let added = await registry.add(try library(name, documents))
            let workspace = try XCTUnwrap(added)
            try await settle(window)
            workspace.navigate(folder: "Notes", documents: ["Notes/\(documents[0]).md"])
            await workspace.waitForNavigation()
            await workspace.search.waitForIndex()
            opened.append(workspace)
        }
        try await settle(window)
        return (registry, window, opened[0], opened[1])
    }

    private func settle(_ window: NSWindow, _ rounds: Int = 3) async throws {
        for _ in 0..<rounds {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func tabBar(_ window: NSWindow) throws -> EditorTabBarView {
        try XCTUnwrap(Self.descendants(window.contentView!).compactMap { $0 as? EditorTabBarView }.first)
    }

    // MARK: Tabs

    func testTheStripListsEveryLibrarysTabsAndNamesTheirLibrary() async throws {
        let (registry, window, a, b) = try await twoLibraries()
        var bar = try tabBar(window)
        XCTAssertEqual(bar.buttons.map(\.tab.editor.name), ["Apple", "Banana"], "one strip, in opening order")
        XCTAssertEqual(bar.buttons.map { $0.library.stringValue }, [" · Alpha", " · Beta"])
        XCTAssertFalse(bar.buttons.contains { $0.library.isHidden })
        XCTAssertEqual(bar.buttons.map(\.isActive), [false, true], "only the current Library's tab is active")
        XCTAssertEqual(bar.buttons[0].accessibilityLabel(), "Apple, preview, in Alpha")
        XCTAssertEqual(bar.buttons[0].toolTip?.hasSuffix(", in Alpha"), true)
        XCTAssertEqual(bar.buttons[1].menuTitle, "Banana · Beta")
        // The suffix sits after the title and inside the tab, at every tab width.
        for size in [NSSize(width: 900, height: 560), NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            try await settle(window, 2)
            bar = try tabBar(window)
            for button in bar.buttons {
                button.layoutSubtreeIfNeeded()
                let title = try XCTUnwrap(
                    button.subviews.compactMap { $0 as? NSTextField }.first { $0 !== button.library })
                XCTAssertGreaterThanOrEqual(button.library.frame.minX, title.frame.maxX)
                XCTAssertLessThanOrEqual(button.library.frame.maxX, button.bounds.maxX)
                XCTAssertGreaterThan(title.frame.width, 0)
            }
        }

        // A click on Alpha's tab makes Alpha current; the editor and the status bar follow.
        bar.buttons[0].mouseDown(with: try mouseEvent(window))
        try await settle(window)
        XCTAssertTrue(registry.current === a)
        XCTAssertEqual(a.editor.url?.lastPathComponent, "Apple.md")
        XCTAssertEqual(a.breadcrumb.crumbs.first?.title, "Alpha")
        bar = try tabBar(window)
        XCTAssertEqual(bar.buttons.map(\.isActive), [true, false])
        XCTAssertEqual(b.activeTabID, b.tabs.first?.id, "Beta keeps its own active tab")

        // One Library's tabs only: the strip looks as it did before sections.
        _ = await b.closeTab(try XCTUnwrap(b.tabs.first).id)
        try await settle(window)
        bar = try tabBar(window)
        XCTAssertEqual(bar.buttons.map(\.tab.editor.name), ["Apple"])
        XCTAssertTrue(bar.buttons[0].library.isHidden)
        XCTAssertEqual(bar.buttons[0].accessibilityLabel(), "Apple, preview")
    }

    func testTheStripShowsWhileTheCurrentLibraryHasNoTab() async throws {
        let (registry, window, a, b) = try await twoLibraries()
        _ = await b.closeTab(try XCTUnwrap(b.tabs.first).id)
        try await settle(window)
        XCTAssertTrue(registry.current === b)
        XCTAssertTrue(b.tabs.isEmpty)
        let bar = try tabBar(window)
        XCTAssertEqual(bar.buttons.map(\.tab.editor.name), ["Apple"])
        XCTAssertFalse(bar.buttons[0].isActive)
        XCTAssertTrue(bar.buttons[0].library.isHidden, "one Library's tabs: no suffix")
        // Show Next Tab reaches Alpha's tab from an empty Beta.
        registry.cycleTab(1)
        try await settle(window)
        XCTAssertTrue(registry.current === a)
    }

    func testShowNextTabAndMoveTabCrossLibraries() async throws {
        let (registry, window, a, b) = try await twoLibraries()
        // A second Alpha tab opens next to Alpha's first, before Beta's.
        registry.activate(try XCTUnwrap(registry.stripTabs.first))
        a.openSelectionInNewTab("Notes/Avocado.md")
        await a.waitForNavigation()
        try await settle(window)
        func names() -> [String] { registry.stripTabs.map(\.tab.editor.name) }
        XCTAssertEqual(names(), ["Apple", "Avocado", "Banana"])
        XCTAssertTrue(registry.current === a)

        registry.cycleTab(1)
        XCTAssertTrue(registry.current === b, "Show Next Tab crosses into Beta")
        registry.cycleTab(1)
        XCTAssertTrue(registry.current === a, "and wraps back to Alpha")
        XCTAssertEqual(a.editor.name, "Apple")
        registry.cycleTab(-1)
        XCTAssertTrue(registry.current === b)
        XCTAssertEqual(b.editor.name, "Banana")

        // Move Tab Left: Banana between Alpha's tabs; each Library keeps its own order.
        registry.moveActiveTab(-1)
        XCTAssertEqual(names(), ["Apple", "Banana", "Avocado"])
        XCTAssertEqual(a.tabs.map(\.editor.name), ["Apple", "Avocado"])
        // A reorder inside Alpha (its own Move Tab) shows in Alpha's slots.
        registry.activate(try XCTUnwrap(registry.stripTabs.first))
        registry.moveActiveTab(1)
        XCTAssertEqual(names(), ["Banana", "Apple", "Avocado"])
        a.reorderTab(try XCTUnwrap(a.tabs.last).id, to: 0)
        XCTAssertEqual(names(), ["Banana", "Avocado", "Apple"])

        // Close Other Tabs closes every other Library's tabs too.
        let banana = try XCTUnwrap(registry.stripTabs.first)
        await registry.closeTabs(otherThan: banana)
        XCTAssertEqual(names(), ["Banana"])
        XCTAssertTrue(a.tabs.isEmpty)
    }

    func testClosingTheWindowBringsBackEveryLibrarysTabs() async throws {
        let (registry, window, a, b) = try await twoLibraries()
        XCTAssertEqual(registry.stripTabs.count, 2)
        await registry.windowClosed()
        XCTAssertTrue(registry.stripTabs.isEmpty)
        let reopened = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered,
            defer: false)
        reopened.isReleasedWhenClosed = false
        registry.register(window: reopened)
        await b.resumeEditor() // The window's own launch task does this for the current Library.
        try await waitUntil("Alpha's tab comes back with the window") { !a.tabs.isEmpty }
        XCTAssertEqual(registry.stripTabs.map(\.tab.editor.name).sorted(), ["Apple", "Banana"])
        _ = window
    }

    private func mouseEvent(_ window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    // MARK: Search scope

    func testSearchLibraryDefaultsToTheCurrentLibraryWithAnAllLibrariesSegment() async throws {
        let (_, _, a, b) = try await twoLibraries()
        let search = a.search
        search.text = "kiwi"
        await search.query(quick: false, debounce: false)
        XCTAssertEqual(Set(a.filteredSearchResults.map(\.displayName)), ["Apple", "Avocado"], "no Beta rows")
        XCTAssertTrue(a.filteredSearchResults.allSatisfy { $0.folderPathComponents == ["Notes"] })

        search.allLibraries = true
        XCTAssertTrue(search.hasPendingQuery)
        await search.query(quick: false, debounce: false)
        let rows = a.filteredSearchResults
        XCTAssertEqual(rows.map(\.displayName).sorted(), ["Apple", "Avocado", "Banana"])
        XCTAssertEqual(rows.last?.displayName, "Banana", "the current Library's rows come first")
        XCTAssertEqual(rows.last?.folderPathComponents, ["Beta", "Notes"])
        XCTAssertEqual(rows.first?.folderPathComponents, ["Alpha", "Notes"])
        let banana = try XCTUnwrap(rows.last)
        XCTAssertNotEqual(banana.id, b.snapshot?.documents.first?.id, "another Library's row has its own id")

        // Beta's own search is untouched.
        XCTAssertEqual(b.search.text, "")
        XCTAssertTrue(b.search.results.isEmpty)

        // Opening Beta's row makes Beta current and opens the document there.
        await a.openSearchResult(banana, findText: "kiwi")
        XCTAssertTrue(a.shell?.current === b)
        XCTAssertEqual(b.editor.url?.lastPathComponent, "Banana.md")
        XCTAssertEqual(a.search.text, "", "Alpha's search ends as an open does")

        // A new search starts in the current Library again (the view resets the segment on new text).
        b.search.text = "kiwi"
        await b.search.query(quick: false, debounce: false)
        XCTAssertEqual(b.filteredSearchResults.map(\.displayName), ["Banana"])
    }

    func testAllLibrariesIsOffWithOneLibrary() async throws {
        let registry = registry()
        let window = window(registry)
        let added = await registry.add(try library("Alpha", ["Apple"]))
        let a = try XCTUnwrap(added)
        try await settle(window)
        await a.search.waitForIndex()
        // The window's Search Library field scopes a new search to the selected folder first.
        a.search.text = "kiwi"
        try await settle(window)
        a.search.allLibraries = true
        XCTAssertFalse(a.search.searchesAllLibraries)
        XCTAssertEqual(a.search.searchScope, a.search.folderScope, "the folder scope still applies")
        await a.search.query(quick: false, debounce: false)
        try await waitUntil("the search settles") { !a.search.hasPendingQuery }
        XCTAssertEqual(a.filteredSearchResults.map(\.folderPathComponents), [["Notes"]], "no Library prefix")
    }

    func testQuickOpenDefaultsToTheCurrentLibraryWithAnAllLibrariesToggle() async throws {
        let (registry, window, a, b) = try await twoLibraries()
        registry.focus(a)
        try await settle(window)
        let search = a.search
        search.toggleQuickOpen()
        search.quickText = "Banana"
        await search.query(quick: true, debounce: false)
        XCTAssertTrue(search.quickResults.isEmpty, "Quick Open searches only the current Library by default")

        search.quickAllLibraries = true
        await search.query(quick: true, debounce: false)
        let banana = try XCTUnwrap(search.quickResults.first)
        XCTAssertEqual(search.quickResults.count, 1)
        XCTAssertEqual(banana.folderPathComponents, ["Beta", "Notes"])

        // Return opens it in Beta; Quick Open closes in Alpha so it doesn't come back with it.
        await a.openSearchSelection(banana.id, quick: true)
        XCTAssertTrue(registry.current === b)
        XCTAssertEqual(b.editor.url?.lastPathComponent, "Banana.md")
        XCTAssertFalse(search.showsQuickOpen)

        // The toggle is off again the next time Quick Open opens.
        search.toggleQuickOpen()
        XCTAssertFalse(search.quickAllLibraries)
        search.dismissQuickOpen(restoreFocus: false)
    }

    func testQuickOpenRecentsStayWithTheirLibrary() async throws {
        let (_, _, a, b) = try await twoLibraries()
        a.search.quickText = ""
        await a.search.query(quick: true, debounce: false)
        b.search.quickText = ""
        await b.search.query(quick: true, debounce: false)
        XCTAssertEqual(a.search.quickResults.map(\.displayName), ["Apple"])
        XCTAssertEqual(b.search.quickResults.map(\.displayName), ["Banana"])
        // With All Libraries, recents from every Library, the current one's first.
        a.search.quickAllLibraries = true
        await a.search.query(quick: true, debounce: false)
        XCTAssertEqual(a.search.quickResults.map(\.displayName), ["Apple", "Banana"])
    }

    func testInterleaveTakesEachListInTurn() {
        XCTAssertEqual(LibrarySearch.interleave([[1, 2, 3], [10], [20, 21]], limit: 12), [1, 10, 20, 2, 21, 3])
        XCTAssertEqual(LibrarySearch.interleave([[1, 2, 3], [10], [20, 21]], limit: 4), [1, 10, 20, 2])
        XCTAssertEqual(LibrarySearch.interleave([[Int](), []], limit: 12), [])
    }

    // MARK: Per-Library state

    func testAgentFilterMoveRecentsZoomAndSearchStayWithTheirLibrary() async throws {
        let (registry, window, a, b) = try await twoLibraries()
        registry.focus(a)
        a.agentFilter = "Claude"
        a.recentMoveFolders = ["Notes"]
        a.zoomEditor(by: 2)
        a.search.text = "kiwi"
        a.preview.mode = .split
        registry.focus(b)
        try await settle(window)
        XCTAssertNil(b.agentFilter)
        XCTAssertTrue(b.recentMoveFolders.isEmpty)
        XCTAssertEqual(b.editorZoom, 0)
        XCTAssertEqual(b.search.text, "")
        XCTAssertEqual(b.preview.mode, .editor)
        b.agentFilter = "Codex"
        b.zoomEditor(by: -1)
        registry.focus(a)
        try await settle(window)
        XCTAssertEqual(a.agentFilter, "Claude", "switching Libraries keeps each Library's Agent filter")
        XCTAssertEqual(a.recentMoveFolders, ["Notes"])
        XCTAssertEqual(a.editorZoom, 2)
        XCTAssertEqual(a.search.text, "kiwi")
        XCTAssertEqual(b.agentFilter, "Codex")
        XCTAssertEqual(b.editorZoom, -1)
        // The editors on screen use their own Library's zoom.
        XCTAssertEqual(a.preview.editor?.zoom, 2)
    }

    // MARK: Collapsed sections

    func testACollapsedSectionBuildsItsFolderTreeOnlyWhenExpanded() async throws {
        let defaults = disposableDefaults("MultiScopeLazy")
        let alpha = try library("Alpha", ["Apple"])
        let beta = try library("Beta", ["Banana"])
        let session = AppSession(
            sections: [
                .init(location: LibraryLocation.saving(alpha)),
                .init(location: LibraryLocation.saving(beta), collapsed: true),
            ],
            currentPath: alpha.path)
        defaults.set(try JSONEncoder().encode(session), forKey: LibraryWindowRegistry.sessionKey)
        let registry = registry(defaults)
        let window = window(registry)
        try await waitUntil("both sections load") {
            registry.sections.count == 2 && registry.sections.allSatisfy { $0.snapshot != nil && !$0.loading }
        }
        try await settle(window)
        let outline = try XCTUnwrap(
            Self.descendants(window.contentView!).compactMap { $0 as? SidebarOutlineView }.first)
        let sections = try XCTUnwrap(outline.delegate as? SidebarSections)
        XCTAssertEqual(sections.headers.map(\.title), ["Alpha", "Beta"])
        XCTAssertNotNil(sections.headers[0].coordinator)
        XCTAssertNil(sections.headers[1].coordinator, "a collapsed section draws only its header")
        XCTAssertTrue(registry.current.root == alpha)
        let rows = outline.numberOfRows

        // The chevron expands it: its rows appear under its header, and Alpha keeps the selection.
        outline.expandItem(sections.headers[1])
        try await waitUntil("Beta's tree is built") { sections.headers[1].coordinator != nil }
        try await settle(window)
        XCTAssertGreaterThan(outline.numberOfRows, rows)
        let titles = (0..<outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? FolderSidebar.Item)?.title }
        XCTAssertEqual(titles.filter { $0 == "Notes" }.count, 2)
        XCTAssertTrue(registry.current.root == alpha)
        XCTAssertFalse(registry.sections[1].sectionCollapsed)
    }
}

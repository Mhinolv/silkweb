import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #196: relaunch restores every open Library section (order, collapse state, the current Library) and each
/// Library's tabs from its own `WindowSessionMetadata`; a missing Library keeps its section.
@MainActor
final class SessionRestoreTests: XCTestCase {
    private var cleanUps: [@MainActor () async -> Void] = []
    private var temporary: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebRestore-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defaults = disposableDefaults("Restore")
        let live = LivePreferences.shared.current
        LivePreferences.shared.current.reopensSession = true
        cleanUps.append { @MainActor in LivePreferences.shared.current = live }
    }

    override func tearDown() async throws {
        for cleanUp in cleanUps.reversed() { await cleanUp() }
        cleanUps = []
        try? FileManager.default.removeItem(at: temporary)
        try await super.tearDown()
    }

    /// One launch of the app: a fresh registry on the same preferences.
    private func launch() -> LibraryWindowRegistry {
        let defaults = defaults!
        let recovery = temporary.appendingPathComponent(".recovery")
        let registry = LibraryWindowRegistry(defaults: defaults) {
            let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: nil)
            workspace.recoveryDirectory = recovery
            return workspace
        }
        registry.presentAlert = { _, _ in
            XCTFail("unexpected alert"); return false
        }
        cleanUps.append { @MainActor in
            for workspace in registry.workspaces { await workspace.releaseLibrary() }
        }
        return registry
    }

    /// Launch, restore and wait until every section has loaded or failed.
    private func relaunch(reopensSession: Bool = true) async -> LibraryWindowRegistry {
        LivePreferences.shared.current.reopensSession = reopensSession
        let registry = launch()
        await registry.restoreSession(reopensSession: reopensSession).value
        return registry
    }

    /// Quit: the real per-Library flush (no unsaved text, so no alert), then the Libraries close.
    private func quit(_ registry: LibraryWindowRegistry) async {
        let permitted = await registry.prepareToQuit()
        XCTAssertTrue(permitted)
        for workspace in registry.workspaces { await workspace.releaseLibrary() }
    }

    /// A Library folder with `Notes/One.md` and `Notes/Two.md`.
    private func library(_ name: String) throws -> URL {
        let root = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        for document in ["One", "Two"] {
            try Data("# \(name) \(document)\n\nBody.\n".utf8).write(
                to: root.appendingPathComponent("Notes/\(document).md"))
        }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func open(_ workspace: LibraryWorkspace, _ paths: [String]) async {
        for path in paths {
            workspace.navigate(folder: "Notes", documents: [path], pinned: true)
            await workspace.waitForNavigation()
        }
    }

    private func added(_ registry: LibraryWindowRegistry, _ url: URL) async throws -> LibraryWorkspace {
        let workspace = await registry.add(url)
        return try XCTUnwrap(workspace)
    }

    private func roots(_ registry: LibraryWindowRegistry) -> [String] {
        registry.sections.compactMap { $0.root?.lastPathComponent }
    }

    private func tabs(_ workspace: LibraryWorkspace) -> [String] {
        workspace.tabs.compactMap { $0.editor.url?.lastPathComponent }
    }

    private var saved: AppSession? {
        defaults.data(forKey: LibraryWindowRegistry.sessionKey).flatMap {
            try? JSONDecoder().decode(AppSession.self, from: $0)
        }
    }

    /// Quit with Alpha and Beta open and the current Library's tabs saved; returns their roots.
    private func quitWithTwoSections() async throws -> (alpha: URL, beta: URL) {
        let a = try library("Alpha")
        let b = try library("Beta")
        let registry = await relaunch()
        let alpha = try await added(registry, a)
        await open(alpha, ["Notes/One.md", "Notes/Two.md"])
        let beta = try await added(registry, b)
        await open(beta, ["Notes/Two.md"])
        registry.focus(alpha)
        beta.sectionCollapsed = true
        alpha.focusColumn = 1
        await quit(registry)
        return (a, b)
    }

    // MARK: Relaunch

    func testRelaunchRestoresBothSectionsWithTheirTabsAndTheCurrentLibrary() async throws {
        let (a, b) = try await quitWithTwoSections()
        XCTAssertEqual(saved?.sections.map(\.path), [a.path, b.path])
        XCTAssertEqual(saved?.sections.map(\.collapsed), [false, true])
        XCTAssertEqual(saved?.currentPath, a.path)

        let registry = await relaunch()
        XCTAssertEqual(roots(registry), ["Alpha", "Beta"], "both sections, in their order")
        let alpha = try XCTUnwrap(registry.workspace(for: a))
        let beta = try XCTUnwrap(registry.workspace(for: b))
        XCTAssertTrue(registry.current === alpha, "the Library that was current at quit")
        XCTAssertFalse(alpha.sectionCollapsed)
        XCTAssertTrue(beta.sectionCollapsed, "collapse state")
        XCTAssertNotNil(alpha.snapshot)
        XCTAssertNotNil(beta.snapshot)
        XCTAssertEqual(tabs(alpha), ["One.md", "Two.md"], "Alpha's tabs from its WindowSessionMetadata")
        XCTAssertEqual(alpha.editor.url?.lastPathComponent, "Two.md", "and its active tab")
        XCTAssertEqual(tabs(beta), ["Two.md"], "Beta's tabs from its own WindowSessionMetadata")
        XCTAssertEqual(alpha.session.selectedFolder, "Notes", "Alpha's remembered scope")
        XCTAssertEqual(alpha.focusColumn, 1, "keyboard focus returns to the list")
        XCTAssertEqual(registry.workspaces.count, 2, "no welcome workspace left over")
        XCTAssertEqual(saved?.sections.map(\.path), [a.path, b.path], "relaunch saves the same sections")
    }

    func testReopenOffRestoresOnlyTheLastCurrentLibraryWithoutTabs() async throws {
        let (a, _) = try await quitWithTwoSections()
        let registry = await relaunch(reopensSession: false)
        XCTAssertEqual(roots(registry), ["Alpha"], "owner decision: the last current Library only")
        XCTAssertTrue(registry.current.root == a)
        // No tab strip comes back; as before #196, the Library's selected document opens on its own.
        XCTAssertEqual(tabs(registry.current), ["Two.md"], "not the saved strip One, Two")
        XCTAssertFalse(registry.current.sectionCollapsed)

        // The session keeps being written: what's open now is saved, atomically, as one complete value.
        XCTAssertEqual(saved?.sections.map(\.path), [a.path])
        XCTAssertNotNil(registry.current.snapshot)
    }

    func testLegacyLibraryLocationRestoresOneSectionAsBefore() async throws {
        let root = try library("Legacy")
        defaults.set(try JSONEncoder().encode(LibraryLocation.saving(root)), forKey: "libraryLocation")
        XCTAssertNil(defaults.data(forKey: LibraryWindowRegistry.sessionKey))
        let registry = await relaunch()
        let launch = registry.current
        _ = try await waitUntil("the legacy Library") { launch.snapshot != nil }
        await launch.waitForLoad()
        XCTAssertEqual(roots(registry), ["Legacy"])
        XCTAssertEqual(registry.workspaces.count, 1)
        XCTAssertEqual(saved?.sections.map(\.path), [root.path], "the app session is written from now on")

        // No Library at all: the welcome screen, and no session is invented.
        defaults.removeObject(forKey: "libraryLocation")
        defaults.removeObject(forKey: LibraryWindowRegistry.sessionKey)
        let empty = await relaunch()
        XCTAssertTrue(empty.sections.isEmpty)
        XCTAssertNil(empty.current.error)
        XCTAssertNil(defaults.data(forKey: LibraryWindowRegistry.sessionKey))
    }

    /// #194-era multi-window file. Mapping: windows front to back become sections, deduplicated by path; the key
    /// window's Library is current.
    func testMultiWindowSessionOpensAsOneWindowWithSections() async throws {
        let a = try library("Alpha")
        let b = try library("Beta")
        let json = """
            {"version":1,"windows":[{"libraryPath":"\(b.path)"},{"libraryPath":"\(a.path)","isKey":true},
            {"libraryPath":"\(b.path)/"}]}
            """
        defaults.set(Data(json.utf8), forKey: LibraryWindowRegistry.sessionKey)
        let registry = await relaunch()
        XCTAssertEqual(roots(registry), ["Beta", "Alpha"])
        XCTAssertEqual(registry.current.root, a)
        XCTAssertTrue(registry.sections.allSatisfy { $0.snapshot != nil })
        XCTAssertEqual(saved?.sections.map(\.path), [b.path, a.path], "rewritten in the current shape")
        XCTAssertNil(
            (try JSONSerialization.jsonObject(
                with: XCTUnwrap(defaults.data(forKey: LibraryWindowRegistry.sessionKey))) as? [String: Any])?[
                    "windows"])
    }

    func testCorruptSessionFallsBackToTheLegacyLibrary() async throws {
        let root = try library("Legacy")
        defaults.set(try JSONEncoder().encode(LibraryLocation.saving(root)), forKey: "libraryLocation")
        defaults.set(Data("{not json".utf8), forKey: LibraryWindowRegistry.sessionKey)
        let registry = await relaunch()
        _ = try await waitUntil("the legacy Library") { registry.current.snapshot != nil }
        await registry.current.waitForLoad()
        XCTAssertEqual(roots(registry), ["Legacy"])
        XCTAssertEqual(saved?.sections.map(\.path), [root.path], "a corrupt session is replaced")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Notes/One.md"), encoding: .utf8),
            "# Legacy One\n\nBody.\n", "nothing inside the Library changes")
    }

    func testNewerSessionIsNeverOverwritten() async throws {
        let root = try library("Legacy")
        defaults.set(try JSONEncoder().encode(LibraryLocation.saving(root)), forKey: "libraryLocation")
        let newer = Data(#"{"version":99,"sections":[{"location":{"path":"/Future"}}],"future":true}"#.utf8)
        defaults.set(newer, forKey: LibraryWindowRegistry.sessionKey)
        let registry = await relaunch()
        _ = try await waitUntil("the legacy Library") { registry.current.snapshot != nil }
        await registry.current.waitForLoad()
        XCTAssertEqual(roots(registry), ["Legacy"], "falls back to the legacy Library")
        // Opening, collapsing, closing and quitting all leave the newer file as it was.
        let other = try await added(registry, try library("Other"))
        other.sectionCollapsed = true
        _ = await registry.closeLibrary(other)
        await quit(registry)
        XCTAssertEqual(defaults.data(forKey: LibraryWindowRegistry.sessionKey), newer)
    }

    // MARK: Missing Libraries

    func testMissingLibraryKeepsItsSectionAndTheFirstAvailableBecomesCurrent() async throws {
        let (a, b) = try await quitWithTwoSections()
        // Beta was current at quit, then its folder went away.
        var session = try XCTUnwrap(saved)
        session.currentPath = b.path
        defaults.set(try JSONEncoder().encode(session), forKey: LibraryWindowRegistry.sessionKey)
        try FileManager.default.removeItem(at: b)

        let registry = await relaunch()
        XCTAssertEqual(roots(registry), ["Alpha", "Beta"], "the missing section is kept, never dropped")
        let alpha = try XCTUnwrap(registry.workspace(for: a))
        let beta = try XCTUnwrap(registry.sections.last)
        XCTAssertTrue(registry.current === alpha, "the first available section becomes current")
        XCTAssertNil(beta.snapshot)
        XCTAssertFalse(beta.loading)
        XCTAssertEqual(beta.errorTitle, "Library Not Found")
        XCTAssertEqual(beta.errorSymbol, "externaldrive.badge.questionmark")
        XCTAssertEqual(
            beta.error,
            "Silkweb can’t find “Beta”. It may have been moved, renamed, or be on a disconnected drive.")
        XCTAssertTrue(beta.sectionCollapsed, "its collapse state too")
        XCTAssertEqual(saved?.sections.map(\.path), [a.path, b.path], "and it stays saved for the next launch")
        XCTAssertEqual(saved?.sections.last?.location.bookmark, session.sections.last?.location.bookmark)

        // Locate… replaces it in place.
        let found = try library("Beta Found")
        registry.replace(beta, with: found)
        await beta.waitForLoad()
        XCTAssertEqual(roots(registry), ["Alpha", "Beta Found"])
        XCTAssertNil(beta.error)
        XCTAssertEqual(saved?.sections.map(\.path), [a.path, found.path])
    }

    func testEverySectionMissingSelectsTheFirstNotTheWelcomeScreen() async throws {
        let session = AppSession(
            sections: [
                .init(location: LibraryLocation(path: temporary.appendingPathComponent("Gone A").path)),
                .init(location: LibraryLocation(path: temporary.appendingPathComponent("Gone B").path)),
            ], currentPath: temporary.appendingPathComponent("Gone B").path)
        defaults.set(try JSONEncoder().encode(session), forKey: LibraryWindowRegistry.sessionKey)
        let registry = await relaunch()
        XCTAssertEqual(roots(registry), ["Gone A", "Gone B"])
        XCTAssertEqual(registry.current.root?.lastPathComponent, "Gone A")
        XCTAssertEqual(registry.current.errorTitle, "Library Not Found")
        XCTAssertEqual(saved?.sections.count, 2)
        // Close Library on a missing section closes it without touching anything on disk.
        _ = await registry.closeLibrary(registry.current)
        XCTAssertEqual(roots(registry), ["Gone B"])
        XCTAssertEqual(saved?.sections.map(\.location.path), [session.sections[1].location.path])
    }

    // MARK: Quit and Close Window

    /// The sections are snapshotted before any unsaved-changes alert makes another Library current.
    func testQuitSnapshotsTheSectionsBeforeTeardown() async throws {
        let registry = await relaunch()
        let alpha = try await added(registry, try library("Alpha"))
        let beta = try await added(registry, try library("Beta"))
        registry.focus(alpha)
        XCTAssertEqual(saved?.currentPath, alpha.root?.path)

        // Cancel in an alert shown on Beta: Beta became current, and that's saved as usual again.
        let cancelled = await registry.prepareToQuit { workspace in
            registry.focus(beta)
            return false
        }
        XCTAssertFalse(cancelled)
        XCTAssertEqual(saved?.currentPath, beta.root?.path)

        registry.focus(alpha)
        let quit = await registry.prepareToQuit { workspace in
            registry.focus(beta)
            beta.sectionCollapsed = true
            return true
        }
        XCTAssertTrue(quit)
        XCTAssertEqual(saved?.currentPath, alpha.root?.path, "the state at Quit, not the alerts' focus")
        XCTAssertEqual(saved?.sections.map(\.collapsed), [false, false])
        // Closing every Library is the welcome screen next time.
        let next = await relaunch()
        XCTAssertEqual(roots(next), ["Alpha", "Beta"])
        for workspace in next.sections { _ = await next.closeLibrary(workspace) }
        XCTAssertEqual(saved, AppSession(sections: [], currentPath: nil, focusColumn: nil))
        let welcome = await relaunch()
        XCTAssertTrue(welcome.sections.isEmpty)
    }

    func testClosingTheWindowKeepsTheSavedSections() async throws {
        let registry = await relaunch()
        let alpha = try await added(registry, try library("Alpha"))
        _ = try await added(registry, try library("Beta"))
        let before = saved
        let closed = await registry.prepareToExit(.closeWindow)
        XCTAssertTrue(closed)
        await registry.windowClosed()
        XCTAssertEqual(saved, before)
        XCTAssertEqual(roots(registry), ["Alpha", "Beta"])
        // Saving carries on after the window closed.
        registry.focus(alpha)
        XCTAssertEqual(saved?.currentPath, alpha.root?.path)
    }

    // MARK: The window's view hierarchy

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// The real window: a missing section lists a “Not Found” row under a ⚠︎ header; selecting it shows Library Not
    /// Found beside the sidebar. Resize sweep and switching between the sections keep both.
    func testMissingSectionShowsNotFoundRowAndViewInTheWindow() async throws {
        let a = try library("Alpha")
        let gone = temporary.appendingPathComponent("Writing")
        let session = AppSession(
            sections: [.init(location: LibraryLocation.saving(a)), .init(location: LibraryLocation(path: gone.path))],
            currentPath: a.path)
        defaults.set(try JSONEncoder().encode(session), forKey: LibraryWindowRegistry.sessionKey)

        let registry = launch()
        let window = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: LibraryWindow(registry: registry))
        controller.sizingOptions = []
        window.contentViewController = controller // Never ordered on screen.
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        cleanUps.append { @MainActor in
            window.contentViewController = nil
            window.close()
        }
        func settle() async throws {
            for _ in 0..<3 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        // The window's own launch task restores the saved sections.
        _ = try await waitUntil("the restored sections") {
            registry.sections.count == 2 && registry.sections.allSatisfy { !$0.loading }
        }
        await registry.restoreSession().value
        try await settle()
        let outline = try XCTUnwrap(
            Self.descendants(window.contentView!).compactMap { $0 as? SidebarOutlineView }.first)
        let sections = try XCTUnwrap(outline.delegate as? SidebarSections)
        let titles = (0..<outline.numberOfRows).map { row -> String in
            switch outline.item(atRow: row) {
            case let header as SidebarSections.Header: "# " + header.title
            case let item as FolderSidebar.Item: item.title
            case let item as SidebarSections.Unavailable: "! " + item.title
            default: "?"
            }
        }
        XCTAssertEqual(titles, ["# Alpha", "All Documents", "Alpha", "Notes", "Tags", "# Writing", "! Not Found"])
        let missing = try XCTUnwrap(sections.headers.last)
        let header = try XCTUnwrap(outline.view(atColumn: 0, row: 5, makeIfNecessary: true) as? SectionHeaderCell)
        XCTAssertTrue(header.showsWarning)
        XCTAssertEqual(header.textField?.textColor, .secondaryLabelColor)
        XCTAssertEqual(header.accessibilityValue() as? String, "not found")
        let alphaHeader = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? SectionHeaderCell)
        XCTAssertFalse(alphaHeader.showsWarning)
        let row = try XCTUnwrap(outline.view(atColumn: 0, row: 6, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(row.textField?.stringValue, "Not Found")
        XCTAssertEqual(row.textField?.textColor, .tertiaryLabelColor)
        XCTAssertTrue(outline.delegate?.outlineView?(outline, shouldSelectItem: outline.item(atRow: 6)!) == true)

        // Selecting it makes Writing current and shows Library Not Found beside the sidebar.
        outline.selectRowIndexes([6], byExtendingSelection: false)
        XCTAssertTrue(registry.current === missing.workspace)
        try await settle()
        XCTAssertTrue(
            Self.descendants(window.contentView!).contains { $0 is SidebarOutlineView }, "the sidebar stays")
        XCTAssertEqual(outline.selectedRow, 6)
        XCTAssertEqual(saved?.currentPath, gone.path)

        // Resize sweep and switching back keep both sections and the selection where it belongs.
        for size in [NSSize(width: 900, height: 560), NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            try await settle()
            XCTAssertEqual(outline.numberOfRows, 7)
            XCTAssertEqual(outline.selectedRow, 6)
        }
        outline.selectRowIndexes([3], byExtendingSelection: false)
        try await settle()
        XCTAssertEqual(registry.current.root, a)
        registry.focus(missing.workspace)
        try await settle()
        XCTAssertEqual(outline.selectedRow, 6, "focusing the missing section selects its Not Found row")
    }
}

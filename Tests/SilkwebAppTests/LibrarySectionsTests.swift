import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #195: one library window; each open Library is a sidebar section with its own `LibraryWorkspace` (#194).
/// Open Folder in Place, New Library, the welcome screen and Open Recent add a section or focus the open one.
@MainActor
final class LibrarySectionsTests: XCTestCase {
    private var cleanUps: [@MainActor () async -> Void] = []
    private var temporary: URL!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebSections-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defaults = disposableDefaults("Sections")
    }

    override func tearDown() async throws {
        for cleanUp in cleanUps.reversed() { await cleanUp() }
        cleanUps = []
        try? FileManager.default.removeItem(at: temporary)
        try await super.tearDown()
    }

    private func makeRegistry() -> LibraryWindowRegistry {
        let defaults = defaults!
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
        cleanUps.append { @MainActor in
            for workspace in registry.workspaces { await workspace.releaseLibrary() }
        }
        return registry
    }

    /// A Library folder with `Notes/<document>.md`.
    private func library(_ name: String, document: String) throws -> URL {
        let root = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("# \(document)\n\nBody of \(name).\n".utf8).write(
            to: root.appendingPathComponent("Notes/\(document).md"))
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func added(_ registry: LibraryWindowRegistry, _ url: URL) async throws -> LibraryWorkspace {
        let workspace = await registry.add(url)
        return try XCTUnwrap(workspace)
    }

    private func roots(_ registry: LibraryWindowRegistry) -> [String] {
        registry.sections.compactMap { $0.root?.lastPathComponent }
    }

    private func openDocument(_ workspace: LibraryWorkspace, _ path: String) async {
        workspace.selectDocuments([path])
        await workspace.waitForNavigation()
    }

    // MARK: Adding and focusing

    func testOpeningTwoFoldersYieldsTwoSectionsWithoutReplacingTheFirst() async throws {
        let registry = makeRegistry()
        let welcome = registry.current
        XCTAssertTrue(registry.sections.isEmpty, "launch: the welcome screen")
        let a = try library("Alpha Library", document: "Alpha")
        let b = try library("Beta Library", document: "Beta")

        let first = try await added(registry, a)
        XCTAssertTrue(first === welcome, "the welcome screen opens the first Library in place")
        await openDocument(first, "Notes/Alpha.md")
        XCTAssertEqual(first.tabs.count, 1)

        let second = try await added(registry, b)
        XCTAssertFalse(second === first)
        XCTAssertEqual(roots(registry), ["Alpha Library", "Beta Library"], "sections in the order they were added")
        XCTAssertTrue(registry.current === second, "the new section is the current Library")
        XCTAssertEqual(first.root, a, "Alpha was not replaced")
        XCTAssertNotNil(first.snapshot)
        XCTAssertEqual(first.tabs.count, 1, "Alpha's tab stays open")
        XCTAssertEqual(second.snapshot?.documents.map(\.relativePath), ["Notes/Beta.md"])
        XCTAssertEqual(registry.workspaces.count, 2)
    }

    func testChoosingAnOpenFolderFocusesItsSectionWithoutADuplicate() async throws {
        let registry = makeRegistry()
        let a = try library("Alpha", document: "Alpha")
        let b = try library("Beta", document: "Beta")
        let alpha = try await added(registry, a)
        let beta = try await added(registry, b)
        alpha.sectionCollapsed = true
        let reveal = alpha.sectionRevealRequest

        // The same folder through another spelling (a trailing `..` hop, a symlink) is the same section.
        let link = temporary.appendingPathComponent("Alpha link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
        for spelling in [a, a.appendingPathComponent("Notes/.."), link] {
            let focused = await registry.add(spelling)
            XCTAssertTrue(focused === alpha)
            XCTAssertEqual(roots(registry), ["Alpha", "Beta"], "no second section for \(spelling.path)")
            XCTAssertTrue(registry.current === alpha)
        }
        XCTAssertFalse(alpha.sectionCollapsed, "focusing expands the section")
        XCTAssertGreaterThan(alpha.sectionRevealRequest, reveal, "and scrolls its scope into view")
        XCTAssertEqual(registry.workspaces.count, 2)
        XCTAssertTrue(registry.workspace(for: URL(fileURLWithPath: b.path + "/")) === beta)
        XCTAssertNil(registry.workspace(for: temporary.appendingPathComponent("Elsewhere")))
    }

    func testFailedOpenOrNewLibraryAlertsAndLeavesSectionsUnchanged() async throws {
        let registry = makeRegistry()
        let alpha = try await added(registry, try library("Alpha", document: "Alpha"))
        alpha.session.selectedFolder = "Notes"

        // A folder that's gone: alert on the current Library, nothing added, the selection stays.
        let missing = temporary.appendingPathComponent("Writing")
        let added = await registry.add(missing)
        XCTAssertNil(added)
        XCTAssertEqual(alpha.mutationErrorTitle, "“Writing” couldn’t be opened.")
        XCTAssertEqual(alpha.mutationError, "The folder may have been moved, renamed or deleted.")
        XCTAssertEqual(roots(registry), ["Alpha"])
        XCTAssertTrue(registry.current === alpha)
        XCTAssertEqual(alpha.session.selectedFolder, "Notes")
        XCTAssertNil(registry.recents.entry(path: missing.path), "only successful opens are recorded")

        // A file is not a Library.
        let file = temporary.appendingPathComponent("Note.md")
        try Data("x".utf8).write(to: file)
        alpha.mutationError = nil
        _ = await registry.add(file)
        XCTAssertEqual(alpha.mutationErrorTitle, "“Note.md” couldn’t be opened.")
        XCTAssertEqual(roots(registry), ["Alpha"])

        // New Library over an existing item: the create alert, and no section (#102).
        alpha.mutationError = nil
        alpha.createLibrary(at: temporary.appendingPathComponent("Alpha"))
        XCTAssertEqual(alpha.mutationErrorTitle, "“Alpha” couldn’t be created.")
        XCTAssertEqual(roots(registry), ["Alpha"])
        XCTAssertEqual(registry.workspaces.count, 1)
    }

    func testNewLibraryAddsASection() async throws {
        let registry = makeRegistry()
        let alpha = try await added(registry, try library("Alpha", document: "Alpha"))
        let fresh = temporary.appendingPathComponent("Fresh Library")
        alpha.createLibrary(at: fresh)
        _ = try await waitUntil("the new Library's section") { registry.sections.count == 2 }
        let created = try XCTUnwrap(registry.sections.last)
        await created.waitForLoad()
        XCTAssertTrue(registry.current === created)
        XCTAssertEqual(created.root, fresh.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertNotNil(created.snapshot)
        XCTAssertEqual(alpha.root?.lastPathComponent, "Alpha", "the first section stays")
    }

    // MARK: Close Library

    func testCloseLibraryClosesOnlyItsSectionAndTabs() async throws {
        let registry = makeRegistry()
        let alpha = try await added(registry, try library("Alpha", document: "Alpha"))
        await openDocument(alpha, "Notes/Alpha.md")
        let beta = try await added(registry, try library("Beta", document: "Beta"))
        await openDocument(beta, "Notes/Beta.md")
        let gamma = try await added(registry, try library("Gamma", document: "Gamma"))
        registry.focus(beta)

        // Closing the current middle section selects the next one; Alpha's tab is untouched.
        let closed = await registry.closeLibrary(beta)
        XCTAssertTrue(closed)
        XCTAssertEqual(roots(registry), ["Alpha", "Gamma"])
        XCTAssertTrue(registry.current === gamma, "the next section's scope")
        XCTAssertTrue(beta.tabs.isEmpty)
        XCTAssertEqual(alpha.tabs.count, 1)
        XCTAssertEqual(alpha.editor.url?.lastPathComponent, "Alpha.md")
        XCTAssertNotNil(alpha.snapshot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.appendingPathComponent("Beta").path))
        XCTAssertNotNil(registry.recents.entry(path: temporary.appendingPathComponent("Beta").path), "stays in recents")

        // The last section: no next one, so the previous.
        _ = await registry.closeLibrary(gamma)
        XCTAssertTrue(registry.current === alpha)
        // A section that isn't current closes without moving the selection.
        let delta = try await added(registry, try library("Delta", document: "Delta"))
        registry.focus(alpha)
        _ = await registry.closeLibrary(delta)
        XCTAssertTrue(registry.current === alpha)
        XCTAssertEqual(roots(registry), ["Alpha"])

        // Closing the last Library shows the welcome screen in the same window.
        _ = await registry.closeLibrary(alpha)
        XCTAssertTrue(registry.sections.isEmpty)
        XCTAssertEqual(registry.workspaces.count, 1)
        XCTAssertNil(registry.current.root)
        XCTAssertFalse(registry.current === alpha)
        // And the welcome screen opens the next Library in place.
        let reopened = await registry.add(temporary.appendingPathComponent("Gamma"))
        XCTAssertTrue(reopened === registry.workspaces.first)
        XCTAssertEqual(roots(registry), ["Gamma"])
    }

    /// Owner decision (2026-10-09): Close Library asks first whenever one of its tabs has unsaved changes.
    func testCloseLibraryAsksFirstWithUnsavedChanges() async throws {
        let registry = makeRegistry()
        let root = try library("Kyoto", document: "Temples")
        let kyoto = try await added(registry, root)
        await openDocument(kyoto, "Notes/Temples.md")
        let other = try await added(registry, try library("Other", document: "Other"))
        registry.focus(kyoto)
        kyoto.editor.edit("# Temples\n\nEdited.\n")
        XCTAssertTrue(kyoto.editor.state.isDirty)

        var asked: [String] = []
        registry.presentAlert = { alert, _ in
            asked.append(alert.messageText)
            return false // Cancel
        }
        let cancelled = await registry.closeLibrary(kyoto)
        XCTAssertFalse(cancelled)
        XCTAssertEqual(asked, ["Close “Kyoto”?"])
        XCTAssertEqual(roots(registry), ["Kyoto", "Other"], "Cancel closes nothing")
        XCTAssertEqual(kyoto.tabs.count, 1)

        registry.presentAlert = { alert, _ in
            asked.append(alert.messageText)
            return true // Close Library
        }
        let closed = await registry.closeLibrary(kyoto)
        XCTAssertTrue(closed)
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Notes/Temples.md"), encoding: .utf8),
            "# Temples\n\nEdited.\n", "the unsaved text was saved before closing")
        XCTAssertEqual(roots(registry), ["Other"])
        XCTAssertTrue(registry.current === other)

        // Clean tabs close without a question.
        registry.presentAlert = { _, _ in
            XCTFail("no question without unsaved changes"); return false
        }
        await openDocument(other, "Notes/Other.md")
        let quiet = await registry.closeLibrary(other)
        XCTAssertTrue(quiet)
    }

    func testCloseLibraryKeepsEverythingWhenSavingFails() async throws {
        let registry = makeRegistry()
        let kyoto = try await added(registry, try library("Kyoto", document: "Temples"))
        await openDocument(kyoto, "Notes/Temples.md")
        _ = try await added(registry, try library("Other", document: "Other"))
        kyoto.editor.edit("# Temples\n\nEdited.\n")
        kyoto.editor.recovered = true // Recovered text awaiting Keep/Discard: saving it is refused.

        var asked: [String] = []
        registry.presentAlert = { alert, _ in
            asked.append(alert.messageText)
            return true
        }
        let closed = await registry.closeLibrary(kyoto)
        XCTAssertFalse(closed)
        XCTAssertEqual(asked, ["Close “Kyoto”?", "“Kyoto” couldn’t be saved."])
        XCTAssertEqual(roots(registry), ["Kyoto", "Other"], "nothing is closed")
        XCTAssertEqual(kyoto.tabs.count, 1)
        XCTAssertTrue(kyoto.editor.state.isDirty)
        kyoto.editor.recovered = false
        kyoto.editor.state = .clean
    }

    // MARK: Quit

    func testQuitSavesEveryOpenLibraryCurrentFirst() async throws {
        let registry = makeRegistry()
        let a = try library("A", document: "Alpha")
        let alpha = try await added(registry, a)
        await openDocument(alpha, "Notes/Alpha.md")
        let b = try library("B", document: "Beta")
        let beta = try await added(registry, b)
        await openDocument(beta, "Notes/Beta.md")
        alpha.editor.edit("# Alpha\n\nEdited in A.\n")
        beta.editor.edit("# Beta\n\nEdited in B.\n")

        var asked: [ObjectIdentifier] = []
        let refused = await registry.prepareToQuit { workspace in
            asked.append(ObjectIdentifier(workspace))
            return false
        }
        XCTAssertFalse(refused)
        XCTAssertEqual(asked, [ObjectIdentifier(beta)], "the current Library first; Cancel stops the quit")

        let quit = await registry.prepareToQuit()
        XCTAssertTrue(quit)
        XCTAssertEqual(
            try String(contentsOf: a.appendingPathComponent("Notes/Alpha.md"), encoding: .utf8),
            "# Alpha\n\nEdited in A.\n")
        XCTAssertEqual(
            try String(contentsOf: b.appendingPathComponent("Notes/Beta.md"), encoding: .utf8),
            "# Beta\n\nEdited in B.\n")
    }

    // MARK: Recents

    func testRecentsRecordSuccessfulOpensAndFocusOpenSections() async throws {
        let registry = makeRegistry()
        let a = try library("Writing", document: "Alpha")
        let nested = temporary.appendingPathComponent("Archive")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let b = try library("Archive/Writing", document: "Beta")
        let alpha = try await added(registry, a)
        _ = try await added(registry, b)
        let items = registry.recentItems()
        XCTAssertEqual(items.map(\.path), [b.path, a.path], "most recent first")
        XCTAssertEqual(items.map(\.title), ["Writing — Archive", "Writing — \(temporary.lastPathComponent)"])
        XCTAssertEqual(items.map(\.isOpen), [true, true], "open sections are checked")

        // Open Recent on an open Library focuses it.
        await registry.openRecent(a.path)
        XCTAssertTrue(registry.current === alpha)
        XCTAssertEqual(registry.sections.count, 2)

        // Closed, it reopens as a section from its bookmark.
        _ = await registry.closeLibrary(alpha)
        XCTAssertEqual(registry.recentItems().map(\.isOpen), [true, false])
        await registry.openRecent(a.path)
        XCTAssertEqual(roots(registry), ["Writing", "Writing"])
        XCTAssertEqual(registry.current.root, a)
        XCTAssertEqual(registry.recentItems().first?.path, a.path)

        // Saved for the next launch.
        let saved = try XCTUnwrap(defaults.data(forKey: LibraryWindowRegistry.recentsKey))
        XCTAssertEqual(
            try JSONDecoder().decode(RecentLibraries.self, from: saved).entries.compactMap(\.path), [a.path, b.path])
        registry.clearRecents()
        XCTAssertTrue(registry.recentItems().isEmpty)
    }

    func testMissingRecentOffersRemoveFromRecents() async throws {
        let registry = makeRegistry()
        let root = try library("Writing", document: "Alpha")
        let writing = try await added(registry, root)
        _ = await registry.closeLibrary(writing)
        try FileManager.default.removeItem(at: root)

        var asked: [(String, String, [String])] = []
        registry.presentAlert = { alert, _ in
            asked.append((alert.messageText, alert.informativeText, alert.buttons.map(\.title)))
            return false // Cancel
        }
        await registry.openRecent(root.path)
        XCTAssertEqual(asked.first?.0, "“Writing” can’t be opened.")
        XCTAssertEqual(asked.first?.1, "The folder may have been moved, renamed or deleted.")
        XCTAssertEqual(asked.first?.2, ["Remove from Recents", "Cancel"])
        XCTAssertNotNil(registry.recents.entry(path: root.path), "Cancel keeps the entry")
        XCTAssertTrue(registry.sections.isEmpty)

        registry.presentAlert = { _, _ in true } // Remove from Recents
        await registry.openRecent(root.path)
        XCTAssertNil(registry.recents.entry(path: root.path))
    }

    /// Files saved before #195: the legacy `libraryLocation` still restores at launch and seeds Open Recent.
    func testLegacyLibraryLocationRestoresAndSeedsRecents() async throws {
        let root = try library("Legacy", document: "Old")
        defaults.set(try JSONEncoder().encode(LibraryLocation.saving(root)), forKey: "libraryLocation")
        let registry = makeRegistry()
        XCTAssertEqual(registry.recentItems().map(\.path), [root.path], "seeded from libraryLocation")
        XCTAssertNil(defaults.data(forKey: LibraryWindowRegistry.recentsKey), "nothing written until a change")

        let launch = registry.current
        launch.restore()
        _ = try await waitUntil("the restored Library") { launch.snapshot != nil }
        await launch.waitForLoad()
        XCTAssertEqual(roots(registry), ["Legacy"])
        XCTAssertTrue(registry.current === launch)
        XCTAssertEqual(registry.recentItems().map(\.path), [root.path])

        // A malformed recents list from another build loads as empty rather than failing.
        defaults.set(Data("not json".utf8), forKey: LibraryWindowRegistry.recentsKey)
        XCTAssertTrue(makeRegistry().recentItems().isEmpty)
    }

    func testSettingsChooseLibraryReplacesTheCurrentSection() async throws {
        let registry = makeRegistry()
        let alpha = try await added(registry, try library("Alpha", document: "Alpha"))
        let beta = try await added(registry, try library("Beta", document: "Beta"))
        let gamma = try library("Gamma", document: "Gamma")
        registry.replace(beta, with: gamma)
        await beta.waitForLoad()
        XCTAssertEqual(roots(registry), ["Alpha", "Gamma"], "replaced in place, in the same position")
        XCTAssertTrue(registry.current === beta)
        // A folder that is already another section is focused instead.
        registry.replace(beta, with: try XCTUnwrap(alpha.root))
        XCTAssertTrue(registry.current === alpha)
        XCTAssertEqual(roots(registry), ["Alpha", "Gamma"])
    }

    // MARK: The window's view hierarchy

    private func hostWindow(_ registry: LibraryWindowRegistry) throws -> (NSWindow, () -> SidebarSections?) {
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
        let sections = {
            Self.descendants(window.contentView!).compactMap {
                ($0 as? SidebarOutlineView)?.delegate as? SidebarSections
            }
            .first
        }
        return (window, sections)
    }

    private func settle(_ window: NSWindow, _ rounds: Int = 3) async throws {
        for _ in 0..<rounds {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func rows(_ outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).map { row in
            switch outline.item(atRow: row) {
            case let header as SidebarSections.Header: "# " + header.title
            case let item as FolderSidebar.Item: item.title
            default: "?"
            }
        }
    }

    func testSidebarShowsOneSectionPerLibraryAndFollowsTheCurrentLibrary() async throws {
        let registry = makeRegistry()
        let (window, sidebar) = try hostWindow(registry)
        try await settle(window)
        XCTAssertNil(sidebar(), "the welcome screen has no sidebar")
        XCTAssertTrue(registry.hasWindow)

        let alpha = try await added(registry, try library("Alpha", document: "Alpha"))
        let beta = try await added(registry, try library("Beta", document: "Beta"))
        try await settle(window)
        let sections = try XCTUnwrap(sidebar())
        let outline = try XCTUnwrap(sections.outline)
        XCTAssertEqual(
            rows(outline),
            ["# Alpha", "All Documents", "Alpha", "Notes", "Tags", "# Beta", "All Documents", "Beta", "Notes", "Tags"],
            "a header per Library; under it the rows a lone Library shows")
        XCTAssertTrue(outline.delegate?.outlineView?(outline, isGroupItem: outline.item(atRow: 0)!) == true)
        XCTAssertFalse(outline.delegate?.outlineView?(outline, shouldSelectItem: outline.item(atRow: 0)!) ?? true)
        XCTAssertEqual(outline.rect(ofRow: 0).height, Spacing.sidebarRowHeight, "no space above the first header")
        XCTAssertEqual(outline.rect(ofRow: 5).height, Spacing.sidebarRowHeight + 12, "12 pt above the others")
        // Every Library's rows sit where a lone Library's do: the header level adds no indentation.
        XCTAssertEqual(outline.frameOfCell(atColumn: 0, row: 1).minX, outline.frameOfCell(atColumn: 0, row: 6).minX)
        XCTAssertEqual(outline.level(forRow: 1), 1)

        // Beta is current: its header in labelColor, its scope selected; the list and editor show Beta.
        func header(_ row: Int) throws -> SectionHeaderCell {
            try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SectionHeaderCell)
        }
        XCTAssertEqual(try header(5).textField?.textColor, .labelColor)
        XCTAssertEqual(try header(0).textField?.textColor, .secondaryLabelColor)
        XCTAssertEqual(try header(5).accessibilityValue() as? String, "current")
        XCTAssertEqual(try header(0).accessibilityLabel(), "Alpha library")
        XCTAssertEqual(outline.selectedRow, 7, "Beta's remembered scope: its root folder")
        XCTAssertTrue(beta.sidebarOutline === outline)
        XCTAssertNil(alpha.sidebarOutline, "only the current Library's sidebar is a command target")
        XCTAssertTrue(beta.librarySplitController?.workspace === beta)

        // A click on Alpha's Notes makes Alpha current and shows that folder.
        outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertTrue(registry.current === alpha)
        XCTAssertEqual(alpha.session.selectedFolder, "Notes")
        try await settle(window)
        XCTAssertTrue(alpha.librarySplitController?.workspace === alpha, "the columns switched to Alpha")
        XCTAssertNil(beta.librarySplitController)
        XCTAssertEqual(try header(0).textField?.textColor, .labelColor)
        XCTAssertEqual(try header(5).textField?.textColor, .secondaryLabelColor)
        XCTAssertEqual(outline.selectedRow, 3)
        XCTAssertEqual(beta.session.selectedFolder, "", "Beta keeps its own scope")
        let list = Self.descendants(window.contentView!).compactMap { $0 as? DocumentTableView }
        XCTAssertEqual(list.count, 1, "one list, for the current Library")

        // Focusing Beta again (Open Folder in Place on its folder) selects its remembered scope.
        _ = await registry.add(try XCTUnwrap(beta.root))
        try await settle(window)
        XCTAssertEqual(outline.selectedRow, 7)
        XCTAssertTrue(beta.librarySplitController?.workspace === beta)

        // Resize sweep: the outline keeps both sections at every sidebar width.
        let columns = try XCTUnwrap(beta.librarySplitController)
        for width: CGFloat in [180, 320, 220] {
            columns.navigationController.splitView.setPosition(width, ofDividerAt: 0)
            try await settle(window, 1)
            XCTAssertEqual(outline.numberOfRows, 10)
        }
        for size in [NSSize(width: 900, height: 560), NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            try await settle(window, 1)
            XCTAssertEqual(outline.numberOfRows, 10)
        }
    }

    func testCollapsedSectionHidesItsRowsAndKeepsItsSelection() async throws {
        let registry = makeRegistry()
        let (window, sidebar) = try hostWindow(registry)
        let alpha = try await added(registry, try library("Alpha", document: "Alpha"))
        let beta = try await added(registry, try library("Beta", document: "Beta"))
        try await settle(window)
        let outline = try XCTUnwrap(sidebar()?.outline)
        outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
        XCTAssertTrue(registry.current === alpha)
        try await settle(window)

        // The Show/Hide chevron: Alpha's rows go, its scope stays.
        outline.collapseItem(outline.item(atRow: 0))
        XCTAssertTrue(alpha.sectionCollapsed)
        XCTAssertEqual(rows(outline), ["# Alpha", "# Beta", "All Documents", "Beta", "Notes", "Tags"])
        XCTAssertEqual(alpha.session.selectedFolder, "Notes")
        XCTAssertTrue(registry.current === alpha)

        // Expanding brings the rows back with the scope selected.
        outline.expandItem(outline.item(atRow: 0))
        XCTAssertFalse(alpha.sectionCollapsed)
        try await settle(window, 1)
        XCTAssertEqual(rows(outline).count, 10)
        XCTAssertEqual(outline.selectedRow, 3)

        // A collapsed section that is focused (Open Recent, ⌘O) expands again.
        alpha.sectionCollapsed = true
        try await settle(window)
        XCTAssertEqual(rows(outline).count, 6)
        registry.focus(alpha)
        try await settle(window)
        XCTAssertEqual(rows(outline).count, 10)
        XCTAssertEqual(outline.selectedRow, 3)
        XCTAssertNotNil(beta.snapshot)
    }

    func testHeaderMenuAndFileMenuCloseLibrary() async throws {
        let registry = makeRegistry()
        let (window, sidebar) = try hostWindow(registry)
        let alpha = try await added(registry, try library("Alpha", document: "Alpha"))
        _ = try await added(registry, try library("Beta", document: "Beta"))
        try await settle(window)
        let outline = try XCTUnwrap(sidebar()?.outline)
        let point = outline.convert(NSPoint(x: 40, y: outline.rect(ofRow: 0).midY), to: nil)
        let event = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(outline.menu(for: event))
        XCTAssertEqual(menu.items.map(\.title), ["Reveal in Finder", "", "Close Library"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertTrue(menu.items.allSatisfy { $0.image == nil && $0.keyEquivalent.isEmpty }, "text only")
        menu.performActionForItem(at: 2)
        _ = try await waitUntil("Alpha's section closes") { registry.sections.count == 1 }
        XCTAssertEqual(roots(registry), ["Beta"])
        XCTAssertNil(alpha.root.flatMap { registry.workspace(for: $0) })
        try await settle(window)
        XCTAssertEqual(rows(outline), ["# Beta", "All Documents", "Beta", "Notes", "Tags"])
        // A folder row's menu is still the folder menu.
        let folderPoint = outline.convert(NSPoint(x: 40, y: outline.rect(ofRow: 3).midY), to: nil)
        let folderEvent = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: folderPoint, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(outline.menu(for: folderEvent)?.items.map(\.title).contains("Move to Trash") == true)
    }

    /// QA #195: inline rename through the sections outline, as the app ships it. A folder's field appears in its
    /// row, a click-away commits and leaves focus where it went; the same for a document in the list.
    /// The Libraries are open and the folder selected before the window is built, as at launch: the sidebar's only
    /// update is the one that builds its sections.
    func testRenameInTheSectionsSidebarShowsTheFieldAndCommitsOnClickAway() async throws {
        let registry = makeRegistry()
        let alpha = try await added(registry, try library("Alpha", document: "Alpha"))
        let beta = try await added(registry, try library("Beta", document: "Beta"))
        beta.selectFolder("Notes")
        await beta.waitForNavigation()
        let (window, sidebar) = try hostWindow(registry)
        try await settle(window)
        let outline = try XCTUnwrap(sidebar()?.outline)
        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: beta.root!.appendingPathComponent(path).path)
        }
        func type(_ label: String, _ text: String) async throws {
            _ = try await waitUntil("\(label): rename field") {
                window.contentView?.layoutSubtreeIfNeeded()
                return beta.rename != nil
                    && Self.descendants(window.contentView!).contains {
                        ($0 as? RenameNameField)?.currentEditor() != nil
                    }
            }
            let field = try XCTUnwrap(
                Self.descendants(window.contentView!).compactMap { $0 as? RenameNameField }.first {
                    $0.currentEditor() != nil
                })
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        }
        func finished(_ label: String) async throws {
            _ = try await waitUntil("\(label): rename finished") { beta.rename == nil && !beta.mutating }
            try await settle(window)
        }

        // A folder: the field sits in Beta's Notes row; clicking the list commits and the list keeps focus.
        beta.beginRename(LibraryRename(path: "Notes", isFolder: true))
        try await type("folder", "Renamed")
        let fieldRow = outline.row(
            for: try XCTUnwrap(Self.descendants(outline).compactMap { $0 as? RenameNameField }.first))
        XCTAssertEqual((outline.item(atRow: fieldRow) as? FolderSidebar.Item)?.folder?.relativePath, "Notes")
        XCTAssertTrue((outline.item(atRow: fieldRow) as? FolderSidebar.Item)?.owner?.workspace === beta)
        let list = try XCTUnwrap(
            Self.descendants(window.contentView!).compactMap { $0 as? NSTableView }.first {
                !($0 is SidebarOutlineView)
            })
        XCTAssertTrue(window.makeFirstResponder(list))
        try await finished("folder")
        XCTAssertTrue(exists("Renamed"), "a click-away commits a valid folder name")
        XCTAssertFalse(exists("Notes"))
        XCTAssertTrue(window.firstResponder === list)
        XCTAssertEqual(
            rows(outline),
            [
                "# Alpha", "All Documents", "Alpha", "Notes", "Tags",
                "# Beta", "All Documents", "Beta", "Renamed", "Tags",
            ], "only Beta's section follows the rename")

        // A document: the field is in the list; clicking the sections outline commits and the outline keeps focus.
        beta.beginRename(LibraryRename(path: "Renamed/Beta.md", isFolder: false))
        try await type("document", "Beta Notes")
        XCTAssertTrue(window.makeFirstResponder(outline))
        try await finished("document")
        XCTAssertTrue(exists("Renamed/Beta Notes.md"), "a click-away commits a valid document name")
        XCTAssertTrue(window.firstResponder === outline)
        XCTAssertTrue(registry.current === beta)
        XCTAssertNil(alpha.rename)
    }
}

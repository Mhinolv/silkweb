import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #227: Copy Path (absolute) and its Option alternate Copy Relative Path, directly below Reveal in Finder in the
/// real window's menus: section headers (the Library root, absolute only), folder rows, document rows (the whole
/// selection in list order), editor tabs, Search Library rows, and File ▸ Copy Path for the focused selection.
@MainActor
final class CopyPathTests: XCTestCase {
    private var cleanUps: [@MainActor () async -> Void] = []
    private var temporary: URL!
    private let board = NSPasteboard.withUniqueName()

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebCopyPath-" + UUID().uuidString)
    }

    override func tearDown() async throws {
        for cleanUp in cleanUps.reversed() { await cleanUp() }
        cleanUps = []
        board.releaseGlobally()
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

    /// Alpha (`Notes/Apple.md`, `Notes/Avocado.md`, `Notes/Cherry Pie.md`) and Beta (`Notes/Banana.md`) in the real
    /// library window, never ordered on screen; each has its first document open and Alpha is current.
    private func twoLibraries() async throws -> (KeyedTestWindow, LibraryWorkspace, URL, LibraryWorkspace, URL) {
        let defaults = disposableDefaults("CopyPath")
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
        var opened: [(LibraryWorkspace, URL)] = []
        for (name, documents) in [("Alpha", ["Apple", "Avocado", "Cherry Pie"]), ("Beta", ["Banana"])] {
            let url = try library(name, documents)
            let added = await registry.add(url)
            let workspace = try XCTUnwrap(added)
            workspace.pathPasteboard = board
            try await settle(window)
            workspace.navigate(folder: "Notes", documents: ["Notes/\(documents[0]).md"])
            await workspace.waitForNavigation()
            await workspace.search.waitForIndex()
            opened.append((workspace, url))
        }
        registry.focus(opened[0].0)
        try await settle(window)
        return (window, opened[0].0, opened[0].1, opened[1].0, opened[1].1)
    }

    private func settle(_ window: NSWindow, _ rounds: Int = 3) async throws {
        for _ in 0..<rounds {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func rightClick(_ window: NSWindow, at point: NSPoint) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .rightMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// Runs the menu's item titled `title` and returns what it put on the pasteboard (nil: nothing).
    private func copied(_ menu: NSMenu, _ title: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> String?
    {
        let index = try XCTUnwrap(menu.items.firstIndex { $0.title == title }, "no \(title)", file: file, line: line)
        board.clearContents()
        menu.performActionForItem(at: index)
        return board.string(forType: .string)
    }

    /// Copy Path directly below Reveal in Finder, then (when offered) Copy Relative Path as its ⌥ alternate.
    private func assertPlacement(
        _ menu: NSMenu, relative: Bool, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let titles = menu.items.map(\.title)
        let reveal = try XCTUnwrap(titles.firstIndex(of: "Reveal in Finder"), "\(titles)", file: file, line: line)
        let copy = menu.items[reveal + 1]
        XCTAssertEqual(copy.title, "Copy Path", file: file, line: line)
        XCTAssertFalse(copy.isAlternate, file: file, line: line)
        XCTAssertTrue(copy.keyEquivalent.isEmpty, "context menus show no shortcut", file: file, line: line)
        XCTAssertTrue(copy.isEnabled, file: file, line: line)
        XCTAssertEqual(titles.filter { $0 == "Copy Path" }.count, 1, file: file, line: line)
        if relative {
            let alternate = menu.items[reveal + 2]
            XCTAssertEqual(alternate.title, "Copy Relative Path", file: file, line: line)
            XCTAssertTrue(alternate.isAlternate, file: file, line: line)
            XCTAssertEqual(alternate.keyEquivalentModifierMask, .option, file: file, line: line)
            XCTAssertEqual(alternate.keyEquivalent, copy.keyEquivalent, file: file, line: line)
        } else {
            XCTAssertFalse(titles.contains("Copy Relative Path"), "\(titles)", file: file, line: line)
        }
    }

    func testSidebarHeaderFolderAndRootRowsCopyTheirPaths() async throws {
        let (window, alpha, alphaURL, _, betaURL) = try await twoLibraries()
        let outline = try XCTUnwrap(
            Self.descendants(window.contentView!).compactMap { $0 as? SidebarOutlineView }.first)
        func menu(row: Int) throws -> NSMenu {
            let point = outline.convert(NSPoint(x: 40, y: outline.rect(ofRow: row).midY), to: nil)
            return try XCTUnwrap(outline.menu(for: rightClick(window, at: point)))
        }
        func row(_ match: (Any?) -> Bool) throws -> Int {
            try XCTUnwrap((0..<outline.numberOfRows).first { match(outline.item(atRow: $0)) })
        }
        func header(_ title: String) throws -> Int {
            try row { ($0 as? SidebarSections.Header)?.title == title }
        }
        func folder(_ workspace: LibraryWorkspace, _ path: String) throws -> Int {
            try row {
                guard let item = $0 as? FolderSidebar.Item else { return false }
                return item.owner?.workspace === workspace && item.folder?.relativePath == path
            }
        }

        // A section header copies its Library's root, absolute only, also for a Library that isn't current.
        for (title, url) in [("Alpha", alphaURL), ("Beta", betaURL)] {
            let headerMenu = try menu(row: header(title))
            try assertPlacement(headerMenu, relative: false)
            XCTAssertEqual(try copied(headerMenu, "Copy Path"), url.path)
        }

        // A folder row: absolute, or relative to its Library with Option.
        let notes = try menu(row: folder(alpha, "Notes"))
        try assertPlacement(notes, relative: true)
        XCTAssertEqual(try copied(notes, "Copy Path"), alphaURL.path + "/Notes")
        XCTAssertEqual(try copied(notes, "Copy Relative Path"), "Notes")
        XCTAssertFalse(try XCTUnwrap(copied(notes, "Copy Path")).hasSuffix("/"))

        // The Library's own row is its root: no relative form.
        let root = try menu(row: folder(alpha, ""))
        try assertPlacement(root, relative: false)
        XCTAssertEqual(try copied(root, "Copy Path"), alphaURL.path)
    }

    func testDocumentRowsCopyTheWholeSelectionInListOrder() async throws {
        let (window, alpha, alphaURL, _, _) = try await twoLibraries()
        let table = try XCTUnwrap(
            Self.descendants(window.contentView!).compactMap { $0 as? DocumentTableView }.first {
                $0.coordinator?.workspace === alpha
            })
        let coordinator = try XCTUnwrap(table.coordinator)
        let listed = coordinator.documents.map(\.relativePath)
        XCTAssertEqual(Set(listed), ["Notes/Apple.md", "Notes/Avocado.md", "Notes/Cherry Pie.md"])

        // One row.
        var menu = coordinator.menu(path: "Notes/Cherry Pie.md")
        try assertPlacement(menu, relative: true)
        XCTAssertEqual(try copied(menu, "Copy Path"), alphaURL.path + "/Notes/Cherry Pie.md")
        XCTAssertEqual(try copied(menu, "Copy Relative Path"), "Notes/Cherry Pie.md")

        // A row in a multi-selection copies every selected row, one per line, top to bottom as listed.
        let selected: Set = ["Notes/Cherry Pie.md", "Notes/Apple.md", "Notes/Avocado.md"]
        alpha.selectDocuments(selected)
        await alpha.waitForNavigation()
        try await settle(window)
        let order = coordinator.documents.map(\.relativePath).filter { selected.contains($0) }
        XCTAssertEqual(order.count, 3)
        menu = coordinator.menu(path: "Notes/Avocado.md")
        try assertPlacement(menu, relative: true)
        XCTAssertEqual(try copied(menu, "Copy Relative Path"), order.joined(separator: "\n"))
        XCTAssertEqual(
            try copied(menu, "Copy Path"), order.map { alphaURL.path + "/" + $0 }.joined(separator: "\n"))

        // A row outside the selection copies only itself.
        alpha.selectDocuments(["Notes/Apple.md", "Notes/Avocado.md"])
        await alpha.waitForNavigation()
        menu = coordinator.menu(path: "Notes/Cherry Pie.md")
        XCTAssertEqual(try copied(menu, "Copy Relative Path"), "Notes/Cherry Pie.md")

        // File ▸ Copy Path with the list focused: the selection, in list order.
        alpha.focusColumn = 1
        board.clearContents()
        alpha.copyPaths()
        XCTAssertEqual(
            board.string(forType: .string),
            coordinator.documents.map(\.relativePath).filter { ["Notes/Apple.md", "Notes/Avocado.md"].contains($0) }
                .map { alphaURL.path + "/" + $0 }.joined(separator: "\n"))
    }

    func testEditorTabsAndFileMenuCopyTheirDocumentOrFolder() async throws {
        let (window, alpha, alphaURL, beta, betaURL) = try await twoLibraries()
        // The strip lists both Libraries' tabs (#197); each copies its path in its own Library.
        let buttons = Self.descendants(window.contentView!).compactMap { $0 as? EditorTabButton }
        let event = try rightClick(window, at: .zero)
        for (workspace, url, path) in [(alpha, alphaURL, "Notes/Apple.md"), (beta, betaURL, "Notes/Banana.md")] {
            let button = try XCTUnwrap(
                buttons.first { $0.owner === workspace && $0.tab.editor.url?.path.hasSuffix(path) == true })
            let menu = try XCTUnwrap(button.menu(for: event))
            try assertPlacement(menu, relative: true)
            XCTAssertEqual(try copied(menu, "Copy Path"), url.path + "/" + path)
            XCTAssertEqual(try copied(menu, "Copy Relative Path"), path)
        }

        // File ▸ Copy Path follows focus: the editor's document, the selected folder, the Library root.
        alpha.focusColumn = 2
        board.clearContents()
        alpha.copyPaths()
        XCTAssertEqual(board.string(forType: .string), alphaURL.path + "/Notes/Apple.md")
        alpha.focusColumn = 0
        alpha.session.selectedFolder = "Notes"
        alpha.copyPaths()
        XCTAssertEqual(board.string(forType: .string), alphaURL.path + "/Notes")
        alpha.session.selectedFolder = ""
        alpha.copyPaths()
        XCTAssertEqual(board.string(forType: .string), alphaURL.path)
        // The root has no relative path: nothing is copied rather than an empty line.
        board.clearContents()
        alpha.copyPaths(relative: true)
        XCTAssertNil(board.string(forType: .string))
    }

    func testWithoutALibraryNothingIsCopied() {
        let workspace = LibraryWorkspace(defaults: disposableDefaults("CopyPathEmpty"), columnAutosaveName: nil)
        workspace.pathPasteboard = board
        board.clearContents()
        board.setString("unchanged", forType: .string)
        workspace.copyPaths()
        XCTAssertEqual(board.string(forType: .string), "unchanged")
    }

    func testSearchRowsCopyTheirPathInTheirOwnLibrary() async throws {
        let (window, alpha, alphaURL, _, betaURL) = try await twoLibraries()
        // The window's Search Library field resets the scope on new text first.
        alpha.search.text = "kiwi"
        try await settle(window)
        alpha.search.allLibraries = true
        await alpha.search.query(quick: false, debounce: false)
        _ = try await waitUntil("both Libraries' rows") {
            Set(alpha.filteredSearchResults.map(\.displayName)).isSuperset(of: ["Apple", "Banana"])
        }
        let rows = alpha.filteredSearchResults
        let apple = try XCTUnwrap(rows.first { $0.displayName == "Apple" })
        let banana = try XCTUnwrap(rows.first { $0.displayName == "Banana" })
        for (row, expected, relative) in [
            (apple, alphaURL.path + "/Notes/Apple.md", false), (apple, "Notes/Apple.md", true),
            (banana, betaURL.path + "/Notes/Banana.md", false), (banana, "Notes/Banana.md", true),
        ] {
            board.clearContents()
            alpha.copySearchResultPath(row, relative: relative)
            XCTAssertEqual(board.string(forType: .string), expected)
        }
        XCTAssertEqual(alpha.searchResultLocation(banana)?.path, "Notes/Banana.md")
        XCTAssertEqual(alpha.search.text, "kiwi", "copying leaves the search as it is")
    }
}

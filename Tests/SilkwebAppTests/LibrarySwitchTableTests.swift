import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #152: switching libraries while the document list shows rows must never trap. `open(_:)` clears the snapshot
/// before the scan, and the native table can still refresh its realized rows before SwiftUI swaps it for the
/// loading state. The real library window, never ordered on screen, is laid out throughout the switch.
final class LibrarySwitchTableTests: XCTestCase {
    static let documentCount = 12

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor private final class Harness {
        let window: NSWindow
        let workspace: LibraryWorkspace
        let defaults: UserDefaults
        let container: URL
        init(window: NSWindow, workspace: LibraryWorkspace, defaults: UserDefaults, container: URL) {
            self.window = window; self.workspace = workspace; self.defaults = defaults; self.container = container
        }
        var content: NSView { window.contentView! }
        var table: DocumentTableView? {
            LibrarySwitchTableTests.descendants(content).compactMap { $0 as? DocumentTableView }.first
        }
        func layout() { content.superview?.layoutSubtreeIfNeeded() }

        /// Lays the window out on every turn until the workspace has finished loading `root`.
        func switchAndPump(to root: URL, _ start: () -> Void) async throws {
            let expected = root.standardizedFileURL.resolvingSymlinksInPath().path
            start()
            layout()
            try await waitUntil("library \(root.lastPathComponent) loads", timeout: .seconds(10)) {
                layout()
                return workspace.snapshot?.rootURL.path == expected && !workspace.loading
            }
            layout()
            XCTAssertEqual(workspace.root?.path, expected)
            XCTAssertNil(workspace.error)
        }
    }

    @MainActor private func makeLibrary(_ name: String, in container: URL, documents: Int) throws -> URL {
        let root = container.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<documents {
            try Data("# \(name) \(index + 1)\n\nSome text for the excerpt.\n".utf8)
                .write(to: root.appendingPathComponent(String(format: "Note %02d.md", index + 1)))
        }
        return root
    }

    /// Hosts `LibraryWorkspaceView` and opens library A, through `restore()` when `restoring`, until rows show.
    @MainActor private func makeHarness(restoring: Bool = false) async throws -> Harness {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebSwitchTable-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        let libraryA = try makeLibrary("A", in: container, documents: Self.documentCount)
        let defaults = disposableDefaults("SwitchTable")
        if restoring {
            // A previous launch persists A's location, as the folder panel does.
            let first = LibraryWorkspace(defaults: defaults)
            first.recoveryDirectory = container.appendingPathComponent("Recovery")
            first.open(libraryA)
            try await waitUntil("A's location persists", timeout: .seconds(10)) {
                first.snapshot != nil && !first.loading && defaults.data(forKey: "libraryLocation") != nil
            }
        }
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: disposableAutosaveName("SwitchTable"))
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        addTeardownBlock { @MainActor in
            window.contentViewController = nil
            window.close()
        }
        let harness = Harness(window: window, workspace: workspace, defaults: defaults, container: container)
        if restoring { workspace.restore() } else { workspace.open(libraryA) }
        try await waitUntil("library A opens", timeout: .seconds(10)) {
            workspace.snapshot != nil && !workspace.loading
        }
        try await waitUntil("the list realizes A's rows", timeout: .seconds(10)) {
            harness.layout()
            return harness.table.map {
                $0.numberOfRows == Self.documentCount && $0.rows(in: $0.visibleRect).length >= 4
            } == true
        }
        return harness
    }

    @MainActor func testNewLibraryWhileRowsAreVisible() async throws {
        let h = try await makeHarness()
        let created = h.container.appendingPathComponent("New Library")
        try await h.switchAndPump(to: created) { h.workspace.createLibrary(at: created) }
        XCTAssertEqual(h.workspace.documents.count, 0)
        XCTAssertNil(h.table, "an empty library shows the empty state, not the table")
    }

    @MainActor func testOpenFolderWhileRowsAreVisible() async throws {
        let h = try await makeHarness()
        let other = try makeLibrary("B", in: h.container, documents: 3)
        try await h.switchAndPump(to: other) { h.workspace.open(other) }
        XCTAssertEqual(h.workspace.documents.count, 3)
        try await waitUntil("the list realizes B's rows") {
            h.layout()
            return h.table?.numberOfRows == 3
        }
    }

    @MainActor func testSwitchAfterRestoringPersistedLocation() async throws {
        let h = try await makeHarness(restoring: true)
        let other = try makeLibrary("B", in: h.container, documents: 0)
        try await h.switchAndPump(to: other) { h.workspace.open(other) }
        XCTAssertEqual(h.workspace.documents.count, 0)
    }

    /// The narrowest form of the crash: a table update that runs while the snapshot is gone, before SwiftUI
    /// re-evaluates the list, refreshes no stale rows and realizes none.
    @MainActor func testTableUpdateWithoutSnapshotClearsRows() async throws {
        let h = try await makeHarness()
        let table = try XCTUnwrap(h.table)
        let coordinator = try XCTUnwrap(table.coordinator)
        let stale = coordinator.documents
        XCTAssertEqual(stale.count, Self.documentCount)
        let snapshot = h.workspace.snapshot
        h.workspace.snapshot = nil
        defer { h.workspace.snapshot = snapshot }
        coordinator.update(documents: stale, dateReference: Date(), makeDragProvider: nil)
        table.layoutSubtreeIfNeeded()
        XCTAssertEqual(table.numberOfRows, 0, "no rows outlive the library they came from")
        XCTAssertNil(coordinator.tableView(table, viewFor: nil, row: 0))
    }
}

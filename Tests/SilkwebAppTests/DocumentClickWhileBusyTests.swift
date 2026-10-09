import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #209: a document click while the library is busy (loading or mutating) moves the capsule on the press and keeps
/// it there; the document opens when the library is idle again, last click wins. The real library window, never
/// ordered on screen, takes plain clicks through the hit-tested row views.
final class DocumentClickWhileBusyTests: XCTestCase {
    static let folder = "Field Notes"
    static let documentCount = 8

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor private final class Harness {
        let window: NSWindow
        let workspace: LibraryWorkspace
        let root: URL
        let cleanUp: () -> Void
        private var eventNumber = 0
        init(window: NSWindow, workspace: LibraryWorkspace, root: URL, cleanUp: @escaping () -> Void) {
            self.window = window; self.workspace = workspace; self.root = root; self.cleanUp = cleanUp
        }
        var content: NSView { window.contentView! }
        var table: DocumentTableView? {
            DocumentClickWhileBusyTests.descendants(content).compactMap { $0 as? DocumentTableView }.first
        }
        var paths: [String] { workspace.documents.map(\.relativePath) }
        func url(_ path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }
        var editorURL: URL? { workspace.editor.url?.standardizedFileURL }

        func pump() async throws {
            try await Task.sleep(for: .milliseconds(1))
            content.superview?.layoutSubtreeIfNeeded()
        }

        /// The native table, its capsule and the workspace all show exactly this one document.
        func shows(_ path: String) -> Bool {
            guard let table, let row = paths.firstIndex(of: path) else { return false }
            return table.selectedRowIndexes == IndexSet(integer: row)
                && table.rowView(atRow: row, makeIfNecessary: false)?.isSelected == true
                && workspace.session.selectedDocuments == [path]
        }

        /// A plain press and release on the row, delivered to the view the press hit-tests to.
        func click(_ path: String) throws {
            let table = try XCTUnwrap(self.table)
            let row = try XCTUnwrap(paths.firstIndex(of: path))
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let now = ProcessInfo.processInfo.systemUptime
            func event(_ type: NSEvent.EventType, _ timestamp: TimeInterval) throws -> NSEvent {
                eventNumber += 1
                return try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: timestamp,
                        windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
                        pressure: type == .leftMouseUp ? 0 : 1))
            }
            let frame = try XCTUnwrap(content.superview)
            let source = try XCTUnwrap(
                frame.hitTest(frame.convert(point, from: nil)) as? DocumentRowClickView, "row source at \(point)")
            XCTAssertEqual(source.path, path)
            source.mouseDown(with: try event(.leftMouseDown, now))
            source.mouseUp(with: try event(.leftMouseUp, now + 0.01))
        }

        /// Opens `path` the ordinary way, with the library idle.
        func open(_ path: String) async throws {
            try click(path)
            try await withDeadline("navigation") { await self.workspace.waitForNavigation() }
            try await waitUntil("the editor shows \(path)") { self.editorURL == self.url(path) }
        }
    }

    @MainActor private func makeHarness() async throws -> Harness {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebBusyClick-" + UUID().uuidString)
        let root = container.appendingPathComponent("Library")
        let folder = root.appendingPathComponent(Self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for index in 0..<Self.documentCount {
            try Data("# Note \(index + 1)\n\nA few lines of text.\n".utf8).write(
                to: folder.appendingPathComponent(String(format: "Note %02d.md", index + 1)))
        }
        let suite = "Silkweb.BusyClick." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
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
        let harness = Harness(window: window, workspace: workspace, root: root.resolvingSymlinksInPath()) {
            window.contentViewController = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: container)
        }
        workspace.open(root)
        try await waitUntil("the library opens", timeout: .seconds(10)) {
            workspace.snapshot != nil && !workspace.loading
        }
        workspace.selectFolder(Self.folder)
        try await withDeadline("navigation") { await workspace.waitForNavigation() }
        try await waitUntil("the list realizes its rows", timeout: .seconds(10)) {
            harness.content.superview?.layoutSubtreeIfNeeded()
            return harness.table?.numberOfRows == Self.documentCount
        }
        return harness
    }

    /// The reported bug: a click while the library is mutating flashed the row, then the list snapped back to the
    /// open document and the click was lost. Now the capsule stays on every frame and the document opens after.
    @MainActor
    func testClickWhileMutatingKeepsTheCapsuleAndOpensWhenTheLibraryIsIdle() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let paths = h.paths
        try await h.open(paths[1])
        let openTab = try XCTUnwrap(h.workspace.activeTabID)

        h.workspace.mutating = true
        try h.click(paths[4])
        XCTAssertTrue(h.shows(paths[4]), "the press selects the row while the library is busy")
        for frame in 0..<10 {
            try await h.pump()
            XCTAssertTrue(h.shows(paths[4]), "frame \(frame): the capsule stays on the clicked row")
            XCTAssertEqual(h.editorURL, h.url(paths[1]), "frame \(frame): the editor opens nothing while busy")
        }
        // A background tab activation (e.g. a tab closing) must not override the newer click.
        h.workspace.activateTab(openTab)
        try await h.pump()
        XCTAssertTrue(h.shows(paths[4]), "a background activateTab does not move the capsule back")

        h.workspace.mutating = false
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
        try await waitUntil("the queued document opens") { h.editorURL == h.url(paths[4]) }
        XCTAssertTrue(h.shows(paths[4]))
    }

    /// Several clicks while busy: the capsule follows each one, and only the last opens.
    @MainActor
    func testLastClickWhileBusyWins() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let paths = h.paths
        try await h.open(paths[0])

        h.workspace.mutating = true
        for path in [paths[2], paths[5], paths[3]] {
            try h.click(path)
            try await h.pump()
            XCTAssertTrue(h.shows(path), "the capsule follows the click on \(path)")
        }
        h.workspace.mutating = false
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
        try await waitUntil("the last clicked document opens") { h.editorURL == h.url(paths[3]) }
        XCTAssertTrue(h.shows(paths[3]))
        let earlier: [URL?] = [h.url(paths[2]), h.url(paths[5])]
        XCTAssertFalse(
            h.workspace.tabs.contains { earlier.contains($0.editor.url?.standardizedFileURL) },
            "earlier busy clicks open nothing")
    }

    /// The queued target is kept by ID: a rename in the same mutation is followed to the new name.
    @MainActor
    func testQueuedClickFollowsARenameByID() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let paths = h.paths
        try await h.open(paths[0])

        h.workspace.mutating = true
        try h.click(paths[2])
        let engine = try LibraryMutations(root: h.root)
        let changes = try await engine.rename(paths[2], to: "Renamed.md")
        try await h.workspace.refresh(changes)
        h.workspace.mutating = false
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
        let renamed = Self.folder + "/Renamed.md"
        try await waitUntil("the renamed document opens") { h.editorURL == h.url(renamed) }
        XCTAssertEqual(h.workspace.session.selectedDocuments, [renamed])
    }

    /// A queued target moved out of the list's scope, or deleted, is dropped: the editor keeps its document.
    @MainActor
    func testQueuedClickIsDroppedWhenItsDocumentLeavesTheList() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let paths = h.paths
        try await h.open(paths[0])
        let engine = try LibraryMutations(root: h.root)

        h.workspace.mutating = true
        try h.click(paths[3])
        try await h.workspace.refresh(try await engine.move(paths[3], toFolder: ""))
        h.workspace.mutating = false
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
        for _ in 0..<5 { try await h.pump() }
        XCTAssertEqual(h.editorURL, h.url(paths[0]), "a target moved out of scope opens nothing")
        XCTAssertTrue(h.workspace.session.selectedDocuments.allSatisfy { h.paths.contains($0) })

        h.workspace.mutating = true
        try h.click(paths[5])
        try FileManager.default.removeItem(at: h.url(paths[5]))
        try await h.workspace.refresh(LibraryChangeSet(changes: []))
        h.workspace.mutating = false
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
        for _ in 0..<5 { try await h.pump() }
        XCTAssertEqual(h.editorURL, h.url(paths[0]), "a deleted target opens nothing")
        XCTAssertFalse(h.workspace.session.selectedDocuments.contains(paths[5]))
    }
}

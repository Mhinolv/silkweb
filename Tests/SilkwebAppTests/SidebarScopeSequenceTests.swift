import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #88: folder A → a document in the list → folder B moves the sidebar capsule straight to B. The real library
/// window (sidebar, list, toolbar, editor), never ordered on screen, records every selected sidebar row from the
/// B press until navigation drains, plus one more run-loop turn.
final class SidebarScopeSequenceTests: XCTestCase {
    static let folders = ["Alpha", "Beta", "Gamma"]

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor private final class Harness {
        let window: NSWindow
        let workspace: LibraryWorkspace
        let root: URL
        let cleanUp: () -> Void
        private var eventNumber = 0
        /// Sidebar rows in the order they were shown; consecutive repeats collapse.
        private(set) var sequence: [String] = []
        private var observers: [NSObjectProtocol] = []
        init(window: NSWindow, workspace: LibraryWorkspace, root: URL, cleanUp: @escaping () -> Void) {
            self.window = window; self.workspace = workspace; self.root = root; self.cleanUp = cleanUp
        }
        var content: NSView { window.contentView! }
        var outline: SidebarOutlineView? {
            SidebarScopeSequenceTests.descendants(content).compactMap { $0 as? SidebarOutlineView }.first
        }
        var table: DocumentTableView? {
            SidebarScopeSequenceTests.descendants(content).compactMap { $0 as? DocumentTableView }.first
        }
        var paths: [String] { workspace.documents.map(\.relativePath) }

        /// The selected sidebar row's folder path ("All" for All Documents, "#tag" for tags).
        var selectedRow: String {
            guard let outline, let item = outline.item(atRow: outline.selectedRow) as? FolderSidebar.Item else {
                return "none"
            }
            if let tag = item.tag { return "#" + tag.name }
            return item.folder?.relativePath ?? "All"
        }

        func record() {
            let row = selectedRow
            if sequence.last != row { sequence.append(row) }
        }

        /// Starts a fresh recording that also catches selections made and undone between display passes.
        func startRecording() throws {
            stopRecording()
            sequence = []
            let outline = try XCTUnwrap(self.outline)
            for name in [NSOutlineView.selectionDidChangeNotification, NSOutlineView.selectionIsChangingNotification] {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: outline, queue: nil) {
                        [weak self] _ in MainActor.assumeIsolated { self?.record() }
                    })
            }
        }
        func stopRecording() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
        }

        /// A display-cycle pass: lets SwiftUI commit pending updates, then lays out.
        func pump() async throws {
            try await Task.sleep(for: .milliseconds(1))
            content.superview?.layoutSubtreeIfNeeded()
            record()
        }

        /// Records until navigation drains, then through a few more run-loop turns.
        func drain() async throws {
            try await pump()
            await workspace.waitForNavigation()
            for _ in 0..<10 { try await pump() }
            await workspace.waitForNavigation()
            try await pump()
        }

        private func events(at point: NSPoint) throws -> (down: NSEvent, up: NSEvent) {
            let now = ProcessInfo.processInfo.systemUptime
            func event(_ type: NSEvent.EventType, _ timestamp: TimeInterval) throws -> NSEvent {
                eventNumber += 1
                return try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: [], timestamp: timestamp,
                        windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
                        pressure: type == .leftMouseUp ? 0 : 1))
            }
            return (try event(.leftMouseDown, now), try event(.leftMouseUp, now + 0.01))
        }

        /// A plain click on the list row through the hit-tested row view.
        func clickDocument(_ row: Int) throws {
            let table = try XCTUnwrap(self.table)
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let frame = try XCTUnwrap(content.superview)
            let source = try XCTUnwrap(
                frame.hitTest(frame.convert(point, from: nil)) as? DocumentRowClickView, "row source at \(point)")
            let (down, up) = try events(at: point)
            source.mouseDown(with: down)
            source.mouseUp(with: up)
        }

        /// A sidebar click as AppKit delivers it: the press focuses the outline, then reaches its `mouseDown`. A
        /// hidden window doesn't run AppKit's press tracking, so the row shown during the press is recorded when
        /// `mouseDown` returns, and the release then commits the clicked row as AppKit does.
        func clickSidebar(_ path: String) throws {
            let outline = try XCTUnwrap(self.outline)
            let row = (0..<outline.numberOfRows).first {
                (outline.item(atRow: $0) as? FolderSidebar.Item)?.folder?.relativePath == path
            }
            let index = try XCTUnwrap(row, "sidebar row \(path)")
            let rect = outline.rect(ofRow: index)
            let point = outline.convert(NSPoint(x: rect.maxX - 40, y: rect.midY), to: nil)
            XCTAssertEqual(outline.row(at: outline.convert(point, from: nil)), index)
            let (down, up) = try events(at: point)
            window.makeFirstResponder(outline)
            NSApp.postEvent(up, atStart: true)
            outline.mouseDown(with: down)
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
            record()
            if outline.selectedRow != index {
                outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            }
        }

        func waitForEditor(_ path: String) async throws {
            let url = root.appendingPathComponent(path).standardizedFileURL
            try await waitUntil("the editor shows \(path)", timeout: .seconds(10)) {
                content.superview?.layoutSubtreeIfNeeded()
                return workspace.editor.url?.standardizedFileURL == url
            }
        }
    }

    @MainActor private func makeHarness() async throws -> Harness {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebScopeSequence-" + UUID().uuidString)
        let root = container.appendingPathComponent("Library")
        for folder in Self.folders {
            let url = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            for index in 1...3 {
                try Data("# \(folder) \(index)\n\nNotes from the road.\n".utf8)
                    .write(to: url.appendingPathComponent("\(folder) \(index).md"))
            }
        }
        let suite = "Silkweb.ScopeSequence." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        let harness = Harness(window: window, workspace: workspace, root: root.resolvingSymlinksInPath()) {
            window.contentViewController = nil
            window.close()
            NSApp.appearance = oldAppearance
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
        try await waitUntil("the sidebar lists the folders", timeout: .seconds(10)) {
            harness.content.superview?.layoutSubtreeIfNeeded()
            return harness.outline.map { $0.numberOfRows > Self.folders.count } == true
        }
        return harness
    }

    /// Folder A, then a document, opened.
    @MainActor private func openDocumentInAlpha(_ h: Harness) async throws {
        try h.clickSidebar("Alpha")
        try await h.drain()
        XCTAssertEqual(h.workspace.session.selectedFolder, "Alpha")
        try await waitUntil("the list shows Alpha", timeout: .seconds(10)) {
            h.content.superview?.layoutSubtreeIfNeeded()
            return h.table?.numberOfRows == 3 && h.paths.allSatisfy { $0.hasPrefix("Alpha/") }
        }
        try h.clickDocument(0)
        try await h.waitForEditor(h.paths[0])
        try await h.drain()
        XCTAssertEqual(h.selectedRow, "Alpha")
    }

    @MainActor func testFolderAfterDocumentMovesStraightToTheNewFolder() async throws {
        let h = try await makeHarness()
        defer { h.stopRecording(); h.cleanUp() }
        try await openDocumentInAlpha(h)
        let opened = h.workspace.editor.url

        try h.startRecording()
        try h.clickSidebar("Beta")
        h.record()
        let outline = try XCTUnwrap(h.outline)
        let rowView = outline.rowView(atRow: outline.selectedRow, makeIfNecessary: false)
        try await h.drain()
        h.stopRecording()

        XCTAssertEqual(h.sequence, ["Beta"], "the capsule moves A → B once and never returns to A")
        XCTAssertNotNil(rowView)
        XCTAssert(
            outline.rowView(atRow: outline.selectedRow, makeIfNecessary: false) === rowView,
            "the completed switch leaves the outline alone: no reload")
        XCTAssertEqual(h.workspace.session.selectedFolder, "Beta")
        XCTAssertEqual(h.workspace.session.selectedDocuments, [])
        XCTAssertEqual(h.workspace.editor.url, opened, "the editor keeps the opened document")
    }

    /// The B click lands while the document's editor is still opening.
    @MainActor func testFolderDuringDocumentOpenMovesStraightToTheNewFolder() async throws {
        let h = try await makeHarness()
        defer { h.stopRecording(); h.cleanUp() }
        try await openDocumentInAlpha(h)

        try h.clickDocument(1)
        try h.startRecording()
        try h.clickSidebar("Beta")
        h.record()
        try h.clickSidebar("Gamma")
        h.record()
        try await h.drain()
        h.stopRecording()

        XCTAssertEqual(h.sequence, ["Beta", "Gamma"], "rapid clicks follow each folder and never revisit one")
        XCTAssertEqual(h.workspace.session.selectedFolder, "Gamma")
    }

    /// A breadcrumb crumb changes scope through `selectFolder`; the sidebar follows with one move.
    @MainActor func testBreadcrumbScopeAfterDocumentMovesStraightToTheNewFolder() async throws {
        let h = try await makeHarness()
        defer { h.stopRecording(); h.cleanUp() }
        try await openDocumentInAlpha(h)

        try h.startRecording()
        h.workspace.selectFolder("Beta")
        try await h.drain()
        h.stopRecording()

        XCTAssertEqual(h.sequence, ["Beta"])
        XCTAssertEqual(h.workspace.session.selectedFolder, "Beta")
    }

    /// A refused switch is the only case that moves the capsule back: once, B → A.
    @MainActor func testRefusedFolderSwitchMovesBackOnce() async throws {
        let h = try await makeHarness()
        defer { h.stopRecording(); h.cleanUp() }
        try await openDocumentInAlpha(h)
        let document = h.workspace.session.selectedDocuments

        try h.startRecording()
        h.workspace.mutating = true
        try h.clickSidebar("Beta")
        h.record()
        try await h.drain()
        h.workspace.mutating = false
        try await h.drain()
        h.stopRecording()

        XCTAssertEqual(h.sequence, ["Beta", "Alpha"], "a refused switch moves back once")
        XCTAssertEqual(h.workspace.session.selectedFolder, "Alpha")
        XCTAssertEqual(h.workspace.session.selectedDocuments, document)
    }
}

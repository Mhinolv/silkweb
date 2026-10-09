import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #204: an agent update reaches the open app quietly. A clean open Document reloads in place (focus, tab and
/// scroll kept, caret clamped, no undo entry); a Document with unsaved changes is refused in the helper and
/// neither disk nor the buffer changes. Agent Activity shows the update.
final class AgentUpdateWorkspaceTests: XCTestCase {
    static let handoffs = "Memory/Projects/Silkweb/Handoffs"
    /// 2026-10-07 09:30:00 UTC.
    static let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private static func grant(_ root: URL) -> AgentGrant {
        AgentGrant(project: "Silkweb", library: LibraryLocation(path: root.path), access: .readCreateUpdate)
    }

    private static func create(_ title: String, in root: URL, body: String) throws -> AgentCreateResult {
        var service = AgentCreateService(
            library: root, grantId: "Silkweb", scope: try AgentScope(grant: grant(root)),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        let date = fixedDate
        service.now = { date }
        return try service.create(
            AgentCreateRequest(
                idempotencyKey: title, type: "handoff", title: title, body: body, agent: "claude-code", session: "s-1"))
    }

    private static func update(_ path: String, in root: URL, key: String, body: String) throws -> AgentUpdateResult {
        var service = AgentUpdateService(
            library: root, grantId: "Silkweb", scope: try AgentScope(grant: grant(root)),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes, maxReadBytes: AgentGrantLimits.defaultMaxReadBytes)
        let date = fixedDate.addingTimeInterval(600)
        service.now = { date }
        let revision = AgentCreateService.digest(try Data(contentsOf: root.appendingPathComponent(path)))
        return try service.update(
            AgentUpdateRequest(
                idempotencyKey: key, path: path, expectedRevision: revision, body: body, agent: "claude-code",
                session: "s-2"))
    }

    func testHistoryEventsReloadReceiptsOnly() {
        let root = "/Volumes/Notes/Library"
        let change = LibraryWatcher.classify([root + "/.silkweb/agent-history/ID/v0 x.md"], root: root)
        XCTAssertEqual([change.library, change.receipts], [false, true])
        for name in ["editing/abc.lock", "agent-update-staging/x.md", "agent-historyx/a"] {
            let other = LibraryWatcher.classify([root + "/.silkweb/" + name], root: root)
            XCTAssertEqual([other.library, other.receipts], [false, false], name)
        }
    }

    /// GUI rule: the real library window, never ordered on screen. Load and resize, then an agent update to
    /// the open, focused Document, then an update refused while the buffer has unsaved changes.
    @MainActor
    func testOffscreenUpdateReloadsACleanDocumentInPlaceAndRefusesADirtyOne() async throws {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebAgentUpdate-" + UUID().uuidString)
        let unresolved = container.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: unresolved.appendingPathComponent(Self.handoffs), withIntermediateDirectories: true)
        let root = unresolved.resolvingSymlinksInPath()
        let long = (1...80).map { "Line \($0) of the first handoff." }.joined(separator: "\n")
        let created = try Self.create("Next steps", in: root, body: long)
        let path = try XCTUnwrap(created.path)
        let documentURL = root.appendingPathComponent(path)

        let suite = "Silkweb.AgentUpdate." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
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
        defer {
            window.contentViewController = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: container)
        }
        let content = try XCTUnwrap(window.contentView)
        func pump() async throws {
            try await Task.sleep(for: .milliseconds(1))
            content.superview?.layoutSubtreeIfNeeded()
        }
        func resizeSweep() async throws {
            for width: CGFloat in [900, 2400, 1100, 1400] {
                window.setContentSize(NSSize(width: width, height: width == 900 ? 560 : 900))
                try await pump()
            }
        }

        workspace.open(root)
        try await waitUntil("the library opens", timeout: .seconds(10)) {
            workspace.snapshot != nil && !workspace.loading
        }
        workspace.navigate(folder: Self.handoffs, documents: [path])
        await workspace.waitForNavigation()
        try await waitUntil("the editor shows the agent Document", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return workspace.editor.url?.standardizedFileURL == documentURL.standardizedFileURL
                && Self.descendants(content).contains { $0 is PlainMarkdownTextView }
        }
        let editorView = try XCTUnwrap(
            Self.descendants(content).compactMap { $0 as? PlainMarkdownTextView }.first {
                $0.string == workspace.editor.text
            })
        XCTAssertTrue(window.makeFirstResponder(editorView))
        try await resizeSweep()
        let scroll = try XCTUnwrap(editorView.enclosingScrollView)
        // The caret near the end of the long text; the update makes it much shorter.
        let caret = (editorView.string as NSString).length - 5
        editorView.setSelectedRange(NSRange(location: caret, length: 0))
        workspace.editor.selection = editorView.selectedRange()
        let tabs = workspace.tabs.map(\.id)
        let activeTab = workspace.activeTabID
        let session = workspace.session

        // A clean open Document: the update applies and the editor reloads in place.
        let short = "# Next steps\n\nShip the update.\n"
        let first = try Self.update(path, in: root, key: "u1", body: short)
        XCTAssertEqual(first.outcome, .updated)
        await workspace.reconcileFinderChanges()
        await workspace.reloadAgentActivity()
        let disk = try String(contentsOf: documentURL, encoding: .utf8)
        try await waitUntil("the editor reloads the update", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return editorView.string == disk
        }
        XCTAssertEqual(workspace.editor.text, disk)
        XCTAssertEqual(workspace.editor.state, .clean)
        XCTAssertTrue(window.firstResponder === editorView, "focus left the editor")
        XCTAssertEqual(workspace.tabs.map(\.id), tabs)
        XCTAssertEqual(workspace.activeTabID, activeTab)
        XCTAssertEqual(workspace.session, session, "the selection or scope moved")
        let length = (disk as NSString).length
        XCTAssertEqual(editorView.selectedRange(), NSRange(location: length, length: 0), "the caret is clamped")
        XCTAssertFalse(editorView.undoManager?.canUndo ?? false, "an update adds no undo entry")
        XCTAssertGreaterThanOrEqual(scroll.contentView.bounds.origin.y, 0)
        XCTAssertTrue(workspace.agentEntries.first?.isUpdate == true, "Agent Activity shows the update")
        try await resizeSweep()

        // Unsaved changes in the editor: the helper refuses, and nothing changes.
        workspace.editor.edit(disk + "Owner typing.")
        try await waitUntil("the editing marker is held", timeout: .seconds(10)) {
            DocumentEditingMarker.isHeld(library: root, relativePath: path)
        }
        let before = try Data(contentsOf: documentURL)
        XCTAssertThrowsError(try Self.update(path, in: root, key: "u2", body: "Agent again.")) { error in
            XCTAssertEqual((error as? AgentAccessError)?.code, "document_has_unsaved_changes")
        }
        XCTAssertEqual(try Data(contentsOf: documentURL), before, "disk is unchanged")
        XCTAssertEqual(workspace.editor.text, disk + "Owner typing.", "the buffer is unchanged")
        XCTAssertTrue(window.firstResponder === editorView)
        try await resizeSweep()
    }
}

import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #139: what the owner sees while agents write. Unsaved human text in the open editor survives agent creates,
/// retries, a real external edit, a relaunch and a failed save, through the real offscreen library window.
/// Background agent writes never announce anything; save failures and conflicts announce once per state.
@MainActor
final class AgentQualificationWorkspaceTests: XCTestCase {
    static let progress = "Memory/Projects/Silkweb/Progress"
    static let draft = progress + "/Owner draft.md"
    static let original = "# Owner draft\n\nWritten by a person."
    /// 2026-10-07 09:30:00 UTC.
    static let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    private var container: URL!
    private var root: URL!
    private var recovery: URL { container.appendingPathComponent("Recovery") }
    private var announcements: [String] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebAgentQualification-" + UUID().uuidString)
        let library = container.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(Self.progress), withIntermediateDirectories: true)
        try Data(Self.original.utf8).write(to: library.appendingPathComponent(Self.draft))
        root = library.resolvingSymlinksInPath()
        announcements = []
    }

    override func tearDown() async throws {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(Self.progress).path)
        try? FileManager.default.removeItem(at: container)
    }

    private func url(_ path: String) -> URL { root.appendingPathComponent(path) }
    private func disk(_ path: String = draft) throws -> String { try String(contentsOf: url(path), encoding: .utf8) }

    private func create(_ title: String, key: String? = nil, minutes: Double = 0) throws -> AgentCreateResult {
        let grant = AgentGrant(project: "Silkweb", library: LibraryLocation(path: root.path))
        var service = AgentCreateService(
            library: root, grantId: "Silkweb", scope: try AgentScope(grant: grant),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        let date = Self.fixedDate.addingTimeInterval(minutes * 60)
        service.now = { date }
        service.timeZone = TimeZone(identifier: "UTC")!
        return try service.create(
            AgentCreateRequest(
                idempotencyKey: key ?? title, type: "progress", title: title, body: "Objective: \(title).",
                agent: "codex", session: "s-1"))
    }

    /// The real library window, never ordered on screen.
    @MainActor private final class Host {
        let workspace: LibraryWorkspace
        let window: NSWindow
        let suite: String
        init(workspace: LibraryWorkspace, window: NSWindow, suite: String) {
            self.workspace = workspace
            self.window = window
            self.suite = suite
        }
        var content: NSView { window.contentView! }
        var views: [NSView] { Self.descendants(content) }
        var table: DocumentTableView? { views.compactMap { $0 as? DocumentTableView }.first }
        var editorView: PlainMarkdownTextView? {
            views.compactMap { $0 as? PlainMarkdownTextView }.first { $0.string == workspace.editor.text }
        }
        /// Accessibility labels and values: buttons have labels, static text has values.
        var labels: [String] {
            StatusBarCountsTests.accessibilityTree(content).flatMap {
                [StatusBarCountsTests.label($0), StatusBarCountsTests.value($0)].compactMap { $0 }
            }
        }
        static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func pump() async throws {
            for _ in 0..<3 {
                content.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        func resizeSweep() async throws {
            for width: CGFloat in [900, 2400, 1100, 1400] {
                window.setContentSize(NSSize(width: width, height: width == 900 ? 560 : 900))
                try await pump()
            }
        }
        func close() {
            StatusBarCountsTests.exposeAccessibility(false)
            window.contentViewController = nil
            window.close()
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    /// Opens the Library in an offscreen window and waits for the editor to show `path` (opened, or restored).
    private func openWindow(selecting path: String? = draft) async throws -> Host {
        let suite = "Silkweb.AgentQualification." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.recoveryDirectory = recovery
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
        let host = Host(workspace: workspace, window: window, suite: suite)
        StatusBarCountsTests.exposeAccessibility(true)
        workspace.open(root)
        try await waitUntil("the library opens", timeout: .seconds(10)) {
            workspace.snapshot != nil && !workspace.loading
        }
        if let path, workspace.editor.url == nil {
            workspace.navigate(folder: Self.progress, documents: [path])
            await workspace.waitForNavigation()
        }
        let target = path.map(url)?.standardizedFileURL
        try await waitUntil("the editor shows the owner's Document", timeout: .seconds(10)) {
            host.content.superview?.layoutSubtreeIfNeeded()
            return workspace.editor.url?.standardizedFileURL == target && host.editorView != nil
        }
        workspace.editor.didAnnounce = { [weak self] in self?.announcements.append($0) }
        return host
    }

    /// The window's own watcher may be reconciling already, which makes another call a no-op; keep asking.
    private func reconcile(_ workspace: LibraryWorkspace, until condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            await workspace.reconcileFinderChanges()
            await workspace.reloadAgentActivity()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "the window never caught up with the change")
    }

    private func label(_ workspace: LibraryWorkspace) -> DocumentStatusBar.SaveLabel {
        DocumentStatusBar.SaveLabel(state: workspace.editor.state, readOnly: workspace.editor.readOnly)
    }

    // MARK: Dirty buffer

    /// Unsaved text, then agent creates and a same-key retry in the same Folder, then a real external edit of
    /// the open file. The buffer, caret, selection, tabs and focus never move; the list stays Edited; the new
    /// rows insert unselected; the external edit raises today's conflict banner once.
    func testUnsavedTextSurvivesAgentCreatesRetriesAndAnExternalEdit() async throws {
        let host = try await openWindow()
        defer { host.close() }
        let workspace = host.workspace
        let editorView = try XCTUnwrap(host.editorView)
        XCTAssertTrue(host.window.makeFirstResponder(editorView))
        try await host.resizeSweep()

        // Typing through the real text view; autosave is at least a second away.
        let end = (editorView.string as NSString).length
        editorView.setSelectedRange(NSRange(location: end, length: 0))
        editorView.insertText(" Unsaved words.", replacementRange: NSRange(location: end, length: 0))
        let typed = Self.original + " Unsaved words."
        XCTAssertEqual(workspace.editor.text, typed)
        let caret = editorView.selectedRange()
        let tabs = workspace.tabs.map(\.id)
        let activeTab = workspace.activeTabID
        let selection = workspace.session.selectedDocuments

        let first = try create("Agent checkpoint")
        let replay = try create("Agent checkpoint")
        let second = try create("Second checkpoint", minutes: 5)
        XCTAssertTrue(replay.replayed)
        // Another Silkweb process holds the gate, so the autosave waits (Edited) while the window catches up.
        let busy = try XCTUnwrap(try LibraryGate(root: root).tryAcquire())
        var released = false
        defer { if !released { busy.release() } }
        try await reconcile(workspace) { workspace.documents.count == 3 && workspace.agentEntries.count == 2 }
        try await host.pump()

        XCTAssertEqual(workspace.editor.text, typed)
        XCTAssertEqual(editorView.string, typed)
        XCTAssertEqual(editorView.selectedRange(), caret, "the caret moved")
        XCTAssertTrue(host.window.firstResponder === editorView, "focus left the editor")
        XCTAssertEqual(workspace.tabs.map(\.id), tabs)
        XCTAssertEqual(workspace.activeTabID, activeTab)
        XCTAssertEqual(workspace.session.selectedDocuments, selection, "an agent Document was selected")
        XCTAssertEqual(label(workspace), .edited)
        XCTAssertTrue(host.window.isDocumentEdited, "the window's edited dot is on")
        XCTAssertEqual(try disk(), Self.original, "nothing reached the owner's file yet")
        let rows = workspace.documents.map(\.relativePath)
        XCTAssertEqual(Set(rows), [Self.draft, try XCTUnwrap(first.path), try XCTUnwrap(second.path)])
        XCTAssertEqual(rows.filter { $0.hasSuffix(" 2.md") }, [], "a retry never adds a row")
        let selectedRow = try XCTUnwrap(rows.firstIndex(of: Self.draft))
        XCTAssertEqual(host.table?.selectedRowIndexes, IndexSet(integer: selectedRow))
        XCTAssertEqual(workspace.agentEntries.count, 2, "Agent Activity counts the receipts")
        XCTAssertNil(workspace.editor.banner)
        XCTAssertNil(workspace.indexRecovery, "no recovery strip")
        XCTAssertNil(workspace.unreadableRecoveryFile)
        XCTAssertEqual(announcements, [], "a background agent write announced something")
        try await host.resizeSweep()

        // The other process lets go: the waiting autosave commits the owner's text, and only that.
        busy.release()
        released = true
        try await waitUntil("the owner's text saves", timeout: .seconds(10)) { workspace.editor.state == .clean }
        XCTAssertEqual(try disk(), typed)
        XCTAssertEqual(label(workspace), .saved)
        XCTAssertEqual(try disk(try XCTUnwrap(first.path)).contains("Objective: Agent checkpoint."), true)

        // A real external edit to the open file while there's unsaved text: the conflict banner, never a reload.
        let end2 = (editorView.string as NSString).length
        editorView.insertText(" More.", replacementRange: NSRange(location: end2, length: 0))
        let unsaved = typed + " More."
        try Data("Changed in another app.".utf8).write(to: url(Self.draft))
        try await reconcile(workspace) { workspace.editor.externalConflict }
        try await host.pump()
        XCTAssertTrue(workspace.editor.externalConflict)
        XCTAssertEqual(workspace.editor.text, unsaved, "the buffer was replaced")
        XCTAssertEqual(editorView.string, unsaved)
        XCTAssertEqual(
            workspace.editor.banner, "“Owner draft” was changed outside Silkweb while you were editing.")
        XCTAssertEqual(label(workspace), .notSaved)
        XCTAssertTrue(host.labels.contains("Keep My Version"), "\(host.labels)")
        XCTAssertTrue(host.labels.contains("Use Disk Version"))
        XCTAssertTrue(host.labels.contains("Compare…"))
        XCTAssertEqual(try disk(), "Changed in another app.", "the other app's text stays on disk")
        // An agent create and more watcher ticks don't announce the same conflict again.
        _ = try create("Third checkpoint", minutes: 10)
        try await reconcile(workspace) { workspace.documents.count == 4 }
        for _ in 0..<3 { await workspace.reconcileFinderChanges() }
        XCTAssertTrue(workspace.editor.externalConflict)
        XCTAssertEqual(workspace.editor.text, unsaved)
        XCTAssertEqual(announcements, [workspace.editor.banner!], "the conflict announces once")
        try await host.resizeSweep()
    }

    // MARK: Relaunch

    /// Silkweb quit with unsaved text (a recovery draft) and agents kept creating while it was closed and after
    /// it reopened. The recovery banner shows the owner's text; the agent Documents arrive without touching it.
    func testRecoveredTextSurvivesAgentCreatesAcrossARelaunch() async throws {
        // The previous launch: unsaved text kept as a recovery draft on quit.
        let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: recovery)
        _ = try await coordinator.open(url(Self.draft))
        let recovered = Self.original + " Typed before quitting."
        try await coordinator.edit(recovered, at: url(Self.draft))
        try await coordinator.preserveUnsavedDrafts()
        // The app is closed: an agent creates in the same Folder.
        let whileClosed = try create("While closed")

        let host = try await openWindow()
        defer { host.close() }
        let workspace = host.workspace
        XCTAssertTrue(workspace.editor.recovered)
        XCTAssertEqual(workspace.editor.text, recovered)
        XCTAssertEqual(workspace.editor.banner, "Silkweb recovered unsaved changes to this document.")
        XCTAssertTrue(host.labels.contains("Keep Recovered Text"), "\(host.labels)")
        XCTAssertEqual(label(workspace), .edited)
        XCTAssertTrue(workspace.documents.contains { $0.relativePath == whileClosed.path })
        let editorView = try XCTUnwrap(host.editorView)
        XCTAssertTrue(host.window.makeFirstResponder(editorView))
        editorView.setSelectedRange(NSRange(location: 4, length: 3))
        try await host.resizeSweep()
        let selection = workspace.session.selectedDocuments
        let tabs = workspace.tabs.map(\.id)

        // Agents keep creating while the recovery banner is up: nothing autosaves and nothing moves.
        let afterOpen = try create("After reopening", minutes: 5)
        _ = try create("After reopening", minutes: 5)
        try await reconcile(workspace) { workspace.agentEntries.count == 2 }
        try await Task.sleep(for: .milliseconds(1300))
        try await host.pump()
        XCTAssertTrue(workspace.editor.recovered)
        XCTAssertEqual(workspace.editor.text, recovered)
        XCTAssertEqual(editorView.selectedRange(), NSRange(location: 4, length: 3))
        XCTAssertTrue(host.window.firstResponder === editorView)
        XCTAssertEqual(workspace.session.selectedDocuments, selection)
        XCTAssertEqual(workspace.tabs.map(\.id), tabs)
        XCTAssertEqual(try disk(), Self.original, "the recovered text waits for Keep")
        XCTAssertEqual(
            workspace.documents.filter { $0.relativePath.hasPrefix(Self.progress + "/2026") }.count, 2,
            "one row per create")
        XCTAssertTrue(workspace.documents.contains { $0.relativePath == afterOpen.path })
        XCTAssertEqual(workspace.agentEntries.count, 2)
        XCTAssertEqual(announcements, [], "agent writes announced something")

        workspace.editor.keepRecovery()
        try await waitUntil("the recovered text saves", timeout: .seconds(10)) { workspace.editor.state == .clean }
        XCTAssertEqual(try disk(), recovered)
    }

    // MARK: Save failure

    /// The owner's Folder becomes unwritable: autosave fails with today's banner and detail, the status is
    /// Not Saved, the text stays, and each failed attempt announces once. Try Again saves once it's writable.
    func testPermissionDeniedSaveKeepsTextWithTheBannerAndAnnouncesOncePerAttempt() async throws {
        guard geteuid() != 0 else { throw XCTSkip("root ignores Folder permissions") }
        let host = try await openWindow()
        defer { host.close() }
        let workspace = host.workspace
        let editorView = try XCTUnwrap(host.editorView)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: url(Self.progress).path)
        let end = (editorView.string as NSString).length
        editorView.insertText(" Unsaved words.", replacementRange: NSRange(location: end, length: 0))
        let typed = Self.original + " Unsaved words."
        try await waitUntil("the autosave fails", timeout: .seconds(10)) {
            if case .failed = workspace.editor.state { return true }
            return false
        }
        try await host.pump()
        guard case .failed(let failure, _) = workspace.editor.state else { return XCTFail("not a failure") }
        XCTAssertEqual(failure.reason, .permission)
        XCTAssertTrue(
            failure.localizedDescription.hasPrefix("You don’t have permission to write to “Progress”."),
            failure.localizedDescription)
        let banner = "Silkweb couldn’t save “Owner draft”. Your text is safe in this window."
        XCTAssertEqual(workspace.editor.banner, banner)
        XCTAssertTrue(host.labels.contains(banner), "\(host.labels)")
        XCTAssertTrue(host.labels.contains(failure.localizedDescription))
        XCTAssertEqual(label(workspace), .notSaved)
        XCTAssertEqual(workspace.editor.text, typed)
        XCTAssertEqual(try disk(), Self.original)
        XCTAssertEqual(announcements, [banner], "the failure announces once")
        try await host.resizeSweep()

        // Try Again while it's still read-only: one more failed attempt, one more announcement.
        _ = await workspace.editor.flush()
        try await host.pump()
        XCTAssertEqual(announcements, [banner, banner], "Try Again announces its failure once")
        XCTAssertEqual(workspace.editor.text, typed)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url(Self.progress).path)
        let saved = await workspace.editor.flush()
        XCTAssertTrue(saved)
        XCTAssertEqual(label(workspace), .saved)
        XCTAssertEqual(try disk(), typed)
        XCTAssertNil(workspace.editor.banner)
    }

    // MARK: Interrupted publication

    /// A helper crashed mid-publication while Silkweb was closed. Opening the Library shows no recovery strip,
    /// no alert and nothing from `.silkweb/`; the published Document is one ordinary row.
    func testInterruptedPublicationOpensSilently() async throws {
        let grant = AgentGrant(project: "Silkweb", library: LibraryLocation(path: root.path))
        struct Crash: Error {}
        for (title, step) in [("Never published", AgentCreateService.Step.intent), ("Published", .published)] {
            var service = AgentCreateService(
                library: root, grantId: "Silkweb", scope: try AgentScope(grant: grant),
                maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
            service.fault = { if $0 == step { throw Crash() } }
            XCTAssertThrowsError(
                try service.create(
                    AgentCreateRequest(
                        idempotencyKey: title, type: "handoff", title: title, body: "Body.", agent: "codex",
                        session: "s")))
        }
        let host = try await openWindow()
        defer { host.close() }
        let workspace = host.workspace
        try await host.resizeSweep()
        XCTAssertNil(workspace.indexRecovery)
        XCTAssertNil(workspace.unreadableRecoveryFile)
        XCTAssertNil(workspace.error)
        XCTAssertNil(workspace.editor.banner)
        let all = workspace.snapshot?.documents.map(\.relativePath) ?? []
        XCTAssertEqual(all.sorted(), [Self.draft, "Memory/Projects/Silkweb/Handoffs/Published.md"].sorted())
        XCTAssertFalse(workspace.snapshot?.folders.contains { $0.relativePath.contains(".silkweb") } ?? true)
        XCTAssertEqual(workspace.agentEntries, [], "no receipt yet")
        // #230: the helper's interrupted create isn't “outside Silkweb” (its intent is still staged); only the
        // owner draft this fixture wrote straight to disk is, and that row arrives quietly.
        XCTAssertEqual(workspace.outsideChanges.map(\.document.relativePath), [Self.draft])
        XCTAssertEqual(announcements, [])
    }
}

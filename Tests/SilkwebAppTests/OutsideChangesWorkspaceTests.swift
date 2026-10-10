import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #230: Library writes that bypassed the helper show in Agent Activity as “Added outside Silkweb” or “Changed
/// outside Silkweb”, quietly; Silkweb's own creates and saves and the owner's edits to known Documents never do.
@MainActor
final class OutsideChangesWorkspaceTests: XCTestCase {
    static let project = "Memory/Projects/Silkweb"
    /// The reported repro: the project's top level is outside the default create folders.
    static let overview = project + "/Silkweb Overview.md"
    /// 2026-10-07 09:30:00 UTC.
    static let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    private var container: URL!
    private var root: URL!
    private var suites: [String] = []
    private var seconds: TimeInterval = 0

    override func setUp() async throws {
        _ = NSApplication.shared
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebOutsideChanges-" + UUID().uuidString)
        let library = container.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(Self.project + "/Progress"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("# Human\n\nWritten by a person.\n".utf8).write(to: library.appendingPathComponent("Notes/Human.md"))
        root = library.resolvingSymlinksInPath()
        suites = []
        seconds = 0
    }

    override func tearDown() async throws {
        for suite in suites {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        try? FileManager.default.removeItem(at: container)
    }

    /// Writes as another app (or an agent's own file tool) would, each time with a later modification date.
    private func write(_ text: String, to path: String) throws {
        let url = root.appendingPathComponent(path)
        try Data(text.utf8).write(to: url)
        seconds += 60
        try FileManager.default.setAttributes(
            [.modificationDate: Self.fixedDate.addingTimeInterval(seconds)], ofItemAtPath: url.path)
    }

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func create(_ title: String) throws -> String {
        let grant = AgentGrant(project: "Silkweb", library: LibraryLocation(path: root.path))
        var service = AgentCreateService(
            library: root, grantId: "Silkweb", scope: try AgentScope(grant: grant),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        service.now = { Self.fixedDate }
        service.timeZone = TimeZone(identifier: "UTC")!
        return try XCTUnwrap(
            service.create(
                AgentCreateRequest(
                    idempotencyKey: title, type: "progress", title: title, body: "Objective: \(title).",
                    agent: "claude-code", session: "s-1")
            ).path)
    }

    private func makeWorkspace() throws -> LibraryWorkspace {
        let suite = "Silkweb.OutsideChanges." + UUID().uuidString
        suites.append(suite)
        let workspace = LibraryWorkspace(
            defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), columnAutosaveName: suite)
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        return workspace
    }

    /// Opens the Library the way the app does: index, receipts, ledger and watcher.
    private func open(_ workspace: LibraryWorkspace? = nil) async throws -> LibraryWorkspace {
        let workspace = try workspace ?? makeWorkspace()
        workspace.open(root)
        try await waitUntil("the library opens", timeout: .seconds(10)) {
            workspace.snapshot != nil && !workspace.loading
        }
        return workspace
    }

    /// The workspace's own watcher may be reconciling already, which makes another call a no-op; keep asking.
    private func reconcile(_ workspace: LibraryWorkspace, until condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            await workspace.reconcileFinderChanges()
            await workspace.reloadAgentActivity()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(condition(), "the workspace never caught up with the change")
    }

    private func flagged(_ workspace: LibraryWorkspace) -> [String: OutsideChangeKind] {
        Dictionary(uniqueKeysWithValues: workspace.outsideChanges.map { ($0.document.relativePath, $0.kind) })
    }

    // MARK: Regression

    /// #230 repro: an agent wrote the project overview with its own file tool instead of `memory_create`. There's no
    /// receipt, and before #230 Agent Activity (receipt-only) never showed it. It must show after opening the Library
    /// and again after a relaunch (a fresh window on the same Library).
    func testADirectWriteUnderMemoryIsVisibleInAgentActivityAfterReopening() async throws {
        try write("# Silkweb overview\n\nWritten without the helper.\n", to: Self.overview)
        for launch in ["open", "relaunch"] {
            let workspace = try await open()
            XCTAssertTrue(workspace.hasAgentActivity, "\(launch): the direct write must make Agent Activity show")
            workspace.selectAgentActivity()
            await workspace.waitForNavigation()
            XCTAssertTrue(workspace.agentScope, launch)
            XCTAssertEqual(workspace.documents.map(\.relativePath), [Self.overview], launch)
            await workspace.releaseLibrary()
        }
    }

    // MARK: Detection

    /// A direct write while the Library is open arrives through the watcher's rescan, with the receipts reread; the
    /// helper's own create in the same batch is never flagged, whichever lands first.
    func testWritesWhileOpenArriveQuietlyAndHelperCreatesAreNeverFlagged() async throws {
        let workspace = try await open()
        XCTAssertEqual(workspace.outsideChanges, [])
        XCTAssertFalse(workspace.hasAgentActivity)
        let session = workspace.session
        let helper = try create("Helper spike")
        try write("# Silkweb overview\n", to: Self.overview)
        // The Document reaches the scan before its receipt is reloaded: the reconcile rereads the receipts.
        try await reconcile(workspace) { workspace.outsideChanges.count == 1 && workspace.agentEntries.count == 1 }
        XCTAssertEqual(flagged(workspace), [Self.overview: .added])
        XCTAssertEqual(workspace.session, session, "arrival moved the selection or scope")
        XCTAssertEqual(workspace.agentActivityCount, 2)
        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        XCTAssertEqual(Set(workspace.documents.map(\.relativePath)), [Self.overview, helper])
        // All Agents ▾: one agent shows its receipts only; Outside Silkweb shows the flagged Documents only.
        workspace.agentFilter = "claude-code"
        XCTAssertEqual(workspace.documents.map(\.relativePath), [helper])
        workspace.outsideFilter = true
        XCTAssertNil(workspace.agentFilter)
        XCTAssertEqual(workspace.documents.map(\.relativePath), [Self.overview])
        workspace.agentFilter = "claude-code"
        XCTAssertFalse(workspace.outsideFilter)
        workspace.agentFilter = nil
        // Detection wrote only its ledger, and only when Silkweb accounted for something: nothing yet.
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".silkweb/" + OutsideChangeLedger.fileName).path))
        XCTAssertEqual(try text(Self.overview), "# Silkweb overview\n", "detection never touches the Document")
    }

    /// Silkweb's own New Document and saves, unsaved editor text, and the owner's later edit of a known Document in
    /// another app are never flagged. An agent envelope edited outside Silkweb is, until the owner keeps it.
    func testSilkwebsOwnWritesAndTheOwnersExternalEditsAreNotFlaggedButEnvelopeEditsAre() async throws {
        let helper = try create("Helper spike")
        let workspace = try await open()
        XCTAssertEqual(workspace.outsideChanges, [])

        // New Document in Memory, as File ▸ New Document does it.
        let engine = try LibraryMutations(root: root)
        let changes = try await engine.createDocument(named: "Owner plan.md", in: Self.project)
        try await workspace.refresh(changes)
        await workspace.waitForOutsideDetection()
        let plan = Self.project + "/Owner plan.md"
        XCTAssertEqual(workspace.outsideChanges, [], "Silkweb's own New Document was flagged")
        // The owner edits it in another app (no envelope): still never flagged.
        try write("# Owner plan\n\nEdited in VS Code.\n", to: plan)
        try await reconcile(workspace) {
            workspace.snapshot?.documents.first { $0.relativePath == plan }?.modified
                == Self.fixedDate.addingTimeInterval(seconds)
        }
        XCTAssertEqual(workspace.outsideChanges, [], "an owner's external edit was flagged")

        // The agent's Document, edited in Silkweb: unsaved text changes nothing on disk, and the save is Silkweb's.
        workspace.navigate(folder: Self.project + "/Progress", documents: [helper])
        await workspace.waitForNavigation()
        try await waitUntil("the agent Document opens") { workspace.editor.url?.path.hasSuffix(helper) == true }
        workspace.editor.edit(workspace.editor.text + "\nOwner line.\n")
        await workspace.reconcileFinderChanges()
        XCTAssertEqual(workspace.outsideChanges, [], "unsaved text was flagged")
        let saved = await workspace.editor.flush()
        XCTAssertTrue(saved)
        let digest = AgentCreateService.digest(Data(try text(helper).utf8))
        let helperID = try XCTUnwrap(workspace.snapshot?.metadata.IDsByPath[helper])
        try await waitUntil("Silkweb records its save") { workspace.outsideLedger?.digest(for: helperID) == digest }
        let savedDate = try root.appendingPathComponent(helper).resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        try await reconcile(workspace) {
            workspace.snapshot?.documents.first { $0.relativePath == helper }?.modified == savedDate
        }
        await workspace.waitForOutsideDetection()
        XCTAssertEqual(workspace.outsideChanges, [], "a save in Silkweb was flagged")

        // Edited outside Silkweb with its envelope kept: changed outside Silkweb, receipt or not.
        try write(try text(helper) + "\nAgent line written directly.\n", to: helper)
        try await reconcile(workspace) { !workspace.outsideChanges.isEmpty }
        XCTAssertEqual(flagged(workspace), [helper: .changed])
        XCTAssertEqual(workspace.outsideChanges.first?.hasReceipt, true)

        // Keep: the flag clears, the ledger is saved, and a relaunch agrees.
        await workspace.keepOutsideChanges([helper])
        XCTAssertEqual(workspace.outsideChanges, [])
        let ledger = try OutsideChangeLedger.load(root: root)
        XCTAssertEqual(ledger.digest(for: helperID), AgentCreateService.digest(Data(try text(helper).utf8)))
        await workspace.releaseLibrary()
        let relaunched = try await open()
        XCTAssertEqual(relaunched.outsideChanges, [], "a kept change came back after a relaunch")
        // It comes back only when the file changes again.
        try write(try text(helper) + "\nAnother direct line.\n", to: helper)
        try await reconcile(relaunched) { !relaunched.outsideChanges.isEmpty }
        XCTAssertEqual(flagged(relaunched), [helper: .changed])
    }

    /// Files saved by earlier builds still load: a Library with receipts and no ledger opens, an envelope-only claim
    /// under Memory shows as added once, and Keep on a plain Document stops flagging it for good.
    func testALibraryWithoutALedgerOpensAndKeepStopsFlaggingAPlainDocument() async throws {
        _ = try create("Helper spike")
        try write("# Silkweb overview\n", to: Self.overview)
        let workspace = try await open()
        XCTAssertEqual(flagged(workspace), [Self.overview: .added])
        XCTAssertEqual(workspace.agentEntries.count, 1)
        // The row's context menu offers Keep for the flagged Document only.
        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        XCTAssertEqual(workspace.outsidePaths(Self.overview), [Self.overview])
        await workspace.keepOutsideChanges([Self.overview])
        XCTAssertEqual(workspace.outsideChanges, [])
        XCTAssertTrue(workspace.agentScope, "the receipt keeps the row and its scope")
        try write("# Silkweb overview\n\nEdited again in another app.\n", to: Self.overview)
        try await reconcile(workspace) {
            workspace.snapshot?.documents.first { $0.relativePath == Self.overview }?.modified
                == Self.fixedDate.addingTimeInterval(seconds)
        }
        XCTAssertEqual(workspace.outsideChanges, [], "a kept plain Document came back")
    }

    // MARK: Offscreen hierarchy

    /// GUI rule: the real library window, never ordered on screen. An external write arrives while a human Document
    /// is open and focused; the Agent Activity row appears with its count, the list row reads “Added outside
    /// Silkweb”, the Outside Silkweb filter and Document Info's block work, and Keep removes the row. Resize sweeps
    /// throughout.
    func testOffscreenAgentActivityShowsAnOutsideWriteQuietly() async throws {
        let workspace = try makeWorkspace()
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
        StatusBarCountsTests.exposeAccessibility(true)
        defer {
            StatusBarCountsTests.exposeAccessibility(false)
            window.contentViewController = nil
            window.close()
        }
        let content = try XCTUnwrap(window.contentView)
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
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
        var outline: SidebarOutlineView? { descendants(content).compactMap { $0 as? SidebarOutlineView }.first }
        var table: DocumentTableView? { descendants(content).compactMap { $0 as? DocumentTableView }.first }
        func agentRow() -> SidebarFolderCell?? {
            guard let outline else { return nil }
            for row in 0..<outline.numberOfRows
            where (outline.item(atRow: row) as? FolderSidebar.Item)?.isAgentActivity == true {
                return .some(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFolderCell)
            }
            return nil
        }
        func rows() -> [DocumentRow] {
            descendants(content).compactMap { ($0 as? NSHostingView<DocumentRow>)?.rootView }
        }
        var labels: [String] {
            StatusBarCountsTests.accessibilityTree(content).flatMap {
                [StatusBarCountsTests.label($0), StatusBarCountsTests.value($0)].compactMap { $0 }
            }
        }

        _ = try await open(workspace)
        try await waitUntil("the sidebar lists the folders", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return (outline?.numberOfRows ?? 0) > 2
        }
        XCTAssertNil(agentRow(), "a Library without agent activity looks as it always did")
        workspace.navigate(folder: "Notes", documents: ["Notes/Human.md"])
        await workspace.waitForNavigation()
        try await waitUntil("the editor shows the human Document", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return workspace.editor.url?.lastPathComponent == "Human.md"
                && descendants(content).contains { $0 is PlainMarkdownTextView }
        }
        let editorView = try XCTUnwrap(
            descendants(content).compactMap { $0 as? PlainMarkdownTextView }.first {
                $0.string == workspace.editor.text
            })
        XCTAssertTrue(window.makeFirstResponder(editorView))
        try await resizeSweep()
        let session = workspace.session
        let tabs = workspace.tabs.map(\.id)

        try write("# Silkweb overview\n\nWritten without the helper.\n", to: Self.overview)
        try await reconcile(workspace) { !workspace.outsideChanges.isEmpty }
        try await pump()
        let cell = try XCTUnwrap(agentRow(), "the Agent Activity row appears for an outside change alone")
        XCTAssertEqual(cell?.countBadge.stringValue, " (1)")
        XCTAssertEqual(workspace.session, session, "arrival moved the selection or scope")
        XCTAssertEqual(workspace.tabs.map(\.id), tabs)
        XCTAssertTrue(window.firstResponder === editorView, "arrival took focus from the editor")
        XCTAssertTrue(MenuCommandValues(workspace: workspace).hasAgentActivity)
        try await resizeSweep()

        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        try await waitUntil("the list shows the outside row", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return table?.numberOfRows == 1 && rows().contains { $0.outsideChange != nil }
        }
        let row = try XCTUnwrap(rows().first { $0.document.relativePath == Self.overview })
        XCTAssertEqual(row.outsideChange?.label, "Added outside Silkweb")
        XCTAssertTrue(
            row.accessibilityValue.hasSuffix(", added outside Silkweb, no Silkweb receipt"), row.accessibilityValue)
        // The row's context menu: Keep right after Reveal in Finder; Move to Trash stays the last item.
        let menu = try XCTUnwrap(table?.coordinator?.menu(path: Self.overview))
        let titles = menu.items.map(\.title)
        let reveal = try XCTUnwrap(titles.firstIndex(of: "Reveal in Finder"))
        XCTAssertEqual(titles[reveal + 1], "Keep")
        XCTAssertEqual(titles.last, "Move to Trash")
        XCTAssertFalse(
            table?.coordinator?.menu(path: "Notes/Human.md").items.map(\.title).contains("Keep") ?? true)
        // All Agents ▾ ▸ Outside Silkweb.
        workspace.outsideFilter = true
        try await pump()
        XCTAssertEqual(table?.numberOfRows, 1)
        XCTAssertTrue(labels.contains("Outside Silkweb"), "the pull-down names the filter")
        try await resizeSweep()

        // Document Info: the text-only block with Keep and Move to Trash….
        workspace.selectDocuments([Self.overview])
        await workspace.waitForNavigation()
        workspace.inspectorInfo = true
        workspace.preview.showsOutline = true
        try await waitUntil("Info shows the outside block", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return labels.contains("Silkweb can’t tell which app made this change.")
        }
        XCTAssertTrue(labels.contains { $0.contains("Added outside Silkweb") }, "\(labels)")
        XCTAssertTrue(labels.contains { $0.contains("No Silkweb receipt") })
        XCTAssertTrue(labels.contains("Keep"))
        XCTAssertTrue(labels.contains("Move to Trash…"))
        try await resizeSweep()

        // Keep from the context menu: the row leaves, the sidebar row hides with nothing else to show.
        let keep = try XCTUnwrap(menu.items.first { $0.title == "Keep" })
        XCTAssertTrue(keep.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(keep.action), to: keep.target, from: keep))
        try await waitUntil("Keep clears the flag", timeout: .seconds(10)) { workspace.outsideChanges.isEmpty }
        try await pump()
        XCTAssertNil(agentRow(), "the row hides when nothing is left to show")
        XCTAssertFalse(workspace.agentScope)
        XCTAssertFalse(workspace.outsideFilter)
        try await resizeSweep()
    }
}

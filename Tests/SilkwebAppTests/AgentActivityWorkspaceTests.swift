import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #137: agent receipts reach the app quietly. A receipt only reloads receipts; a new agent Document appears
/// without moving focus, selection or tabs; Agent Activity lists agent Documents newest first.
final class AgentActivityWorkspaceTests: XCTestCase {
    static let progress = "Memory/Projects/Silkweb/Progress"
    /// 2026-10-07 09:30:00 UTC.
    static let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private static func makeLibrary() throws -> (container: URL, root: URL) {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebAgentActivity-" + UUID().uuidString)
        let root = container.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(progress), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        for name in ["Human", "Other"] {
            try Data("# \(name)\n\nWritten by a person.\n".utf8)
                .write(to: root.appendingPathComponent("Notes/\(name).md"))
        }
        return (container, root.resolvingSymlinksInPath())
    }

    private static func create(
        _ title: String, in root: URL, agent: String = "claude-code", minutes: Double = 0
    ) throws -> AgentCreateResult {
        let grant = AgentGrant(project: "Silkweb", library: LibraryLocation(path: root.path))
        var service = AgentCreateService(
            library: root, grantId: "Silkweb", scope: try AgentScope(grant: grant),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        let date = fixedDate.addingTimeInterval(minutes * 60)
        service.now = { date }
        service.timeZone = TimeZone(identifier: "UTC")!
        return try service.create(
            AgentCreateRequest(
                idempotencyKey: title, type: "progress", title: title, body: "Objective: \(title).", agent: agent,
                session: "s-1"))
    }

    /// Every file under `.silkweb/` with its bytes and modification date.
    private static func metadataState(_ root: URL) throws -> [String: String] {
        var state: [String: String] = [:]
        let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent(".silkweb"), includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey])
            let data = values.isDirectory == true ? Data() : try Data(contentsOf: url)
            state[url.path] = "\(data.base64EncodedString()) \(values.contentModificationDate ?? .distantPast)"
        }
        return state
    }

    // MARK: Watcher

    func testReceiptEventsReloadReceiptsOnlyAndOtherMetadataStaysIgnored() {
        let root = "/Volumes/Notes/Library"
        func classify(_ paths: [String]) -> [Bool] {
            let change = LibraryWatcher.classify(paths, root: root)
            return [change.library, change.receipts]
        }
        XCTAssertEqual(classify([root + "/.silkweb/agent-events/op_1.json"]), [false, true])
        XCTAssertEqual(classify([root + "/.silkweb/agent-events/op_1.json.tmp-ABC"]), [false, true])
        XCTAssertEqual(classify([root + "/.silkweb/agent-events"]), [false, true])
        XCTAssertEqual(classify([root + "/.silkweb"]), [false, true])
        // The index, the staging journal, the lock and the search cache never reload or rescan anything.
        for name in ["index.json", "agent-staging/x.json", "library.lock", "search-index.json", "agent-eventsx/a"] {
            XCTAssertEqual(classify([root + "/.silkweb/" + name]), [false, false], name)
        }
        XCTAssertEqual(classify([root + "/Memory/A.md", root + "/.silkweb/agent-events/op.json"]), [true, true])
        XCTAssertEqual(classify([root + "/Sub/.silkweb/agent-events/op.json"]), [true, false])
        XCTAssertEqual(classify(["/private/tmp/Lib/.silkweb/agent-events/op.json"]).last, false)
        XCTAssertEqual(
            LibraryWatcher.classify(["/private/tmp/Lib/.silkweb/agent-events/op.json"], root: "/tmp/Lib").receipts, true
        )
        // Dropped events: reload both.
        XCTAssertEqual(classify([]), [true, true])
    }

    @MainActor
    func testReceiptWritesCallReceiptsChangedWithoutRescan() async throws {
        if ProcessInfo.processInfo.environment["CODEX_SANDBOX"] == "seatbelt" {
            throw XCTSkip("Managed seatbelt sandbox does not deliver FSEvents; classification is tested separately.")
        }
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(
            ".build/agent-watcher-\(UUID().uuidString)")
        let events = root.appendingPathComponent(".silkweb/agent-events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var rescans = 0
        var reloads = 0
        var seen: [String] = []
        let watcher = LibraryWatcher(root: root, delay: .milliseconds(20)) {
            rescans += 1
        } receiptsChanged: {
            reloads += 1
        }
        defer { watcher.stop() }
        watcher.observeEvents = { seen += $0 }
        // Drain the startup batch with a marker under `.silkweb/` that schedules nothing.
        let marker = "barrier-\(UUID().uuidString)"
        try Data().write(to: root.appendingPathComponent(".silkweb/" + marker))
        try await waitUntil("the barrier", timeout: .seconds(10)) { seen.contains { $0.hasSuffix(marker) } }
        await watcher.pending?.value
        await watcher.pendingReceipts?.value
        rescans = 0
        reloads = 0
        try Data("{}".utf8).write(to: events.appendingPathComponent("op_1.json"), options: .atomic)
        try await waitUntil("the receipt reload", timeout: .seconds(10)) { reloads > 0 }
        await watcher.pending?.value
        XCTAssertEqual(rescans, 0, "a receipt scheduled a library rescan: \(seen)")
    }

    // MARK: Workspace

    @MainActor
    func testAgentScopeListsNewestFirstFiltersAndLeavesOnOtherScopes() async throws {
        let (container, root) = try Self.makeLibrary()
        defer { try? FileManager.default.removeItem(at: container) }
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        await workspace.reloadAgentActivity()
        XCTAssertFalse(workspace.hasAgentActivity)
        workspace.selectAgentActivity()
        XCTAssertFalse(workspace.agentScope, "the hidden row can't be selected")
        let first = try Self.create("First", in: root, agent: "codex", minutes: 0)
        let second = try Self.create("Second", in: root, agent: "claude-code", minutes: 5)
        // The receipt can arrive before the scan sees its Document: nothing shows until both are in.
        await workspace.reloadAgentActivity()
        XCTAssertTrue(workspace.hasAgentActivity)
        XCTAssertEqual(workspace.agentEntries.count, 0)
        await workspace.reconcileFinderChanges()
        XCTAssertEqual(workspace.agentEntries.map(\.document.relativePath), [second.path, first.path])
        workspace.setSortKey(.name)
        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        XCTAssertTrue(workspace.agentScope)
        XCTAssertNil(workspace.session.selectedFolder)
        XCTAssertEqual(workspace.folderName, "Agent Activity")
        // Newest receipt first, whatever Sort By says; All Documents keeps its own sort.
        XCTAssertEqual(workspace.documents.map(\.relativePath), [second.path, first.path])
        workspace.agentFilter = "codex"
        XCTAssertEqual(workspace.documents.map(\.relativePath), [first.path])
        workspace.agentFilter = "nobody"
        XCTAssertEqual(workspace.documents, [])
        workspace.agentFilter = nil
        // Filter by Tag still applies.
        _ = try await TagStore.update(root: root) { metadata in
            TagEditor.edit(["keep"], documents: [try! XCTUnwrap(first.receipt.documentId)], metadata: metadata)
        }
        await workspace.reconcileFinderChanges()
        workspace.tagFilters = Set(workspace.tags.map(\.id))
        XCTAssertEqual(workspace.documents.map(\.relativePath), [first.path])
        workspace.tagFilters = []
        // Selecting an agent Document keeps the scope; revealing a human one shows All Documents.
        workspace.selectDocuments([try XCTUnwrap(second.path)])
        await workspace.waitForNavigation()
        XCTAssertTrue(workspace.agentScope)
        workspace.showDocument(root.appendingPathComponent("Notes/Human.md"))
        await workspace.waitForNavigation()
        XCTAssertFalse(workspace.agentScope)
        XCTAssertNil(workspace.session.selectedFolder)
        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        workspace.selectFolder("Notes")
        await workspace.waitForNavigation()
        XCTAssertFalse(workspace.agentScope)
        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        workspace.selectFolder(nil)
        await workspace.waitForNavigation()
        XCTAssertFalse(workspace.agentScope, "All Documents leaves Agent Activity")
        // Any folder scope set directly (New Document in a folder, Import, a tab) leaves it too.
        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        workspace.session.selectedFolder = "Notes"
        XCTAssertFalse(workspace.agentScope)
        // Receipts removed: the row hides and its scope ends.
        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        try FileManager.default.removeItem(at: root.appendingPathComponent(".silkweb/agent-events"))
        await workspace.reloadAgentActivity()
        XCTAssertFalse(workspace.hasAgentActivity)
        XCTAssertFalse(workspace.agentScope)
        XCTAssertEqual(workspace.agentEntries, [])
    }

    // MARK: Offscreen hierarchy

    /// GUI rule: the real library window, never ordered on screen. Load, resize sweeps, then agent receipts
    /// arrive while a human Document is selected, open and focused, and again inside Agent Activity.
    @MainActor
    func testOffscreenLoadResizeAndReceiptArrivalKeepFocusSelectionAndTabs() async throws {
        _ = NSApplication.shared
        let (container, root) = try Self.makeLibrary()
        let suite = "Silkweb.AgentActivity." + UUID().uuidString
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
        var outline: SidebarOutlineView? { Self.descendants(content).compactMap { $0 as? SidebarOutlineView }.first }
        var table: DocumentTableView? { Self.descendants(content).compactMap { $0 as? DocumentTableView }.first }
        func agentRow() -> (row: Int, cell: SidebarFolderCell?)? {
            guard let outline else { return nil }
            for row in 0..<outline.numberOfRows
            where (outline.item(atRow: row) as? FolderSidebar.Item)?.isAgentActivity == true {
                return (row, outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFolderCell)
            }
            return nil
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
        try await waitUntil("the sidebar lists the folders", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return (outline?.numberOfRows ?? 0) > 2
        }
        // A Library without receipts looks as it always did: no row, Go ▸ Agent Activity disabled.
        XCTAssertNil(agentRow())
        XCTAssertFalse(MenuCommandValues(workspace: workspace).hasAgentActivity)

        workspace.navigate(folder: "Notes", documents: ["Notes/Human.md"])
        await workspace.waitForNavigation()
        let humanURL = root.appendingPathComponent("Notes/Human.md")
        try await waitUntil("the editor shows the human Document", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return workspace.editor.url?.standardizedFileURL == humanURL.standardizedFileURL
                && Self.descendants(content).contains { $0 is PlainMarkdownTextView }
        }
        let editorView = try XCTUnwrap(
            Self.descendants(content).compactMap { $0 as? PlainMarkdownTextView }.first {
                $0.string == workspace.editor.text
            })
        XCTAssertTrue(window.makeFirstResponder(editorView))
        editorView.setSelectedRange(NSRange(location: 3, length: 0))
        try await resizeSweep()

        let session = workspace.session
        let tabs = workspace.tabs.map(\.id)
        let activeTab = workspace.activeTabID
        let text = workspace.editor.text
        let revision = workspace.revision

        // Arrival 1, outside Agent Activity.
        let first = try Self.create("Helper spike", in: root, agent: "codex")
        await workspace.reconcileFinderChanges()
        let metadata = try Self.metadataState(root)
        let reinstalled = workspace.revision
        await workspace.reloadAgentActivity()
        XCTAssertEqual(try Self.metadataState(root), metadata, "a receipt reload wrote to .silkweb")
        XCTAssertEqual(workspace.revision, reinstalled, "a receipt reload rescanned the library")
        XCTAssertGreaterThan(reinstalled, revision, "the new Document reached the library")
        try await pump()
        let arrived = try XCTUnwrap(agentRow(), "the Agent Activity row appears")
        XCTAssertEqual(arrived.row, 1, "directly under All Documents")
        XCTAssertEqual(arrived.cell?.countBadge.stringValue, " (1)")
        XCTAssertEqual(arrived.cell?.accessibilityLabel(), "Agent Activity")
        XCTAssertEqual(arrived.cell?.accessibilityValue() as? String, "1 document")
        XCTAssertTrue(MenuCommandValues(workspace: workspace).hasAgentActivity)
        XCTAssertEqual(workspace.session, session, "the selection or scope moved")
        XCTAssertEqual(workspace.tabs.map(\.id), tabs)
        XCTAssertEqual(workspace.activeTabID, activeTab)
        XCTAssertEqual(workspace.editor.text, text)
        XCTAssertEqual(workspace.editor.state, .clean)
        XCTAssertTrue(
            window.firstResponder === editorView, "focus left the editor: \(String(describing: window.firstResponder))")
        XCTAssertEqual(editorView.selectedRange(), NSRange(location: 3, length: 0), "the caret moved")
        try await resizeSweep()

        // Go ▸ Agent Activity selects the row as a click does.
        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        try await waitUntil("the list shows Agent Activity", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return table?.numberOfRows == 1 && outline?.selectedRow == agentRow()?.row
        }
        XCTAssertTrue(window.firstResponder === editorView, "selecting the scope by menu kept focus in the editor")
        let firstPath = try XCTUnwrap(first.path)
        workspace.selectDocuments([firstPath])
        await workspace.waitForNavigation()
        try await waitUntil("the agent Document opens", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return workspace.editor.url?.path.hasSuffix(firstPath) == true
        }
        workspace.inspectorInfo = true
        workspace.preview.showsOutline = true
        try await resizeSweep()

        // Arrival 2, inside Agent Activity, receipt first: the new row inserts and the selection stays.
        let inScope = workspace.session
        let openTabs = workspace.tabs.map(\.id)
        let openTab = workspace.activeTabID
        let responder = window.firstResponder
        let second = try Self.create("Second checkpoint", in: root, agent: "claude-code", minutes: 10)
        await workspace.reloadAgentActivity()
        await workspace.reconcileFinderChanges()
        try await waitUntil("the second row inserts", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return table?.numberOfRows == 2
        }
        XCTAssertEqual(workspace.documents.map(\.relativePath), [second.path, first.path])
        XCTAssertEqual(workspace.session, inScope)
        XCTAssertTrue(workspace.agentScope)
        XCTAssertEqual(workspace.tabs.map(\.id), openTabs)
        XCTAssertEqual(workspace.activeTabID, openTab)
        XCTAssertTrue(window.firstResponder === responder)
        XCTAssertEqual(table?.selectedRowIndexes, IndexSet(integer: 1), "the selection followed its Document")
        XCTAssertEqual(agentRow()?.cell?.countBadge.stringValue, " (2)")
        XCTAssertEqual(outline?.selectedRow, agentRow()?.row)
        try await resizeSweep()
    }
}

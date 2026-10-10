import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #203, in the Agent Access window since #229: the owner reviews every Library's access requests. Approve checks the
/// #186 rules first, confirms, needs owner authentication, then writes the grant; Deny records a note; the sidebar row
/// and strip follow the request file quietly.
@MainActor
final class AccessRequestsWorkspaceTests: XCTestCase {
    private var container: URL!
    private var root: URL!
    private var requestsURL: URL!
    private var grantsURL: URL!
    private var alerts: [String] = []

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    override func setUp() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebAccessRequests-" + UUID().uuidString)
        let library = container.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Notes/Swift"), withIntermediateDirectories: true)
        try Data("# Human\n\nWritten by a person.\n".utf8).write(to: library.appendingPathComponent("Notes/Human.md"))
        root = library.resolvingSymlinksInPath()
        requestsURL = container.appendingPathComponent("Support/agent-access-requests.json")
        grantsURL = container.appendingPathComponent("Support/agent-grants.json")
        alerts = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: container)
    }

    private var store: AgentAccessRequestStore { AgentAccessRequestStore(url: requestsURL) }

    @discardableResult
    private func ask(_ access: String = "read-create", folders: [String] = ["Notes/Swift"]) throws -> AgentAccessRequest
    {
        let draft = try AgentAccessRequests.draft(
            library: root.path, project: "Silkweb", access: access, readFolders: folders, message: "For handoffs",
            agent: "claude-code", session: "s-1", client: "cli")
        return try store.submit(draft).request
    }

    /// The Agent Access model on the temporary store and grants, with alerts and authentication replaced.
    private func makeModel(
        authenticate: Bool, note: String = "", answer: NSApplication.ModalResponse = .alertFirstButtonReturn
    ) -> (AgentAccessModel, () -> Int) {
        let model = AgentAccessModel()
        model.requestStore = store
        model.grantsURL = grantsURL
        var authentications = 0
        model.authenticate = { _ in
            authentications += 1
            return authenticate
        }
        model.present = { [weak self] alert, _ in
            self?.alerts.append(alert.messageText)
            (alert.accessoryView as? NSTextField)?.stringValue = note
            return answer
        }
        return (model, { authentications })
    }

    func testApproveConfirmsAuthenticatesThenWritesTheGrant() async throws {
        let request = try ask()
        let (model, authentications) = makeModel(authenticate: false)
        await model.reload()
        XCTAssertEqual(model.requests.map(\.requestId), [request.requestId])
        XCTAssertEqual(model.waitingCount, 1)
        XCTAssertEqual(model.summary, "0 grants · 1 request waiting")

        // Authentication refused: nothing is saved.
        await model.approve(request)
        XCTAssertEqual(alerts, ["Give “claude-code” Read and Create access to “Silkweb”?"])
        XCTAssertEqual(authentications(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))
        XCTAssertEqual(try store.load().requests.first?.status, .pending)

        // Cancelled at the confirmation: never asks for authentication.
        model.present = { _, _ in .alertSecondButtonReturn }
        await model.approve(request)
        XCTAssertEqual(authentications(), 1)

        model.present = { _, _ in .alertFirstButtonReturn }
        model.authenticate = { _ in true }
        await model.approve(request)
        let grant = try XCTUnwrap(try AgentGrantStore(url: grantsURL).load().grant(for: "Silkweb"))
        XCTAssertEqual(grant.access, .readCreate)
        XCTAssertEqual(grant.extraReadFolders, ["Notes/Swift"])
        XCTAssertEqual(grant.library.path, root.path)
        let approved = try XCTUnwrap(try store.load().requests.first)
        XCTAssertEqual(approved.status, .approved)
        XCTAssertEqual(approved.decidedVia, .app)
        XCTAssertEqual(model.requests.first?.status, .approved, "the row updates in place")
        XCTAssertEqual(model.waitingCount, 0)
        XCTAssertEqual(model.file.grants, [grant], "the new grant is listed")
        XCTAssertEqual(model.summary, "1 grant")
        XCTAssertNil(model.deciding)
    }

    /// #229: the refusal keeps its title, points at Agent Access, and Show Grant opens the grant to widen it there.
    func testWideningIsRefusedBeforeConfirmationAndShowGrantOpensTheGrant() async throws {
        try AgentGrantFile(grants: [
            AgentGrant(project: "Silkweb", library: LibraryLocation(path: root.path), access: .read)
        ]).write(to: grantsURL)
        let before = try Data(contentsOf: grantsURL)
        let request = try ask(folders: [])
        let (model, authentications) = makeModel(authenticate: true)
        await model.reload()
        var buttons: [String] = []
        model.present = { [weak self] alert, _ in
            self?.alerts.append(alert.messageText)
            buttons = alert.buttons.map(\.title)
            XCTAssertEqual(
                alert.informativeText,
                "The grant “Silkweb” already exists with Read Only access. Approving never widens access. "
                    + "Change the grant in Agent Access first, then approve.")
            return .alertFirstButtonReturn
        }
        await model.approve(request)
        XCTAssertEqual(alerts, ["Can’t Approve This Request"])
        XCTAssertEqual(buttons, ["OK", "Show Grant"])
        XCTAssertEqual(authentications(), 0, "never asks to authenticate for a refusal")
        XCTAssertEqual(try Data(contentsOf: grantsURL), before)
        XCTAssertEqual(try store.load().requests.first?.status, .pending)
        XCTAssertNil(model.selection, "OK stays put")

        model.present = { _, _ in .alertSecondButtonReturn }
        await model.approve(request)
        XCTAssertEqual(model.selection, .grant("Silkweb"), "Show Grant selects the grant")
        XCTAssertEqual(model.draft?.access, .read)

        // The owner widens in the manager, then the same approval goes through.
        model.draft?.access = .readCreate
        let saved = await model.save()
        XCTAssertTrue(saved)
        model.present = { _, _ in .alertFirstButtonReturn }
        await model.approve(request)
        XCTAssertEqual(try store.load().requests.first?.status, .approved)
    }

    func testDenyRecordsTheNoteAndADecisionElsewhereIsReported() async throws {
        let first = try ask()
        let second = try ask("read", folders: [])
        let (model, authentications) = makeModel(authenticate: true, note: "Wrong\nproject")
        await model.reload()
        await model.deny(first)
        XCTAssertEqual(alerts, ["Deny the Request from “claude-code”?"])
        let denied = try XCTUnwrap(try store.load().requests.first { $0.requestId == first.requestId })
        XCTAssertEqual(denied.status, .denied)
        XCTAssertEqual(denied.ownerNote, "Wrong project")
        XCTAssertEqual(denied.decidedVia, .app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))
        XCTAssertEqual(authentications(), 0, "denying needs no authentication")

        // Terminal approved the other one while the window was open.
        _ = try store.decide(second.requestId, approve: true, via: .terminal, grantsURL: grantsURL)
        alerts = []
        await model.approve(second)
        XCTAssertEqual(alerts, ["This request was already approved in Terminal."])
        XCTAssertEqual(model.requests.first { $0.requestId == second.requestId }?.status, .approved)
    }

    /// Requests from every Library share the list; the workspace still counts only its own for the sidebar.
    func testRequestsForEveryLibraryAppearAndTheWorkspaceCountsItsOwn() async throws {
        try ask()
        let other = container.appendingPathComponent("Other").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        _ = try store.submit(
            try AgentAccessRequests.draft(
                library: other.path, project: "Coffee", access: "read", readFolders: [], message: nil, agent: "codex",
                session: nil, client: nil))
        let (model, _) = makeModel(authenticate: true)
        await model.reload()
        XCTAssertEqual(Set(model.requests.map(\.project)), ["Silkweb", "Coffee"])
        XCTAssertEqual(model.waitingCount, 2)

        let workspace = LibraryWorkspace()
        workspace.accessRequestStore = store
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        await workspace.reloadAccessRequests()
        XCTAssertEqual(workspace.accessRequests.map(\.project), ["Silkweb"])
        XCTAssertEqual(workspace.accessRequestsWaitingLabel, "1 access request waiting")
    }

    // MARK: Offscreen hierarchy

    /// GUI rule: the real library window, never ordered on screen. A request alone shows the Agent Activity row
    /// with `hand.raised`; the Agent Access window's Access Requests survives a resize sweep and updates in place
    /// after an approval; the sidebar row follows.
    func testOffscreenRowAndAgentAccessRequestsFollowTheRequestFile() async throws {
        _ = NSApplication.shared
        try ask()
        let suite = "Silkweb.AccessRequests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        workspace.accessRequestStore = store
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        }
        let content = try XCTUnwrap(window.contentView)
        func pump() async throws {
            try await Task.sleep(for: .milliseconds(1))
            content.superview?.layoutSubtreeIfNeeded()
        }
        var outline: SidebarOutlineView? { Self.descendants(content).compactMap { $0 as? SidebarOutlineView }.first }
        func agentCell() -> SidebarFolderCell? {
            guard let outline else { return nil }
            for row in 0..<outline.numberOfRows
            where (outline.item(atRow: row) as? FolderSidebar.Item)?.isAgentActivity == true {
                return outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFolderCell
            }
            return nil
        }

        workspace.open(root)
        try await waitUntil("the library opens", timeout: .seconds(10)) {
            workspace.snapshot != nil && !workspace.loading
        }
        try await waitUntil("the Agent Activity row appears for the request", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return agentCell() != nil
        }
        let cell = try XCTUnwrap(agentCell())
        XCTAssertFalse(cell.requestBadge.isHidden, "hand.raised while a request waits")
        XCTAssertEqual(cell.toolTip, "1 access request waiting")
        XCTAssertEqual(cell.accessibilityValue() as? String, "0 documents, 1 access request waiting")
        XCTAssertTrue(MenuCommandValues(workspace: workspace).hasAgentActivity)
        for width: CGFloat in [900, 2400, 1100, 1400] {
            window.setContentSize(NSSize(width: width, height: width == 900 ? 560 : 900))
            try await pump()
        }
        XCTAssertGreaterThan(cell.requestBadge.frame.minX, cell.countBadge.frame.maxX - 1, "after the count")

        workspace.selectAgentActivity()
        await workspace.waitForNavigation()
        try await pump()
        XCTAssertTrue(workspace.agentScope, "a request alone makes the row selectable")

        // The Agent Access window's own hierarchy, hosted offscreen, through a resize and an approval.
        let (model, _) = makeModel(authenticate: true)
        await model.reload()
        await model.select(.requests)
        let accessWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        accessWindow.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: AgentAccessView(model: model))
        host.sizingOptions = []
        accessWindow.contentViewController = host
        defer {
            accessWindow.contentViewController = nil
            accessWindow.close()
        }
        for size in [
            NSSize(width: 680, height: 440), NSSize(width: 1200, height: 800), NSSize(width: 780, height: 520),
        ] {
            accessWindow.setContentSize(size)
            host.view.layoutSubtreeIfNeeded()
        }
        XCTAssertGreaterThanOrEqual(
            NSHostingView(rootView: AgentAccessView(model: model)).fittingSize.width, 680 - 1,
            "the window's minimum width")
        let request = try XCTUnwrap(model.requests.first)
        await model.approve(request)
        host.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.requests.first?.status, .approved)
        await workspace.reloadAccessRequests()
        try await waitUntil("the sidebar drops hand.raised", timeout: .seconds(10)) {
            content.superview?.layoutSubtreeIfNeeded()
            return agentCell()?.requestBadge.isHidden == true
        }
        XCTAssertEqual(agentCell()?.accessibilityValue() as? String, "0 documents, current folder")
        XCTAssertTrue(workspace.hasAgentActivity)

        // Terminal decisions arrive through the file watcher (or the next reload) without touching the scope.
        try ask("read", folders: [])
        await workspace.reloadAccessRequests()
        try await pump()
        XCTAssertEqual(workspace.pendingAccessRequestCount, 1)
        XCTAssertTrue(workspace.agentScope, "the scope stays put")
    }
}

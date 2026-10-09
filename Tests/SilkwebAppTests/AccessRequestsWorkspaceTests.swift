import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #203: the owner reviews access requests in the app. Approve checks the #186 rules first, confirms, needs owner
/// authentication, then writes the grant; Deny records a note; the sidebar row, strip and sheet follow the request
/// file quietly.
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

    /// A workspace on the temporary Library, store and grants, with alerts and authentication replaced.
    private func makeWorkspace(authenticate: Bool, note: String = "", answer: Bool = true) async throws
        -> (LibraryWorkspace, () -> Int)
    {
        let workspace = LibraryWorkspace()
        workspace.accessRequestStore = store
        workspace.agentGrantsURL = grantsURL
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        var authentications = 0
        workspace.authenticateOwner = { _ in
            authentications += 1
            return authenticate
        }
        workspace.presentMoveAlert = { [weak self] alert, _ in
            self?.alerts.append(alert.messageText)
            (alert.accessoryView as? NSTextField)?.stringValue = note
            return answer
        }
        return (workspace, { authentications })
    }

    func testApproveConfirmsAuthenticatesThenWritesTheGrant() async throws {
        let request = try ask()
        let (workspace, authentications) = try await makeWorkspace(authenticate: false)
        await workspace.reloadAccessRequests()
        XCTAssertEqual(workspace.accessRequests.map(\.requestId), [request.requestId])
        XCTAssertTrue(workspace.hasAgentActivity, "a request alone shows the Agent Activity row")
        XCTAssertEqual(workspace.pendingAccessRequestCount, 1)
        XCTAssertEqual(workspace.accessRequestsWaitingLabel, "1 access request waiting")

        // Authentication refused: nothing is saved.
        await workspace.approveAccessRequest(request)
        XCTAssertEqual(alerts, ["Give “claude-code” Read and Create access to “Silkweb”?"])
        XCTAssertEqual(authentications(), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))
        XCTAssertEqual(try store.load().requests.first?.status, .pending)

        // Cancelled at the confirmation: never asks for authentication.
        workspace.presentMoveAlert = { _, _ in false }
        await workspace.approveAccessRequest(request)
        XCTAssertEqual(authentications(), 1)

        workspace.presentMoveAlert = { _, _ in true }
        workspace.authenticateOwner = { _ in true }
        await workspace.approveAccessRequest(request)
        let grant = try XCTUnwrap(try AgentGrantStore(url: grantsURL).load().grant(for: "Silkweb"))
        XCTAssertEqual(grant.access, .readCreate)
        XCTAssertEqual(grant.extraReadFolders, ["Notes/Swift"])
        XCTAssertEqual(grant.library.path, root.path)
        let approved = try XCTUnwrap(try store.load().requests.first)
        XCTAssertEqual(approved.status, .approved)
        XCTAssertEqual(approved.decidedVia, .app)
        XCTAssertEqual(workspace.accessRequests.first?.status, .approved, "the row updates in place")
        XCTAssertEqual(workspace.pendingAccessRequestCount, 0)
        XCTAssertNil(workspace.accessRequestsWaitingLabel)
        XCTAssertTrue(workspace.hasAgentActivity, "history keeps the row")
        XCTAssertNil(workspace.decidingRequestID)
    }

    func testWideningIsRefusedBeforeConfirmationAndStaysPending() async throws {
        try AgentGrantFile(grants: [
            AgentGrant(project: "Silkweb", library: LibraryLocation(path: root.path), access: .read)
        ]).write(to: grantsURL)
        let before = try Data(contentsOf: grantsURL)
        let request = try ask(folders: [])
        let (workspace, authentications) = try await makeWorkspace(authenticate: true)
        await workspace.reloadAccessRequests()
        await workspace.approveAccessRequest(request)
        XCTAssertEqual(alerts, ["Can’t Approve This Request"])
        XCTAssertEqual(authentications(), 0, "never asks to authenticate for a refusal")
        XCTAssertEqual(try Data(contentsOf: grantsURL), before)
        XCTAssertEqual(try store.load().requests.first?.status, .pending)
        XCTAssertThrowsError(try store.previewApproval(request.requestId, grantsURL: grantsURL)) { error in
            let alert = AccessRequestAlerts.refusal(error)
            XCTAssertEqual(alert.messageText, "Can’t Approve This Request")
            XCTAssertEqual(
                alert.informativeText,
                "The grant “Silkweb” already exists with Read Only access. Approving never widens access; edit "
                    + "agent-grants.json to change it.")
        }
    }

    func testDenyRecordsTheNoteAndADecisionElsewhereIsReported() async throws {
        let first = try ask()
        let second = try ask("read", folders: [])
        let (workspace, authentications) = try await makeWorkspace(authenticate: true, note: "Wrong\nproject")
        await workspace.reloadAccessRequests()
        await workspace.denyAccessRequest(first)
        XCTAssertEqual(alerts, ["Deny the Request from “claude-code”?"])
        let denied = try XCTUnwrap(try store.load().requests.first { $0.requestId == first.requestId })
        XCTAssertEqual(denied.status, .denied)
        XCTAssertEqual(denied.ownerNote, "Wrong project")
        XCTAssertEqual(denied.decidedVia, .app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))
        XCTAssertEqual(authentications(), 0, "denying needs no authentication")

        // Terminal approved the other one while the sheet was open.
        _ = try store.decide(second.requestId, approve: true, via: .terminal, grantsURL: grantsURL)
        alerts = []
        await workspace.approveAccessRequest(second)
        XCTAssertEqual(alerts, ["This request was already approved in Terminal."])
        XCTAssertEqual(workspace.accessRequests.first { $0.requestId == second.requestId }?.status, .approved)
    }

    // MARK: Offscreen hierarchy

    /// GUI rule: the real library window, never ordered on screen. A request alone shows the Agent Activity row
    /// with `hand.raised`; the strip offers Access Requests (1); the sheet survives a resize sweep and updates in
    /// place after an approval.
    func testOffscreenRowStripAndSheetFollowTheRequestFile() async throws {
        _ = NSApplication.shared
        try ask()
        let suite = "Silkweb.AccessRequests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        workspace.accessRequestStore = store
        workspace.agentGrantsURL = grantsURL
        workspace.authenticateOwner = { _ in true }
        workspace.presentMoveAlert = { _, _ in true }
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

        // The sheet's own hierarchy, hosted offscreen, through a resize and an approval.
        workspace.accessRequestClock = { Date() }
        let host = NSHostingView(rootView: AccessRequestsSheet(workspace: workspace))
        host.frame = NSRect(x: 0, y: 0, width: 560, height: 440)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 560, accuracy: 1)
        let request = try XCTUnwrap(workspace.accessRequests.first)
        await workspace.approveAccessRequest(request)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.accessRequests.first?.status, .approved)
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

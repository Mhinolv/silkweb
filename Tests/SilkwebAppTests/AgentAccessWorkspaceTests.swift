import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #229: the Agent Access window lists every grant for every Library with its last activity, creates and edits grants
/// through `AgentGrantOwner`, asks for owner authentication before any widening (and before a new grant), saves
/// narrowing and Pause without it, follows Terminal changes through the watcher, and filters Agent Activity by grant.
@MainActor
final class AgentAccessWorkspaceTests: XCTestCase {
    private var container: URL!
    private var silkweb: URL!
    private var writing: URL!
    private var grantsURL: URL!
    private var requestsURL: URL!
    private var alerts: [String] = []
    private var authentications: [String] = []
    /// 2026-10-09 14:14:00 UTC.
    private static let created = Date(timeIntervalSince1970: 1_791_555_240)

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    override func setUp() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebAgentAccess-" + UUID().uuidString)
        silkweb = container.appendingPathComponent("Silkweb Library")
        writing = container.appendingPathComponent("Writing")
        for folder in [
            silkweb.appendingPathComponent("Memory/Projects/Silkweb/Progress"), silkweb.appendingPathComponent("Notes"),
            writing.appendingPathComponent("Drafts"),
        ] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        silkweb = silkweb.resolvingSymlinksInPath()
        writing = writing.resolvingSymlinksInPath()
        grantsURL = container.appendingPathComponent("Support/agent-grants.json")
        requestsURL = container.appendingPathComponent("Support/agent-access-requests.json")
        alerts = []
        authentications = []
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: container)
    }

    private func grant(
        _ project: String, library: URL, access: AgentGrant.Access = .readCreate, revoked: Date? = nil,
        label: String = ""
    ) -> AgentGrant {
        AgentGrant(
            project: project, library: LibraryLocation(path: library.path), access: access, label: label,
            createdAt: Self.created, revokedAt: revoked)
    }

    private func seed(_ grants: [AgentGrant]) throws {
        try AgentGrantFile(grants: grants).write(to: grantsURL)
    }

    private func onDisk(_ project: String) throws -> AgentGrant? {
        try AgentGrantOwner.load(grantsURL).grant(for: project)
    }

    /// A model on the temporary files. `authenticate` answers every prompt; `answer` every alert.
    private func makeModel(
        authenticate: Bool = true, answer: NSApplication.ModalResponse = .alertFirstButtonReturn
    ) -> AgentAccessModel {
        let model = AgentAccessModel()
        model.grantsURL = grantsURL
        model.requestStore = AgentAccessRequestStore(url: requestsURL)
        model.authenticate = { [weak self] reason in
            self?.authentications.append(reason)
            return authenticate
        }
        model.present = { [weak self] alert, _ in
            self?.alerts.append(alert.messageText)
            return answer
        }
        return model
    }

    private func assertSave(_ model: AgentAccessModel, _ expected: Bool, line: UInt = #line) async {
        let result = await model.save()
        XCTAssertEqual(result, expected, "Save", line: line)
    }

    private func assertCreate(_ model: AgentAccessModel, _ form: NewGrantForm, _ expected: Bool, line: UInt = #line)
        async
    {
        let result = await model.create(form)
        XCTAssertEqual(result, expected, "Create", line: line)
    }

    /// One published receipt for `project`, created by the helper itself.
    @discardableResult
    private func receipt(_ project: String, in root: URL, agent: String, minutes: Double) throws -> AgentCreateResult {
        let grant = AgentGrant(project: project, library: LibraryLocation(path: root.path))
        var service = AgentCreateService(
            library: root, grantId: project, scope: try AgentScope(grant: grant),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        let date = Self.created.addingTimeInterval(minutes * 60)
        service.now = { date }
        service.timeZone = TimeZone(identifier: "UTC")!
        return try service.create(
            AgentCreateRequest(
                idempotencyKey: "\(project)-\(minutes)", type: "progress", title: "Note \(minutes)",
                body: "Objective: note.", agent: agent, session: "s-1"))
    }

    // MARK: List

    func testListsEveryGrantByLibraryWithLastActivityAndFollowsTerminalChanges() async throws {
        try seed([
            grant("Silkweb", library: silkweb), grant("Coffee", library: silkweb, access: .read, revoked: Self.created),
            grant("Novel", library: writing, access: .read, label: "The novel"),
            grant("Gone", library: container.appendingPathComponent("Missing")),
        ])
        try receipt("Silkweb", in: silkweb, agent: "codex", minutes: 0)
        try receipt("Silkweb", in: silkweb, agent: "claude-code", minutes: 30)
        try receipt("Coffee", in: silkweb, agent: "codex", minutes: 10)
        let model = makeModel()
        await model.reload()

        XCTAssertEqual(model.file.grants.count, 4)
        XCTAssertEqual(model.groups.map(\.name), ["Missing", "Silkweb Library", "Writing"], "by name without a window")
        XCTAssertEqual(model.groups[1].grants.map(\.project), ["Silkweb", "Coffee"])
        XCTAssertEqual(model.missingLibraries, [container.appendingPathComponent("Missing").path])
        XCTAssertEqual(
            model.activity["Silkweb"],
            .init(date: Self.created.addingTimeInterval(1_800), agent: "claude-code"), "the newest receipt")
        XCTAssertEqual(model.activity["Coffee"]?.agent, "codex")
        XCTAssertNil(model.activity["Novel"])
        XCTAssertEqual(model.rowDetail(model.file.grant(for: "Novel")!), "Read Only · no activity")
        let coffee = try XCTUnwrap(model.file.grant(for: "Coffee"))
        XCTAssertEqual(model.rowDetail(coffee), "Read Only · active Oct 9")
        XCTAssertEqual(model.accessibilityLabel(coffee), "Coffee project, Read Only, paused, last active Oct 9")
        XCTAssertEqual(model.label(for: "Novel"), "The novel")
        XCTAssertEqual(model.label(for: "Unknown"), "Unknown project")
        XCTAssertEqual(model.summary, "4 grants")

        // The current Library leads when the library window has one open.
        let preferences = TestPreferences("AgentAccessList")
        defer { preferences.remove() }
        let registry = LibraryWindowRegistry(defaults: preferences.defaults) {
            LibraryWorkspace(defaults: preferences.defaults)
        }
        registry.current.root = writing
        model.registry = registry
        XCTAssertEqual(model.groups.map(\.name), ["Writing", "Missing", "Silkweb Library"])

        // Terminal `grant init` adds a grant; the watcher reloads the list in place.
        model.start()
        defer { model.stop() }
        var file = try AgentGrantOwner.load(grantsURL)
        file.grants.append(grant("Specs", library: writing, access: .read))
        try file.write(to: grantsURL)
        try await waitUntil("the watcher picks up the new grant", timeout: .seconds(10)) {
            model.file.grant(for: "Specs") != nil
        }
    }

    // MARK: Editing

    func testWideningAsksForAuthenticationAndCancellingKeepsTheEdits() async throws {
        try seed([grant("Silkweb", library: silkweb, access: .read)])
        let before = try Data(contentsOf: grantsURL)
        let model = makeModel(authenticate: false)
        await model.reload()
        await model.select(.grant("Silkweb"))
        XCTAssertFalse(model.isEdited)
        model.draft?.access = .readCreateUpdate
        model.addReadFolder("Notes")
        model.draft?.agentFolder = "Claude"
        XCTAssertTrue(model.isEdited)

        await assertSave(model, false)
        XCTAssertEqual(authentications, ["change agent access for “Silkweb project”"])
        XCTAssertEqual(try Data(contentsOf: grantsURL), before, "nothing is written when authentication is cancelled")
        XCTAssertTrue(model.isEdited, "the edits stay")
        XCTAssertEqual(alerts, [])

        model.authenticate = { _ in true }
        await assertSave(model, true)
        let saved = try XCTUnwrap(try onDisk("Silkweb"))
        XCTAssertEqual(saved.access, .readCreateUpdate)
        XCTAssertEqual(saved.extraReadFolders, ["Notes"])
        XCTAssertEqual(saved.agentFolder, "Claude")
        XCTAssertFalse(model.isEdited)
        XCTAssertEqual(model.file.grant(for: "Silkweb"), saved)
    }

    func testNarrowingLabelAndPauseSaveWithoutAuthenticationAndResumeNeedsIt() async throws {
        var original = grant("Silkweb", library: silkweb, access: .readCreateUpdate)
        original.extraReadFolders = ["Notes"]
        original.agentFolder = "Claude"
        try seed([original, grant("Coffee", library: silkweb)])
        let model = makeModel(authenticate: false)
        model.clock = { Self.created.addingTimeInterval(60) }
        await model.reload()
        await model.select(.grant("Silkweb"))
        model.draft?.access = .read
        model.removeReadFolder("Notes")
        model.draft?.agentFolder = nil
        model.draft?.label = "Silkweb repo"
        model.setAllowed(false)
        await assertSave(model, true)
        XCTAssertEqual(authentications, [], "narrowing, relabelling and pausing never ask")
        let saved = try XCTUnwrap(try onDisk("Silkweb"))
        XCTAssertEqual(saved.access, .read)
        XCTAssertEqual(saved.extraReadFolders, [])
        XCTAssertNil(saved.agentFolder)
        XCTAssertEqual(saved.label, "Silkweb repo")
        XCTAssertEqual(saved.revokedAt, Self.created.addingTimeInterval(60))

        // Allow access back on is a Resume: it widens.
        model.setAllowed(true)
        await assertSave(model, false)
        XCTAssertEqual(authentications, ["change agent access for “Silkweb repo”"])
        XCTAssertTrue(try XCTUnwrap(try onDisk("Silkweb")).isRevoked)
        model.revert()

        // The context menu's Pause applies at once; Resume asks first.
        authentications = []
        await model.setPaused(true, project: "Coffee")
        XCTAssertTrue(try XCTUnwrap(try onDisk("Coffee")).isRevoked)
        XCTAssertEqual(authentications, [])
        await model.setPaused(false, project: "Coffee")
        XCTAssertEqual(authentications, ["resume agent access for “Coffee project”"])
        XCTAssertTrue(try XCTUnwrap(try onDisk("Coffee")).isRevoked, "cancelled: still paused")
        model.authenticate = { _ in true }
        await model.setPaused(false, project: "Silkweb")
        XCTAssertFalse(try XCTUnwrap(try onDisk("Silkweb")).isRevoked)
        XCTAssertEqual(model.draft?.isRevoked, false, "the selected grant's toggle follows")
        XCTAssertFalse(model.isEdited)
    }

    func testOutsideChangesDeletionUnsavedPromptAndRemove() async throws {
        try seed([grant("Silkweb", library: silkweb), grant("Coffee", library: silkweb)])
        let model = makeModel(answer: .alertThirdButtonReturn)
        await model.reload()
        await model.select(.grant("Silkweb"))

        // An unedited grant follows the file.
        var file = try AgentGrantOwner.load(grantsURL)
        file.grants[0].label = "From Terminal"
        try file.write(to: grantsURL)
        await model.reload()
        XCTAssertEqual(model.draft?.label, "From Terminal")
        XCTAssertEqual(model.outside, .none)

        // An edited one keeps the edits and shows the strip; Save is refused until Reload.
        model.draft?.access = .read
        file.grants[0].label = "Again"
        try file.write(to: grantsURL)
        await model.reload()
        XCTAssertEqual(model.outside, .changed)
        XCTAssertEqual(model.draft?.access, .read)
        await assertSave(model, false)
        XCTAssertEqual(alerts, ["Can’t Save This Grant"])
        model.reloadSelection()
        XCTAssertEqual(model.draft?.label, "Again")
        XCTAssertEqual(model.outside, .none)

        // Leaving with unsaved edits asks; Cancel stays, Don’t Save leaves, Save saves first.
        alerts = []
        model.draft?.label = "Edited"
        await model.select(.requests)
        XCTAssertEqual(alerts, ["Save changes to “Edited”?"])
        XCTAssertEqual(model.selection, .grant("Silkweb"), "Cancel stays")
        model.present = { _, _ in .alertSecondButtonReturn }
        await model.select(.grant("Coffee"))
        XCTAssertEqual(model.selection, .grant("Coffee"))
        XCTAssertEqual(try onDisk("Silkweb")?.label, "Again", "Don’t Save writes nothing")
        model.draft?.label = "Coffee beans"
        model.present = { _, _ in .alertFirstButtonReturn }
        await model.select(.requests)
        XCTAssertEqual(try onDisk("Coffee")?.label, "Coffee beans")
        XCTAssertEqual(model.selection, .requests)

        // Deleted in Terminal: the detail says so.
        await model.select(.grant("Silkweb"))
        try AgentGrantOwner.remove(project: "Silkweb", in: grantsURL)
        await model.reload()
        XCTAssertEqual(model.outside, .deleted)

        // Remove Grant… asks, then deletes the row.
        alerts = []
        model.present = { [weak self] alert, _ in
            self?.alerts.append(alert.messageText)
            XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
            XCTAssertEqual(alert.buttons.map(\.title), ["Remove", "Cancel"])
            return .alertSecondButtonReturn
        }
        await model.remove(project: "Coffee")
        XCTAssertEqual(alerts, ["Remove access for “Coffee beans”?"])
        XCTAssertNotNil(try onDisk("Coffee"), "Cancel keeps it")
        await model.select(.grant("Coffee"))
        model.present = { _, _ in .alertFirstButtonReturn }
        await model.remove(project: "Coffee")
        XCTAssertNil(try onDisk("Coffee"))
        XCTAssertNil(model.selection)
        XCTAssertTrue(model.file.grants.isEmpty)
    }

    func testAddFolderRefusesFoldersOutsideTheLibrary() async throws {
        try seed([grant("Silkweb", library: silkweb)])
        let model = makeModel()
        await model.reload()
        await model.select(.grant("Silkweb"))
        await model.addReadFolder(silkweb.appendingPathComponent("Notes"), library: silkweb)
        XCTAssertEqual(model.draft?.extraReadFolders, ["Notes"])
        await model.addReadFolder(writing.appendingPathComponent("Drafts"), library: silkweb)
        XCTAssertEqual(alerts, ["Can’t Add This Folder"])
        XCTAssertEqual(model.draft?.extraReadFolders, ["Notes"])
    }

    // MARK: New Grant

    func testNewGrantValidatesLikeGrantInitAndNeedsAuthentication() async throws {
        try seed([grant("Silkweb", library: silkweb)])
        let model = makeModel(authenticate: false)
        await model.reload()
        XCTAssertEqual(model.projectError("a/b"), "The project name isn’t a valid folder name.")
        XCTAssertEqual(model.projectError("Silkweb"), "A grant for “Silkweb” already exists.")
        XCTAssertNil(model.projectError("Coffee"))
        XCTAssertNil(model.projectError(""))

        model.beginNewGrant()
        let form = try XCTUnwrap(model.newGrant)
        XCTAssertEqual(form.library, silkweb.path, "a Library grants already use")
        XCTAssertEqual(form.access, .readCreate)
        form.project = "Coffee"
        form.agentFolder = "Claude"
        await assertCreate(model, form, false)
        XCTAssertEqual(authentications, ["give agents access to “Coffee project”"])
        XCTAssertNil(try onDisk("Coffee"), "nothing is written without authentication")
        XCTAssertNotNil(model.newGrant, "the sheet stays")

        model.authenticate = { _ in true }
        form.library = container.appendingPathComponent("Missing").path
        await assertCreate(model, form, false)
        XCTAssertEqual(alerts, ["Can’t Save This Grant"])

        form.library = writing.path
        await assertCreate(model, form, true)
        let saved = try XCTUnwrap(try onDisk("Coffee"))
        XCTAssertEqual(saved.library.path, writing.path)
        XCTAssertEqual(saved.agentFolder, "Claude")
        XCTAssertEqual(saved.access, .readCreate)
        XCTAssertNil(model.newGrant)
        XCTAssertEqual(model.selection, .grant("Coffee"))
        XCTAssertEqual(model.draft, saved)
    }

    // MARK: Agent Activity

    func testShowInAgentActivityFiltersByGrant() async throws {
        let silkwebNote = try receipt("Silkweb", in: silkweb, agent: "codex", minutes: 0)
        let coffeeNote = try receipt("Coffee", in: silkweb, agent: "codex", minutes: 5)
        try seed([grant("Silkweb", library: silkweb), grant("Coffee", library: silkweb)])
        let preferences = TestPreferences("AgentAccessShow")
        defer { preferences.remove() }
        let registry = LibraryWindowRegistry(defaults: preferences.defaults) {
            let workspace = LibraryWorkspace(defaults: preferences.defaults)
            workspace.canSaveWindowSession = false
            workspace.recoveryDirectory = self.container.appendingPathComponent("Recovery")
            return workspace
        }
        let model = makeModel()
        model.registry = registry
        await model.reload()
        await model.showInAgentActivity(try XCTUnwrap(model.file.grant(for: "Coffee")))
        let workspace = registry.current
        await workspace.reloadAgentActivity()
        await workspace.waitForNavigation()
        XCTAssertEqual(workspace.root, silkweb)
        XCTAssertTrue(workspace.agentScope)
        XCTAssertEqual(workspace.grantFilter, "Coffee")
        XCTAssertEqual(workspace.documents.map(\.relativePath), [coffeeNote.path])
        XCTAssertEqual(
            AgentActivity.grants(in: workspace.agentEntries).map { "\($0.id) \($0.count)" }, ["Coffee 1", "Silkweb 1"])
        workspace.agentFilter = "codex"
        XCTAssertNil(workspace.grantFilter, "the filters are exclusive")
        XCTAssertEqual(Set(workspace.documents.map(\.relativePath)), [coffeeNote.path, silkwebNote.path])
        workspace.grantFilter = "Silkweb"
        XCTAssertNil(workspace.agentFilter)
        XCTAssertEqual(workspace.documents.map(\.relativePath), [silkwebNote.path])
        await registry.closeLibrary(workspace)
    }

    // MARK: Offscreen hierarchy

    /// GUI rule: the real Agent Access hierarchy, never ordered on screen, through the empty state, a resize sweep,
    /// switching between Access Requests and grants, an edit and its Save, a paused grant and a deletion.
    func testOffscreenWindowThroughEmptyListEditPauseAndDeletion() async throws {
        _ = NSApplication.shared
        let model = makeModel()
        await model.reload()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: AgentAccessView(model: model))
        host.sizingOptions = []
        window.contentViewController = host
        defer {
            window.contentViewController = nil
            window.close()
        }
        func layout() async throws {
            try await Task.sleep(for: .milliseconds(1))
            host.view.layoutSubtreeIfNeeded()
        }
        func sweep() async throws {
            for size in [
                NSSize(width: 680, height: 440), NSSize(width: 1400, height: 900), NSSize(width: 780, height: 520),
            ] {
                window.setContentSize(size)
                try await layout()
            }
        }
        try await sweep()
        let minimum = NSHostingView(rootView: AgentAccessView(model: model)).fittingSize
        XCTAssertGreaterThanOrEqual(minimum.width, 679, "680 pt minimum")
        XCTAssertGreaterThanOrEqual(minimum.height, 439, "440 pt minimum")
        func sidebarRows() -> Int {
            Self.descendants(host.view).compactMap { $0 as? NSTableView }.first?.numberOfRows ?? 0
        }
        let emptyRows = sidebarRows()
        XCTAssertGreaterThanOrEqual(emptyRows, 1, "Access Requests is always the first row")

        try seed([grant("Silkweb", library: silkweb), grant("Coffee", library: writing, revoked: Self.created)])
        await model.reload()
        try await layout()
        XCTAssertGreaterThanOrEqual(sidebarRows(), emptyRows + 2, "both grants are listed without a restart")
        for selection: AgentAccessModel.Selection in [.requests, .grant("Coffee"), .grant("Silkweb")] {
            await model.select(selection)
            try await sweep()
        }
        model.draft?.access = .read
        try await layout()
        XCTAssertTrue(model.isEdited)
        await assertSave(model, true)
        try await layout()
        XCTAssertEqual(try onDisk("Silkweb")?.access, .read)
        try AgentGrantOwner.remove(project: "Silkweb", in: grantsURL)
        await model.reload()
        try await sweep()
        XCTAssertEqual(model.outside, .deleted)
    }
}

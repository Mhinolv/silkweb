import AppKit
import SilkwebCore

/// #229: the Agent Access window's state, one per app: every grant in `agent-grants.json`, every Library's access
/// requests (#203), the grant being edited and each grant's last activity. Files are read off the main thread and
/// watched, so Terminal `grant init`, approvals and hand edits show without a restart. Every change goes through
/// `AgentGrantOwner`; widening asks for owner authentication first.
@MainActor @Observable final class AgentAccessModel {
    static let shared = AgentAccessModel()
    static let sceneID = "agent-access"

    enum Selection: Hashable {
        case requests
        case grant(String)
    }

    /// What happened on disk to the grant being edited.
    enum OutsideChange: Equatable { case none, changed, deleted }

    /// The newest published receipt for one grant.
    struct Activity: Equatable, Sendable {
        let date: Date
        let agent: String
    }

    /// One sidebar section: a Library's grants.
    struct LibraryGroup: Identifiable, Equatable {
        let path: String
        let grants: [AgentGrant]
        var id: String { path }
        var name: String { path.isEmpty ? "No Library" : URL(fileURLWithPath: path).lastPathComponent }
    }

    private(set) var file = AgentGrantFile()
    /// Why the grants file can't be read (broken or newer); the list keeps what it showed.
    private(set) var loadError: String?
    /// Every Library's requests, waiting and decided.
    private(set) var requests: [AgentAccessRequest] = []
    private(set) var activity: [String: Activity] = [:]
    /// Library paths that don't exist (any more); their header says “Not found”.
    private(set) var missingLibraries: Set<String> = []
    private(set) var selection: Selection?
    /// The selected grant as loaded, and the owner's edited copy. Equal until something is edited.
    private(set) var original: AgentGrant?
    var draft: AgentGrant?
    private(set) var outside = OutsideChange.none
    /// The New Grant sheet.
    var newGrant: NewGrantForm?
    /// The request an Approve… or Deny… is working on.
    private(set) var deciding: String?
    private(set) var saving = false

    @ObservationIgnored var grantsURL = AgentGrantFile.defaultURL()
    @ObservationIgnored var requestStore = AgentAccessRequestStore.standard
    /// Owner decision 2026-10-09 (#203): Touch ID or the account password. Tests replace it.
    @ObservationIgnored var authenticate: @MainActor (String) async -> Bool =
        LibraryWorkspace.authenticateWithLocalAuthentication
    /// Shows an alert and returns the button chosen. Tests replace it.
    @ObservationIgnored var present: @MainActor (NSAlert, NSWindow?) async -> NSApplication.ModalResponse =
        AgentAccessModel.presentAlert
    @ObservationIgnored var clock: @MainActor () -> Date = { Date() }
    /// The library window's sections: the current Library leads, New Grant offers them, Show in Agent Activity opens one.
    @ObservationIgnored weak var registry: LibraryWindowRegistry?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var watcher: AccessRequestWatcher?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var activityTask: Task<Void, Never>?

    // MARK: Loading

    /// Starts watching both files (once) and reads them.
    func start() {
        if watcher == nil {
            watcher = AccessRequestWatcher(file: requestStore.url) { [weak self] in await self?.reload() }
        }
        Task { await reload() }
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Rereads grants and requests off the main thread, then refreshes last activity. Assigns only what changed.
    func reload() async {
        let previous = reloadTask
        let grantsURL = grantsURL
        let store = requestStore
        let task = Task {
            await previous?.value
            let (grants, requests) = await Task.detached(priority: .utility) {
                (Result { try AgentGrantOwner.load(grantsURL) }, try? store.load().requests)
            }.value
            switch grants {
            case .success(let loaded):
                if loaded != file { file = loaded }
                if loadError != nil { loadError = nil }
            case .failure(let error):
                let message = (error as? AgentAccessError)?.message ?? "The grants file can’t be read."
                if loadError != message { loadError = message }
            }
            if let requests, requests != self.requests { self.requests = requests }
            followDisk()
        }
        reloadTask = task
        await task.value
        await reloadActivity()
    }

    /// The selected grant changed on disk: an unedited one follows; an edited one keeps the edits and shows the strip.
    private func followDisk() {
        guard case .grant(let project) = selection else { return }
        guard let current = file.grant(for: project) else {
            if outside != .deleted { outside = .deleted }
            return
        }
        if current == original {
            if outside != .none { outside = .none }
        } else if isEdited {
            outside = .changed
        } else {
            original = current
            draft = current
            outside = .none
        }
    }

    /// Newest published receipt per grant, read from each Library's `.silkweb/agent-events/` off the main thread.
    func reloadActivity() async {
        let previous = activityTask
        let libraries = Dictionary(grouping: file.grants, by: { $0.library.path ?? "" }).mapValues {
            Set($0.map(\.project))
        }
        let task = Task {
            await previous?.value
            let (found, missing) = await Task.detached(priority: .utility) {
                Self.loadActivity(libraries)
            }.value
            if found != activity { activity = found }
            if missing != missingLibraries { missingLibraries = missing }
        }
        activityTask = task
        await task.value
    }

    nonisolated static func loadActivity(_ libraries: [String: Set<String>]) -> ([String: Activity], Set<String>) {
        var found: [String: Activity] = [:]
        var missing: Set<String> = []
        for (path, projects) in libraries {
            var isFolder: ObjCBool = false
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isFolder),
                isFolder.boolValue
            else {
                missing.insert(path)
                continue
            }
            for receipt in AgentActivity.load(root: URL(fileURLWithPath: path)).receipts
            where receipt.outcome.isPublished && projects.contains(receipt.grantId) {
                guard let date = AgentActivity.date(receipt.createdAt) else { continue }
                if let newest = found[receipt.grantId], newest.date >= date { continue }
                found[receipt.grantId] = Activity(date: date, agent: AgentActivity.displayName(receipt.agent))
            }
        }
        return (found, missing)
    }

    // MARK: Presentation

    /// One section per Library: the current Library first, then by name.
    var groups: [LibraryGroup] {
        let current = registry?.current.root.map { RecentLibraries.canonicalPath($0.path) }
        let grouped = Dictionary(grouping: file.grants, by: { $0.library.path ?? "" })
        return grouped.map { LibraryGroup(path: $0.key, grants: $0.value) }.sorted { lhs, rhs in
            let left = RecentLibraries.canonicalPath(lhs.path) == current
            let right = RecentLibraries.canonicalPath(rhs.path) == current
            if left != right { return left }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
    }

    func review(_ now: Date) -> (waiting: [AgentAccessRequest], history: [AgentAccessRequest]) {
        AgentAccessRequestFile(requests: requests).review(now: now, historyLimit: 50)
    }

    var waitingCount: Int {
        let now = clock()
        return requests.count { $0.isPending(at: now) }
    }

    /// “3 grants · 1 request waiting” for Settings ▸ Library.
    var summary: String {
        let grants = file.grants.count == 1 ? "1 grant" : "\(file.grants.count) grants"
        let waiting = waitingCount
        guard waiting > 0 else { return grants }
        return grants + " · " + (waiting == 1 ? "1 request waiting" : "\(waiting) requests waiting")
    }

    /// The label the Agent Activity pull-down shows for a receipt's grant.
    func label(for project: String) -> String {
        file.grant(for: project)?.displayLabel ?? project + " project"
    }

    /// “Read and Create · active Oct 9”.
    func rowDetail(_ grant: AgentGrant) -> String {
        grant.access.displayName + " · "
            + (activity[grant.project].map { "active " + AgentAccessRequests.shortDate($0.date) } ?? "no activity")
    }

    /// One VoiceOver element: “Silkweb project, Read and Create, paused, last active Oct 9”.
    func accessibilityLabel(_ grant: AgentGrant) -> String {
        var parts = [grant.displayLabel, grant.access.displayName]
        if grant.isRevoked { parts.append("paused") }
        parts.append(
            activity[grant.project].map { "last active " + AgentAccessRequests.shortDate($0.date) } ?? "no activity")
        return parts.joined(separator: ", ")
    }

    var isEdited: Bool { draft != nil && draft != original }

    var selectsGrant: Bool {
        if case .grant = selection { return true }
        return false
    }

    // MARK: Selection

    /// Opens the window on `selection` (Go ▸ Agent Access…, the strip's Access Requests, Show Grant).
    func select(_ next: Selection?) async {
        guard next != selection else { return }
        if isEdited, let draft {
            switch await present(AgentAccessAlerts.unsaved(draft), window) {
            case .alertFirstButtonReturn: guard await save() else { return }
            case .alertSecondButtonReturn: break
            default: return
            }
        }
        selection = next
        loadSelection()
    }

    private func loadSelection() {
        outside = .none
        guard case .grant(let project) = selection else {
            original = nil
            draft = nil
            return
        }
        original = file.grant(for: project)
        draft = original
        if original == nil { outside = .deleted }
    }

    /// The strip's Reload: drops the edits and shows the grant as it is on disk.
    func reloadSelection() { loadSelection() }

    func revert() { draft = original }

    // MARK: Editing

    /// Allow access: off pauses from now (or keeps the first date); on resumes.
    func setAllowed(_ allowed: Bool) {
        guard draft != nil else { return }
        let now = Date(timeIntervalSince1970: clock().timeIntervalSince1970.rounded(.down))
        draft?.revokedAt = allowed ? nil : (original?.revokedAt ?? now)
    }

    func addReadFolder(_ folder: String) {
        guard let draft else { return }
        self.draft?.extraReadFolders = AgentGrantOwner.addingReadFolder(folder, to: draft)
    }

    func removeReadFolder(_ folder: String) {
        draft?.extraReadFolders.removeAll { $0 == folder }
    }

    /// Add Folder…: an open panel rooted at the Library. A folder outside it alerts with `grant init`'s copy.
    func chooseReadFolder() async {
        guard let draft, let path = draft.library.path else { return }
        let library = URL(fileURLWithPath: path)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = library
        panel.prompt = "Add Folder"
        panel.message = "Choose a folder in “\(library.lastPathComponent)” that agents may read."
        let response: NSApplication.ModalResponse
        if let window {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let url = panel.url else { return }
        await addReadFolder(url, library: library)
    }

    func addReadFolder(_ url: URL, library: URL) async {
        do {
            addReadFolder(try AgentGrantOwner.readFolder(url, library: library))
        } catch {
            let message = (error as? AgentScopeError)?.message ?? "That folder isn’t inside the Library."
            _ = await present(AgentAccessAlerts.failure("Can’t Add This Folder", message), window)
        }
    }

    /// Save: a widening change asks for owner authentication first; cancelling it writes nothing and keeps the edits.
    @discardableResult
    func save() async -> Bool {
        guard let draft, isEdited, !saving else { return !isEdited }
        let original = original
        let widens = !AgentGrantOwner.widenings(from: original, to: draft).isEmpty
        if widens {
            guard await authenticate("change agent access for “\(draft.displayLabel)”") else { return false }
        }
        saving = true
        defer { saving = false }
        let url = grantsURL
        let result = await Task.detached(priority: .userInitiated) {
            Result { try AgentGrantOwner.save(draft, replacing: original, in: url, authenticated: widens) }
        }.value
        switch result {
        case .success(let saved):
            self.original = saved
            self.draft = saved
            outside = .none
            await reload()
            return true
        case .failure(let error):
            _ = await present(AgentAccessAlerts.failure(error), window)
            return false
        }
    }

    /// Pause Access (no authentication) or Resume Access (authentication first), applied at once.
    func setPaused(_ paused: Bool, project: String) async {
        let label = label(for: project)
        if !paused { guard await authenticate("resume agent access for “\(label)”") else { return } }
        let url = grantsURL
        let now = clock()
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                try AgentGrantOwner.setPaused(paused, project: project, in: url, authenticated: !paused, now: now)
            }
        }.value
        switch result {
        case .success(let saved):
            if selection == .grant(project) {
                // Edits elsewhere in the form stay; Allow access shows the saved state.
                draft?.revokedAt = saved.revokedAt
                original = saved
            }
        case .failure(let error):
            _ = await present(AgentAccessAlerts.failure(error), window)
        }
        await reload()
    }

    /// Remove Grant…: asks, then deletes the row. Pause is the reversible option.
    func remove(project: String) async {
        guard await present(AgentAccessAlerts.remove(label(for: project)), window) == .alertFirstButtonReturn else {
            return
        }
        let url = grantsURL
        let result = await Task.detached(priority: .userInitiated) {
            Result { try AgentGrantOwner.remove(project: project, in: url) }
        }.value
        if case .failure(let error) = result {
            _ = await present(AgentAccessAlerts.failure(error), window)
        } else if selection == .grant(project) {
            selection = nil
            original = nil
            draft = nil
            outside = .none
        }
        await reload()
    }

    // MARK: New Grant

    /// New Grant…: the sheet, on the current Library when one is open.
    func beginNewGrant() {
        newGrant = NewGrantForm(library: registry?.current.root?.path ?? libraryChoices.first ?? "")
    }

    /// Open and Recent Libraries and the Libraries grants already use, without repeats.
    var libraryChoices: [String] {
        var paths: [String] = []
        var seen: Set<String> = []
        let candidates =
            (registry?.sections.compactMap { $0.root?.path } ?? [])
            + (registry?.recentItems().map(\.path) ?? []) + file.grants.compactMap(\.library.path)
        for path in candidates where seen.insert(RecentLibraries.canonicalPath(path)).inserted { paths.append(path) }
        return paths
    }

    /// The project key's inline error: `grant init`'s copy, or that a grant for it exists.
    func projectError(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        guard let key = AgentGrantOwner.validProject(text) else { return AgentGrantOwner.invalidProjectMessage }
        return file.grant(for: key) == nil ? nil : AgentGrantOwner.existsMessage(key)
    }

    /// Create: `grant init`'s checks, the not-local warning, owner authentication, then the save. Selects the grant.
    @discardableResult
    func create(_ form: NewGrantForm) async -> Bool {
        let (library, project, label, access, agent) = (
            form.library, form.project, form.label, form.access, form.agentFolder
        )
        let made = await Task.detached(priority: .userInitiated) {
            Result {
                try AgentGrantOwner.newGrant(
                    library: library, project: project, label: label, access: access, agentFolder: agent)
            }
        }.value
        let sheet = window?.attachedSheet ?? window
        let grant: AgentGrant
        switch made {
        case .failure(let error):
            _ = await present(AgentAccessAlerts.failure(error), sheet)
            return false
        case .success(let value):
            if value.filesystem == .unqualified, access.allowsCreate {
                guard await present(AgentAccessAlerts.notLocal(library), sheet) == .alertFirstButtonReturn else {
                    return false
                }
            }
            grant = value.grant
        }
        guard await authenticate("give agents access to “\(grant.displayLabel)”") else { return false }
        let url = grantsURL
        let saved = await Task.detached(priority: .userInitiated) {
            Result { try AgentGrantOwner.save(grant, replacing: nil, in: url, authenticated: true) }
        }.value
        if case .failure(let error) = saved {
            _ = await present(AgentAccessAlerts.failure(error), sheet)
            return false
        }
        newGrant = nil
        await reload()
        selection = .grant(grant.project)
        loadSelection()
        return true
    }

    // MARK: Requests (#203)

    /// Approve…: refusals first (would widen, already decided), then the confirmation, then owner authentication,
    /// then the same core approval as `silkweb grant approve`. A widen refusal offers Show Grant.
    func approve(_ request: AgentAccessRequest) async {
        guard deciding == nil else { return }
        deciding = request.id
        defer { deciding = nil }
        let store = requestStore
        let grants = grantsURL
        let now = clock()
        let preview = await Task.detached(priority: .userInitiated) {
            Result { try store.previewApproval(request.id, grantsURL: grants, now: now) }
        }.value
        if case .failure(let error) = preview {
            let showGrant =
                (error as? AgentAccessError)?.code == "approve_would_widen" && file.grant(for: request.project) != nil
            let response = await present(AccessRequestAlerts.refusal(error, showGrant: showGrant), window)
            await reload()
            if showGrant, response == .alertSecondButtonReturn { await select(.grant(request.project)) }
            return
        }
        guard await present(AccessRequestAlerts.confirm(request), window) == .alertFirstButtonReturn else { return }
        guard await authenticate("approve access for “\(request.agentName)” to “\(request.project)”") else { return }
        let decided = await Task.detached(priority: .userInitiated) {
            Result { try store.decide(request.id, approve: true, via: .app, grantsURL: grants, now: Date()) }
        }.value
        if case .failure(let error) = decided {
            _ = await present(AccessRequestAlerts.refusal(error), window)
        }
        await reload()
    }

    /// Deny…: an optional note for the agent, then the denial. Nothing changes in `agent-grants.json`.
    func deny(_ request: AgentAccessRequest) async {
        guard deciding == nil else { return }
        deciding = request.id
        defer { deciding = nil }
        let store = requestStore
        let grants = grantsURL
        let alert = AccessRequestAlerts.deny(request)
        guard await present(alert, window) == .alertFirstButtonReturn else { return }
        let note = (alert.accessoryView as? NSTextField)?.stringValue ?? ""
        let decided = await Task.detached(priority: .userInitiated) {
            Result {
                try store.decide(request.id, approve: false, note: note, via: .app, grantsURL: grants, now: Date())
            }
        }.value
        if case .failure(let error) = decided {
            _ = await present(AccessRequestAlerts.refusal(error), window)
        }
        await reload()
    }

    // MARK: Agent Activity

    /// Show in Agent Activity: opens (or focuses) the grant's Library and filters Agent Activity to the grant.
    func showInAgentActivity(_ grant: AgentGrant) async {
        guard let registry, let path = grant.library.path else { return }
        guard let workspace = await registry.add(URL(fileURLWithPath: path)) else { return }
        workspace.grantFilter = grant.project
        workspace.selectAgentActivity()
        registry.orderFront()
    }

    // MARK: Alerts

    static func presentAlert(_ alert: NSAlert, window: NSWindow?) async -> NSApplication.ModalResponse {
        guard let window else {
            guard NSClassFromString("XCTestCase") == nil else { return .abort }
            return alert.runModal()
        }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }
}

/// The New Grant sheet's fields.
@MainActor @Observable final class NewGrantForm: Identifiable {
    let id = UUID()
    var library: String
    var project = ""
    var label = ""
    var access = AgentGrant.Access.readCreate
    var agentFolder = ""

    init(library: String) { self.library = library }
}

/// The Agent Access window's alerts. The first button is the action.
@MainActor enum AgentAccessAlerts {
    /// “Save changes to “Silkweb project”?” Save / Don’t Save / Cancel.
    static func unsaved(_ grant: AgentGrant) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(grant.displayLabel)”?"
        alert.informativeText = "Your changes to this grant aren’t saved yet."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    static func remove(_ label: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Remove access for “\(label)”?"
        alert.informativeText =
            "Agents using it stop at their next operation. Documents aren’t changed. To allow access again, create a "
            + "new grant."
        alert.addButton(withTitle: "Remove").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    /// The Library isn't on a local disk: creating stays off (`grant init`'s warning).
    static func notLocal(_ library: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(URL(fileURLWithPath: library).lastPathComponent)” isn’t on a local disk."
        alert.informativeText = AgentGrantOwner.notLocalWarning
        alert.addButton(withTitle: "Create Grant")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    static func failure(_ error: Error) -> NSAlert {
        if let owner = error as? AgentGrantOwner.Failure { return failure(owner.title, owner.message) }
        if let error = error as? AgentAccessError { return failure("Can’t Save This Grant", error.message) }
        return failure("Can’t Save This Grant", "Silkweb couldn’t save “agent-grants.json”. Nothing was saved.")
    }

    static func failure(_ title: String, _ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        return alert
    }
}

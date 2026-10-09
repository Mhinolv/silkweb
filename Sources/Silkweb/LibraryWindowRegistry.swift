import AppKit
import Observation
import SilkwebCore

/// The library window's open Libraries (#195): one window, each Library a sidebar section with its own
/// `LibraryWorkspace` (#194: own watcher, index, tabs). The section holding the selection is `current`; the list,
/// the editor and every command act on it. Sections never duplicate: the key is the canonical root path.
@MainActor @Observable final class LibraryWindowRegistry: NSObject {
    static let shared = LibraryWindowRegistry()
    static let recentsKey = "recentLibraries"
    /// The open sections, saved for relaunch (#196).
    static let sessionKey = "appSession"

    /// Every workspace in the window, in the order its section was added. A workspace without a Library is the
    /// welcome (or can't-open) screen; there is one only while no section is open.
    private(set) var workspaces: [LibraryWorkspace]
    /// The current Library: the section that holds the selection.
    private(set) var current: LibraryWorkspace
    /// File ▸ Open Recent ▸ and the welcome screen's Recent Libraries, most recent first.
    private(set) var recents: RecentLibraries
    /// The library window is up; commands bring it back first otherwise.
    private(set) var hasWindow = false
    @ObservationIgnored private weak var window: NSWindow?
    /// Sections whose tabs closed with the window; each reopens its tabs when it is next current.
    @ObservationIgnored private var resumesEditors: Set<ObjectIdentifier> = []
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let makeWorkspace: @MainActor () -> LibraryWorkspace
    /// A newer build's app session is kept as it is (#196).
    @ObservationIgnored private var canSaveSession = true
    /// Launch is restoring the sections, or Quit / Close Window has snapshotted them: nothing is saved meanwhile.
    @ObservationIgnored private var sessionSuspended = false
    @ObservationIgnored private var sessionRestore: Task<Void, Never>?
    /// Presents an alert and returns true for its first button. Tests replace it.
    @ObservationIgnored var presentAlert: @MainActor (NSAlert, NSWindow?) async -> Bool =
        LibraryWorkspace.presentAlert(_:window:)

    init(
        defaults: UserDefaults = AppDefaults.store,
        makeWorkspace: @escaping @MainActor () -> LibraryWorkspace = { LibraryWorkspace() }
    ) {
        self.defaults = defaults
        self.makeWorkspace = makeWorkspace
        recents = Self.loadRecents(defaults)
        let first = makeWorkspace()
        current = first
        workspaces = [first]
        super.init()
        first.shell = self
    }

    /// Commands, Settings ▸ Library and the window's columns act here.
    var target: LibraryWorkspace { current }

    /// Open Libraries in sidebar order.
    var sections: [LibraryWorkspace] { workspaces.filter { $0.root != nil } }

    /// The open section whose Library is at `root` (canonical file URL comparison).
    func workspace(for root: URL) -> LibraryWorkspace? {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        return sections.first { $0.root?.standardizedFileURL.resolvingSymlinksInPath() == root }
    }

    private func newWorkspace() -> LibraryWorkspace {
        let workspace = makeWorkspace()
        workspace.shell = self
        // Only the launch workspace restores the last-opened Library.
        workspace.restoresLastLibrary = false
        workspace.attachedWindow = window
        return workspace
    }

    // MARK: Sections

    /// Open Folder in Place…, New Library…, the welcome screen and Open Recent (#195): focuses the section if the
    /// folder is open, else checks it can be read and appends a section (or opens it on the welcome screen). A
    /// failure alerts on the current Library and changes no section or selection (#102).
    @discardableResult
    func add(_ url: URL, usesSecurityScope: Bool = false) async -> LibraryWorkspace? {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        if let open = workspace(for: url) {
            focus(open)
            return open
        }
        let title = "“\(url.lastPathComponent)” couldn’t be opened."
        do {
            try await Task.detached(priority: .userInitiated) {
                try LibraryLocationRestore.validateDirectory(url, scoped: usesSecurityScope)
            }.value
        } catch {
            fail(title, Self.message(for: error))
            return nil
        }
        // A second request for the same folder may have landed while this one was checking.
        if let open = workspace(for: url) {
            focus(open)
            return open
        }
        let previous = current
        let inPlace = current.root == nil && !current.loading
        let workspace = inPlace ? current : newWorkspace()
        if !inPlace { workspaces.append(workspace) }
        workspace.beginOpening(url)
        workspace.open(url, usesSecurityScope: usesSecurityScope)
        focus(workspace)
        await workspace.waitForLoad()
        // An appended section that couldn't load leaves again; the welcome screen keeps its error instead.
        if !inPlace, workspace.snapshot == nil, let error = workspace.error,
            workspaces.contains(where: { $0 === workspace })
        {
            await workspace.releaseLibrary()
            workspaces.removeAll { $0 === workspace }
            if current === workspace {
                setCurrent(workspaces.contains { $0 === previous } ? previous : sections.last ?? welcomeWorkspace())
            }
            fail(title, error)
            return nil
        }
        return workspace
    }

    /// Already open: expands the section, selects its remembered scope and scrolls it into view. No alert.
    func focus(_ workspace: LibraryWorkspace) {
        guard workspaces.contains(where: { $0 === workspace }) else { return }
        workspace.sectionCollapsed = false
        workspace.sectionRevealRequest += 1
        setCurrent(workspace)
    }

    private func setCurrent(_ workspace: LibraryWorkspace) {
        guard workspace !== current else { return }
        current = workspace
        if resumesEditors.remove(ObjectIdentifier(workspace)) != nil {
            Task { await workspace.resumeEditor() }
        }
        saveSession()
    }

    private func welcomeWorkspace() -> LibraryWorkspace {
        if let empty = workspaces.first(where: { $0.root == nil }) { return empty }
        let empty = newWorkspace()
        workspaces.append(empty)
        return empty
    }

    /// Settings ▸ Library ▸ Choose Library… (and Locate… on a can't-open screen) replace this section in place:
    /// `open` flushes first, and a refused flush keeps it (#102). A folder already open elsewhere is focused.
    func replace(_ workspace: LibraryWorkspace, with url: URL) {
        if let open = self.workspace(for: url), open !== workspace {
            focus(open)
            return
        }
        workspace.open(url)
        focus(workspace)
    }

    /// File ▸ Close Library and the section header's context menu (#195; owner decision 2026-10-09): asks first
    /// whenever one of the Library's tabs has unsaved changes, saves them, then closes only that Library's tabs.
    /// A failed save alerts and closes nothing. The files stay on disk and the folder stays in Open Recent.
    @discardableResult
    func closeLibrary(_ workspace: LibraryWorkspace) async -> Bool {
        guard let root = workspace.root, workspaces.contains(where: { $0 === workspace }) else { return false }
        let name = root.lastPathComponent
        await workspace.waitForNavigation()
        guard !workspace.mutating else { return false }
        if workspace.allEditors.contains(where: { $0.state.isDirty }) {
            guard await presentAlert(Self.closeLibraryAlert(name), window) else { return false }
        }
        guard await workspace.flushEditors() else {
            _ = await presentAlert(Self.saveFailedAlert(name), window)
            return false
        }
        let order = sections
        guard let index = order.firstIndex(where: { $0 === workspace }) else { return false }
        await workspace.saveSessionNow()
        await workspace.releaseLibrary()
        workspaces.removeAll { $0 === workspace }
        resumesEditors.remove(ObjectIdentifier(workspace))
        if current === workspace {
            // The next section's remembered scope, else the previous one's; the welcome screen after the last.
            let remaining = sections
            if remaining.isEmpty {
                setCurrent(welcomeWorkspace())
            } else {
                focus(remaining[min(index, remaining.count - 1)])
            }
        }
        saveSession()
        return true
    }

    // MARK: Open Recent

    /// Called by `LibraryWorkspace.open` after a successful load: the entry is recorded only then.
    func libraryDidOpen(_ location: LibraryLocation) {
        recents.record(location)
        saveRecents()
        saveSession()
    }

    func recentItems() -> [RecentLibraryItem] {
        recents.items(openPaths: Set(sections.compactMap { $0.root?.path }))
    }

    func openRecent(_ path: String) async {
        if let open = workspace(for: URL(fileURLWithPath: path)) {
            focus(open)
            return
        }
        guard let location = recents.entry(path: path) else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let resolved = try? await Task.detached(priority: .userInitiated) {
            try LibraryLocationRestore.restore(location)
        }.value
        guard let resolved else {
            if await presentAlert(Self.missingRecentAlert(name), window) {
                recents.remove(path: path)
                saveRecents()
            }
            return
        }
        // The bookmark followed a moved folder: the old path's entry gives way to the new one.
        if RecentLibraries.canonicalPath(resolved.url.path) != RecentLibraries.canonicalPath(path) {
            recents.remove(path: path)
            saveRecents()
        }
        await add(resolved.url, usesSecurityScope: resolved.usesSecurityScope)
    }

    func clearRecents() {
        recents.clear()
        saveRecents()
    }

    private static func loadRecents(_ defaults: UserDefaults) -> RecentLibraries {
        if let data = defaults.data(forKey: recentsKey) {
            return (try? JSONDecoder().decode(RecentLibraries.self, from: data)) ?? RecentLibraries()
        }
        let legacy = defaults.data(forKey: "libraryLocation").flatMap {
            try? JSONDecoder().decode(LibraryLocation.self, from: $0)
        }
        return .seeded(from: legacy)
    }

    private func saveRecents() {
        guard let data = try? JSONEncoder().encode(recents) else { return }
        defaults.set(data, forKey: Self.recentsKey)
    }

    // MARK: Relaunch (#196)

    /// Launch: reopens the saved sections in their order and collapse state, the current Library first, or the
    /// legacy single `libraryLocation` when there is no usable app session. With “Reopen windows and tabs” off, only
    /// the last current Library comes back, without tabs (owner decision on #196). Runs once. Nothing is saved
    /// before it has run, so a launch that hasn't restored yet never replaces the saved sections.
    @discardableResult
    func restoreSession(reopensSession: Bool = LivePreferences.shared.current.reopensSession) -> Task<Void, Never> {
        if let sessionRestore { return sessionRestore }
        let launch = current
        let restore: Task<Void, Never>
        if !launch.restoresLastLibrary || launch.root != nil || launch.loading || !sections.isEmpty {
            restore = Task {}
        } else {
            switch AppSessionLaunch.plan(defaults.data(forKey: Self.sessionKey), reopensSession: reopensSession) {
            case .legacy(let canSave):
                canSaveSession = canSave
                if !canSave {
                    NSLog("Silkweb: the saved library session is from a newer version; it is left as it is.")
                }
                launch.restore()
                restore = Task {}
            case .sections(let session):
                launch.restoresLastLibrary = false
                sessionSuspended = true
                restore = Task {
                    await self.restore(session, launch: launch)
                    self.sessionSuspended = false
                    self.saveSession()
                }
            }
        }
        sessionRestore = restore
        return restore
    }

    private func restore(_ session: AppSession, launch: LibraryWorkspace) async {
        guard let currentIndex = session.currentIndex else { return }
        // Every section shows from the first frame, loading, in its saved order.
        let restored = session.sections.enumerated().map { index, section in
            let workspace = index == 0 ? launch : newWorkspace()
            if index > 0 { workspaces.append(workspace) }
            workspace.libraryLocation = section.location
            workspace.sectionCollapsed = section.collapsed
            workspace.beginOpening(URL(fileURLWithPath: section.path ?? "/"))
            return workspace
        }
        let locations = session.sections.map(\.location)
        let resolved = await Task.detached(priority: .userInitiated) {
            locations.map { location -> Result<ResolvedLibraryLocation, LibraryLocationError> in
                do {
                    guard let resolved = try LibraryLocationRestore.restore(location) else {
                        return .failure(.notFound)
                    }
                    return .success(resolved)
                } catch {
                    return .failure(error as? LibraryLocationError ?? .unreadable)
                }
            }
        }.value
        var opened: [(workspace: LibraryWorkspace, location: ResolvedLibraryLocation)] = []
        var openPaths: Set<String> = []
        for (workspace, result) in zip(restored, resolved) {
            switch result {
            case .success(let location):
                // Two saved bookmarks that now resolve to one folder keep only the first section.
                guard openPaths.insert(RecentLibraries.canonicalPath(location.url.path)).inserted else {
                    workspaces.removeAll { $0 === workspace }
                    continue
                }
                if let refreshed = location.refreshedLocation { workspace.libraryLocation = refreshed }
                opened.append((workspace, location))
            case .failure(let failure):
                // A missing Library keeps its section and shows why; there's no alert at launch.
                workspace.showUnavailable(failure)
            }
        }
        // The saved current Library, else the first one that opens, else the first section.
        let saved = restored[currentIndex]
        let first = opened.contains { $0.workspace === saved } ? saved : opened.first?.workspace ?? sections[0]
        setCurrent(first)
        // The current Library loads first; the others after it.
        let ordered = opened.filter { $0.workspace === first } + opened.filter { $0.workspace !== first }
        for (index, entry) in ordered.enumerated() {
            entry.workspace.open(entry.location.url, usesSecurityScope: entry.location.usesSecurityScope)
            if index == 0 { await entry.workspace.waitForLoad() }
        }
        for entry in ordered.dropFirst() { await entry.workspace.waitForLoad() }
        // Keyboard focus returns to the column that had it.
        if let column = session.focusColumn, (0...2).contains(column), current.snapshot != nil,
            column == 2 || !current.sidebarsHidden
        {
            current.focus(column)
        }
    }

    /// The sections as they are now; the welcome screen has none.
    var appSession: AppSession {
        AppSession(
            sections: sections.compactMap { workspace in
                guard let root = workspace.root else { return nil }
                let key = RecentLibraries.canonicalPath(root.path)
                let location =
                    workspace.libraryLocation.flatMap { $0.path.map(RecentLibraries.canonicalPath) == key ? $0 : nil }
                    ?? LibraryLocation(path: root.path)
                return AppSession.Section(location: location, collapsed: workspace.sectionCollapsed)
            },
            currentPath: current.root?.path, focusColumn: current.root == nil ? nil : current.focusColumn)
    }

    /// Saved whenever a section opens, closes, collapses or becomes current: paths and bookmarks only.
    func saveSession() {
        guard canSaveSession, !sessionSuspended, sessionRestore != nil,
            let data = try? JSONEncoder().encode(appSession)
        else { return }
        defaults.set(data, forKey: Self.sessionKey)
    }

    // MARK: Alerts

    /// The existing failure alert (`mutationFailure` style) on the current Library.
    private func fail(_ title: String, _ message: String) {
        current.mutationRevealURLs = []
        current.mutationErrorTitle = title
        current.mutationError = message
    }

    private static func message(for error: Error) -> String {
        switch error as? LibraryLocationError {
        case .notFound: "The folder may have been moved, renamed or deleted."
        case .unreadable: "Silkweb doesn’t have permission to read it."
        case nil: error.localizedDescription
        }
    }

    static func closeLibraryAlert(_ name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Close “\(name)”?"
        alert.informativeText =
            "Some of its documents have unsaved changes. Silkweb saves them before closing the library."
        alert.addButton(withTitle: "Close Library")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func saveFailedAlert(_ name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(name)” couldn’t be saved."
        alert.informativeText = "The library stays open with its documents."
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    static func missingRecentAlert(_ name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "“\(name)” can’t be opened."
        alert.informativeText = "The folder may have been moved, renamed or deleted."
        alert.addButton(withTitle: "Remove from Recents")
        alert.addButton(withTitle: "Cancel")
        return alert
    }

    // MARK: Window and Quit

    /// The library window is up. Repeated calls (the probe moving between hierarchies) are harmless.
    func register(window: NSWindow) {
        self.window = window
        hasWindow = true
        for workspace in workspaces { workspace.attachedWindow = window }
    }

    /// The window closed: every section keeps its Library; its tabs reopen when the window comes back.
    func windowClosed() async {
        hasWindow = false
        for workspace in workspaces {
            await workspace.didCloseWindow()
            if workspace !== current { resumesEditors.insert(ObjectIdentifier(workspace)) }
        }
    }

    /// The current Library first, then the others in sidebar order.
    var allWorkspaces: [LibraryWorkspace] { [current] + workspaces.filter { $0 !== current } }

    /// Quit and Close Window: one Library at a time; each becomes current before its unsaved-changes alert, and
    /// Cancel in any alert stops and leaves every section open. Tests replace `prepare`.
    func prepareToExit(
        _ reason: DocumentSession.ExitReason, _ prepare: ((LibraryWorkspace) async -> Bool)? = nil
    ) async -> Bool {
        // #196: the sections are saved before any alert makes another Library current or the window closes.
        saveSession()
        let suspended = sessionSuspended
        sessionSuspended = true
        let permitted = await prepareEach(reason, prepare)
        // A quit that goes ahead keeps this snapshot; Cancel, and a closed window, save as usual again.
        if !(permitted && reason == .quit) { sessionSuspended = suspended }
        if !permitted { saveSession() }
        return permitted
    }

    private func prepareEach(
        _ reason: DocumentSession.ExitReason, _ prepare: ((LibraryWorkspace) async -> Bool)?
    ) async -> Bool {
        for workspace in allWorkspaces {
            let permitted: Bool
            if let prepare {
                permitted = await prepare(workspace)
            } else {
                permitted = await workspace.prepareToExit(reason) { [weak self] in
                    self?.focus(workspace)
                    self?.window?.makeKeyAndOrderFront(nil)
                }
            }
            guard permitted else { return false }
        }
        return true
    }

    func prepareToQuit(_ prepare: ((LibraryWorkspace) async -> Bool)? = nil) async -> Bool {
        await prepareToExit(.quit, prepare)
    }

    func flushEditors() async {
        for workspace in allWorkspaces { await workspace.flushEditors() }
    }
}

import AppKit
import Observation
import SilkwebCore

/// The library window's open Libraries (#195): one window, each Library a sidebar section with its own
/// `LibraryWorkspace` (#194: own watcher, index, tabs). The section holding the selection is `current`; the list,
/// the editor and every command act on it. Sections never duplicate: the key is the canonical root path.
@MainActor @Observable final class LibraryWindowRegistry: NSObject {
    static let shared = LibraryWindowRegistry()
    static let recentsKey = "recentLibraries"

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
        return true
    }

    // MARK: Open Recent

    /// Called by `LibraryWorkspace.open` after a successful load: the entry is recorded only then.
    func libraryDidOpen(_ location: LibraryLocation) {
        recents.record(location)
        saveRecents()
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

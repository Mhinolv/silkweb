import AppKit
import Observation

/// One `LibraryWorkspace` per library window (#194). The app's commands and Settings ▸ Library are registered once
/// and act on `target`: the key library window, or the last one to be key while Settings or a panel is in front.
@MainActor @Observable final class LibraryWindowRegistry: NSObject {
    static let shared = LibraryWindowRegistry()

    /// Open library windows' workspaces, the most recently key first.
    private(set) var workspaces: [LibraryWorkspace] = []
    /// The workspace without a window: the launch one, or the last one closed, which the next library window
    /// adopts so a Dock click reopens the last Library as the single `Window` scene did. Never nil while
    /// `workspaces` is empty; it only changes together with `workspaces`, which publishes the change.
    @ObservationIgnored private var spare: LibraryWorkspace?
    /// A window has taken `spare` and not attached yet; another new window gets a fresh workspace.
    @ObservationIgnored private var spareClaimed = false
    /// Per-window split autosave slot; 0 keeps the legacy name (see `AppDefaults.windowColumnAutosaveName(base:slot:)`).
    @ObservationIgnored private var slots: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private let columnAutosaveBase: String?
    @ObservationIgnored private let makeWorkspace: @MainActor (String?) -> LibraryWorkspace

    init(
        columnAutosaveBase: String? = AppDefaults.columnAutosaveName,
        makeWorkspace: @escaping @MainActor (String?) -> LibraryWorkspace = { LibraryWorkspace(columnAutosaveName: $0) }
    ) {
        self.columnAutosaveBase = columnAutosaveBase
        self.makeWorkspace = makeWorkspace
        let first = makeWorkspace(AppDefaults.windowColumnAutosaveName(base: columnAutosaveBase, slot: 0))
        spare = first
        super.init()
        slots[ObjectIdentifier(first)] = 0
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowBecameKey(_:)), name: NSWindow.didBecomeKeyNotification, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Library-wide commands and Settings ▸ Library act here. With no library window open it is the workspace the
    /// next window adopts.
    var target: LibraryWorkspace { workspaces.first ?? spare! }

    /// The open library window whose Library is at `root` (canonical file URL comparison).
    func workspace(for root: URL) -> LibraryWorkspace? {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        return workspaces.first { $0.root?.standardizedFileURL.resolvingSymlinksInPath() == root }
    }

    func isOpen(_ workspace: LibraryWorkspace) -> Bool { workspaces.contains { $0 === workspace } }

    /// A new library window's workspace. The first one takes over the spare (with its saved Library and column
    /// widths); later ones start on the welcome screen with their own autosave slot.
    func adopt() -> LibraryWorkspace {
        if let spare, !spareClaimed {
            spareClaimed = true
            return spare
        }
        let used = Set(slots.values)
        let slot = (0...).first { !used.contains($0) }!
        let workspace = makeWorkspace(AppDefaults.windowColumnAutosaveName(base: columnAutosaveBase, slot: slot))
        // Only the adopted spare restores the last-opened Library, so two windows never open it twice.
        workspace.restoresLastLibrary = false
        slots[ObjectIdentifier(workspace)] = slot
        return workspace
    }

    func slot(of workspace: LibraryWorkspace) -> Int? { slots[ObjectIdentifier(workspace)] }

    /// The workspace's window is up. Repeated calls (the probe moving between windows) are harmless.
    func register(_ workspace: LibraryWorkspace, window: NSWindow) {
        workspace.attachedWindow = window
        if workspace === spare {
            spare = nil
            spareClaimed = false
        }
        if !isOpen(workspace) {
            if window.isKeyWindow { workspaces.insert(workspace, at: 0) } else { workspaces.append(workspace) }
        } else if window.isKeyWindow {
            activate(workspace)
        }
    }

    /// The window closed: only its workspace leaves. The last one waits as the spare for the next window.
    func close(_ workspace: LibraryWorkspace) {
        guard isOpen(workspace) else { return }
        if workspaces.count == 1, spare == nil {
            spare = workspace
        } else {
            slots[ObjectIdentifier(workspace)] = nil
        }
        workspaces.removeAll { $0 === workspace }
    }

    func activate(_ workspace: LibraryWorkspace) {
        guard let index = workspaces.firstIndex(where: { $0 === workspace }), index > 0 else { return }
        workspaces.insert(workspaces.remove(at: index), at: 0)
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let workspace = workspaces.first(where: { $0.libraryWindow === window })
        else { return }
        activate(workspace)
    }

    /// Every workspace: open windows in quit order (key or last-active first), then the spare.
    var allWorkspaces: [LibraryWorkspace] { workspaces + [spare].compactMap { $0 } }

    /// Quit (#193): one window at a time, the key (or last-active) one first. Each window comes to the front before
    /// its unsaved-changes alert; Cancel in any alert stops the quit and leaves every window open. Tests replace
    /// `prepare`.
    func prepareToQuit(_ prepare: ((LibraryWorkspace) async -> Bool)? = nil) async -> Bool {
        for workspace in allWorkspaces {
            let permitted: Bool
            if let prepare {
                permitted = await prepare(workspace)
            } else {
                permitted = await workspace.prepareToExit(.quit) { workspace.libraryWindow?.makeKeyAndOrderFront(nil) }
            }
            guard permitted else { return false }
        }
        return true
    }

    func flushEditors() async {
        for workspace in allWorkspaces { await workspace.flushEditors() }
    }
}

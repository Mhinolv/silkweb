import AppKit
import Observation
import SilkwebCore

/// Menu capabilities change much less often than the library snapshot (for example,
/// autosave refreshes file dates). Keep those publishes out of the command graph.
struct MenuCommandValues: Equatable {
    var canMutate: Bool
    var canRename: Bool
    var canMove: Bool
    var trashTitle: String
    var canTrash: Bool
    var hasLibrary: Bool
    var canOpenTab: Bool
    var canExport: Bool
    var canPrint: Bool
    var canFind: Bool
    var canReplace: Bool
    var usesTextUndo: Bool
    var undoTitle: String
    var canUndo: Bool
    var canRedo: Bool
    var sidebarsTitle: String
    var canToggleSidebars: Bool
    var previewMode: DocumentViewMode
    var inspectorSegment: LibraryWorkspace.InspectorSegment?
    var showsStatusBar: Bool
    var focusMode: Bool
    var typewriterMode: Bool
    var canToggleWritingModes: Bool
    var listPreference: LibraryListPreference
    var includesSubfolders: Bool
    var hasSelectedFolder: Bool

    @MainActor init(workspace: LibraryWorkspace) {
        canMutate = workspace.canMutate
        canRename = canMutate && workspace.libraryHasFocus && workspace.selectedItem != nil
        canMove = canMutate && workspace.libraryHasFocus && !workspace.movePaths.isEmpty
        trashTitle = workspace.trashMenuTitle
        canTrash = workspace.canTrashSelection
        hasLibrary = workspace.snapshot != nil
        canOpenTab = hasLibrary && !workspace.mutating && (workspace.selectedDocument != nil || workspace.editor.url != nil)
        canExport = workspace.canExport
        canPrint = workspace.canPrint
        canFind = workspace.canFind
        canReplace = canFind && !workspace.editor.readOnly
        usesTextUndo = workspace.usesTextUndo
        undoTitle = usesTextUndo
            ? (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.undoMenuItemTitle ?? "Undo"
            : workspace.libraryUndo.last?.title ?? "Undo"
        canUndo = usesTextUndo || workspace.canUndoLibrary
        canRedo = workspace.usesTextRedo
        sidebarsTitle = workspace.sidebarsTitle
        canToggleSidebars = hasLibrary || workspace.loading
        previewMode = workspace.preview.mode
        inspectorSegment = workspace.inspectorSegment
        showsStatusBar = workspace.preview.showsStatusBar
        focusMode = workspace.focusMode
        typewriterMode = workspace.typewriterMode
        canToggleWritingModes = workspace.canToggleWritingModes
        listPreference = workspace.listPreference
        includesSubfolders = workspace.includesSubfolders
        hasSelectedFolder = workspace.session.selectedFolder != nil
    }
}

@MainActor @Observable final class MenuCommandState: NSObject {
    private(set) var value: MenuCommandValues
    @ObservationIgnored private weak var workspace: LibraryWorkspace?

    init(workspace: LibraryWorkspace) {
        self.workspace = workspace
        value = MenuCommandValues(workspace: workspace)
        super.init()
        observe()
        // Responder/undo state is AppKit-owned. Sample it at menu open, and when undo or
        // key-window state changes (key equivalents skip tracking), rather than polling
        // or publishing every caret movement. `refresh` publishes only real changes.
        for name in [NSMenu.didBeginTrackingNotification, .NSUndoManagerDidCloseUndoGroup,
                     .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(appKitStateChanged), name: name, object: nil)
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func appKitStateChanged(_ notification: Notification) { refresh() }

    func refresh() {
        guard let workspace else { return }
        let next = MenuCommandValues(workspace: workspace)
        if value != next { value = next }
    }

    private func observe() {
        guard let workspace else { return }
        withObservationTracking {
            _ = MenuCommandValues(workspace: workspace)
        } onChange: { [weak self] in
            // Observation calls before the mutation completes. Coalesce dependent
            // publishes and read the completed state on the next main-actor turn.
            Task { @MainActor [weak self] in
                self?.refresh()
                self?.observe()
            }
        }
    }
}

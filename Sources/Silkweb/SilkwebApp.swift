import AppKit
import SwiftUI

@main
struct SilkwebApp: App {
    @NSApplicationDelegateAdaptor(EditorApplicationDelegate.self) private var appDelegate
    private let registry = LibraryWindowRegistry.shared

    var body: some Scene {
        // One workspace per window (#194). `.newItem` is replaced below, so there is no File ▸ New Window.
        WindowGroup("Silkweb", id: LibraryWindow.sceneID) {
            LibraryWindow(registry: registry)
        }
        .defaultSize(width: 1200, height: 760)
        // One slim bar: toolbar items share the traffic-lights row (silkweb-1.65).
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        // Registered once; every action resolves the key (or last-active) library window when it runs.
        .commands { LibraryWindowCommands(registry: registry) }
        // Silkweb ▸ Settings… ⌘, (1.24).
        Settings { LibraryWindowSettings(registry: registry) }
    }
}

/// A library window's content: the workspace it adopted from the registry, kept for the window's lifetime.
struct LibraryWindow: View {
    static let sceneID = "library"
    let registry: LibraryWindowRegistry
    @State private var holder = Holder()

    /// Adopts on first use, outside any published state, so building the view never publishes.
    @MainActor final class Holder {
        private var workspace: LibraryWorkspace?
        func workspace(from registry: LibraryWindowRegistry) -> LibraryWorkspace {
            if let workspace { return workspace }
            let adopted = registry.adopt()
            workspace = adopted
            return adopted
        }
    }

    var body: some View {
        let workspace = holder.workspace(from: registry)
        LibraryWorkspaceView(workspace: workspace)
            .background(EditorWindowLifecycle(workspace: workspace, registry: registry))
            .onAppear { WritingSettings.shared.applyAppearance() }
    }
}

/// App-level commands for whichever library window they target (#194, extends #104).
struct LibraryWindowCommands: Commands {
    let registry: LibraryWindowRegistry
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        let workspace = registry.target
        WorkspaceCommands(workspace: workspace) {
            // Open Folder in Place… / New Library… with every window closed: bring the Library's window back first.
            if !registry.isOpen(workspace) { openWindow(id: LibraryWindow.sceneID) }
        }
        PrintCommands(workspace: workspace)
    }
}

/// Settings ▸ Library shows and replaces the last-active library window's Library, live (#194).
struct LibraryWindowSettings: View {
    let registry: LibraryWindowRegistry
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let workspace = registry.target
        SettingsView(settings: WritingSettings.shared, workspace: workspace) {
            if !registry.isOpen(workspace) { openWindow(id: LibraryWindow.sceneID) }
        }
    }
}

/// Separate command observation from the window scene so idle activity can be tested offscreen.
struct WorkspaceCommands: Commands {
    let workspace: LibraryWorkspace
    /// Runs before Open Folder in Place… and New Library… so the chosen Library has a window to show in.
    var showWindow: () -> Void = {}
    var body: some Commands {
        let state = workspace.menuState.value
        CommandGroup(replacing: .newItem) {
            Button("New Document") { workspace.create(folder: false) }
                .keyboardShortcut("n").disabled(!state.canMutate)
            Button("New Folder") { workspace.create(folder: true) }
                .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!state.canMutate)
            Button("Rename…") { workspace.beginRename() }
                .disabled(!state.canRename)
            Button("Move To…") { workspace.requestMove() }
                .keyboardShortcut("m", modifiers: [.control, .command]).disabled(!state.canMove)
            Button(state.trashTitle) { workspace.requestTrash() }
                .keyboardShortcut(.delete, modifiers: .command).disabled(!state.canTrash)
            Button("Reveal in Finder") { workspace.reveal() }
                .keyboardShortcut("r", modifiers: [.command, .option]).disabled(!state.hasLibrary)
            Divider()
            ExportMenu(workspace: workspace, state: state)
            Divider()
            Button("Open Folder in Place…") {
                showWindow(); workspace.chooseFolder()
            }
            .keyboardShortcut("o")
            Button("Open in New Tab") { workspace.openSelectionInNewTab() }
                .keyboardShortcut("t").disabled(!state.canOpenTab)
            Button("Quick Open…") { workspace.search.toggleQuickOpen() }
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!state.hasLibrary)
            Button("Import Folder Copy…") { workspace.chooseImportFolder() }
                .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!state.canMutate)
            Button("New Library…") {
                showWindow(); workspace.newLibrary()
            }
            .keyboardShortcut("n", modifiers: [.command, .option])
        }
        TabCommands(workspace: workspace)
        CommandGroup(replacing: .undoRedo) {
            Button(state.undoTitle) {
                if workspace.usesTextUndo {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    workspace.undoLibrary()
                }
            }.keyboardShortcut("z").disabled(!state.canUndo)
            Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!state.canRedo)
        }
        CommandGroup(after: .pasteboard) {
            Button("Paste and Match Style") {
                NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            FindMenu(workspace: workspace, state: state)
        }
        TextEditingCommands()
        FormatCommands()
        CommandGroup(replacing: .sidebar) {
            Button(state.sidebarsTitle) { workspace.toggleSidebars() }
                .keyboardShortcut("s", modifiers: [.control, .command])
                .disabled(!state.canToggleSidebars)
        }
        CommandGroup(after: .sidebar) {
            Button(state.previewMode == .preview ? "Show Editor" : "Show Preview") { workspace.preview.togglePreview() }
                .keyboardShortcut("r")
            Toggle(
                "Split Editor and Preview",
                isOn: Binding(
                    get: { state.previewMode == .split }, set: { workspace.preview.mode = $0 ? .split : .editor })
            ).keyboardShortcut("4")
            // Checked only for the visible Inspector segment; same switch-or-close rules as the toolbar (#69).
            Toggle(
                "Show Document Info",
                isOn: Binding(get: { state.inspectorSegment == .info }, set: { _ in workspace.toggleInspector(.info) })
            )
            .keyboardShortcut("8")
            Toggle(
                "Show Outline",
                isOn: Binding(
                    get: { state.inspectorSegment == .outline }, set: { _ in workspace.toggleInspector(.outline) })
            )
            .keyboardShortcut("7")
            Button(state.showsStatusBar ? "Hide Status Bar" : "Show Status Bar") {
                workspace.preview.showsStatusBar.toggle()
            }
            .keyboardShortcut("/")
            Divider()
            // Per-window writing modes (1.27); disabled in Preview-only, which keeps their state.
            WritingModeItems(
                workspace: workspace, focus: state.focusMode, typewriter: state.typewriterMode,
                enabled: state.canToggleWritingModes)
            Divider()
            // Temporary editor zoom for this window (1.24); Actual Size returns to the Settings size.
            Button("Bigger") { workspace.zoomEditor(by: 1) }.keyboardShortcut("+")
            Button("Smaller") { workspace.zoomEditor(by: -1) }.keyboardShortcut("-")
            Button("Actual Size") { workspace.zoomEditor(by: nil) }.keyboardShortcut("0")
            Divider()
            Menu("Sort By") { DocumentSortItems(workspace: workspace, commandState: state) }
                .disabled(!state.hasLibrary)
            IncludeSubfoldersItem(workspace: workspace, hideForAllDocuments: false, commandState: state)
        }
        ToolbarCommands()
        CommandMenu("Go") {
            Button("Folders") { workspace.focus(0) }.keyboardShortcut("1", modifiers: [.command, .option])
            Button("Documents") { workspace.focus(1) }.keyboardShortcut("2", modifiers: [.command, .option])
            Button("Editor") { workspace.focus(2) }.keyboardShortcut("3", modifiers: [.command, .option])
            Divider()
            // #137: no shortcut; selects the sidebar row as a click does, and is disabled while it's hidden.
            Button("Agent Activity") { workspace.selectAgentActivity() }.disabled(!state.hasAgentActivity)
            // #203: no shortcut; the sheet works for any open Library, with or without requests.
            Button("Access Requests…") { workspace.showAccessRequests() }.disabled(!state.hasLibrary)
        }
    }
}

struct TabCommands: Commands {
    let workspace: LibraryWorkspace
    var body: some Commands {
        // Tab-scoped items and Save act only while the library window is key (#104).
        let key = workspace.menuState.libraryKey
        CommandGroup(after: .windowArrangement) {
            Button("Show Next Tab") { workspace.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(!key || workspace.tabs.isEmpty)
            Button("Show Previous Tab") { workspace.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(!key || workspace.tabs.isEmpty)
            Button("Keep Open") {
                if let id = workspace.activeTabID { workspace.keepTab(id) }
            }.disabled(!key || workspace.tabs.first { $0.id == workspace.activeTabID }?.isPreview != true)
            Button("Reveal in Library") {
                if let id = workspace.activeTabID { workspace.search.text = ""; workspace.activateTab(id) }
            }.disabled(!key || workspace.tabs.isEmpty)
            Button("Move Tab Left") { workspace.moveActiveTab(-1) }.disabled(!key || workspace.tabs.count < 2)
            Button("Move Tab Right") { workspace.moveActiveTab(1) }.disabled(!key || workspace.tabs.count < 2)
            Button("Close Other Tabs") {
                if let id = workspace.activeTabID { Task { await workspace.closeTabs(otherThan: id) } }
            }.keyboardShortcut("w", modifiers: [.command, .option]).disabled(!key || workspace.tabs.count < 2)
            Button("Close Tabs to the Right") {
                if let id = workspace.activeTabID { Task { await workspace.closeTabs(otherThan: id, toRight: true) } }
            }.disabled(!key || workspace.tabs.last?.id == workspace.activeTabID)
        }
        CommandGroup(replacing: .saveItem) {
            Button(key && !workspace.tabs.isEmpty ? "Close Tab" : "Close Window") {
                workspace.performCloseCommand()
            }.keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Divider()
            Button("Save") { Task { await workspace.editor.save() } }
                .keyboardShortcut("s").disabled(!key || workspace.editor.url == nil || workspace.editor.readOnly)
        }
    }
}

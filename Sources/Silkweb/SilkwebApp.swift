import AppKit
import SwiftUI

@main
struct SilkwebApp: App {
    @NSApplicationDelegateAdaptor(EditorApplicationDelegate.self) private var appDelegate
    private let registry = LibraryWindowRegistry.shared

    var body: some Scene {
        // One library window; each open Library is a sidebar section (#195). `.newItem` is replaced below, so
        // there is no File ▸ New Window.
        Window("Silkweb", id: LibraryWindow.sceneID) {
            LibraryWindow(registry: registry)
        }
        .defaultSize(width: 1200, height: 760)
        // One slim bar: toolbar items share the traffic-lights row (silkweb-1.65).
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        // Registered once; every action resolves the current Library when it runs.
        .commands { LibraryWindowCommands(registry: registry) }
        // Silkweb ▸ Settings… ⌘, (1.24).
        Settings { LibraryWindowSettings(registry: registry) }
    }
}

/// The library window's content: the current Library's columns beside every section (#195).
struct LibraryWindow: View {
    static let sceneID = "library"
    let registry: LibraryWindowRegistry

    var body: some View {
        LibraryWorkspaceView(workspace: registry.current, registry: registry)
            .background(EditorWindowLifecycle(workspace: registry.current, registry: registry))
            .onAppear { WritingSettings.shared.applyAppearance() }
    }
}

/// App-level commands for the current Library (#195, extends #104).
struct LibraryWindowCommands: Commands {
    let registry: LibraryWindowRegistry
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        let workspace = registry.target
        WorkspaceCommands(workspace: workspace, registry: registry) {
            // Open Folder in Place… / New Library… with the window closed: bring it back first.
            if !registry.hasWindow { openWindow(id: LibraryWindow.sceneID) }
        }
        PrintCommands(workspace: workspace)
    }
}

/// Settings ▸ Library shows and replaces the current Library, live (#195).
struct LibraryWindowSettings: View {
    let registry: LibraryWindowRegistry
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let workspace = registry.target
        SettingsView(settings: WritingSettings.shared, workspace: workspace) {
            if !registry.hasWindow { openWindow(id: LibraryWindow.sceneID) }
        }
    }
}

/// Separate command observation from the window scene so idle activity can be tested offscreen.
struct WorkspaceCommands: Commands {
    let workspace: LibraryWorkspace
    /// The window's sections: Open Recent ▸ and Close Library (#195). Offscreen command tests leave it out.
    var registry: LibraryWindowRegistry? = nil
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
            if let registry {
                OpenRecentMenu(registry: registry, showWindow: showWindow)
            }
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
        TabCommands(workspace: workspace, registry: registry)
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

/// File ▸ Open Recent ▸ (#195): up to 10 Libraries, most recent first; open sections are checked.
struct OpenRecentMenu: View {
    let registry: LibraryWindowRegistry
    var showWindow: () -> Void = {}
    var body: some View {
        let items = registry.recentItems()
        Menu("Open Recent") {
            ForEach(items) { item in
                Toggle(
                    item.title,
                    isOn: Binding(
                        get: { item.isOpen },
                        set: { _ in
                            showWindow()
                            Task { await registry.openRecent(item.path) }
                        }))
            }
            Divider()
            Button("Clear Menu") { registry.clearRecents() }.disabled(items.isEmpty)
        }
    }
}

struct TabCommands: Commands {
    let workspace: LibraryWorkspace
    var registry: LibraryWindowRegistry? = nil
    var body: some Commands {
        // Tab-scoped items and Save act only while the library window is key (#104).
        let key = workspace.menuState.libraryKey
        // #197: with sections, the items work on the window's one strip, across Libraries; the active tab is the
        // current Library's.
        let strip = registry?.stripTabs ?? workspace.tabs.map { .init(workspace: workspace, tab: $0) }
        let active = strip.firstIndex { $0.workspace === workspace && $0.tab.id == workspace.activeTabID }
        CommandGroup(after: .windowArrangement) {
            Button("Show Next Tab") { cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(!key || strip.isEmpty)
            Button("Show Previous Tab") { cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(!key || strip.isEmpty)
            Button("Keep Open") {
                if let id = workspace.activeTabID { workspace.keepTab(id) }
            }.disabled(!key || workspace.tabs.first { $0.id == workspace.activeTabID }?.isPreview != true)
            Button("Reveal in Library") {
                if let id = workspace.activeTabID { workspace.search.text = ""; workspace.activateTab(id) }
            }.disabled(!key || workspace.activeTabID == nil)
            Button("Move Tab Left") { moveActiveTab(-1) }.disabled(!key || active == nil || strip.count < 2)
            Button("Move Tab Right") { moveActiveTab(1) }.disabled(!key || active == nil || strip.count < 2)
            Button("Close Other Tabs") {
                if let active { closeTabs(otherThan: strip[active], toRight: false) }
            }.keyboardShortcut("w", modifiers: [.command, .option]).disabled(!key || active == nil || strip.count < 2)
            Button("Close Tabs to the Right") {
                if let active { closeTabs(otherThan: strip[active], toRight: true) }
            }.disabled(!key || active == nil || active == strip.count - 1)
        }
        CommandGroup(replacing: .saveItem) {
            Button(key && !workspace.tabs.isEmpty ? "Close Tab" : "Close Window") {
                workspace.performCloseCommand()
            }.keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            if let registry {
                // #195: closes only the current Library's section and tabs; no shortcut.
                Button("Close Library") { Task { await registry.closeLibrary(workspace) } }
                    .disabled(workspace.root == nil)
            }
            Divider()
            Button("Save") { Task { await workspace.editor.save() } }
                .keyboardShortcut("s").disabled(!key || workspace.editor.url == nil || workspace.editor.readOnly)
        }
    }

    private func cycleTab(_ delta: Int) {
        if let registry { registry.cycleTab(delta) } else { workspace.cycleTab(delta) }
    }

    private func moveActiveTab(_ delta: Int) {
        if let registry { registry.moveActiveTab(delta) } else { workspace.moveActiveTab(delta) }
    }

    private func closeTabs(otherThan entry: LibraryWindowRegistry.StripTab, toRight: Bool) {
        if let registry {
            Task { await registry.closeTabs(otherThan: entry, toRight: toRight) }
        } else {
            Task { await workspace.closeTabs(otherThan: entry.tab.id, toRight: toRight) }
        }
    }
}

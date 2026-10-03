import AppKit
import SwiftUI

@main
struct SilkwebApp: App {
    @NSApplicationDelegateAdaptor(EditorApplicationDelegate.self) private var appDelegate
    @State private var workspace = LibraryWorkspace()

    var body: some Scene {
        Window("Silkweb", id: "library") {
            LibraryWorkspaceView(workspace: workspace)
                .background(EditorWindowLifecycle(workspace: workspace))
                .onAppear { appDelegate.workspace = workspace }
        }
        .defaultSize(width: 1200, height: 760)
        .commands { WorkspaceCommands(workspace: workspace) }
        .commands { PrintCommands(workspace: workspace) }
    }
}

/// Separate command observation from the window scene so idle activity can be tested offscreen.
struct WorkspaceCommands: Commands {
    let workspace: LibraryWorkspace
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
            Button("Open Folder in Place…") { workspace.chooseFolder() }
                .keyboardShortcut("o")
            Button("Open in New Tab") { workspace.openSelectionInNewTab() }
                .keyboardShortcut("t").disabled(!state.canOpenTab)
            Button("Quick Open…") { workspace.search.toggleQuickOpen() }
                .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!state.hasLibrary)
            Button("Import Folder Copy…") { workspace.chooseImportFolder() }
                .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!state.canMutate)
            Button("New Library…") { workspace.newLibrary() }
                .keyboardShortcut("n", modifiers: [.command, .option])
        }
        TabCommands(workspace: workspace)
        CommandGroup(replacing: .undoRedo) {
            Button(state.undoTitle) {
                if workspace.usesTextUndo { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                else { workspace.undoLibrary() }
            }.keyboardShortcut("z").disabled(!state.canUndo)
            Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!state.canRedo)
        }
        CommandGroup(after: .pasteboard) {
            Button("Paste and Match Style") { NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil) }
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
            Button(state.previewMode == .preview ? "Show Editor" : "Show Preview") { workspace.preview.togglePreview() }.keyboardShortcut("r")
            Toggle("Split Editor and Preview", isOn: Binding(get: { state.previewMode == .split }, set: { workspace.preview.mode = $0 ? .split : .editor })).keyboardShortcut("4")
            Button("Show Document Info") { workspace.showInfo() }.keyboardShortcut("8")
            Toggle("Show Outline", isOn: Binding(get: { state.showsOutline }, set: { workspace.inspectorInfo = false; workspace.preview.showsOutline = $0 })).keyboardShortcut("7")
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
        }
    }
}

struct TabCommands: Commands {
    let workspace: LibraryWorkspace
    var body: some Commands {
            CommandGroup(after: .windowArrangement) {
                Button("Show Next Tab") { workspace.cycleTab(1) }
                    .keyboardShortcut("]", modifiers: [.command, .shift]).disabled(workspace.tabs.isEmpty)
                Button("Show Previous Tab") { workspace.cycleTab(-1) }
                    .keyboardShortcut("[", modifiers: [.command, .shift]).disabled(workspace.tabs.isEmpty)
                Button("Keep Open") {
                    if let id = workspace.activeTabID { workspace.keepTab(id) }
                }.disabled(workspace.tabs.first { $0.id == workspace.activeTabID }?.isPreview != true)
                Button("Reveal in Library") {
                    if let id = workspace.activeTabID { workspace.search.text = ""; workspace.activateTab(id) }
                }.disabled(workspace.tabs.isEmpty)
                Button("Move Tab Left") { workspace.moveActiveTab(-1) }.disabled(workspace.tabs.count < 2)
                Button("Move Tab Right") { workspace.moveActiveTab(1) }.disabled(workspace.tabs.count < 2)
                Button("Close Other Tabs") {
                    if let id = workspace.activeTabID { Task { await workspace.closeTabs(otherThan: id) } }
                }.keyboardShortcut("w", modifiers: [.command, .option]).disabled(workspace.tabs.count < 2)
                Button("Close Tabs to the Right") {
                    if let id = workspace.activeTabID { Task { await workspace.closeTabs(otherThan: id, toRight: true) } }
                }.disabled(workspace.tabs.last?.id == workspace.activeTabID)
            }
            CommandGroup(replacing: .saveItem) {
                Button(workspace.tabs.isEmpty ? "Close Window" : "Close Tab") {
                    if let id = workspace.activeTabID { Task { await workspace.closeTab(id) } }
                    else { NSApp.keyWindow?.performClose(nil) }
                }.keyboardShortcut("w")
                Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                Divider()
                Button("Save") { Task { await workspace.editor.save() } }
                    .keyboardShortcut("s").disabled(workspace.editor.url == nil || workspace.editor.readOnly)
            }
    }
}

import AppKit
import SwiftUI

@main
struct SilkwebApp: App {
    @NSApplicationDelegateAdaptor(EditorApplicationDelegate.self) private var appDelegate
    @State private var workspace = LibraryWorkspace()

    var body: some Scene {
        Window("Silkweb", id: "library") {
            LibraryWorkspaceView(workspace: workspace)
                .background(EditorWindowLifecycle(session: workspace.editor))
                .onAppear { appDelegate.session = workspace.editor }
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Document") { workspace.create(folder: false) }
                    .keyboardShortcut("n").disabled(!workspace.canMutate)
                Button("New Folder") { workspace.create(folder: true) }
                    .keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!workspace.canMutate)
                Button("Rename…") { workspace.beginRename() }
                    .disabled(!workspace.canMutate || workspace.selectedItem == nil)
                Button("Move To…") { workspace.requestMove() }
                    .keyboardShortcut("m", modifiers: [.control, .command]).disabled(!workspace.canMutate || workspace.movePaths.isEmpty)
                Button(workspace.trashMenuTitle) { workspace.requestTrash() }
                    .keyboardShortcut(.delete, modifiers: .command).disabled(!workspace.canTrashSelection)
                Button("Reveal in Finder") { workspace.reveal() }
                    .keyboardShortcut("r", modifiers: [.command, .option]).disabled(workspace.snapshot == nil)
                Divider()
                Button("Open Folder in Place…") { workspace.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Quick Open…") { workspace.search.toggleQuickOpen() }
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(workspace.snapshot == nil)
                Button("Import Folder Copy…") { workspace.chooseImportFolder() }
                    .keyboardShortcut("i", modifiers: [.command, .shift]).disabled(!workspace.canMutate)
                Button("New Library…") { workspace.newLibrary() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { Task { await workspace.editor.save() } }
                    .keyboardShortcut("s").disabled(workspace.editor.url == nil || workspace.editor.readOnly)
            }
            CommandGroup(replacing: .undoRedo) {
                Button(workspace.usesTextUndo ? (NSApp.keyWindow?.firstResponder as? NSTextView)?.undoManager?.undoMenuItemTitle ?? "Undo" : workspace.libraryUndo.last?.title ?? "Undo") {
                    if workspace.usesTextUndo { NSApp.sendAction(Selector(("undo:")), to: nil, from: nil) }
                    else { workspace.undoLibrary() }
                }.keyboardShortcut("z").disabled(!workspace.usesTextUndo && !workspace.canUndoLibrary)
                Button("Redo") { NSApp.sendAction(Selector(("redo:")), to: nil, from: nil) }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!workspace.usesTextRedo)
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste and Match Style") { NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v", modifiers: [.command, .option, .shift])
                FindMenu(workspace: workspace)
            }
            TextEditingCommands()
            FormatCommands()
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Sidebar") { workspace.sidebarToggleRequest += 1 }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    .disabled(workspace.snapshot == nil && !workspace.loading)
            }
            CommandGroup(after: .sidebar) {
                Button(workspace.preview.mode == .preview ? "Show Editor" : "Show Preview") { workspace.preview.togglePreview() }.keyboardShortcut("r")
                Toggle("Split Editor and Preview", isOn: Binding(get: { workspace.preview.mode == .split }, set: { workspace.preview.mode = $0 ? .split : .editor })).keyboardShortcut("4")
                Toggle("Show Outline", isOn: Binding(get: { workspace.preview.showsOutline }, set: { workspace.preview.showsOutline = $0 })).keyboardShortcut("7")
                Divider()
                Menu("Sort By") { DocumentSortItems(workspace: workspace) }
                    .disabled(workspace.snapshot == nil)
                IncludeSubfoldersItem(workspace: workspace, hideForAllDocuments: false)
            }
            ToolbarCommands()
            CommandMenu("Go") {
                Button("Folders") { workspace.focus(0) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Documents") { workspace.focus(1) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Editor") { workspace.focus(2) }.keyboardShortcut("3", modifiers: [.command, .option])
            }
        }
    }
}

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
                Button("Open Folder in Place…") { workspace.chooseFolder() }
                    .keyboardShortcut("o")
                Button("New Library…") { workspace.newLibrary() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { Task { await workspace.editor.flush() } }
                    .keyboardShortcut("s").disabled(workspace.editor.url == nil || workspace.editor.readOnly)
            }
            CommandGroup(after: .pasteboard) {
                Button("Paste and Match Style") { NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil) }
                    .keyboardShortcut("v", modifiers: [.command, .option, .shift])
            }
            TextEditingCommands()
            SidebarCommands()
            ToolbarCommands()
            CommandMenu("Go") {
                Button("Folders") { workspace.focus(0) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button("Documents") { workspace.focus(1) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button("Editor") { workspace.focus(2) }.keyboardShortcut("3", modifiers: [.command, .option])
            }
        }
    }
}

import SwiftUI

@main
struct SilkwebApp: App {
    @State private var workspace = LibraryWorkspace()

    var body: some Scene {
        Window("Silkweb", id: "library") {
            LibraryWorkspaceView(workspace: workspace)
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder in Place…") { workspace.chooseFolder() }
                    .keyboardShortcut("o")
                Button("New Library…") { workspace.newLibrary() }
                    .keyboardShortcut("n", modifiers: [.command, .option])
            }
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

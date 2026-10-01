import SwiftUI
import SilkwebCore

struct DocumentSortItems: View {
    let workspace: LibraryWorkspace
    var body: some View {
        ForEach([DocumentSortKey.modified, .created, .name], id: \.self) { key in
            Toggle(key.title, isOn: Binding(get: { workspace.listPreference.key == key }, set: { if $0 { workspace.setSortKey(key) } }))
                .keyboardShortcut(key == .name ? "1" : key == .modified ? "2" : "3", modifiers: [.control, .option, .command])
        }
        Divider()
        Toggle(workspace.listPreference.key == .name ? "A to Z" : "Oldest First",
               isOn: Binding(get: { !workspace.listPreference.descending }, set: { if $0 { workspace.setSortDescending(false) } }))
        Toggle(workspace.listPreference.key == .name ? "Z to A" : "Newest First",
               isOn: Binding(get: { workspace.listPreference.descending }, set: { if $0 { workspace.setSortDescending(true) } }))
    }
}

struct IncludeSubfoldersItem: View {
    let workspace: LibraryWorkspace
    var hideForAllDocuments = true
    var body: some View {
        if !hideForAllDocuments || workspace.session.selectedFolder != nil {
            Toggle("Include Subfolders", isOn: Binding(get: { workspace.includesSubfolders }, set: { workspace.setIncludeSubfolders($0) }))
                .disabled(workspace.session.selectedFolder == nil || workspace.snapshot == nil)
        }
    }
}

import SilkwebCore
import SwiftUI

struct DocumentSortItems: View {
    let workspace: LibraryWorkspace
    var commandState: MenuCommandValues? = nil
    var body: some View {
        let preference = commandState?.listPreference ?? workspace.listPreference
        ForEach([DocumentSortKey.modified, .created, .name], id: \.self) { key in
            Toggle(
                key.title, isOn: Binding(get: { preference.key == key }, set: { if $0 { workspace.setSortKey(key) } })
            )
            .keyboardShortcut(
                key == .name ? "1" : key == .modified ? "2" : "3", modifiers: [.control, .option, .command])
        }
        Divider()
        Toggle(
            preference.key == .name ? "A to Z" : "Oldest First",
            isOn: Binding(get: { !preference.descending }, set: { if $0 { workspace.setSortDescending(false) } }))
        Toggle(
            preference.key == .name ? "Z to A" : "Newest First",
            isOn: Binding(get: { preference.descending }, set: { if $0 { workspace.setSortDescending(true) } }))
    }
}

struct IncludeSubfoldersItem: View {
    let workspace: LibraryWorkspace
    var hideForAllDocuments = true
    var commandState: MenuCommandValues? = nil
    var body: some View {
        if !hideForAllDocuments || workspace.session.selectedFolder != nil {
            Toggle(
                "Include Subfolders",
                isOn: Binding(
                    get: { commandState?.includesSubfolders ?? workspace.includesSubfolders },
                    set: { workspace.setIncludeSubfolders($0) })
            )
            .disabled(
                !(commandState?.hasSelectedFolder ?? (workspace.session.selectedFolder != nil))
                    || !(commandState?.hasLibrary ?? (workspace.snapshot != nil)))
        }
    }
}

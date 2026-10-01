import AppKit
import SwiftUI
import SilkwebCore

struct DocumentList: View {
    @Bindable var workspace: LibraryWorkspace
    @State private var selectionRevision = 0
    @State private var dateReference = Date()
    var body: some View {
        Group {
            if workspace.snapshot?.folders.first(where: { $0.relativePath == workspace.session.selectedFolder })?.isUnreadable == true {
                ContentUnavailableView("Folder Unavailable", systemImage: "lock",
                                       description: Text("You don't have permission to view this folder."))
            } else if workspace.documents.isEmpty {
                ContentUnavailableView {
                    Label(workspace.snapshot?.documents.isEmpty == true ? "No Documents Yet" : "No Documents", systemImage: "doc.text")
                } description: {
                    Text(workspace.snapshot?.documents.isEmpty == true ? "Create a document or folder to get started." : "This folder is empty.")
                } actions: {
                    Button("New Document") { workspace.create(folder: false) }.disabled(!workspace.canMutate)
                    if workspace.snapshot?.documents.isEmpty == true {
                        Button("New Folder") { workspace.create(folder: true) }.disabled(!workspace.canMutate)
                    }
                }
            } else {
                ScrollViewReader { proxy in
                    List(workspace.documents, selection: Binding(get: { workspace.session.selectedDocuments }, set: { workspace.focusColumn = 1; workspace.selectDocuments($0) })) { document in
                        DocumentRow(document: document, root: workspace.snapshot!.rootURL, workspace: workspace, dateReference: dateReference)
                            .onDrag {
                                workspace.dragProvider(workspace.documentDragPaths(document.relativePath))
                            } preview: {
                                HStack {
                                    Label((document.name as NSString).deletingPathExtension, systemImage: "doc.text")
                                    let count = workspace.documentDragPaths(document.relativePath).count
                                    if count > 1 {
                                        Text(count.formatted()).font(.caption.bold()).padding(6)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }.padding(8).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            }
                            .tag(document.relativePath).id(document.relativePath)
                            .contextMenu {
                                Button("Open in New Tab") { }.disabled(true)
                                Divider()
                                Button("Rename…") { workspace.beginRename(LibraryRename(path: document.relativePath, isFolder: false)) }.disabled(!workspace.canMutate)
                                Button("Move To…") { workspace.requestMove(workspace.documentDragPaths(document.relativePath)) }.disabled(!workspace.canMutate)
                                Button("Reveal in Finder") { workspace.reveal(document.relativePath) }
                                Divider()
                                Button("Move to Trash") { }.disabled(true)
                            }
                    }
                    .id(selectionRevision)
                    .onChange(of: workspace.editor.refusedNavigation) { selectionRevision += 1 }
                    .onChange(of: workspace.rename) { if let item = workspace.rename, !item.isFolder { proxy.scrollTo(item.path) } }
                    .onChange(of: workspace.revision) { if let path = workspace.session.selectedDocuments.first { proxy.scrollTo(path) } }
                    .onKeyPress(.return) { workspace.focusColumn = 1; workspace.beginRename(); return .handled }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in dateReference = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in dateReference = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in dateReference = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in dateReference = Date() }
    }
}

private struct DocumentRow: View {
    let document: LibraryDocument
    let root: URL
    let workspace: LibraryWorkspace
    let dateReference: Date
    @Environment(\.locale) private var locale
    @State private var summary: DocumentSummary?
    private var title: String { URL(fileURLWithPath: document.name).deletingPathExtension().lastPathComponent }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let item = workspace.rename, item.path == document.relativePath, !item.isFolder {
                InlineRenameField(item: item, workspace: workspace).frame(height: 24)
            } else {
                Text(title).font(.headline).lineLimit(1)
            }
            HStack(spacing: 4) {
                if let modified = summary?.modified {
                    Text(DocumentRowPresentation.dateLabel(modified, now: dateReference, locale: locale))
                }
                Text(summary?.firstLine ?? "")
            }.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape([.interaction, .dragPreview], Rectangle())
        .background(DocumentRowClickObserver(path: document.relativePath, workspace: workspace))
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: workspace.rename?.path == document.relativePath ? .contain : .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(summary?.modified.map { "modified \($0.formatted(.relative(presentation: .named)))" } ?? "")
        .task(id: document.relativePath) { summary = await DocumentSummary.load(document: document, root: root) }
    }
}

struct DocumentDetail: View {
    let workspace: LibraryWorkspace
    var body: some View {
        VStack(spacing: 0) {
            if workspace.snapshot?.isReadOnly == true {
                Label("This library is read-only. Documents can be viewed, but changes can’t be saved.", systemImage: "lock")
                    .font(.callout).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .padding(.horizontal, 12).background(.bar)
            }
            EditorBanner(session: workspace.editor)
            if workspace.editor.url != nil {
                MarkdownTextView(session: workspace.editor, workspace: workspace)
            } else if workspace.session.selectedDocuments.count > 1 {
                ContentUnavailableView("\(workspace.session.selectedDocuments.count) Documents Selected", systemImage: "doc.on.doc")
            } else {
                ContentUnavailableView("No Document Selected", systemImage: "doc.text", description: Text("Select a document in the list."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

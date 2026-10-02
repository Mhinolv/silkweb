import AppKit
import SwiftUI
import SilkwebCore

struct DocumentList: View {
    @Bindable var workspace: LibraryWorkspace
    var makeDragProvider: (([String]) -> NSItemProvider)? = nil
    @State private var dateReference = Date()
    var body: some View {
        SearchView(workspace: workspace, search: workspace.search) {
            PinnedColumn {
                if workspace.includesSubfolders {
                    HStack {
                        Text("Including subfolders · \(CountPresentation.label(workspace.documents.count, unit: .document))")
                        Spacer()
                        Button("Show Only This Folder") { workspace.setIncludeSubfolders(false) }.buttonStyle(.borderless)
                    }
                    .font(.caption).monospacedDigit().padding(.horizontal, 8).frame(height: 28).background(.bar)
                    .accessibilityElement(children: .contain).accessibilityLabel("Including subfolders")
                }
            } content: {
                if workspace.snapshot?.folders.first(where: { $0.relativePath == workspace.session.selectedFolder })?.isUnreadable == true {
                    ColumnEmptyState {
                        ContentUnavailableView("Folder Unavailable", systemImage: "lock",
                                           description: Text("You don't have permission to view this folder."))
                    }
                } else if workspace.documents.isEmpty {
                    ColumnEmptyState {
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
                    }
                } else {
                    DocumentTable(workspace: workspace, documents: workspace.documents,
                                  dateReference: dateReference, makeDragProvider: makeDragProvider)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in dateReference = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in dateReference = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in dateReference = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in dateReference = Date() }
    }
}

struct DocumentRow: View {
    let document: LibraryDocument
    let root: URL
    let workspace: LibraryWorkspace
    let dateReference: Date
    let pointerState: DocumentRowPointerState
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
                if let date = workspace.listPreference.key == .created ? document.created : document.modified {
                    Text((workspace.listPreference.key == .created ? "Created " : "") + DocumentRowPresentation.dateLabel(date, now: dateReference, locale: locale))
                }
                Text(summary?.firstLine ?? "")
            }.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            if workspace.includesSubfolders, let path = LibraryPresentation.breadcrumb(for: document, in: workspace.session.selectedFolder) {
                Label(path, systemImage: "folder").font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape([.interaction, .dragPreview], Rectangle())
        .overlay(DocumentRowClickObserver(path: document.relativePath, workspace: workspace, pointerState: pointerState))
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: workspace.rename?.path == document.relativePath ? .contain : .ignore)
        .accessibilityLabel(title)
        .accessibilityValue((workspace.listPreference.key == .created ? document.created : document.modified).map {
            "\(workspace.listPreference.key == .created ? "created" : "modified") \($0.formatted(.relative(presentation: .named)))"
        } ?? "")
        .task(id: DocumentSummaryIdentity(path: document.relativePath, modified: document.modified)) {
            summary = nil
            summary = await DocumentSummary.load(document: document, root: root)
        }
    }
}

private struct DocumentSummaryIdentity: Hashable {
    let path: String
    let modified: Date?
}

struct DocumentDetail: View {
    let workspace: LibraryWorkspace
    @State private var isNarrow = true
    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty { EditorTabBar(workspace: workspace).frame(height: 28) }
            MediaMigrationBanner(workspace: workspace)
            if workspace.snapshot?.isReadOnly == true {
                Label("This library is read-only. Documents can be viewed, but changes can’t be saved.", systemImage: "lock")
                    .font(.callout).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .padding(.horizontal, 12).background(.bar)
            }
            EditorBanner(session: workspace.editor, workspace: workspace)
            AssetErrorBanner(session: workspace.editor)
            if workspace.editor.url != nil {
                DocumentPanes(workspace: workspace)
                if let progress = workspace.editor.assetProgress {
                    HStack { Text(progress); Spacer() }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                        .frame(height: 24).background(.bar)
                }
            } else if workspace.session.selectedDocuments.count > 1 {
                ContentUnavailableView("\(workspace.session.selectedDocuments.count) Documents Selected", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Document Selected", systemImage: "doc.text", description: Text("Select a document in the list."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .inspector(isPresented: Binding(get: { workspace.preview.showsOutline }, set: { workspace.preview.showsOutline = $0 })) {
            InspectorView(workspace: workspace).inspectorColumnWidth(min: 200, ideal: 240, max: 320)
        }
        .onChange(of: workspace.editor.text, initial: true) { render() }
        .onChange(of: workspace.editor.url) { render() }
        .onGeometryChange(for: Bool.self) { $0.size.width < 600 } action: { narrow in
            isNarrow = narrow
            if narrow, workspace.preview.mode == .split { workspace.preview.showsOutline = false }
        }
        .onChange(of: workspace.preview.showsOutline) { render() }
        .onChange(of: workspace.root) { render() }
        .onChange(of: workspace.preview.mode) {
            render()
            if isNarrow, workspace.preview.mode == .split { workspace.preview.showsOutline = false }
        }
    }

    private func render() {
        workspace.preview.schedule(text: workspace.editor.text, document: workspace.editor.url, root: workspace.root)
    }
}

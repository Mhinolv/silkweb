import SwiftUI
import SilkwebCore

struct DocumentList: View {
    @Bindable var workspace: LibraryWorkspace
    var body: some View {
        Group {
            if workspace.documents.isEmpty {
                ContentUnavailableView(
                    workspace.snapshot?.documents.isEmpty == true ? "No Documents Yet" : "No Documents",
                    systemImage: "doc.text",
                    description: Text(workspace.snapshot?.documents.isEmpty == true
                                      ? "Create a document or folder to get started." : "This folder is empty.")
                )
            } else {
                List(workspace.documents, selection: $workspace.session.selectedDocuments) { document in
                    DocumentRow(document: document, root: workspace.snapshot!.rootURL)
                        .tag(document.relativePath)
                }
            }
        }
        .navigationTitle(workspace.folderName)
        .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 480)
    }
}

private struct DocumentRow: View {
    let document: LibraryDocument
    let root: URL
    @State private var summary: DocumentSummary?
    private var title: String { URL(fileURLWithPath: document.name).deletingPathExtension().lastPathComponent }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).lineLimit(1)
            HStack(spacing: 4) {
                if let modified = summary?.modified { Text(modified, style: .relative) }
                Text(summary?.firstLine ?? "")
            }.font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(minHeight: 36, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(summary?.modified.map { "modified \($0.formatted(.relative(presentation: .named)))" } ?? "")
        .task(id: document.relativePath) { summary = await DocumentSummary.load(document: document, root: root) }
    }
}

struct DocumentDetail: View {
    let workspace: LibraryWorkspace
    @State private var text = ""
    @State private var readError: String?
    @State private var loading = false
    var body: some View {
        VStack(spacing: 0) {
            if workspace.snapshot?.isReadOnly == true {
                Label("This library is read-only. Documents can be viewed, but changes can’t be saved.", systemImage: "lock")
                    .font(.callout).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .padding(.horizontal, 12).background(.bar)
            }
            if workspace.session.selectedDocuments.count > 1 {
                ContentUnavailableView("\(workspace.session.selectedDocuments.count) Documents Selected", systemImage: "doc.on.doc")
            } else if workspace.selectedDocument != nil {
                if let readError {
                    ContentUnavailableView("Can’t Read Document", systemImage: "exclamationmark.triangle", description: Text(readError))
                } else if loading {
                    ProgressView()
                } else {
                    ScrollView {
                        Text(verbatim: text).font(.body).textSelection(.enabled)
                            .frame(maxWidth: 720, alignment: .leading)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.horizontal, 40).padding(.vertical, 24)
                    }
                }
            } else {
                ContentUnavailableView("No Document Selected", systemImage: "doc.text", description: Text("Select a document in the list."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationSplitViewColumnWidth(min: 420, ideal: 680)
        .focusable()
        .task(id: workspace.selectedDocument?.id) {
            text = ""
            readError = nil
            guard let document = workspace.selectedDocument, let root = workspace.snapshot?.rootURL else { return }
            loading = true
            do {
                let loaded = try await LibraryScanner.readDocument(document, root: root)
                guard !Task.isCancelled else { return }
                text = loaded
            } catch {
                guard !Task.isCancelled else { return }
                readError = error.localizedDescription
            }
            loading = false
        }
    }
}

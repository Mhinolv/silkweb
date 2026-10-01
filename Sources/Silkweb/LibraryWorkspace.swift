import AppKit
import SwiftUI
import SilkwebCore

@MainActor @Observable
final class LibraryWorkspace {
    let editor = DocumentSession()
    var libraryUndo: [LibraryUndo] = []
    var rename: LibraryRename?
    var mutating = false
    var revision = 0
    var mutationError: String?
    var mutationErrorTitle = ""

    func install(_ snapshot: LibrarySnapshot, sorted: [LibraryDocument]) {
        self.snapshot = snapshot
        allDocuments = sorted
        groupedDocuments = Dictionary(grouping: sorted, by: \.folderID)
    }
    private var navigationTask: Task<Void, Never>?
    var snapshot: LibrarySnapshot?
    var session = LibrarySession()
    var loading = false
    var loadingCount: Int?
    var error: String?
    var errorTitle = "Can’t Open Library"
    var errorSymbol = "exclamationmark.triangle"
    var root: URL?
    var focusRequest = 0
    var focusColumn = 0
    private var scope: URL?
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var canSaveSession = true
    private var groupedDocuments: [UUID: [LibraryDocument]] = [:]
    private var allDocuments: [LibraryDocument] = []

    var documents: [LibraryDocument] {
        guard let snapshot else { return [] }
        if session.selectedFolder == nil { return allDocuments }
        guard let folder = snapshot.folders.first(where: { $0.relativePath == session.selectedFolder }) else { return [] }
        return groupedDocuments[folder.id] ?? []
    }
    var selectedDocument: LibraryDocument? {
        guard session.selectedDocuments.count == 1 else { return nil }
        return documents.first { session.selectedDocuments.contains($0.relativePath) }
    }
    var folderName: String {
        snapshot?.folders.first { $0.relativePath == session.selectedFolder }?.name ?? "All Documents"
    }
    var subtitle: String {
        (session.selectedFolder ?? "").split(separator: "/").joined(separator: " › ")
    }

    func restore() {
        guard root == nil, let data = UserDefaults.standard.data(forKey: "libraryBookmark") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            open(url)
        } catch {
            self.error = "Choose your library folder again to restore access."
        }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose a folder to use as your Silkweb library. Documents stay where they are."
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    func newLibrary() {
        let panel = NSSavePanel()
        panel.prompt = "Create"
        panel.nameFieldStringValue = "Silkweb Library"
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                // Never adopt or replace an existing item through the Create command.
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                self?.open(url)
            } catch { self?.error = error.localizedDescription }
        }
    }

    func open(_ url: URL) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let previousLoad = loadTask
        previousLoad?.cancel()
        saveTask?.cancel()
        loadTask = Task {
            await previousLoad?.value
            guard !Task.isCancelled else { return }
            await navigationTask?.value
            guard !mutating else { return }
            libraryUndo = []
            rename = nil
            guard await editor.open(nil, readOnly: false) else { return }
            await editor.configure(root: url)
            // Let any previous scan finish cancellation before releasing its access.
            scope?.stopAccessingSecurityScopedResource()
            scope = url.startAccessingSecurityScopedResource() ? url : nil
            root = url
            snapshot = nil
            error = nil
            loading = true
            loadingCount = nil
            do {
                let scanned = try await LibraryScanner.scan(root: url) { [weak self] count in
                    Task { @MainActor in
                        guard let self, self.root == url, self.loading else { return }
                        self.loadingCount = count
                    }
                }
                guard !Task.isCancelled else { return }
                var restored = LibrarySession()
                canSaveSession = true
                do { restored = try await LibrarySession.load(root: url) }
                catch LibraryError.unsupportedMetadataVersion { canSaveSession = false }
                catch { /* A rebuildable navigation session can fall back to its defaults. */ }
                let sorted = await Task.detached {
                    scanned.documents.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                }.value
                guard !Task.isCancelled else { return }
                allDocuments = sorted
                groupedDocuments = Dictionary(grouping: sorted, by: \.folderID)
                session = restored
                if let path = session.selectedFolder, !scanned.folders.contains(where: { $0.relativePath == path }) {
                    session.selectedFolder = ""
                }
                snapshot = scanned
                session.selectedDocuments.formIntersection(Set(documents.map(\.relativePath)))
                var recoveryURL: URL?
                if let drafts = try? await SaveCoordinator().pendingRecoveryDrafts(),
                   let draft = drafts.first(where: { $0.documentURL.path.hasPrefix(scanned.rootURL.path + "/") }) {
                    recoveryURL = draft.documentURL
                    session.selectedFolder = nil
                    session.selectedDocuments = Set(scanned.documents.filter { scanned.rootURL.appendingPathComponent($0.relativePath) == draft.documentURL }.map(\.relativePath))
                }
                _ = await editor.open(recoveryURL ?? selectedDocument.map { scanned.rootURL.appendingPathComponent($0.relativePath) }, readOnly: scanned.isReadOnly)
                if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(bookmark, forKey: "libraryBookmark")
                }
            } catch {
                guard !Task.isCancelled else { return }
                let cocoa = error as NSError
                if [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code) {
                    errorTitle = "Library Not Found"
                    errorSymbol = "externaldrive.badge.questionmark"
                    self.error = "Silkweb can’t find “\(url.lastPathComponent)”. It may have been moved, renamed, or be on a disconnected drive."
                } else if cocoa.code == NSFileReadNoPermissionError {
                    errorTitle = "Can’t Open Library"
                    errorSymbol = "lock"
                    self.error = "Silkweb doesn’t have permission to read “\(url.lastPathComponent)”."
                } else {
                    errorTitle = "Can’t Open Library"
                    errorSymbol = "exclamationmark.triangle"
                    self.error = error.localizedDescription
                }
            }
            loading = false
        }
    }

    func resumeEditor() async {
        guard editor.url == nil, let snapshot else { return }
        _ = await editor.open(selectedDocument.map { snapshot.rootURL.appendingPathComponent($0.relativePath) }, readOnly: snapshot.isReadOnly)
    }

    func waitForNavigation() async { await navigationTask?.value }

    func selectDocuments(_ paths: Set<String>) {
        navigate(folder: session.selectedFolder, documents: paths)
    }

    func selectFolder(_ path: String?) {
        navigate(folder: path, documents: [])
    }

    private func navigate(folder: String?, documents: Set<String>) {
        guard !loading, !mutating else { return }
        let previous = navigationTask
        navigationTask = Task {
            await previous?.value
            let destination = documents.count == 1 ? documents.first.flatMap { path in
                snapshot?.documents.first(where: { $0.relativePath == path }).map { snapshot!.rootURL.appendingPathComponent($0.relativePath) }
            } : nil
            guard await editor.open(destination, readOnly: snapshot?.isReadOnly == true) else { return }
            session.selectedFolder = folder
            session.selectedDocuments = documents
        }
    }

    func persistSession() {
        saveTask?.cancel()
        guard let snapshot, !snapshot.isReadOnly, canSaveSession else { return }
        let session = session
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                try await session.save(root: snapshot.rootURL)
            } catch is CancellationError { } catch {
                // Navigation persistence must never interrupt reading or modify document text.
                NSLog("Silkweb could not save navigation: %@", error.localizedDescription)
            }
        }
    }

    func focus(_ column: Int) { focusColumn = column; focusRequest += 1 }
}

struct LibraryWorkspaceView: View {
    @Bindable var workspace: LibraryWorkspace
    @State private var visibility: NavigationSplitViewVisibility = .all
    @FocusState private var focusedColumn: Int?

    var body: some View {
        Group {
            if let error = workspace.error {
                ContentUnavailableView {
                    Label(workspace.errorTitle, systemImage: workspace.errorSymbol)
                } description: { Text(error) } actions: {
                    Button(workspace.errorTitle == "Library Not Found" ? "Locate…" : "Choose Folder Again…") { workspace.chooseFolder() }
                    if workspace.errorTitle == "Library Not Found" {
                        Button("Open Another Folder…") { workspace.chooseFolder() }
                    }
                }
            } else if workspace.snapshot != nil || workspace.loading {
                libraryColumns
            } else {
                welcome
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .alert(workspace.mutationErrorTitle, isPresented: Binding(get: { workspace.mutationError != nil }, set: { if !$0 { workspace.mutationError = nil } })) {
            Button("OK") { workspace.mutationError = nil }
        } message: { Text(workspace.mutationError ?? "") }
        .task { workspace.restore(); await workspace.resumeEditor() }
        .onChange(of: workspace.session) { workspace.persistSession() }
        .onChange(of: focusedColumn) { if focusedColumn == 1 { workspace.focusColumn = 1 } }
        .onChange(of: workspace.focusRequest) {
            visibility = .all
            focusedColumn = workspace.focusColumn == 1 ? 1 : nil
        }
    }

    private var libraryColumns: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            if let snapshot = workspace.snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    Text("LIBRARY").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12)
                    FolderSidebar(snapshot: snapshot, workspace: workspace)
                    Menu {
                        Button("New Folder") { workspace.create(folder: true) }
                        Button("New Document") { workspace.create(folder: false) }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().padding(8)
                    .accessibilityLabel("Add").help("Add")
                    .disabled(!workspace.canMutate)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 320)
            } else {
                DelayedLibraryProgress(count: workspace.loadingCount)
            }
        } content: {
            DocumentList(workspace: workspace)
                .focused($focusedColumn, equals: 1)
                .onKeyPress(keys: [.tab], phases: .down) { press in
                    workspace.focus(press.modifiers.contains(.shift) ? 0 : 2)
                    return .handled
                }
        } detail: {
            DocumentDetail(workspace: workspace)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(workspace.editor.url == nil ? workspace.folderName : workspace.editor.name)
        .navigationSubtitle(workspace.subtitle)
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(systemName: "books.vertical").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Silkweb").font(.largeTitle)
            Text("Write Markdown in folders you own.").font(.title3).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                welcomeCard("Open Folder in Place…", symbol: "folder", hint: "Use an existing folder of Markdown files where it is.", action: workspace.chooseFolder)
                    .keyboardShortcut(.defaultAction)
                welcomeCard("New Library…", symbol: "plus.rectangle.on.folder", hint: "Start an empty library in a new folder.", action: workspace.newLibrary)
            }
            Text("To copy files in instead, use File › Import Folder Copy…").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func welcomeCard(_ title: String, symbol: String, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                Text(hint).font(.subheadline).foregroundStyle(.secondary)
            }.frame(width: 224, height: 72, alignment: .leading).padding(8)
        }.buttonStyle(.bordered).accessibilityLabel(title).accessibilityHint(hint)
    }
}

private struct DelayedLibraryProgress: View {
    let count: Int?
    @State private var visible = false
    var body: some View {
        Group {
            if visible { ProgressView(count.map { "Loading library… \($0.formatted()) documents" } ?? "Loading library…").controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled { visible = true } }
    }
}

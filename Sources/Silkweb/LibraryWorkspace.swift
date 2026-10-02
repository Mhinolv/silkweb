import AppKit
import SwiftUI
import SilkwebCore

@MainActor @Observable
final class LibraryWorkspace {
    let emptyEditor = DocumentSession()
    var tabs: [DocumentTab] = []
    var activeTabID: UUID?
    var editor: DocumentSession { tabs.first { $0.id == activeTabID }?.editor ?? emptyEditor }
    var canSaveWindowSession = true
    var restoringTabs = false
    @ObservationIgnored var closingTabIDs: Set<UUID> = []
    @ObservationIgnored var recoveryDirectory: URL?
    let search = LibrarySearch()
    let preview: PreviewCoordinator
    let columnAutosaveName: String
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, columnAutosaveName: String = "Silkweb.LibraryColumns") {
        self.defaults = defaults
        self.columnAutosaveName = columnAutosaveName
        preview = PreviewCoordinator(defaults: defaults)
    }
    var libraryUndo: [LibraryUndo] = []
    var importRequest: ImportRequest?
    var moveRequest: MoveRequest?
    var trashPlan: DeletionPlan?
    var mutationRevealURLs: [URL] = []
    var mutationRevealTitle = "Reveal in Finder"
    var recentMoveFolders: [String] = []
    var dragIdentity = UUID()
    var rename: LibraryRename?
    var mutating = false
    var revision = 0
    var mutationError: String?
    var mutationErrorTitle = ""

    func install(_ snapshot: LibrarySnapshot) {
        self.snapshot = snapshot
        search.install(snapshot)
        itemPathsByID = Dictionary(uniqueKeysWithValues: snapshot.metadata.IDsByPath.map { ($0.value, $0.key) })
        documentCache = nil
        presentationRevision += 1
    }
    private var watcher: LibraryWatcher?
    private var reconciling = false
    private var navigationTask: Task<Void, Never>?
    var snapshot: LibrarySnapshot?
    var session = LibrarySession()
    var loading = false
    var loadingCount: Int?
    var error: String?
    var errorTitle = "Can’t Open Library"
    var errorSymbol = "exclamationmark.triangle"
    var root: URL?
    var sidebarToggleRequest = 0
    var focusRequest = 0
    var focusColumn = 0
    private var scope: URL?
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var canSaveSession = true
    @ObservationIgnored var itemPathsByID: [UUID: String] = [:]
    @ObservationIgnored private var presentationRevision = 0
    @ObservationIgnored private var documentCache: (folder: String?, preference: LibraryListPreference, documents: [LibraryDocument])?

    var selectedFolder: LibraryFolder? {
        snapshot?.folders.first { $0.relativePath == session.selectedFolder }
    }
    private var preferenceID: String { selectedFolder.map { "folder:" + $0.id.uuidString } ?? "all" }
    var listPreference: LibraryListPreference { session.listPreferences[preferenceID] ?? LibraryListPreference() }
    var includesSubfolders: Bool { session.selectedFolder != nil && listPreference.includeSubfolders }
    func setSortKey(_ key: DocumentSortKey) {
        var preference = listPreference
        preference.select(key)
        session.listPreferences[preferenceID] = preference
    }
    func setSortDescending(_ descending: Bool) {
        var preference = listPreference
        preference.descending = descending
        session.listPreferences[preferenceID] = preference
    }
    func setIncludeSubfolders(_ include: Bool) {
        guard session.selectedFolder != nil else { return }
        var preference = listPreference
        preference.includeSubfolders = include
        session.listPreferences[preferenceID] = preference
        // Preserve the open editor when narrowing hides its row; never discard dirty text.
    }
    var documents: [LibraryDocument] {
        guard let snapshot else { return [] }
        let preference = listPreference
        if let cached = documentCache, cached.folder == session.selectedFolder, cached.preference == preference {
            return cached.documents
        }
        guard session.selectedFolder == nil || selectedFolder != nil else { return [] }
        let documents = snapshot.presentation.documents(in: selectedFolder, preference: preference)
        documentCache = (session.selectedFolder, preference, documents)
        return documents
    }
    func refreshSavedDocumentDates() async {
        guard !loading, !mutating, let snapshot, let url = editor.url,
              let document = snapshot.documents.first(where: { snapshot.rootURL.appendingPathComponent($0.relativePath) == url }) else { return }
        let revision = presentationRevision
        guard let refreshed = try? await LibraryScanner.refreshingDates(in: snapshot, documentID: document.id),
              !loading, !mutating, presentationRevision == revision else { return }
        install(refreshed)
    }
    var selectedDocument: LibraryDocument? {
        guard session.selectedDocuments.count == 1 else { return nil }
        return documents.first { session.selectedDocuments.contains($0.relativePath) }
    }
    var folderName: String {
        snapshot?.folders.first { $0.relativePath == session.selectedFolder }?.name ?? "All Documents"
    }
    var subtitle: String {
        search.text.isEmpty ? "\(documents.count.formatted()) documents" + (includesSubfolders ? " (with subfolders)" : "") : "\(search.results.count.formatted()) results"
    }

    func restore() {
        guard root == nil, loadTask == nil else { return }
        let location = defaults.data(forKey: "libraryLocation").flatMap { try? JSONDecoder().decode(LibraryLocation.self, from: $0) }
        let legacy = defaults.data(forKey: "libraryBookmark")
        guard location != nil || legacy != nil else { return }
        loadTask = Task {
            do {
                let restored = try await Task.detached(priority: .userInitiated) {
                    try LibraryLocationRestore.restore(location, legacyBookmark: legacy)
                }.value
                guard !Task.isCancelled, let restored else { return }
                if let refreshed = restored.refreshedLocation { persistLocation(refreshed) }
                // Clear this task before open captures the previous load to await.
                loadTask = nil
                open(restored.url, usesSecurityScope: restored.usesSecurityScope)
            } catch {
                guard !Task.isCancelled else { return }
                let failure = error as? LibraryLocationError ?? .unreadable
                errorTitle = failure.title
                errorSymbol = failure == .notFound ? "externaldrive.badge.questionmark" : "lock"
                self.error = failure == .notFound
                    ? "Silkweb can’t find your library. It may have been moved, renamed, or be on a disconnected drive."
                    : "Silkweb doesn’t have permission to read your library."
                loadTask = nil
            }
        }
    }

    private func persistLocation(_ location: LibraryLocation) {
        guard let data = try? JSONEncoder().encode(location) else { return }
        defaults.set(data, forKey: "libraryLocation")
        defaults.removeObject(forKey: "libraryBookmark")
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

    func open(_ url: URL, usesSecurityScope: Bool = false) {
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
            importRequest = nil
            moveRequest = nil
            recentMoveFolders = []
            dragIdentity = UUID()
            rename = nil
            guard await flushEditors() else { return }
            if let snapshot { await saveSessionNow(root: snapshot.rootURL) }
            await didCloseWindow()
            search.reset()
            watcher?.stop()
            watcher = nil
            await editor.configure(root: url)
            // Let any previous scan finish cancellation before releasing its access.
            scope?.stopAccessingSecurityScopedResource()
            scope = usesSecurityScope && url.startAccessingSecurityScopedResource() ? url : nil
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
                guard !Task.isCancelled else { return }
                install(scanned)
                session = restored
                var windowSession: WindowSessionMetadata?
                canSaveWindowSession = true
                do { windowSession = try await WindowSessionMetadata.load(root: url) }
                catch LibraryError.unsupportedMetadataVersion { canSaveWindowSession = false }
                catch { /* Stale tab state never interrupts opening a library. */ }
                if let windowSession { await restoreTabs(windowSession) }
                if let path = session.selectedFolder, !scanned.folders.contains(where: { $0.relativePath == path }) {
                    session.selectedFolder = ""
                }
                session.selectedDocuments.formIntersection(Set(documents.map(\.relativePath)))
                var recoveryURL: URL?
                if let drafts = try? await SaveCoordinator().pendingRecoveryDrafts(),
                   let draft = drafts.first(where: { $0.documentURL.path.hasPrefix(scanned.rootURL.path + "/") }) {
                    recoveryURL = draft.documentURL
                    session.selectedFolder = nil
                    session.selectedDocuments = Set(scanned.documents.filter { scanned.rootURL.appendingPathComponent($0.relativePath) == draft.documentURL }.map(\.relativePath))
                }
                if let recoveryURL, let document = scanned.documents.first(where: { scanned.rootURL.appendingPathComponent($0.relativePath) == recoveryURL }) {
                    _ = await openTab(document, pinned: true)
                } else if windowSession == nil, let document = selectedDocument {
                    _ = await openTab(document)
                }
                if let id = activeTabID, let document = scanned.documents.first(where: { $0.id == id }) {
                    session.selectedDocuments = [document.relativePath]
                }
                watcher = LibraryWatcher(root: url) { [weak self] in await self?.reconcileFinderChanges() }
                let location = await Task.detached(priority: .utility) { LibraryLocation.saving(url) }.value
                guard !Task.isCancelled else { return }
                persistLocation(location)
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

    func reconcileFinderChanges() async {
        guard !loading, !mutating, !reconciling, let root, let old = snapshot else {
            if mutating || reconciling { watcher?.notifyChange() }
            return
        }
        reconciling = true
        defer { reconciling = false }
        let installedRevision = presentationRevision
        do {
            let scanned = try await LibraryScanner.scan(root: root, previousSnapshot: old)
            guard self.root == root, !loading, !mutating, installedRevision == presentationRevision else {
                watcher?.notifyChange()
                return
            }
            await navigationTask?.value
            for editor in allEditors {
                guard let url = editor.url else { continue }
                let path = String(url.path.dropFirst(root.path.count + 1))
                let id = old.metadata.IDsByPath[path]
                let destination = scanned.documents.first { $0.id == id }.map { root.appendingPathComponent($0.relativePath) }
                await editor.reconcileExternalChange(movedTo: destination)
            }
            // Derived index/cache writes also reach the watcher. A no-op scan must
            // not invalidate the entire workspace and restart search presentation.
            guard old.folders != scanned.folders || old.documents != scanned.documents
                || old.metadata != scanned.metadata || old.isReadOnly != scanned.isReadOnly
                || old.recoveredMetadataURL != scanned.recoveredMetadataURL else { return }
            // Finder batches are installed without row animations.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                session = LibraryReconciler.session(session, from: old, to: scanned)
                install(scanned)
                revision += 1
            }
        } catch {
            guard !Task.isCancelled, self.root == root, !loading else { return }
            if !FileManager.default.fileExists(atPath: root.path) {
                for editor in allEditors { await editor.libraryDisappeared() }
                errorTitle = "Library Not Found"
                errorSymbol = "externaldrive.badge.questionmark"
                self.error = "Silkweb can’t find “\(root.lastPathComponent)”. It may have been moved, renamed, or be on a disconnected drive."
                snapshot = nil
            } else {
                editor.error = error.localizedDescription
                editor.announce()
            }
        }
    }

    func resumeEditor() async {
        guard editor.url == nil, let snapshot else { return }
        if let saved = try? await WindowSessionMetadata.load(root: snapshot.rootURL) {
            await restoreTabs(saved)
        } else if let document = selectedDocument { _ = await openTab(document) }
    }

    func waitForNavigation() async { await navigationTask?.value }

    func showDocument(_ url: URL) {
        guard let root else { return }
        navigate(folder: nil, documents: [String(url.path.dropFirst(root.path.count + 1))])
    }

    func selectDocuments(_ paths: Set<String>) {
        navigate(folder: session.selectedFolder, documents: paths)
    }

    func selectFolder(_ path: String?) {
        navigate(folder: path, documents: [])
    }

    func navigate(folder: String?, documents: Set<String>, pinned: Bool = false) {
        guard !loading, !mutating else { return }
        let previous = navigationTask
        navigationTask = Task {
            await previous?.value
            let document = documents.count == 1 ? documents.first.flatMap { path in
                snapshot?.documents.first(where: { $0.relativePath == path })
            } : nil
            if let document { guard await openTab(document, pinned: pinned) else { return } }
            session.selectedFolder = folder
            session.selectedDocuments = documents
            if let path = documents.count == 1 ? documents.first : nil,
               let id = snapshot?.metadata.IDsByPath[path], let index = search.index {
                try? await index.recordOpened(id, persist: snapshot?.isReadOnly == false)
            }
            persistSession()
        }
    }

    func persistSession() {
        saveTask?.cancel()
        guard !loading, !restoringTabs, let snapshot, !snapshot.isReadOnly, canSaveSession else { return }
        let session = session
        let window = windowMetadata()
        let saveWindow = canSaveWindowSession
        saveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                try Task.checkCancellation()
                try await session.save(root: snapshot.rootURL)
                if saveWindow { try await window.save(root: snapshot.rootURL) }
            } catch is CancellationError { } catch {
                // Navigation persistence must never interrupt reading or modify document text.
                NSLog("Silkweb could not save navigation: %@", error.localizedDescription)
            }
        }
    }

    func saveSessionNow(root: URL? = nil) async {
        saveTask?.cancel()
        await saveTask?.value
        guard let snapshot, !snapshot.isReadOnly, canSaveSession else { return }
        do {
            try await session.save(root: root ?? snapshot.rootURL)
            if canSaveWindowSession { try await windowMetadata().save(root: root ?? snapshot.rootURL) }
        } catch { NSLog("Silkweb could not save navigation: %@", error.localizedDescription) }
    }

    func focus(_ column: Int) {
        if column == 2, preview.mode == .preview { preview.mode = preview.lastWritingMode }
        focusColumn = column
        focusRequest += 1
    }
}

struct LibraryWorkspaceView: View {
    @Bindable var workspace: LibraryWorkspace

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
        .overlay {
            if workspace.search.showsQuickOpen {
                QuickOpenPanel(workspace: workspace)
            }
        }
        .alert(workspace.mutationErrorTitle, isPresented: Binding(get: { workspace.mutationError != nil }, set: { if !$0 { workspace.mutationError = nil } })) {
            if !workspace.mutationRevealURLs.isEmpty {
                Button(workspace.mutationRevealTitle) {
                    NSWorkspace.shared.activateFileViewerSelecting(workspace.mutationRevealURLs)
                    workspace.mutationError = nil
                }
            }
            Button("OK") { workspace.mutationError = nil }
        } message: { Text(workspace.mutationError ?? "") }
        .alert(workspace.trashTitle, isPresented: Binding(get: { workspace.trashPlan != nil }, set: { if !$0 && workspace.trashPlan != nil { workspace.cancelTrash() } })) {
            Button("Move to Trash", role: .destructive) { workspace.confirmTrash() }.keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) { workspace.cancelTrash() }.keyboardShortcut(.cancelAction)
        } message: { Text(workspace.trashMessage) }
        .sheet(item: $workspace.importRequest) { request in ImportSheet(workspace: workspace, request: request) }
        .sheet(item: $workspace.moveRequest) { request in MovePicker(workspace: workspace, request: request) }
        .task { workspace.restore(); await workspace.resumeEditor() }
        .onChange(of: workspace.session) { workspace.persistSession() }
        .onChange(of: workspace.preview.mode) { workspace.persistSession() }
        .onChange(of: workspace.editor.state) { old, new in
            if old.isDirty, new == .clean { Task { await workspace.refreshSavedDocumentDates() } }
        }
    }

    private var libraryColumns: some View {
        LibrarySplitView(workspace: workspace)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Picker("View Mode", selection: Binding(get: { workspace.preview.mode }, set: { workspace.preview.mode = $0 })) {
                    ForEach(DocumentViewMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode).help(mode.title)
                    }
                }.pickerStyle(.segmented).labelStyle(.iconOnly).help("Editor, Split or Preview")
                Button("Show Outline", systemImage: "list.bullet.indent") { workspace.preview.showsOutline.toggle() }.help("Show Outline")
            }
            ToolbarItem(placement: .navigation) {
                Button("Toggle Sidebar", systemImage: "sidebar.left") { workspace.sidebarToggleRequest += 1 }
                    .help("Toggle Sidebar")
            }
            ToolbarItem(placement: .navigation) {
                Button("New Document", systemImage: "square.and.pencil") { workspace.create(folder: false) }
                    .help("New Document").disabled(!workspace.canMutate)
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    DocumentSortItems(workspace: workspace)
                    Divider()
                    IncludeSubfoldersItem(workspace: workspace)
                } label: { Label("Sort By", systemImage: "arrow.up.arrow.down") }
                .help("Sort By")
                .accessibilityLabel("Sort By, \(workspace.listPreference.key.title), \(workspace.listPreference.directionTitle)")
                .disabled(workspace.snapshot == nil)
            }
        }
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

struct DelayedLibraryProgress: View {
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

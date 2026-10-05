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
    /// View ▸ Bigger/Smaller (1.24): points added to the Settings editor size in this window. Never saved.
    var editorZoom = 0
    /// View ▸ Focus Mode / Typewriter Mode (1.27): per window, saved in the window session.
    var focusMode = false
    var typewriterMode = false
    @ObservationIgnored lazy var menuState = MenuCommandState(workspace: self)
    @ObservationIgnored var closingTabIDs: Set<UUID> = []
    @ObservationIgnored var recoveryDirectory: URL?
    let search = LibrarySearch()
    let toolbarMetrics = ToolbarMetrics()
    let preview: PreviewCoordinator
    let columnAutosaveName: String
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = AppDefaults.store, columnAutosaveName: String = "Silkweb.LibraryColumns") {
        self.defaults = defaults
        self.columnAutosaveName = columnAutosaveName
        preview = PreviewCoordinator(defaults: defaults)
    }
    var tagCounts: [UUID: Int] = [:]
    var tags: [LibraryTag] = []
    var recentTags: [LibraryTag] = []
    var inspectorInfo = false
    var tagFocusRequest = 0
    var tagRenameID: UUID?
    var tagRenameName = ""
    var tagEditing = false
    @ObservationIgnored var tagEditTask: Task<Void, Never>?
    @ObservationIgnored var pendingTagEdits = 0
    var tagFilters: Set<UUID> = [] { didSet { documentCache = nil } }
    var libraryUndo: [LibraryUndo] = []
    var importRequest: ImportRequest?
    var moveRequest: MoveRequest?
    var trashPlan: DeletionPlan?
    var mutationRevealURLs: [URL] = []
    var mutationRevealTitle = "Reveal in Finder"
    var recentMoveFolders: [String] = []
    var dragIdentity = UUID()
    var rename: LibraryRename?
    var exporting = false
    var pdfProgress: PDFProgress?
    @ObservationIgnored let printInfo = PrintCoordinator.defaultPrintInfo()
    var mutating = false
    var revision = 0
    var mutationError: String?
    var mutationErrorTitle = ""

    func install(_ snapshot: LibrarySnapshot) {
        self.snapshot = snapshot
        tagFilters.formIntersection(Set(snapshot.metadata.tags.map(\.id)))
        if let id = session.selectedTagID, !snapshot.metadata.tags.contains(where: { $0.id == id }) { session.selectedTagID = nil }
        tags = snapshot.metadata.tags.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var counts: [UUID: Int] = [:]
        for ids in snapshot.metadata.tagsByDocument.values { for id in ids { counts[id, default: 0] += 1 } }
        tagCounts = counts
        recentTags = TagEditor.recentTags(metadata: snapshot.metadata)
        search.install(snapshot)
        itemPathsByID = Dictionary(uniqueKeysWithValues: snapshot.metadata.IDsByPath.map { ($0.value, $0.key) })
        documentCache = nil
        presentationRevision += 1
    }
    private var watcher: LibraryWatcher?
    private var reconciling = false
    private var navigationTask: Task<Void, Never>?
    @ObservationIgnored private var navigationGeneration = 0
    var snapshot: LibrarySnapshot?
    var session = LibrarySession()
    var loading = false
    var mediaProgress: (name: String, done: Int, total: Int)?
    var mediaFailures: [AssetFailure] = []
    var mediaDirectoryName = "media"
    var mediaMigrationRunning = false
    var mediaBannerVisible = false
    /// A recovery file set aside in `Recovery/Unreadable/` (1.70); shown once per launch.
    var unreadableRecoveryFile: URL?
    @ObservationIgnored static var unreadableRecoveryShown = false
    var loadingCount: Int?
    var error: String?
    var errorTitle = "Can’t Open Library"
    var errorSymbol = "exclamationmark.triangle"
    var root: URL?
    var sidebarToggleRequest = 0
    var sidebarsHidden = false
    var tagsExpanded = true
    var libraryColumnCollapsed = false
    @ObservationIgnored weak var librarySplitController: LibrarySplitViewController?
    var sidebarsTitle: String { sidebarsHidden || libraryColumnCollapsed ? "Show Sidebars" : "Hide Sidebars" }
    var focusRequest = 0
    var focusColumn = 0
    private var scope: URL?
    private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var mediaRetryTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var canSaveSession = true
    @ObservationIgnored var itemPathsByID: [UUID: String] = [:]
    @ObservationIgnored private var presentationRevision = 0
    @ObservationIgnored private var documentCache: (folder: String?, preference: LibraryListPreference, tag: UUID?, documents: [LibraryDocument])?

    var selectedFolder: LibraryFolder? {
        session.selectedTagID == nil ? snapshot?.folders.first { $0.relativePath == session.selectedFolder } : nil
    }
    private var preferenceID: String { if let id = session.selectedTagID { return "tag:" + id.uuidString }; return selectedFolder.map { "folder:" + $0.id.uuidString } ?? "all" }
    var listPreference: LibraryListPreference { session.listPreferences[preferenceID] ?? LibraryListPreference() }
    var includesSubfolders: Bool { selectedFolder != nil && listPreference.includeSubfolders }
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
        if let cached = documentCache, cached.folder == session.selectedFolder, cached.preference == preference, cached.tag == session.selectedTagID {
            return cached.documents
        }
        guard session.selectedTagID != nil || session.selectedFolder == nil || selectedFolder != nil else { return [] }
        let documents = snapshot.presentation.documents(in: selectedFolder, preference: preference).filter {
            TagEditor.matches($0, folder: nil, includeSubfolders: false, tags: effectiveTagFilters, metadata: snapshot.metadata)
        }
        documentCache = (session.selectedFolder, preference, session.selectedTagID, documents)
        return documents
    }
    func refreshSavedDocumentDates() async {
        // One hash lookup by relative path; no URL is built per library document on the main thread.
        guard !loading, !mutating, let snapshot, let url = editor.url,
              url.path.hasPrefix(snapshot.rootURL.path + "/"),
              let id = snapshot.metadata.IDsByPath[String(url.path.dropFirst(snapshot.rootURL.path.count + 1))] else { return }
        let revision = presentationRevision
        guard let refreshed = try? await LibraryScanner.refreshingDates(in: snapshot, documentID: id),
              !loading, !mutating, presentationRevision == revision else { return }
        install(refreshed)
    }
    var selectedDocument: LibraryDocument? {
        guard session.selectedDocuments.count == 1 else { return nil }
        return documents.first { session.selectedDocuments.contains($0.relativePath) }
    }
    var folderName: String {
        tags.first { $0.id == session.selectedTagID }?.name ?? snapshot?.folders.first { $0.relativePath == session.selectedFolder }?.name ?? "All Documents"
    }
    var subtitle: String {
        search.text.isEmpty ? CountPresentation.label(documents.count, unit: .document) + (includesSubfolders ? " (with subfolders)" : "") : CountPresentation.label(filteredSearchResults.count, unit: .result)
    }
    /// The toolbar path: the open document's real folder, else the list scope. Reads no document text.
    var breadcrumb: Breadcrumb {
        let rootURL = snapshot?.rootURL ?? root
        let library = snapshot?.folders.first { $0.relativePath.isEmpty }?.name ?? rootURL?.lastPathComponent ?? "Library"
        let documentPath = editor.url.flatMap { url -> String? in
            guard let rootURL, url.path.hasPrefix(rootURL.path + "/") else { return nil }
            return String(url.path.dropFirst(rootURL.path.count + 1))
        }
        return Breadcrumb.make(libraryName: library, documentPath: documentPath, documentTitle: editor.name,
                               folder: session.selectedFolder, tagName: tags.first { $0.id == session.selectedTagID }?.name)
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

    /// Steps of 1 pt, keeping the effective size within 10–32 pt; `nil` returns to the Settings size.
    func zoomEditor(by step: Int?) {
        let base = Int(LivePreferences.shared.current.fontSize.rounded())
        let range = WritingPreferences.fontSizes
        editorZoom = step.map { min(max(editorZoom + $0, Int(range.lowerBound) - base), Int(range.upperBound) - base) } ?? 0
        for editor in EditorRegistry.editors.allObjects where editor.workspace === self && editor.zoom != editorZoom {
            editor.zoom = editorZoom
            editor.applySettings()
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

    func open(_ url: URL, usesSecurityScope: Bool = false) {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        let previousLoad = loadTask
        previousLoad?.cancel()
        saveTask?.cancel()
        loadTask = Task {
            await previousLoad?.value
            mediaRetryTask?.cancel()
            await mediaRetryTask?.value
            mediaRetryTask = nil
            guard !Task.isCancelled else { return }
            await navigationTask?.value
            guard !mutating else { return }
            tagFilters = []
            tags = []
            tagCounts = [:]
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
            tagsExpanded = true
            snapshot = nil
            error = nil
            mediaProgress = nil
            mediaFailures = []
            mediaBannerVisible = false
            unreadableRecoveryFile = nil
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
                session = restored.pruningPreferences(folderIDs: Set(scanned.folders.map(\.id)), tagIDs: Set(scanned.metadata.tags.map(\.id)))
                var windowSession: WindowSessionMetadata?
                canSaveWindowSession = true
                do { windowSession = try await WindowSessionMetadata.load(root: url) }
                catch LibraryError.unsupportedMetadataVersion { canSaveWindowSession = false }
                catch { /* Stale tab state never interrupts opening a library. */ }
                // Settings ▸ “Reopen windows and tabs from the last session” (1.24).
                if !LivePreferences.shared.current.reopensSession { windowSession = nil }
                if let windowSession { await restoreTabs(windowSession) }
                if let path = session.selectedFolder, !scanned.folders.contains(where: { $0.relativePath == path }) {
                    session.selectedFolder = ""
                }
                session.selectedDocuments.formIntersection(Set(documents.map(\.relativePath)))
                var recoveryURL: URL?
                let recovery = SaveCoordinator(recoveryDirectory: recoveryDirectory)
                let drafts = (try? await recovery.pendingRecoveryDrafts()) ?? []
                reportUnreadableRecovery(await recovery.takeUnreadableRecoveryFiles())
                if let draft = drafts.first(where: { $0.documentURL.path.hasPrefix(scanned.rootURL.path + "/") }) {
                    recoveryURL = draft.documentURL
                    session.selectedFolder = nil
                    session.selectedDocuments = Set(scanned.documents.filter { scanned.rootURL.appendingPathComponent($0.relativePath) == draft.documentURL }.map(\.relativePath))
                }
                if let recoveryURL, let document = scanned.documents.first(where: { scanned.rootURL.appendingPathComponent($0.relativePath) == recoveryURL }) {
                    _ = await openTab(document, pinned: true)
                } else if let recoveryURL {
                    // The note was deleted outside Silkweb; its draft must stay reachable (1.70).
                    await openOrphanDraft(recoveryURL.standardizedFileURL)
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
                loading = false
                await migrateMedia()
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

    func reportUnreadableRecovery(_ files: [URL]) {
        guard let file = files.first, !Self.unreadableRecoveryShown else { return }
        Self.unreadableRecoveryShown = true
        unreadableRecoveryFile = file
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: UnreadableRecoveryBanner.message,
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    func retryMediaMigration() {
        mediaRetryTask = Task { await migrateMedia() }
    }

    func migrateMedia() async {
        guard !mediaMigrationRunning, let root, let snapshot, !snapshot.isReadOnly,
              FileManager.default.fileExists(atPath: root.appendingPathComponent(".silkweb-assets").path) else { return }
        mediaMigrationRunning = true
        mediaFailures = []
        mediaBannerVisible = false
        let delay = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, self.root == root, self.mediaMigrationRunning else { return }
            self.mediaBannerVisible = true
        }
        defer { delay.cancel(); mediaMigrationRunning = false; mediaProgress = nil }
        let result = await AssetStore.shared.migrate(root: root, documents: snapshot.documents.map(\.relativePath), progress: { [weak self] name, done, total in
            Task { @MainActor in
                guard let self, self.root == root, self.mediaMigrationRunning else { return }
                self.mediaDirectoryName = name
                self.mediaProgress = (name, done, total)
            }
        }, beforeRewrite: { [weak self] in
            guard let self else { return false }
            return await self.beginMediaRewrite(root: root)
        }, afterRewrite: { [weak self] in
            await self?.finishMediaRewrite(root: root)
        })
        guard self.root == root, !Task.isCancelled else { return }
        mediaDirectoryName = result.directoryName
        mediaFailures = result.failures
        mediaBannerVisible = !result.failures.isEmpty
        if mediaBannerVisible {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: "Some images couldn’t be moved to the “\(mediaDirectoryName)” folder.",
                                            .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        if let updated = try? await LibraryScanner.scan(root: root, previousSnapshot: snapshot) { install(updated) }
    }

    private func beginMediaRewrite(root: URL) async -> Bool {
        // An insert already copying on the asset executor must publish its text
        // before we disable editing and flush. The executor can resume inserts
        // while it awaits this callback.
        while preview.editor?.assetHandler.busy == true {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
            guard self.root == root, !mutating else { return false }
        }
        await navigationTask?.value
        guard self.root == root, !mutating, !Task.isCancelled else { return false }
        mutating = true
        for editor in allEditors { editor.loading = true }
        guard await flushEditors() else {
            for editor in allEditors { editor.loading = false }
            mutating = false
            return false
        }
        return true
    }

    private func finishMediaRewrite(root: URL) async {
        guard self.root == root else { return }
        for editor in allEditors {
            if let url = editor.url { await editor.followRename(to: url) }
            editor.loading = false
        }
        mutating = false
    }

    func reconcileFinderChanges() async {
        guard !loading, !mutating, !mediaMigrationRunning, !reconciling, let root, let old = snapshot else {
            if mutating || mediaMigrationRunning || reconciling { watcher?.notifyChange() }
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
            for tab in tabs {
                tab.textView?.inlineImages.schedule()
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
                rekeyTabs(in: scanned)
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
        if LivePreferences.shared.current.reopensSession, let saved = try? await WindowSessionMetadata.load(root: snapshot.rootURL) {
            await restoreTabs(saved)
        } else if let document = selectedDocument { _ = await openTab(document) }
    }

    func waitForNavigation() async { await navigationTask?.value }

    /// Queues `work` behind pending navigation; later navigation waits for it.
    func afterNavigation(_ work: @escaping @MainActor () async -> Void) async {
        let previous = navigationTask
        let task = Task { await previous?.value; await work() }
        navigationTask = task
        await task.value
    }

    func showDocument(_ url: URL) {
        guard let root else { return }
        navigate(folder: nil, documents: [String(url.path.dropFirst(root.path.count + 1))])
    }

    func selectDocuments(_ paths: Set<String>) {
        navigate(folder: session.selectedFolder, documents: paths)
    }

    func selectFolder(_ path: String?) {
        navigate(folder: path, documents: [], tag: nil, changesScope: true)
    }

    func navigate(folder: String?, documents: Set<String>, pinned: Bool = false, tag: UUID? = nil, changesScope: Bool = false) {
        guard !loading, !mutating else { return }
        // The list follows the click at once (#70); the editor swaps in when the buffer has loaded.
        let shown = (folder: session.selectedFolder, documents: session.selectedDocuments, tag: session.selectedTagID, filters: tagFilters)
        var next = session
        next.selectedFolder = folder
        next.selectedDocuments = documents
        if changesScope { next.selectedTagID = tag }
        session = next
        // Install the new tag scope before clearing toolbar filters: never expose the full library.
        if changesScope && tag != nil { tagFilters = [] }
        navigationGeneration += 1
        let generation = navigationGeneration
        let previous = navigationTask
        navigationTask = Task {
            await previous?.value
            // Rapid clicks coalesce: a navigation already replaced by a newer one opens nothing.
            guard generation == navigationGeneration else { return }
            let document = documents.count == 1 ? documents.first.flatMap { path in
                snapshot?.documents.first(where: { $0.relativePath == path })
            } : nil
            if let document, !(await openTab(document, pinned: pinned)) {
                // The editor kept its document (unsaved text): the list goes back to it.
                guard generation == navigationGeneration else { return }
                session.selectedFolder = shown.folder
                session.selectedDocuments = shown.documents
                session.selectedTagID = shown.tag
                tagFilters = shown.filters
                return
            }
            if let path = documents.count == 1 ? documents.first : nil,
               let id = snapshot?.metadata.IDsByPath[path], let index = search.index {
                try? await index.recordOpened(id, persist: snapshot?.isReadOnly == false)
            }
            persistSession()
        }
    }

    private var prunedSession: LibrarySession {
        session.pruningPreferences(folderIDs: Set(snapshot?.folders.map(\.id) ?? []), tagIDs: Set(tags.map(\.id)))
    }

    func persistSession() {
        saveTask?.cancel()
        guard !loading, !restoringTabs, let snapshot, !snapshot.isReadOnly, canSaveSession else { return }
        let session = prunedSession
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
            try await prunedSession.save(root: root ?? snapshot.rootURL)
            if canSaveWindowSession { try await windowMetadata().save(root: root ?? snapshot.rootURL) }
        } catch { NSLog("Silkweb could not save navigation: %@", error.localizedDescription) }
    }

    func setSidebarsHidden(_ hidden: Bool) {
        sidebarsHidden = hidden
        sidebarToggleRequest += 1
        librarySplitController?.updateRequests()
        persistSession()
    }

    func toggleSidebars() {
        setSidebarsHidden(!(sidebarsHidden || libraryColumnCollapsed))
    }

    func focus(_ column: Int) {
        if column < 2 { setSidebarsHidden(false) }
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
        .background(Color.silkwebPaneBackground.ignoresSafeArea())
        .background(WindowSurface())
        .overlay(alignment: .top) { TitlebarHairline() }
        // Silkweb-drawn SwiftUI accents are sage; native focus rings keep the system accent.
        .tint(.silkwebAccent)
        // Unified chrome: `WindowSurface` puts the titlebar on the pane color; SwiftUI's toolbar background agrees.
        .toolbarBackground(Color.silkwebPaneBackground, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
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
        .sheet(item: $workspace.pdfProgress) { progress in PDFProgressSheet(progress: progress) }
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
                    // Same glyph size; the selected segment keeps the system tint.
                    .font(.system(size: 13, weight: .regular))
                Button("Show Outline", systemImage: "list.bullet.indent") { workspace.inspectorInfo = false; workspace.preview.showsOutline.toggle() }
                    .help("Show Outline").toolbarGlyph()
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Show Document Info", systemImage: "info.circle") { workspace.showInfo() }.help("Show Document Info").toolbarGlyph()
            }
            ToolbarItem(placement: .navigation) {
                Button(workspace.sidebarsTitle, systemImage: "sidebar.left") { workspace.toggleSidebars() }
                    .help(workspace.sidebarsTitle)
                    .accessibilityLabel(workspace.sidebarsTitle)
                    .toolbarGlyph()
            }
            ToolbarItem(placement: .navigation) {
                Button("New Document", systemImage: "square.and.pencil") { workspace.create(folder: false) }
                    .help("New Document").disabled(!workspace.canMutate).toolbarGlyph()
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
                .toolbarGlyph()
            }
            ToolbarItem(placement: .navigation) {
                Menu {
                    ForEach(workspace.tags) { tag in
                        Toggle(tag.name, isOn: Binding(get: { workspace.tagFilters.contains(tag.id) }, set: { on in
                            if on { workspace.tagFilters.insert(tag.id) } else { workspace.tagFilters.remove(tag.id) }
                        }))
                    }
                } label: { Label("Filter by Tag", systemImage: "tag") }
                .help("Filter by Tag").disabled(workspace.tags.isEmpty).toolbarGlyph()
            }
            ToolbarItem(placement: .navigation) {
                ToolbarBreadcrumb(workspace: workspace)
            }
        }
        // The compact bar has no title row; the breadcrumb replaces it. The title still feeds the
        // Window menu, Mission Control and VoiceOver.
        .toolbar(removing: .title)
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

private extension View {
    /// Smaller, lighter symbols for the compact bar (silkweb-1.65).
    func toolbarGlyph() -> some View {
        font(.system(size: 13, weight: .regular)).foregroundStyle(Color(nsColor: .secondaryLabelColor))
    }
}

struct DelayedLibraryProgress: View {
    let count: Int?
    @State private var visible = false
    var body: some View {
        ColumnEmptyState {
            if visible { ProgressView(count.map { "Loading library… \(CountPresentation.label($0, unit: .document))" } ?? "Loading library…").controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { try? await Task.sleep(for: .milliseconds(300)); if !Task.isCancelled { visible = true } }
    }
}

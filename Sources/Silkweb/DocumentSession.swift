import AppKit
import SilkwebCore
import SwiftUI

/// Owns the visible buffer. Actor work is ordered so a flush includes every edit.
@MainActor @Observable
final class DocumentSession {
    @ObservationIgnored var didEdit: (() -> Void)?
    /// Sees every banner announcement this session posts (tests count them, #139).
    @ObservationIgnored var didAnnounce: ((String) -> Void)?
    /// The banner and state last announced. Watcher ticks (an agent create, for one) re-publish an unchanged
    /// conflict or failure; it's announced once, until the document saves cleanly or another one opens (#139).
    @ObservationIgnored private var announced: (banner: String, state: DocumentSaveState)?
    var text = ""
    var url: URL?
    var state: DocumentSaveState = .clean
    var readOnly = false
    var recovered = false
    /// A recovery draft whose file was deleted outside Silkweb (1.70): editable, never
    /// autosaved, offered Save Again / Save a Copy; closing the tab keeps the draft.
    var orphanDraft = false
    /// Recovery files set aside by the last open, for the workspace strip.
    @ObservationIgnored var unreadableRecovery: [URL] = []
    var error: String?
    var assetMessage: String?
    var assetFailures: [AssetFailure] = []
    var assetProgress: String?
    var loading = false
    var refusedNavigation = 0
    var diskText: String?
    var diskModified: Date?
    var showingComparison = false
    var conflictCopy: URL?
    private var wasDirtyBeforeDelete = false
    private var libraryRoot: URL?
    var externalDeleted: Bool { if case .conflict(diskRevision: nil) = state { return true }; return false }
    var externalConflict: Bool { if case .conflict(diskRevision: .some) = state { return true }; return false }
    var caretLocation = 0
    @ObservationIgnored var selection = NSRange(location: 0, length: 0)
    @ObservationIgnored var scroll = NSPoint.zero
    /// Created by the first status bar that shows this buffer (silkweb-1.25).
    @ObservationIgnored private(set) var loadedStatistics: DocumentStatisticsModel?
    var statistics: DocumentStatisticsModel {
        if let loadedStatistics { return loadedStatistics }
        let model = DocumentStatisticsModel(session: self)
        loadedStatistics = model
        return model
    }
    private var positions: [URL: (NSRange, NSPoint)] = [:]
    private var coordinator = SaveCoordinator()
    private var tail: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var pendingEdits = 0

    var name: String { url?.deletingPathExtension().lastPathComponent ?? "Document" }
    var banner: String? {
        if externalConflict { return "“\(name)” was changed outside Silkweb while you were editing." }
        if externalDeleted { return "“\(name)” was moved to the Trash or deleted outside Silkweb." }
        if let error { return error }
        if case .failed = state { return "Silkweb couldn’t save “\(name)”. Your text is safe in this window." }
        if case .conflict = state {
            return "This document changed on disk. Your text is safe in this window. Save a copy to keep it."
        }
        if recovered { return "Silkweb recovered unsaved changes to this document." }
        if let conflictCopy {
            return "The other version was saved as “\(conflictCopy.deletingPathExtension().lastPathComponent)”."
        }
        return nil
    }

    func configure(root: URL, recoveryDirectory: URL? = nil) async {
        observation?.cancel()
        libraryRoot = root
        assetMessage = nil
        assetFailures = []
        assetProgress = nil
        diskText = nil
        conflictCopy = nil
        coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: recoveryDirectory)
        positions = [:]
        url = nil
        text = ""
        state = .clean
        announced = nil
    }

    func open(_ destination: URL?, readOnly: Bool) async -> Bool {
        guard destination != url else { return true }
        loading = true
        defer { loading = false }
        guard await flush(), !recovered else { refusedNavigation += 1; announce(); return false }
        if let url {
            positions[url] = (selection, scroll)
            guard await coordinator.close(url) else { return false }
        }
        observation?.cancel()
        url = destination
        assetMessage = nil
        assetFailures = []
        assetProgress = nil
        diskText = nil
        conflictCopy = nil
        text = ""
        state = .clean
        announced = nil
        error = nil
        self.readOnly = readOnly
        recovered = false
        orphanDraft = false
        guard let destination else { return true }
        do {
            // Only this note's draft is read (#208); an unreadable one never blocks opening (1.70).
            let found = await coordinator.recoveryDraft(for: destination)
            unreadableRecovery = await coordinator.takeUnreadableRecoveryFiles()
            if let draft = found {
                await coordinator.restore(draft)
                text = draft.text
                state = await coordinator.state(for: destination) ?? .dirty
                // A draft for a deleted file uses the deleted strip instead of Keep/Discard.
                orphanDraft = externalDeleted
                wasDirtyBeforeDelete = orphanDraft
                recovered = !orphanDraft
                announce()
            } else {
                text = try await coordinator.open(destination).text
            }
        } catch let failure as NSError where failure.code == NSFileReadInapplicableStringEncodingError {
            self.readOnly = true
            text =
                (try? await Task.detached { String(decoding: try Data(contentsOf: destination), as: UTF8.self) }.value)
                ?? ""
            error = "This document isn’t UTF-8 text, so Silkweb opened it read-only."
            announce()
        } catch {
            self.readOnly = true
            self.error = error.localizedDescription
            announce()
        }
        (selection, scroll) = positions[destination] ?? (NSRange(location: 0, length: 0), .zero)
        observe(destination)
        return true
    }

    private func observe(_ destination: URL) {
        observation?.cancel()
        let coordinator = coordinator
        observation = Task { [weak self] in
            for await value in await coordinator.states(for: destination) {
                guard !Task.isCancelled, let self, self.url == destination else { return }
                if self.pendingEdits == 0 {
                    self.state = value
                    if value == .clean { self.announced = nil }
                    if self.banner != nil { self.announce(once: true) }
                }
            }
        }
    }

    func reconcileExternalChange(movedTo destination: URL? = nil) async {
        guard !loading, let original = url else { return }
        // Watcher ticks after every autosave: an unchanged file must not refuse typing or IME
        // input. Only a move or a real disk change locks the buffer for the reload (1.74).
        if destination == nil || destination?.standardizedFileURL == original.standardizedFileURL {
            guard await coordinator.needsReconcile(original), !loading, url == original else { return }
        }
        loading = true
        defer { loading = false }
        observation?.cancel()
        await tail?.value
        guard url == original else { return }
        do {
            wasDirtyBeforeDelete = externalDeleted ? wasDirtyBeforeDelete : state.isDirty
            let disk = try await coordinator.reconcile(original, movedTo: destination)
            let target = destination ?? original
            guard url == original else { return }
            url = target
            state = await coordinator.state(for: target) ?? state
            if state == .clean, pendingEdits == 0, let disk { text = disk.text }
            diskText = disk?.text
            diskModified = try? await Task.detached {
                try target.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.value
            observe(target)
            if externalConflict || externalDeleted { announce(once: true) }
        } catch {
            self.error = error.localizedDescription
            if let url { observe(url) }
            announce()
        }
    }

    func compare() {
        guard let url else { return }
        Task {
            do {
                diskText = try await coordinator.diskVersion(url).text
                showingComparison = true
            } catch { self.error = error.localizedDescription; announce() }
        }
    }

    func resolveConflict(keepMine: Bool) async {
        guard let url, let root = libraryRoot else { return }
        loading = true
        defer { loading = false }
        await tail?.value
        do {
            conflictCopy = try await coordinator.resolve(url, keepMine: keepMine, root: root)
            text = await coordinator.draft(for: url) ?? text
            state = await coordinator.state(for: url) ?? state
            recovered = false
            error = nil
            showingComparison = false
            diskText = nil
            announce()
        } catch { self.error = error.localizedDescription; announce() }
    }

    func saveAgain() async {
        guard let url, let root = libraryRoot else { return }
        loading = true
        defer { loading = false }
        await tail?.value
        do {
            self.url = try await coordinator.recreate(url, root: root)
            state = .clean
            recovered = false
            orphanDraft = false
            error = nil
            observe(self.url!)
        } catch { self.error = error.localizedDescription; announce() }
    }

    func closeDeleted() async {
        guard let url else { return }
        if wasDirtyBeforeDelete {
            let alert = NSAlert()
            alert.messageText = "Close without saving “\(name)”?"
            alert.informativeText = "Your changes will be lost."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Close").hasDestructiveAction = true
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        await tail?.value
        do { try await coordinator.discardRecovery(url); await didCloseWindow() } catch {
            self.error = error.localizedDescription; announce()
        }
    }

    /// Closing an orphan draft's tab keeps its latest text as the recovery draft.
    func preserveOrphanDraft() async -> Bool {
        guard orphanDraft else { return false }
        await tail?.value
        do { try await coordinator.preserveUnsavedDrafts(); return true } catch {
            self.error = "Recovery draft couldn’t be saved: \(error.localizedDescription)"; announce(); return false
        }
    }

    func libraryDisappeared() async {
        await reconcileExternalChange()
        do { try await coordinator.preserveUnsavedDrafts() } catch {
            self.error = "Recovery draft couldn’t be saved: \(error.localizedDescription)"; announce()
        }
    }

    func edit(_ value: String) {
        guard !readOnly, !loading, let url else { return }
        didEdit?()
        text = value
        if externalDeleted { wasDirtyBeforeDelete = true }
        if !externalConflict && !externalDeleted { state = .dirty }
        pendingEdits += 1
        let previous = tail
        let coordinator = coordinator
        tail = Task {
            await previous?.value
            do {
                try await coordinator.edit(value, at: url)
                if !recovered && !externalConflict && !externalDeleted { await coordinator.scheduleSave(url) }
            } catch { self.error = error.localizedDescription }
            pendingEdits -= 1
        }
    }

    @discardableResult
    func flush() async -> Bool {
        await tail?.value
        guard let url, !readOnly else { return true }
        guard !recovered, !externalConflict, !externalDeleted else { return false }
        let value = text
        let result = await coordinator.save(url) ?? .clean
        // Typing may continue while IO runs. Never mark newer text clean.
        if value == text, pendingEdits == 0 { state = result }
        if state == .clean { announced = nil }
        if result.isDirty { announce(once: true) }
        return !result.isDirty && value == text && pendingEdits == 0
    }

    func save() async -> Bool {
        recovered = false
        return await flush()
    }

    func followRename(to destination: URL) async {
        let wasLoading = loading
        loading = false
        await reconcileExternalChange(movedTo: destination)
        loading = wasLoading
    }

    func keepRecovery() {
        recovered = false
        Task { _ = await flush() }
    }

    static func discardRecoveryAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Discard the recovered text?"
        alert.informativeText = "This can’t be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Recovered Text").hasDestructiveAction = true
        return alert
    }

    func discardRecovery() {
        guard Self.discardRecoveryAlert().runModal() == .alertSecondButtonReturn, let url else { return }
        Task {
            await tail?.value
            do {
                try await coordinator.discardRecovery(url)
                recovered = false
                state = .clean
                text = ""
                do { text = try await coordinator.open(url).text } catch {
                    readOnly = true; self.error = error.localizedDescription
                }
            } catch { self.error = error.localizedDescription }
        }
    }

    func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + " copy.md"
        panel.begin { [weak self] response in
            guard response == .OK, let target = panel.url, let self else { return }
            let value = self.text
            Task {
                do { try await Task.detached { try Data(value.utf8).write(to: target, options: .atomic) }.value } catch
                { self.error = error.localizedDescription; self.announce() }
            }
        }
    }

    /// Quitting the app and closing a window share one exit path; only the alert's verb differs (#111).
    enum ExitReason { case quit, closeWindow }

    /// Cancel stays first and takes Escape; the destructive button has no key equivalent, so Return never discards.
    static func exitAlert(_ reason: ExitReason) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Some changes couldn’t be saved."
        alert.informativeText =
            "They’ll be kept as a recovery draft and offered the next time you open "
            + (reason == .quit ? "Silkweb." : "the document.")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: reason == .quit ? "Quit Anyway" : "Close Anyway").hasDestructiveAction = true
        return alert
    }

    func prepareToExit(_ reason: ExitReason, beforeAlert: (() -> Void)? = nil) async -> Bool {
        let wasLoading = loading
        loading = true
        defer { loading = wasLoading }
        if await flush() { return true }
        do { try await coordinator.preserveUnsavedDrafts() } catch {
            beforeAlert?()
            self.error = "Recovery draft couldn’t be saved: \(error.localizedDescription)"; announce(); return false
        }
        beforeAlert?()
        return Self.exitAlert(reason).runModal() == .alertSecondButtonReturn
    }

    func didCloseWindow() async {
        if let url, !state.isDirty { _ = await coordinator.close(url) }
        observation?.cancel()
        url = nil
        text = ""
        state = .clean
        announced = nil
        recovered = false
        orphanDraft = false
        error = nil
    }

    /// `once`: a re-published state (the save observer, a watcher tick) is skipped if it was already announced.
    /// Explicit paths (a refused switch, a failed action) always announce.
    func announce(once: Bool = false) {
        guard let banner else { return }
        if once, let announced, announced.banner == banner, announced.state == state { return }
        announced = (banner, state)
        didAnnounce?(banner)
        // `NSApplication.shared`, not `NSApp`: the global is nil until something creates the application (#63).
        NSAccessibility.post(
            element: NSApplication.shared.mainWindow ?? NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: banner, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

import Darwin
import Foundation

public struct DocumentSaveFailure: Error, LocalizedError, Equatable, Sendable {
    /// `libraryBusy`: another Silkweb process held the library's gate for the whole wait (#131).
    public enum Reason: Equatable, Sendable { case diskFull, permission, volumeUnavailable, libraryBusy, other(String) }
    public let reason: Reason
    public let folderName: String

    public var errorDescription: String? {
        let message: String
        switch reason {
        case .diskFull: message = "There isn’t enough space on the disk."
        case .permission: message = "You don’t have permission to write to “\(folderName)”."
        case .volumeUnavailable: message = "The disk containing this library is no longer available."
        // The banner already says the text is safe; this detail says what happens next.
        case .libraryBusy: return LibraryGateError.busy(retryAfter: 1).errorDescription
        case .other(let description): message = description
        }
        return message + " Your text is safe in this window."
    }

    public init(reason: Reason, folderName: String) {
        self.reason = reason
        self.folderName = folderName
    }

    init(error: Error, url: URL) {
        let isBusy = error is LibraryGateError
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError ?? error
        if isBusy {
            reason = .libraryBusy
        } else if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
            || (underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC))
        {
            reason = .diskFull
        } else if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError)
            || (underlying.domain == NSPOSIXErrorDomain
                && [Int(EACCES), Int(EPERM), Int(EROFS)].contains(underlying.code))
        {
            reason = .permission
        } else if underlying.domain == NSPOSIXErrorDomain && [Int(ENODEV), Int(ENXIO)].contains(underlying.code) {
            reason = .volumeUnavailable
        } else {
            reason = .other(error.localizedDescription)
        }
        folderName = url.deletingLastPathComponent().lastPathComponent
    }
}

public enum DocumentSaveState: Equatable, Sendable {
    case clean, dirty, saving
    case failed(error: DocumentSaveFailure, attempt: Int)
    /// nil means the file was deleted. The reconciliation UI handles both cases.
    case conflict(diskRevision: DocumentRevision?)

    public var isDirty: Bool { self != .clean }
}

/// Separate versioned recovery format; Markdown and library metadata remain unchanged.
public struct RecoveryDraft: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let formatVersion: Int
    public let documentURL: URL
    public let text: String
    public let revision: DocumentRevision?

    init(documentURL: URL, text: String, revision: DocumentRevision?) {
        formatVersion = Self.currentVersion
        self.documentURL = documentURL
        self.text = text
        self.revision = revision
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, documentURL, text, revision }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard formatVersion == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion, in: values, debugDescription: "Unsupported recovery format")
        }
        documentURL = try values.decode(URL.self, forKey: .documentURL)
        text = try values.decode(String.self, forKey: .text)
        revision = try values.decodeIfPresent(DocumentRevision.self, forKey: .revision)
    }
}

/// One coordinator per open library. Actor isolation serializes commits (including
/// each document's edits and retries), with no filesystem work on the main actor.
/// Streams expose typed state for the editor without importing a UI framework.
public actor SaveCoordinator {
    private struct Entry {
        var text: String
        var revision: DocumentRevision?
        var state: DocumentSaveState
        var attempts = 0
        /// Restored from a recovery draft and not yet kept: only an explicit save may write it.
        var recoveryPending = false
    }
    private let store: DocumentStore
    private let recoveryDirectory: URL
    /// After a busy-gate failure, autosave tries again on its own after this delay.
    private let busyRetryDelay: Duration
    private var entries: [URL: Entry] = [:]
    private var scheduled: [URL: Task<Void, Never>] = [:]
    private var recoveryFailures: [URL: DocumentSaveFailure] = [:]
    private var unreadableRecovery: [URL] = []
    private var observers: [URL: [UUID: AsyncStream<DocumentSaveState>.Continuation]] = [:]
    /// #204: held while a document has unsaved changes, so an agent update refuses instead of overwriting them.
    private let markers: DocumentEditingMarker.Holder?
    /// Each URL's Library-relative path for its marker (`nil` outside the Library), worked out once.
    private var markerPaths: [URL: String?] = [:]

    public init(
        store: DocumentStore = DocumentStore(), recoveryDirectory: URL? = nil, busyRetryDelay: Duration = .seconds(2)
    ) {
        self.store = store
        self.busyRetryDelay = busyRetryDelay
        markers = store.gate.map { DocumentEditingMarker.Holder(root: $0.root) }
        self.recoveryDirectory = recoveryDirectory ?? Self.defaultRecoveryDirectory
    }

    /// Application Support, except under XCTest: test runs get a disposable folder of their own,
    /// so they never read or write the user's real drafts (#208).
    public static let defaultRecoveryDirectory: URL = {
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent(
                "Silkweb Test Recovery \(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silkweb/Recovery", isDirectory: true)
    }()

    @discardableResult
    public func open(_ url: URL) throws -> LoadedDocument {
        let url = url.standardizedFileURL
        // Reopening must never discard a dirty buffer.
        if let entry = entries[url] {
            guard let revision = entry.revision else { throw CocoaError(.fileReadNoSuchFile) }
            return LoadedDocument(text: entry.text, revision: revision)
        }
        let loaded = try store.load(url)
        entries[url] = Entry(text: loaded.text, revision: loaded.revision, state: .clean)
        publish(url)
        return loaded
    }

    public func edit(_ text: String, at url: URL) throws {
        let url = url.standardizedFileURL
        guard var entry = entries[url] else { throw CocoaError(.fileReadUnknown) }
        guard text != entry.text else { return }
        entry.text = text
        if case .conflict = entry.state {} else { entry.state = .dirty }
        entries[url] = entry
        publish(url)
    }

    /// Replaces the pending deadline; explicit save/close cancels it.
    /// A pending recovery draft is never autosaved; see `save(_:)`.
    public func scheduleSave(_ url: URL, delay: Duration = .seconds(1)) {
        let url = url.standardizedFileURL
        if case .conflict = entries[url]?.state { return }
        if entries[url]?.recoveryPending == true { return }
        scheduled[url]?.cancel()
        scheduled[url] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                _ = await self?.commit(url, explicit: false)
            } catch {}
        }
    }

    /// Failed closes retain the entry so the UI can refuse navigation.
    @discardableResult
    public func close(_ url: URL) async -> Bool {
        let url = url.standardizedFileURL
        guard await commit(url, explicit: false)?.isDirty != true else { return false }
        entries[url] = nil
        recoveryFailures[url] = nil
        syncMarker(url)
        return true
    }

    /// Explicitly confirmed discard, including the on-disk recovery copy.
    public func discardRecovery(_ url: URL) throws {
        let url = url.standardizedFileURL
        let recovery = recoveryURL(url)
        if FileManager.default.fileExists(atPath: recovery.path) {
            try FileManager.default.removeItem(at: recovery)
        }
        scheduled.removeValue(forKey: url)?.cancel()
        entries[url] = nil
        recoveryFailures[url] = nil
        syncMarker(url)
    }

    public func state(for url: URL) -> DocumentSaveState? { entries[url.standardizedFileURL]?.state }
    public func draft(for url: URL) -> String? { entries[url.standardizedFileURL]?.text }
    public func recoveryFailure(for url: URL) -> DocumentSaveFailure? { recoveryFailures[url.standardizedFileURL] }

    public func states(for url: URL) -> AsyncStream<DocumentSaveState> {
        let url = url.standardizedFileURL
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            observers[url, default: [:]][id] = continuation
            if let state = entries[url]?.state { continuation.yield(state) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeObserver(id, url: url) }
            }
        }
    }

    /// An explicit save (Keep Recovered Text, Save) also accepts a pending recovery draft.
    /// Failure is represented in state; the in-memory text always remains available.
    @discardableResult
    public func save(_ url: URL) async -> DocumentSaveState? { await commit(url, explicit: true) }

    private func commit(_ url: URL, explicit: Bool) async -> DocumentSaveState? {
        let url = url.standardizedFileURL
        scheduled.removeValue(forKey: url)?.cancel()
        guard var entry = entries[url], entry.state.isDirty else { return entries[url]?.state }
        if entry.recoveryPending {
            // Until the user keeps the recovered text, the file on disk stays untouched.
            guard explicit else { return entry.state }
            entry.recoveryPending = false
            entries[url] = entry
        }
        if case .conflict = entry.state {
            _ = try? reconcile(url)
            return entries[url]?.state
        }
        entry.state = .saving
        entry.attempts += 1
        entries[url] = entry
        publish(url)
        // Another Silkweb process may hold the gate. Wait quietly (the state stays `.saving`, shown as
        // Edited); edits typed meanwhile land in `entries` and are saved by this same commit.
        let lease: LibraryGate.Lease?
        do {
            lease = try await gateLease()
        } catch {
            return fail(url, error: error)
        }
        defer { lease?.release() }
        // The wait may have let another commit, a conflict or a close happen first.
        guard var latest = entries[url], latest.state.isDirty else { return entries[url]?.state }
        if case .conflict = latest.state { return latest.state }
        if latest.state != .saving {
            latest.state = .saving
            entries[url] = latest
            publish(url)
        }
        entry = latest
        do {
            guard let revision = entry.revision else { throw CocoaError(.fileReadNoSuchFile) }
            entry.revision = try store.saveHoldingGate(entry.text, to: url, expectedRevision: revision)
            entry.state = .clean
            entry.attempts = 0
            // A leftover draft must never silently overwrite the successfully saved file.
            try? FileManager.default.removeItem(at: recoveryURL(url))
        } catch DocumentStoreError.conflict(let revision) {
            entry.state = .conflict(diskRevision: revision)
        } catch {
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError ?? failure
            if (failure.domain == NSCocoaErrorDomain
                && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code))
                || (underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT))
            {
                entry.state = .conflict(diskRevision: nil)
            } else {
                entry.state = .failed(error: DocumentSaveFailure(error: error, url: url), attempt: entry.attempts)
            }
        }
        entries[url] = entry
        if entry.state.isDirty {
            do { try persistRecovery(url, entry: entry) } catch {
                recoveryFailures[url] = DocumentSaveFailure(error: error, url: recoveryDirectory)
            }
        }
        publish(url)
        return entry.state
    }

    /// The uncontended case takes the gate without suspending. The wait runs in a task of its own:
    /// a scheduled autosave cancels its own task as it commits, and that must not cut the wait short.
    private func gateLease() async throws -> LibraryGate.Lease? {
        guard let gate = store.gate else { return nil }
        if let lease = try gate.tryAcquire() { return lease }
        let timeout = store.gateTimeout
        return try await Task.detached(priority: .userInitiated) { try await gate.acquire(timeout: timeout) }.value
    }

    /// The gate couldn't be had. Never a conflict: the buffer (including edits typed during the wait)
    /// stays dirty with a save-failure reason, and a busy library is retried on its own.
    private func fail(_ url: URL, error: Error) -> DocumentSaveState? {
        guard var entry = entries[url], entry.state.isDirty else { return entries[url]?.state }
        if case .conflict = entry.state { return entry.state }
        let failure = DocumentSaveFailure(error: error, url: url)
        entry.state = .failed(error: failure, attempt: entry.attempts)
        entries[url] = entry
        do { try persistRecovery(url, entry: entry) } catch {
            recoveryFailures[url] = DocumentSaveFailure(error: error, url: recoveryDirectory)
        }
        publish(url)
        if failure.reason == .libraryBusy { scheduleSave(url, delay: busyRetryDelay) }
        return entry.state
    }

    /// Call before quitting. Throws if recovery storage fails so the app can keep
    /// the window open; failed primary saves still retain the in-memory buffer.
    public func preserveUnsavedDrafts() throws {
        for (url, entry) in entries where entry.state.isDirty { try persistRecovery(url, entry: entry) }
    }

    /// Decodes each draft on its own. A file that can't be read is moved to
    /// `Unreadable/` (bytes kept) and reported once through `takeUnreadableRecoveryFiles()`;
    /// drafts from a newer format stay in place for the build that wrote them.
    public func pendingRecoveryDrafts() throws -> [RecoveryDraft] {
        guard FileManager.default.fileExists(atPath: recoveryDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            .compactMap { decodeDraft(at: $0) }
    }

    /// The draft for one document, if any. Reads only the files its URL could be saved under, so
    /// opening a note never costs more with more drafts (#208); an unreadable one is set aside as in
    /// `pendingRecoveryDrafts()`. A draft found under another spelling of the URL moves to this one,
    /// so Keep, Save and Discard clear it.
    public func recoveryDraft(for url: URL) -> RecoveryDraft? {
        let original = url
        let url = url.standardizedFileURL
        let canonical = recoveryURL(url)
        let path = url.path
        let other = URL(fileURLWithPath: path.hasPrefix("/private/") ? String(path.dropFirst(8)) : "/private" + path)
        var files = [canonical]
        for file in [original, other, other.standardizedFileURL].map(recoveryURL) where !files.contains(file) {
            files.append(file)
        }
        for file in files where FileManager.default.fileExists(atPath: file.path) {
            guard let draft = decodeDraft(at: file) else { continue }
            guard file != canonical else { return draft }
            let moved = RecoveryDraft(documentURL: url, text: draft.text, revision: draft.revision)
            if !FileManager.default.fileExists(atPath: canonical.path),
                (try? JSONEncoder().encode(moved).write(to: canonical, options: .atomic)) != nil
            {
                try? FileManager.default.removeItem(at: file)
            }
            return moved
        }
        return nil
    }

    /// Drafts from a newer format stay in place for the build that wrote them; any other unreadable file is set aside.
    private func decodeDraft(at file: URL) -> RecoveryDraft? {
        let data = try? Data(contentsOf: file)
        if let data, let draft = try? JSONDecoder().decode(RecoveryDraft.self, from: data) { return draft }
        if let data, let version = try? JSONDecoder().decode(RecoveryVersion.self, from: data).formatVersion,
            version > RecoveryDraft.currentVersion
        {
            return nil
        }
        quarantine(file)
        return nil
    }

    /// Quarantined files since the last call, so the UI reports each one once.
    public func takeUnreadableRecoveryFiles() -> [URL] {
        defer { unreadableRecovery = [] }
        return unreadableRecovery
    }

    private struct RecoveryVersion: Decodable { let formatVersion: Int }

    private func quarantine(_ file: URL) {
        let folder = recoveryDirectory.appendingPathComponent("Unreadable", isDirectory: true)
        var target = folder.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent(
                file.deletingPathExtension().lastPathComponent + " " + UUID().uuidString + ".json")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: target)
            unreadableRecovery.append(target)
        } catch {
            // Left in place, it is skipped again next time; opening never depends on it.
            unreadableRecovery.append(file)
        }
    }

    /// Explicit review action: restore as dirty, retaining the original disk token.
    /// The draft is not written over the file until an explicit `save(_:)`. A draft whose
    /// file no longer exists opens as deleted (Save Again / Save a Copy), never autosaved.
    public func restore(_ draft: RecoveryDraft) {
        let url = draft.documentURL.standardizedFileURL
        guard entries[url] == nil else { return }
        let deleted = !FileManager.default.fileExists(atPath: url.path)
        entries[url] = Entry(
            text: draft.text, revision: draft.revision,
            state: deleted ? .conflict(diskRevision: nil) : .dirty, recoveryPending: true)
        publish(url)
    }

    /// Whether `reconcile(_:)` could change the entry: the disk revision moved, the file is
    /// unreadable or gone, or a conflict may resolve. Never mutates and never reschedules a save,
    /// so an unchanged file costs one read and no editor lock (1.74).
    public func needsReconcile(_ url: URL) -> Bool {
        guard let entry = entries[url.standardizedFileURL] else { return false }
        if case .conflict = entry.state { return true }
        guard let disk = try? store.load(url.standardizedFileURL) else { return true }
        return disk.revision != entry.revision
    }

    /// Reads only the open document; library scans never read all document bodies.
    public func reconcile(_ url: URL, movedTo destination: URL? = nil) throws -> LoadedDocument? {
        let old = url.standardizedFileURL
        let target = destination?.standardizedFileURL ?? old
        guard var entry = entries[old] else { return nil }
        scheduled.removeValue(forKey: old)?.cancel()
        if target != old {
            entries[old] = nil
            entries[target] = entry
            syncMarker(old)
            syncMarker(target)
            try? FileManager.default.removeItem(at: recoveryURL(old))
        }
        do {
            let disk = try store.load(target)
            if entry.revision == disk.revision {
                if case .conflict = entry.state {
                    // A restored file or reverted external edit resolves the conflict.
                    entry.state = entry.text == disk.text ? .clean : .dirty
                    entries[target] = entry
                    publish(target)
                }
                entries[target] = entry
                if entry.state.isDirty { scheduleSave(target) }
                return nil
            }
            if entry.state == .clean {
                entry.text = disk.text
                entry.revision = disk.revision
            } else {
                entry.state = .conflict(diskRevision: disk.revision)
            }
            entries[target] = entry
            if entry.state.isDirty {
                do { try persistRecovery(target, entry: entry) } catch {
                    recoveryFailures[target] = DocumentSaveFailure(error: error, url: recoveryDirectory)
                }
            }
            publish(target)
            return disk
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code)
        {
            entry.state = .conflict(diskRevision: nil)
            entries[target] = entry
            do { try persistRecovery(target, entry: entry) } catch {
                recoveryFailures[target] = DocumentSaveFailure(error: error, url: recoveryDirectory)
            }
            publish(target)
            return nil
        }
    }

    public func diskVersion(_ url: URL) throws -> LoadedDocument { try store.load(url) }

    /// Re-read at resolution time so a second external edit is preserved too.
    public func resolve(_ url: URL, keepMine: Bool, root: URL, date: Date = Date()) async throws -> URL {
        guard let entry = entries[url], case .conflict = entry.state else { throw CocoaError(.fileWriteUnknown) }
        let disk = try store.load(url)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        // Leave room for the collision suffix even at the filesystem name limit.
        let suffix = " (Conflict " + formatter.string(from: date) + ")." + url.pathExtension
        var stem = url.deletingPathExtension().lastPathComponent
        while (stem + suffix).utf8.count > 240 { stem.removeLast() }
        let base = stem + suffix
        let parent = String(url.deletingLastPathComponent().path.dropFirst(root.path.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        let mutations = try LibraryMutations(root: root)
        let name = try await mutations.uniqueName(base: base, in: parent)
        _ = try await mutations.createDocument(named: name, in: parent, text: keepMine ? disk.text : entry.text)
        let copy = url.deletingLastPathComponent().appendingPathComponent(name)
        // An edit queued during the copy IO must also survive resolution.
        guard let latest = entries[url] else { throw CocoaError(.fileWriteUnknown) }
        if keepMine {
            let revision = try store.save(latest.text, to: url, expectedRevision: disk.revision)
            entries[url] = Entry(text: latest.text, revision: revision, state: .clean)
        } else {
            guard latest.text == entry.text else { throw CocoaError(.fileWriteUnknown) }
            let current = try store.load(url)
            guard current.revision == disk.revision else { throw DocumentStoreError.conflict(current.revision) }
            entries[url] = Entry(text: disk.text, revision: disk.revision, state: .clean)
        }
        scheduled.removeValue(forKey: url)?.cancel()
        try? FileManager.default.removeItem(at: recoveryURL(url))
        publish(url)
        return copy
    }

    public func recreate(_ url: URL, root: URL) async throws -> URL {
        guard let entry = entries[url] else { throw CocoaError(.fileWriteUnknown) }
        let parent = String(url.deletingLastPathComponent().path.dropFirst(root.path.count)).trimmingCharacters(
            in: CharacterSet(charactersIn: "/"))
        let mutations = try LibraryMutations(root: root)
        // Save Again also restores a containing folder deleted in Finder.
        var ancestor = ""
        for component in parent.split(separator: "/") {
            let next = ancestor.isEmpty ? String(component) : ancestor + "/" + component
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(next).path) {
                _ = try await mutations.createFolder(named: String(component), in: ancestor)
            }
            ancestor = next
        }
        let name = try await mutations.uniqueName(base: url.lastPathComponent, in: parent)
        _ = try await mutations.createDocument(named: name, in: parent, text: entry.text)
        let target = url.deletingLastPathComponent().appendingPathComponent(name)
        let loaded = try store.load(target)
        guard let latest = entries[url] else { throw CocoaError(.fileWriteUnknown) }
        entries[url] = nil
        syncMarker(url)
        entries[target] = Entry(
            text: latest.text, revision: loaded.revision, state: latest.text == entry.text ? .clean : .dirty)
        if latest.text != entry.text { scheduleSave(target) }
        try? FileManager.default.removeItem(at: recoveryURL(url))
        publish(target)
        return target
    }

    private func recoveryURL(_ url: URL) -> URL {
        let token = DocumentRevision(data: Data(url.absoluteString.utf8)).digest
        return recoveryDirectory.appendingPathComponent(token + ".json")
    }

    private func persistRecovery(_ url: URL, entry: Entry) throws {
        try FileManager.default.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)
        let draft = RecoveryDraft(documentURL: url, text: entry.text, revision: entry.revision)
        try JSONEncoder().encode(draft).write(to: recoveryURL(url), options: .atomic)
        recoveryFailures[url] = nil
    }

    private func publish(_ url: URL) {
        syncMarker(url)
        guard let state = entries[url]?.state else { return }
        for continuation in observers[url, default: [:]].values { continuation.yield(state) }
    }

    /// Holds the editing marker while `url` has unsaved changes (any dirty state, conflicts included) and lets
    /// it go otherwise. File work happens only on a change between the two, never per keystroke.
    private func syncMarker(_ url: URL) {
        guard let markers else { return }
        let relative: String?
        if let cached = markerPaths[url] {
            relative = cached
        } else {
            let root = markers.root.path + "/"
            let standardized = url.standardizedFileURL.path
            let path = standardized.hasPrefix(root) ? standardized : url.resolvingSymlinksInPath().path
            relative = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : nil
            markerPaths[url] = .some(relative)
        }
        guard let relative else { return }
        if entries[url]?.state.isDirty == true { markers.hold(relative) } else { markers.release(relative) }
    }

    /// Test seam: whether this coordinator holds the editing marker for a Library-relative path.
    func isHoldingEditingMarker(_ relativePath: String) -> Bool { markers?.isHolding(relativePath) ?? false }

    private func removeObserver(_ id: UUID, url: URL) { observers[url]?[id] = nil }
}

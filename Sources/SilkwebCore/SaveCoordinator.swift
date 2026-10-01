import Foundation
import Darwin

public struct DocumentSaveFailure: Error, LocalizedError, Equatable, Sendable {
    public enum Reason: Equatable, Sendable { case diskFull, permission, volumeUnavailable, other(String) }
    public let reason: Reason
    public let folderName: String

    public var errorDescription: String? {
        let message: String
        switch reason {
        case .diskFull: message = "There isn’t enough space on the disk."
        case .permission: message = "You don’t have permission to write to “\(folderName)”."
        case .volumeUnavailable: message = "The disk containing this library is no longer available."
        case .other(let description): message = description
        }
        return message + " Your text is safe in this window."
    }

    init(error: Error, url: URL) {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError ?? error
        if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError)
            || (underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOSPC)) {
            reason = .diskFull
        } else if (error.domain == NSCocoaErrorDomain && error.code == NSFileWriteNoPermissionError)
            || (underlying.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM), Int(EROFS)].contains(underlying.code)) {
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
            throw DecodingError.dataCorruptedError(forKey: .formatVersion, in: values, debugDescription: "Unsupported recovery format")
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
    }
    private let store: DocumentStore
    private let recoveryDirectory: URL
    private var entries: [URL: Entry] = [:]
    private var scheduled: [URL: Task<Void, Never>] = [:]
    private var recoveryFailures: [URL: DocumentSaveFailure] = [:]
    private var observers: [URL: [UUID: AsyncStream<DocumentSaveState>.Continuation]] = [:]

    public init(store: DocumentStore = DocumentStore(), recoveryDirectory: URL? = nil) {
        self.store = store
        self.recoveryDirectory = recoveryDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silkweb/Recovery", isDirectory: true)
    }

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
        if case .conflict = entry.state { } else { entry.state = .dirty }
        entries[url] = entry
        publish(url)
    }

    /// Replaces the pending deadline; explicit save/close cancels it.
    public func scheduleSave(_ url: URL, delay: Duration = .seconds(1)) {
        let url = url.standardizedFileURL
        if case .conflict = entries[url]?.state { return }
        scheduled[url]?.cancel()
        scheduled[url] = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                _ = await self?.save(url)
            } catch { }
        }
    }

    /// Failed closes retain the entry so the UI can refuse navigation.
    @discardableResult
    public func close(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        guard save(url)?.isDirty != true else { return false }
        entries[url] = nil
        recoveryFailures[url] = nil
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

    /// Failure is represented in state; the in-memory text always remains available.
    @discardableResult
    public func save(_ url: URL) -> DocumentSaveState? {
        let url = url.standardizedFileURL
        scheduled.removeValue(forKey: url)?.cancel()
        guard var entry = entries[url], entry.state.isDirty else { return entries[url]?.state }
        if case .conflict = entry.state {
            _ = try? reconcile(url)
            return entries[url]?.state
        }
        entry.state = .saving
        entry.attempts += 1
        entries[url] = entry
        publish(url)
        do {
            guard let revision = entry.revision else { throw CocoaError(.fileReadNoSuchFile) }
            entry.revision = try store.save(entry.text, to: url, expectedRevision: revision)
            entry.state = .clean
            entry.attempts = 0
            // A leftover draft must never silently overwrite the successfully saved file.
            try? FileManager.default.removeItem(at: recoveryURL(url))
        } catch DocumentStoreError.conflict(let revision) {
            entry.state = .conflict(diskRevision: revision)
        } catch {
            let failure = error as NSError
            let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError ?? failure
            if (failure.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code))
                || (underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)) {
                entry.state = .conflict(diskRevision: nil)
            } else {
                entry.state = .failed(error: DocumentSaveFailure(error: error, url: url), attempt: entry.attempts)
            }
        }
        entries[url] = entry
        if entry.state.isDirty {
            do { try persistRecovery(url, entry: entry) }
            catch { recoveryFailures[url] = DocumentSaveFailure(error: error, url: recoveryDirectory) }
        }
        publish(url)
        return entry.state
    }

    /// Call before quitting. Throws if recovery storage fails so the app can keep
    /// the window open; failed primary saves still retain the in-memory buffer.
    public func preserveUnsavedDrafts() throws {
        for (url, entry) in entries where entry.state.isDirty { try persistRecovery(url, entry: entry) }
    }

    public func pendingRecoveryDrafts() throws -> [RecoveryDraft] {
        guard FileManager.default.fileExists(atPath: recoveryDirectory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: recoveryDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            .map { try JSONDecoder().decode(RecoveryDraft.self, from: Data(contentsOf: $0)) }
    }

    /// Explicit review action: restore as dirty, retaining the original disk token.
    public func restore(_ draft: RecoveryDraft) {
        let url = draft.documentURL.standardizedFileURL
        guard entries[url] == nil else { return }
        entries[url] = Entry(text: draft.text, revision: draft.revision, state: .dirty)
        publish(url)
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
                do { try persistRecovery(target, entry: entry) }
                catch { recoveryFailures[target] = DocumentSaveFailure(error: error, url: recoveryDirectory) }
            }
            publish(target)
            return disk
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            entry.state = .conflict(diskRevision: nil)
            entries[target] = entry
            do { try persistRecovery(target, entry: entry) }
            catch { recoveryFailures[target] = DocumentSaveFailure(error: error, url: recoveryDirectory) }
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
        let parent = String(url.deletingLastPathComponent().path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
        let parent = String(url.deletingLastPathComponent().path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
        entries[target] = Entry(text: latest.text, revision: loaded.revision, state: latest.text == entry.text ? .clean : .dirty)
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
        guard let state = entries[url]?.state else { return }
        for continuation in observers[url, default: [:]].values { continuation.yield(state) }
    }

    private func removeObserver(_ id: UUID, url: URL) { observers[url]?[id] = nil }
}

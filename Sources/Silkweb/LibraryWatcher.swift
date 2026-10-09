import CoreServices
import Foundation

/// FSEvents watches descendants recursively, including atomic replacements. Only
/// the coalesced callback reaches the workspace; scanning runs on a worker.
/// Silkweb's own `.silkweb/` writes (search cache, metadata) never schedule a rescan. Agent receipts under
/// `.silkweb/agent-events/` (#137) only reload the receipts, through their own debounce.
@MainActor final class LibraryWatcher {
    private var stream: FSEventStreamRef?
    private var rootPath = ""
    /// Test seam: the scheduled debounce, so tests can await it instead of sleeping.
    private(set) var pending: Task<Void, Never>?
    /// Test seam: the scheduled receipt reload.
    private(set) var pendingReceipts: Task<Void, Never>?
    /// Test seam: sees every delivered batch's paths, before filtering. Unset in the app.
    var observeEvents: (@MainActor ([String]) -> Void)?
    private let delay: Duration
    private let changed: @MainActor () async -> Void
    private let receiptsChanged: (@MainActor () async -> Void)?

    init(
        root: URL? = nil, delay: Duration = .milliseconds(300), changed: @escaping @MainActor () async -> Void,
        receiptsChanged: (@MainActor () async -> Void)? = nil
    ) {
        self.delay = delay
        self.changed = changed
        self.receiptsChanged = receiptsChanged
        guard let root else { return }
        rootPath = LibraryWatcher.canonicalRoot(root)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        stream = FSEventStreamCreate(
            nil,
            { _, info, _, paths, _, _ in
                guard let info else { return }
                let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                MainActor.assumeIsolated {
                    let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
                    watcher.observeEvents?(paths)
                    let change = LibraryWatcher.classify(paths, root: watcher.rootPath)
                    if change.library { watcher.notifyChange() }
                    if change.receipts { watcher.notifyReceiptsChange() }
                }
            }, &context, [rootPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                    | kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { stop() }
        }
    }

    /// False only when every event lies in the library's own `.silkweb` directory.
    /// No paths (dropped/coalesced events) conservatively counts as a change.
    /// Paths are compared in `eventPathForm`, so `/tmp` vs `/private/tmp` or a
    /// `/System/Volumes/Data` firmlink prefix on either side still matches.
    nonisolated static func isLibraryChange(_ paths: [String], root: String) -> Bool {
        classify(paths, root: root).library
    }

    /// `library`: some event lies outside `.silkweb`. `receipts`: some event touches `.silkweb/agent-events` or
    /// `.silkweb/agent-history` (or `.silkweb` itself, which may have been replaced). No paths (dropped/coalesced
    /// events) is both.
    nonisolated static func classify(_ paths: [String], root: String) -> (library: Bool, receipts: Bool) {
        guard !paths.isEmpty else { return (true, true) }
        let metadata = eventPathForm(root) + "/.silkweb"
        let events = metadata + "/agent-events"
        // #204: earlier versions an update saved; Info counts them.
        let history = metadata + "/agent-history"
        var library = false
        var receipts = false
        for raw in paths {
            let path = eventPathForm(raw)
            if path != metadata && !path.hasPrefix(metadata + "/") {
                library = true
            } else if path == metadata || path == events || path.hasPrefix(events + "/") || path == history
                || path.hasPrefix(history + "/")
            {
                receipts = true
            }
            if library && receipts { break }
        }
        return (library, receipts)
    }

    /// The root as FSEvents reports it, resolved once at start. `realpath` resolves
    /// every symlink but, unlike `resolvingSymlinksInPath`, keeps `/private`, which
    /// FSEvents includes in `/tmp` and `/var` event paths.
    nonisolated static func canonicalRoot(_ root: URL) -> String {
        let path = root.standardizedFileURL.path
        guard let resolved = realpath(path, nil) else { return eventPathForm(path) }
        defer { free(resolved) }
        return eventPathForm(String(cString: resolved))
    }

    /// String-only normalisation (no I/O, safe per event): drops the Data-volume
    /// firmlink prefix and a trailing slash, and spells the `/tmp`, `/var` and
    /// `/etc` symlinks as their `/private` targets.
    nonisolated static func eventPathForm(_ path: String) -> String {
        var path = path
        let data = "/System/Volumes/Data"
        if path.hasPrefix(data + "/") { path.removeFirst(data.count) }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        for link in ["/tmp", "/var", "/etc"] where path == link || path.hasPrefix(link + "/") {
            return "/private" + path
        }
        return path
    }

    func notifyChange() {
        pending?.cancel()
        let delay = delay
        let changed = changed
        pending = Task {
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                await changed()
            } catch {}
        }
    }

    func notifyReceiptsChange() {
        guard let receiptsChanged else { return }
        pendingReceipts?.cancel()
        let delay = delay
        pendingReceipts = Task {
            do {
                try await Task.sleep(for: delay)
                try Task.checkCancellation()
                await receiptsChanged()
            } catch {}
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        pendingReceipts?.cancel()
        pendingReceipts = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit {
        pending?.cancel()
        pendingReceipts?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

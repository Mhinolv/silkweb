import Foundation
import CoreServices

/// FSEvents watches descendants recursively, including atomic replacements. Only
/// the coalesced callback reaches the workspace; scanning runs on a worker.
/// Silkweb's own `.silkweb/` writes (search cache, metadata) never schedule a rescan.
@MainActor final class LibraryWatcher {
    private var stream: FSEventStreamRef?
    private var rootPath = ""
    /// Test seam: the scheduled debounce, so tests can await it instead of sleeping.
    private(set) var pending: Task<Void, Never>?
    /// Test seam: sees every delivered batch's paths, before filtering. Unset in the app.
    var observeEvents: (@MainActor ([String]) -> Void)?
    private let delay: Duration
    private let changed: @MainActor () async -> Void

    init(root: URL? = nil, delay: Duration = .milliseconds(300), changed: @escaping @MainActor () async -> Void) {
        self.delay = delay
        self.changed = changed
        guard let root else { return }
        rootPath = LibraryWatcher.canonicalRoot(root)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
            guard let info else { return }
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated {
                let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
                watcher.observeEvents?(paths)
                if LibraryWatcher.isLibraryChange(paths, root: watcher.rootPath) { watcher.notifyChange() }
            }
        }, &context, [rootPath] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes))
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
        let metadata = eventPathForm(root) + "/.silkweb"
        return paths.isEmpty || paths.contains {
            let path = eventPathForm($0)
            return path != metadata && !path.hasPrefix(metadata + "/")
        }
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
            } catch { }
        }
    }

    func stop() {
        pending?.cancel()
        pending = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    deinit {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

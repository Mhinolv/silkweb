import Foundation
import CoreServices

/// FSEvents watches descendants recursively, including atomic replacements. Only
/// the coalesced callback reaches the workspace; scanning runs on a worker.
/// Silkweb's own `.silkweb/` writes (search cache, metadata) never schedule a rescan.
@MainActor final class LibraryWatcher {
    private var stream: FSEventStreamRef?
    private var rootPath = ""
    private var pending: Task<Void, Never>?
    private let delay: Duration
    private let changed: @MainActor () async -> Void

    init(root: URL? = nil, delay: Duration = .milliseconds(300), changed: @escaping @MainActor () async -> Void) {
        self.delay = delay
        self.changed = changed
        guard let root else { return }
        rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, paths, _, _ in
            guard let info else { return }
            let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            MainActor.assumeIsolated {
                let watcher = Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue()
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
    nonisolated static func isLibraryChange(_ paths: [String], root: String) -> Bool {
        let metadata = root + "/.silkweb"
        return paths.isEmpty || paths.contains { $0 != metadata && !$0.hasPrefix(metadata + "/") }
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

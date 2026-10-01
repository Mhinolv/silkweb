import Foundation
import CoreServices

/// FSEvents watches descendants recursively, including atomic replacements. Only
/// the coalesced callback reaches the workspace; scanning runs on a worker.
@MainActor final class LibraryWatcher {
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    private let delay: Duration
    private let changed: @MainActor () async -> Void

    init(root: URL? = nil, delay: Duration = .milliseconds(300), changed: @escaping @MainActor () async -> Void) {
        self.delay = delay
        self.changed = changed
        guard let root else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated {
                Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue().notifyChange()
            }
        }, &context, [root.standardizedFileURL.resolvingSymlinksInPath().path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15,
        FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            if !FSEventStreamStart(stream) { stop() }
        }
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

import Darwin
import Foundation

/// Tells the `silkweb` helper which documents have unsaved changes in the app (#204), so an agent update
/// never overwrites them. While a document's buffer is dirty, the app's save coordinator holds a shared
/// `flock` on `.silkweb/editing/<key>.lock`; the helper probes it without waiting. The kernel drops the lock
/// when the app quits or crashes, so a stale marker never blocks updates.
///
/// Keys come from the Library-relative path in NFC and lower case, so both sides agree however a path is
/// spelled on the default case-insensitive volume (on a case-sensitive one, two names differing only in
/// case share a key, which only makes the helper more careful).
public enum DocumentEditingMarker {
    static let folder = "editing"

    static func name(for relativePath: String) -> String {
        let key = relativePath.precomposedStringWithCanonicalMapping.lowercased()
        return String(DocumentRevision(data: Data(key.utf8)).digest.prefix(32)) + ".lock"
    }

    /// Whether Silkweb holds the marker for `relativePath` right now. Never waits and never creates
    /// anything; a missing marker or folder means no unsaved changes.
    public static func isHeld(library: URL, relativePath: String) -> Bool {
        guard let root = try? AgentCreateFiles.openRoot(library) else { return false }
        defer { close(root) }
        guard let folder = try? AgentCreateFiles.metadataFolder(root, Self.folder, create: false) else {
            return false
        }
        defer { close(folder) }
        let name = name(for: relativePath)
        // The app unlinks a marker before letting it go; a lock on an unlinked file means look again.
        for _ in 0..<3 {
            let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { return false }
            defer { close(descriptor) }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 { return errno == EWOULDBLOCK }
            var info = stat()
            let unlinked = fstat(descriptor, &info) == 0 && info.st_nlink == 0
            _ = flock(descriptor, LOCK_UN)
            if !unlinked { return false }
        }
        return false
    }

    /// The app's side: one shared lock per dirty document. Not thread-safe; its owner (an actor) serializes it.
    final class Holder: @unchecked Sendable {
        let root: URL
        private var held: [String: Int32] = [:]

        init(root: URL) { self.root = root }

        deinit { for descriptor in held.values { close(descriptor) } }

        func isHolding(_ relativePath: String) -> Bool { held[Self.key(relativePath)] != nil }

        /// Best effort: a Library that can't hold the marker (read-only) simply has none.
        func hold(_ relativePath: String) {
            let key = Self.key(relativePath)
            guard held[key] == nil else { return }
            let directory = root.appendingPathComponent(".silkweb/" + DocumentEditingMarker.folder)
            if mkdir(directory.path, 0o755) != 0, errno == ENOENT {
                _ = mkdir(root.appendingPathComponent(".silkweb").path, 0o755)
                _ = mkdir(directory.path, 0o755)
            }
            let path = directory.appendingPathComponent(DocumentEditingMarker.name(for: relativePath)).path
            for _ in 0..<3 {
                let descriptor = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
                guard descriptor >= 0 else { return }
                // The helper only probes, so this waits at most for one probe.
                guard flock(descriptor, LOCK_SH) == 0 else {
                    close(descriptor)
                    return
                }
                var info = stat()
                if fstat(descriptor, &info) == 0, info.st_nlink > 0 {
                    held[key] = descriptor
                    return
                }
                // Another holder unlinked it as we opened it: use a fresh file.
                close(descriptor)
            }
        }

        /// Removes the marker when this was its only holder, then lets it go.
        func release(_ relativePath: String) {
            guard let descriptor = held.removeValue(forKey: Self.key(relativePath)) else { return }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                let path = root.appendingPathComponent(
                    ".silkweb/" + DocumentEditingMarker.folder + "/" + DocumentEditingMarker.name(for: relativePath))
                _ = unlink(path.path)
            }
            close(descriptor)
        }

        func releaseAll() {
            for descriptor in held.values { close(descriptor) }
            held = [:]
        }

        private static func key(_ relativePath: String) -> String {
            relativePath.precomposedStringWithCanonicalMapping.lowercased()
        }
    }
}

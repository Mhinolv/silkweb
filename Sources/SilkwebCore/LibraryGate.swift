import Darwin
import Foundation

/// Raised when another cooperating writer holds the gate for the whole wait. Never a conflict:
/// nothing was written and the caller's text is untouched.
public enum LibraryGateError: Error, Equatable, LocalizedError, Sendable {
    case busy(retryAfter: Int)

    public var errorDescription: String? {
        "Another Silkweb process is updating this library. Silkweb will try again."
    }
}

/// The cross-process mutation gate (#131, `docs/agent-memory.md` › Coordination). The Silkweb app and
/// the `silkweb` helper hold it for each commit that checks and then changes the Library: replacing a
/// document after its revision check, and every read-modify-write of `.silkweb/index.json`. Scans and
/// reads never wait for it.
///
/// It is an exclusive `flock` on `.silkweb/library.lock`. The kernel drops the lock when its holder
/// exits or crashes, so there's no lease timeout and no lock is ever broken. Each open file holds its
/// own lock, so two gates in one process exclude each other exactly as two processes do.
public struct LibraryGate: Sendable {
    public static let defaultTimeout: Duration = .seconds(5)

    public let root: URL
    public var lockURL: URL { root.appendingPathComponent(".silkweb/library.lock") }

    public init(root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    }

    /// Held until `release()` or deinit, and released by the kernel if the process dies first.
    public final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var descriptor: Int32
        /// The pid a previous holder recorded and never cleared: it exited without releasing. Its
        /// lock was already gone, so this is diagnostics only (the helper logs it, never a document).
        public let staleHolder: Int32?

        init(descriptor: Int32, staleHolder: Int32? = nil) {
            self.descriptor = descriptor
            self.staleHolder = staleHolder
        }

        /// Whether this lease excludes other writers. False when the Library can't hold a lock file
        /// (read-only, or a volume without `flock`), where the write itself decides.
        public var isExclusive: Bool { lock.withLock { descriptor >= 0 } }

        public func release() {
            lock.withLock {
                guard descriptor >= 0 else { return }
                _ = ftruncate(descriptor, 0)
                _ = flock(descriptor, LOCK_UN)
                close(descriptor)
                descriptor = -1
            }
        }

        deinit { release() }
    }

    /// Takes the gate without waiting; nil when another writer holds it.
    public func tryAcquire() throws -> Lease? {
        let directory = lockURL.deletingLastPathComponent()
        try LibraryMetadataStore.rejectLink(directory)
        try LibraryMetadataStore.rejectLink(lockURL)
        if mkdir(directory.path, 0o755) != 0, errno != EEXIST {
            if Self.unlockable(errno) { return Lease(descriptor: -1) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            if Self.unlockable(errno) { return Lease(descriptor: -1) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK { return nil }
            if [ENOTSUP, EOPNOTSUPP].contains(code) { return Lease(descriptor: -1) }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        // A holder clears its pid on release, so one left behind belonged to a process that died.
        var buffer = [UInt8](repeating: 0, count: 32)
        let count = pread(descriptor, &buffer, buffer.count, 0)
        let stale =
            count > 0
            ? Int32(String(decoding: buffer[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            : nil
        let pid = Array("\(getpid())\n".utf8)
        _ = ftruncate(descriptor, 0)
        _ = pwrite(descriptor, pid, pid.count, 0)
        return Lease(descriptor: descriptor, staleHolder: stale)
    }

    /// Waits on the calling thread. For short commits inside actors that are already off the main thread.
    public func acquire(timeout: Duration = defaultTimeout) throws -> Lease {
        let deadline = ContinuousClock.now + timeout
        var pause = Duration.milliseconds(2)
        while true {
            if let lease = try tryAcquire() { return lease }
            guard ContinuousClock.now < deadline else { throw LibraryGateError.busy(retryAfter: 1) }
            let components = pause.components
            var interval = timespec(
                tv_sec: Int(components.seconds), tv_nsec: Int(components.attoseconds / 1_000_000_000))
            nanosleep(&interval, nil)
            pause = min(pause * 2, .milliseconds(50))
        }
    }

    /// Waits without blocking a thread. Throws `CancellationError` if the task is cancelled; callers
    /// that must finish their commit run this in a task of its own.
    public func acquire(timeout: Duration = defaultTimeout) async throws -> Lease {
        let deadline = ContinuousClock.now + timeout
        var pause = Duration.milliseconds(2)
        while true {
            if let lease = try tryAcquire() { return lease }
            guard ContinuousClock.now < deadline else { throw LibraryGateError.busy(retryAfter: 1) }
            try await Task.sleep(for: pause)
            pause = min(pause * 2, .milliseconds(50))
        }
    }

    /// Runs `body` while holding the gate.
    public func withLease<T>(timeout: Duration = defaultTimeout, _ body: () throws -> T) throws -> T {
        let lease = try acquire(timeout: timeout)
        defer { lease.release() }
        return try body()
    }

    private static func unlockable(_ code: Int32) -> Bool {
        [EACCES, EPERM, EROFS, ENOTSUP, EOPNOTSUPP].contains(code)
    }
}

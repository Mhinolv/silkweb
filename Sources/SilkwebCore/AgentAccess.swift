import Darwin
import Foundation

/// Every headless operation the helper can be asked for (`docs/agent-memory.md` › Supported operations).
public enum AgentOperation: String, CaseIterable, Sendable {
    case capabilities, list, search, read, activity, create
    case createFolder = "create-folder"

    /// Only Read and Create grants on a qualified filesystem may run these.
    public var creates: Bool { self == .create || self == .createFolder }
}

/// Owner-set bounds for one grant. Missing or non-positive values decode to the defaults.
public struct AgentGrantLimits: Codable, Equatable, Sendable {
    public static let defaultMaxReadBytes = 1_048_576
    public static let defaultMaxResults = 200
    public static let defaultRequestsPerMinute = 120

    /// Largest document a read returns.
    public var maxReadBytes: Int
    /// Most rows a search, list or activity page returns (#134, #137).
    public var maxResults: Int
    /// Operations per rolling minute for one helper session.
    public var requestsPerMinute: Int

    public init(
        maxReadBytes: Int = defaultMaxReadBytes, maxResults: Int = defaultMaxResults,
        requestsPerMinute: Int = defaultRequestsPerMinute
    ) {
        self.maxReadBytes = maxReadBytes
        self.maxResults = maxResults
        self.requestsPerMinute = requestsPerMinute
    }

    private enum CodingKeys: String, CodingKey {
        case maxReadBytes = "max_read_bytes"
        case maxResults = "max_results"
        case requestsPerMinute = "requests_per_minute"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let positive = { (key: CodingKeys, fallback: Int) -> Int in
            (try? values.decodeIfPresent(Int.self, forKey: key)).flatMap { $0 }.flatMap { $0 > 0 ? $0 : nil }
                ?? fallback
        }
        maxReadBytes = positive(.maxReadBytes, Self.defaultMaxReadBytes)
        maxResults = positive(.maxResults, Self.defaultMaxResults)
        requestsPerMinute = positive(.requestsPerMinute, Self.defaultRequestsPerMinute)
    }
}

/// What an agent sees when the helper refuses or fails: a stable JSON `code`, an owner-readable
/// title and a sentence-case message. Refusals name the grant's scope, never the requested target,
/// and never include document text.
public struct AgentAccessError: Error, Equatable, Sendable {
    public let code: String
    public let title: String
    public let message: String

    public init(code: String, title: String, message: String) {
        self.code = code
        self.title = title
        self.message = message
    }

    static let noAccess = "No Agent Access"

    /// “That location is outside this grant’s read folders (Memory › Projects › Silkweb).”
    public static func outOfScope(_ roots: [String], kind: String = "read") -> Self {
        let scope = roots.isEmpty ? "" : " (" + roots.map(AgentMemoryContract.displayPath).joined(separator: ", ") + ")"
        return Self(
            code: "out_of_scope", title: noAccess,
            message: "That location is outside this grant’s \(kind) folders\(scope).")
    }

    public static let createNotAllowed = Self(
        code: "create_not_allowed", title: noAccess,
        message: "This grant is Read Only. Ask the owner to switch it to Read and Create.")

    /// Same code as a Read Only grant: creating is off because the Library isn't on a qualified disk.
    public static let createNotQualified = Self(
        code: "create_not_allowed", title: noAccess,
        message: "This Library isn’t on a local disk, so agents can only read it.")

    /// One message for traversal, links, special files and `.silkweb` paths, so a caller can't tell
    /// which check failed.
    public static let invalidPath = Self(
        code: "invalid_path", title: noAccess,
        message: "Paths must stay inside the Library and can’t use “..”, links or special files.")

    public static let excluded = Self(
        code: "excluded_name", title: noAccess,
        message: "Agents can create only Markdown documents, never instruction files or reserved Folders.")

    public static func grantRevoked(_ label: String) -> Self {
        Self(
            code: "grant_revoked", title: noAccess,
            message: "Agent access “\(label)” was turned off. Ask the owner to turn it back on.")
    }

    public static func rateLimited(retryAfter seconds: Int) -> Self {
        Self(
            code: "rate_limited", title: "Too Many Requests",
            message: "Too many requests. Try again in \(seconds) \(seconds == 1 ? "second" : "seconds").")
    }

    public static func tooLarge(limit: Int) -> Self {
        Self(
            code: "too_large", title: "Document Too Large",
            message: "That document is larger than this grant’s read limit ("
                + ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file) + ").")
    }

    /// Only reachable for in-scope targets: out-of-scope paths are refused before the disk is touched.
    public static let notFound = Self(
        code: "not_found", title: "Document Not Found", message: "There’s no document at that location.")

    public static let unreadable = Self(
        code: "unreadable", title: LibraryLocationError.unreadable.title,
        message: "Silkweb doesn’t have permission to read that location.")

    static func scope(_ error: AgentScopeError, in scope: AgentScope) -> Self {
        switch error {
        case .invalidProject, .invalidPath: return .invalidPath
        case .outsideRead: return .outOfScope(scope.readRoots)
        case .outsideCreate: return .outOfScope(scope.createRoots, kind: "create")
        case .excluded: return .excluded
        }
    }
}

/// `agent-grants.json`, re-read only when its stamp (inode, size, change and modification times)
/// changes, so checking for revocation before every operation costs one `stat`.
public final class AgentGrantStore: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var cache: (stamp: [Int], file: AgentGrantFile)?

    public init(url: URL) { self.url = url }

    public func load() throws -> AgentGrantFile {
        var info = stat()
        guard stat(url.path, &info) == 0 else {
            throw errno == ENOENT || errno == ENOTDIR ? missing : invalid
        }
        let stamp = [
            Int(info.st_dev), Int(info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec,
            info.st_mtimespec.tv_nsec, info.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec,
        ]
        lock.lock()
        defer { lock.unlock() }
        if let cache, cache.stamp == stamp { return cache.file }
        let file: AgentGrantFile
        do {
            file = try JSONDecoder().decode(AgentGrantFile.self, from: Data(contentsOf: url))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            throw missing
        } catch {
            throw invalid
        }
        guard file.version <= AgentGrantFile.currentVersion else {
            throw AgentAccessError(
                code: "unsupported_grants_version", title: AgentAccessError.noAccess,
                message: "The grants file was saved by a newer version of Silkweb.")
        }
        // Stamped before reading, so a replacement during the read is picked up next time.
        cache = (stamp, file)
        return file
    }

    private var missing: AgentAccessError {
        AgentAccessError(
            code: "no_grants_file", title: AgentAccessError.noAccess,
            message: "There’s no grants file at “\(url.path)”.")
    }

    private var invalid: AgentAccessError {
        AgentAccessError(
            code: "invalid_grants_file", title: AgentAccessError.noAccess,
            message: "The grants file at “\(url.path)” can’t be read.")
    }
}

/// Rolling one-minute window for a single helper session.
public struct AgentRateLimiter: Sendable {
    private var recent: [TimeInterval] = []

    public init() {}

    public mutating func admit(limit: Int, now: Date) throws {
        let time = now.timeIntervalSinceReferenceDate
        recent.removeFirst(recent.prefix { $0 <= time - 60 }.count)
        guard recent.count < limit else {
            let retry = recent.first.map { $0 + 60 - time } ?? 60
            throw AgentAccessError.rateLimited(retryAfter: max(1, Int(retry.rounded(.up))))
        }
        recent.append(time)
    }
}

/// What one authorized operation may touch. Valid for that operation only; ask again for the next.
public struct AgentAuthorization: Sendable {
    public let library: URL
    public let filesystem: AgentFilesystem
    public let grant: AgentGrant
    public let scope: AgentScope
    /// The normalized Library-relative target, when the operation names one.
    public let path: String?
}

/// One helper session (an MCP connection or a single CLI command) bound to a project. Every
/// operation calls `authorize` first: the grant file is re-checked each time, so turning access off
/// or narrowing it takes effect on the very next operation (fail closed). An operation that was
/// already authorized runs to completion; creates publish atomically (#133), so they finish whole
/// or not at all.
public final class AgentSession: @unchecked Sendable {
    public let project: String
    public let store: AgentGrantStore
    private let clientRoots: [String]?
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var limiter = AgentRateLimiter()
    private var boundLabel: String?
    private var resolved: (grant: AgentGrant, library: URL, filesystem: AgentFilesystem, scope: AgentScope)?

    /// `clientRoots` (MCP roots, Library-relative) may narrow the grant but never widen it.
    public init(
        project: String, store: AgentGrantStore, clientRoots: [String]? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.project = project
        self.store = store
        self.clientRoots = clientRoots
        self.now = now
    }

    public func authorize(_ operation: AgentOperation, path: String? = nil) throws -> AgentAuthorization {
        lock.lock()
        defer { lock.unlock() }
        let file: AgentGrantFile
        do {
            file = try store.load()
        } catch let error as AgentAccessError where error.code == "no_grants_file" && boundLabel != nil {
            throw AgentAccessError.grantRevoked(boundLabel ?? project)
        }
        guard let grant = file.grant(for: project) else {
            if let boundLabel { throw AgentAccessError.grantRevoked(boundLabel) }
            throw AgentAccessError(
                code: "no_grant", title: AgentAccessError.noAccess,
                message: "There’s no grant for the project “\(project)”.")
        }
        boundLabel = grant.displayLabel
        if grant.isRevoked { throw AgentAccessError.grantRevoked(grant.displayLabel) }
        let context = try resolve(grant)
        try limiter.admit(limit: grant.limits.requestsPerMinute, now: now())

        if operation.creates {
            guard grant.access == .readCreate else { throw AgentAccessError.createNotAllowed }
            guard context.filesystem == .qualified else { throw AgentAccessError.createNotQualified }
        }
        var normalized: String?
        if let path {
            do {
                switch operation {
                case .create: normalized = try context.scope.checkCreate(path)
                case .createFolder: normalized = try context.scope.checkCreateFolder(path)
                default: normalized = try context.scope.checkRead(path)
                }
            } catch let error as AgentScopeError {
                throw AgentAccessError.scope(error, in: context.scope)
            }
        }
        return AgentAuthorization(
            library: context.library, filesystem: context.filesystem, grant: grant, scope: context.scope,
            path: normalized)
    }

    /// Library and filesystem are resolved once per grant revision, not per call.
    private func resolve(_ grant: AgentGrant) throws -> (
        grant: AgentGrant, library: URL, filesystem: AgentFilesystem, scope: AgentScope
    ) {
        if let resolved, resolved.grant == grant { return resolved }
        resolved = nil
        let library: URL
        do {
            // Same restore path the app uses; the refreshed location is ignored (the helper never
            // writes the grants file).
            guard let restored = try LibraryLocationRestore.restore(grant.library) else {
                throw LibraryLocationError.notFound
            }
            library = restored.url
        } catch let error as LibraryLocationError {
            let name = grant.library.path.map { ($0 as NSString).lastPathComponent } ?? "Library"
            throw AgentAccessError(
                code: error == .notFound ? "library_not_found" : "library_unreadable", title: error.title,
                message: error == .notFound
                    ? "The Library “\(name)” can’t be found." : "The Library “\(name)” can’t be read.")
        }
        let filesystem = AgentFilesystem.probe(library)
        // Unknown case sensitivity is treated as sensitive: the stricter containment check.
        let caseSensitive =
            (try? library.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? true
        var scope: AgentScope
        do {
            scope = try AgentScope(grant: grant, createAllowed: filesystem == .qualified, caseSensitive: caseSensitive)
        } catch let error as AgentScopeError {
            throw AgentAccessError(code: "invalid_grant", title: AgentAccessError.noAccess, message: error.message)
        }
        if let clientRoots { scope = scope.narrowed(to: clientRoots) }
        resolved = (grant, library, filesystem, scope)
        return (grant, library, filesystem, scope)
    }
}

/// Descriptor-based file access below the Library root. Each component is opened with
/// `O_NOFOLLOW` relative to its parent's descriptor, so a link or a folder swapped for a link
/// between the scope check and the use can't redirect the operation outside the Library.
public enum AgentSecureFiles {
    public struct Document: Equatable, Sendable {
        public let path: String
        public let size: Int
        public let modified: Date
    }

    /// Opens a Folder (`""` is the Library itself). The caller closes the returned descriptor.
    /// The Library root may itself be reached through a link the owner chose; nothing below it may.
    public static func openFolder(library: URL, path: String) throws -> Int32 {
        var descriptor = open(library.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(errno) }
        let components = path.isEmpty ? [] : try validated(path)
        for component in components {
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(descriptor)
            guard next >= 0 else { throw failure(code) }
            descriptor = next
        }
        return descriptor
    }

    /// One regular file's bytes, at most `maxBytes`. FIFOs, devices, sockets, Folders and links
    /// are refused with the generic `invalid_path`.
    public static func readDocument(library: URL, path: String, maxBytes: Int) throws -> Data {
        let components = try validated(path)
        let folder = try openFolder(library: library, path: components.dropLast().joined(separator: "/"))
        defer { close(folder) }
        // O_NONBLOCK keeps a FIFO from blocking the open; fstat then rejects it.
        let descriptor = openat(
            folder, components[components.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw failure(errno) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw AgentAccessError.invalidPath
        }
        guard info.st_size <= maxBytes else { throw AgentAccessError.tooLarge(limit: maxBytes) }
        let data = (try? handle.read(upToCount: maxBytes + 1)) ?? nil
        guard let data else { throw AgentAccessError.unreadable }
        guard data.count <= maxBytes else { throw AgentAccessError.tooLarge(limit: maxBytes) }
        return data
    }

    /// Markdown documents below `root`, sorted by path. Hidden items, links and special files are
    /// skipped; a missing root is empty.
    public static func documents(library: URL, under root: String) throws -> [Document] {
        let descriptor: Int32
        do {
            descriptor = try openFolder(library: library, path: root)
        } catch let error as AgentAccessError where error == .notFound {
            return []
        }
        var documents: [Document] = []
        walk(descriptor, prefix: root, into: &documents)
        return documents.sorted { $0.path < $1.path }
    }

    /// Takes ownership of `descriptor`.
    private static func walk(_ descriptor: Int32, prefix: String, into documents: inout [Document]) {
        guard let folder = fdopendir(descriptor) else {
            close(descriptor)
            return
        }
        defer { closedir(folder) }
        let parent = dirfd(folder)
        while let entry = readdir(folder) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            var info = stat()
            guard !name.hasPrefix("."), fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if child >= 0 { walk(child, prefix: path, into: &documents) }
            case S_IFREG where (name as NSString).pathExtension.lowercased() == "md":
                let modified = info.st_mtimespec
                documents.append(
                    Document(
                        path: path, size: Int(info.st_size),
                        modified: Date(
                            timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(modified.tv_nsec) / 1e9)
                    ))
            default:
                continue
            }
        }
    }

    private static func validated(_ path: String) throws -> [String] {
        guard let normalized = try? AgentScope.normalize(path) else { throw AgentAccessError.invalidPath }
        return normalized.split(separator: "/").map(String.init)
    }

    private static func failure(_ code: Int32) -> AgentAccessError {
        switch code {
        case ENOENT: return .notFound
        case EACCES, EPERM: return .unreadable
        default: return .invalidPath // ELOOP (a link), ENOTDIR (a file mid-path) and the rest
        }
    }
}

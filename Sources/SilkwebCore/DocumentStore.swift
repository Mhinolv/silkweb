import CryptoKit
import Darwin
import Foundation

/// Content token, independent of timestamps and stable across launches.
public struct DocumentRevision: Codable, Equatable, Sendable {
    public let digest: String

    init(data: Data) {
        digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct LoadedDocument: Sendable {
    public let text: String
    public let revision: DocumentRevision
}

/// Injectable synchronous operations. Implementations must leave the destination
/// intact when staging or replacement throws, and publish replacement atomically.
public protocol DocumentFileSystem: Sendable {
    func read(_ url: URL) throws -> Data
    func stage(_ data: Data, at url: URL) throws
    func replace(_ destination: URL, with staging: URL) throws
    func remove(_ url: URL) throws
}

public struct DiskDocumentFileSystem: DocumentFileSystem {
    public init() {}
    public func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    public func stage(_ data: Data, at url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
    }
    public func replace(_ destination: URL, with staging: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        var preserved: [FileAttributeKey: Any] = [:]
        if let permissions = attributes[.posixPermissions] { preserved[.posixPermissions] = permissions }
        if let created = attributes[.creationDate] { preserved[.creationDate] = created }
        try FileManager.default.setAttributes(preserved, ofItemAtPath: staging.path)
        guard rename(staging.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

public struct DocumentStore: Sendable {
    private let fileSystem: any DocumentFileSystem
    private let root: URL?
    /// The Library's cross-process gate; nil for standalone documents outside a library.
    public let gate: LibraryGate?
    let gateTimeout: Duration

    public init(
        fileSystem: any DocumentFileSystem = DiskDocumentFileSystem(), root: URL? = nil,
        gateTimeout: Duration = LibraryGate.defaultTimeout
    ) {
        self.root = root?.standardizedFileURL.resolvingSymlinksInPath()
        self.fileSystem = fileSystem
        gate = self.root.map(LibraryGate.init(root:))
        self.gateTimeout = gateTimeout
    }

    public func load(_ url: URL) throws -> LoadedDocument {
        try validate(url)
        let data = try fileSystem.read(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return LoadedDocument(text: text, revision: DocumentRevision(data: data))
    }

    /// Only existing Markdown documents are saved here; creation belongs to LibraryMutations.
    /// The revision check and the replacement are one commit inside the Library's gate, so a
    /// cooperating writer can't publish between them (#131).
    public func save(_ text: String, to url: URL, expectedRevision: DocumentRevision) throws -> DocumentRevision {
        try validate(url)
        let lease = try gate?.acquire(timeout: gateTimeout)
        defer { lease?.release() }
        return try saveHoldingGate(text, to: url, expectedRevision: expectedRevision)
    }

    /// For callers that already hold this store's gate (or whose store has none).
    func saveHoldingGate(_ text: String, to url: URL, expectedRevision: DocumentRevision) throws -> DocumentRevision {
        try validate(url)
        let staging = url.deletingLastPathComponent().appendingPathComponent(".silkweb-save-\(UUID().uuidString)")
        defer { try? fileSystem.remove(staging) }
        let data = Data(text.utf8)
        try fileSystem.stage(data, at: staging)
        // Check after staging to catch changes that occurred while writing the draft.
        let diskRevision = try load(url).revision
        guard diskRevision == expectedRevision else { throw DocumentStoreError.conflict(diskRevision) }
        try fileSystem.replace(url, with: staging)
        return DocumentRevision(data: data)
    }

    private func validate(_ url: URL) throws {
        guard url.isFileURL, ["md", "markdown"].contains(url.pathExtension.lowercased()) else {
            throw LibraryError.invalidRelativePath
        }
        let canonical = url.standardizedFileURL
        if let root {
            try LibraryMetadataStore.rejectLink(root)
            guard canonical.path.hasPrefix(root.path + "/") else { throw LibraryError.invalidRelativePath }
        }
        // With a library root, inspect only its descendants. Standalone callers
        // accept ancestor aliases, but never a linked document itself.
        var ancestor = canonical
        repeat {
            try LibraryMetadataStore.rejectLink(ancestor)
            ancestor.deleteLastPathComponent()
        } while root != nil && ancestor != root && ancestor.path != "/"
    }
}

public enum DocumentStoreError: Error, Equatable, Sendable {
    case conflict(DocumentRevision)
}

import Foundation
import CryptoKit
import Darwin

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
        if let permissions = attributes[.posixPermissions] {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: staging.path)
        }
        guard rename(staging.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    public func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

public struct DocumentStore: Sendable {
    private let fileSystem: any DocumentFileSystem

    public init(fileSystem: any DocumentFileSystem = DiskDocumentFileSystem()) {
        self.fileSystem = fileSystem
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
    public func save(_ text: String, to url: URL, expectedRevision: DocumentRevision) throws -> DocumentRevision {
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
        var ancestor = url.standardizedFileURL
        while ancestor.path != "/" {
            // macOS exposes its system temporary locations through these aliases.
            // Library-provided symlinks below them are still rejected.
            if ["/var", "/tmp"].contains(ancestor.path) { break }
            try LibraryMetadataStore.rejectLink(ancestor)
            ancestor.deleteLastPathComponent()
        }
    }
}

public enum DocumentStoreError: Error, Equatable, Sendable {
    case conflict(DocumentRevision)
}

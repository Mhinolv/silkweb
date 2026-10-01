import Foundation

public struct LibraryFolder: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let parentID: UUID?
    /// Empty for the library root; otherwise relative to that root.
    public let relativePath: String
    public let name: String
    /// Scan-time permission state; never persisted because access can change between scans.
    public internal(set) var isUnreadable = false
}

public struct LibraryDocument: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let folderID: UUID
    public let relativePath: String
    public let name: String
    public var created: Date? = nil
    public var modified: Date? = nil
}

public struct LibrarySnapshot: Sendable {
    public let rootURL: URL
    /// Includes the root and empty folders. Parents precede their children.
    public let folders: [LibraryFolder]
    public let documents: [LibraryDocument]
    public let presentation: LibraryPresentation
    public let metadata: LibraryMetadata
    public let recoveredMetadataURL: URL?
    public let isReadOnly: Bool
}

public enum LibraryError: Error, Equatable {
    case invalidRoot
    case symbolicLink(URL)
    case invalidRelativePath
    case unsupportedMetadataVersion(Int)
}

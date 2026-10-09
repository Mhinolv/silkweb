import Foundation

public struct LibraryFolder: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let parentID: UUID?
    /// Empty for the library root; otherwise relative to that root.
    public let relativePath: String
    public let name: String
    /// Transient filesystem identity used only for live Finder reconciliation.
    public internal(set) var fileIdentity: String? = nil
    /// Scan-time permission state; never persisted because access can change between scans.
    public internal(set) var isUnreadable = false
}

public struct LibraryDocument: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let folderID: UUID
    public let relativePath: String
    public let name: String
    /// Transient filesystem identity used only for live Finder reconciliation.
    public internal(set) var fileIdentity: String? = nil
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
    /// The index existed but couldn't be read, so tags and IDs were rebuilt (#107). With no
    /// `recoveredMetadataURL`, no copy could be set aside.
    public internal(set) var metadataWasReset = false

    /// The scanned document a link's relative path names (#151), by the shared link rule (#176): an exact spelling
    /// wins; on a case-insensitive volume a single case alias resolves to the on-disk spelling. Several matches
    /// with no exact spelling are ambiguous and name no document.
    public func document(linkedAt path: String, caseSensitive: Bool? = nil) -> LibraryDocument? {
        let key = MarkdownLinkResolver.fold(path)
        var equivalent: [LibraryDocument] = []
        var folded: [LibraryDocument] = []
        for document in documents where MarkdownLinkResolver.fold(document.relativePath) == key {
            folded.append(document)
            if document.relativePath == path { equivalent.append(document) }
        }
        let match = MarkdownLinkResolver.match(
            path, equivalent: equivalent.map(\.relativePath), folded: folded.map(\.relativePath),
            caseSensitive: caseSensitive ?? self.caseSensitive)
        guard case .item(let spelling) = match else { return nil }
        return folded.first { $0.relativePath.utf8.elementsEqual(spelling.utf8) }
    }

    /// Whether the library volume distinguishes letter case; assumed when it can't be read.
    public var caseSensitive: Bool {
        (try? rootURL.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames != false
    }
}

public enum LibraryError: Error, Equatable {
    case invalidRoot
    case symbolicLink(URL)
    case invalidRelativePath
    case unsupportedMetadataVersion(Int)
}

/// Plain messages for Can’t Open Library (#107); never a format number or Cocoa text.
extension LibraryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRoot: "This folder can’t be used as a library."
        case .symbolicLink(let url):
            "“\(url.lastPathComponent)” is a symbolic link. Silkweb doesn’t open libraries through links."
        case .invalidRelativePath: "That location is outside the library."
        case .unsupportedMetadataVersion:
            "This library was last used with a newer version of Silkweb. Update Silkweb to open it. Nothing in the library was changed."
        }
    }
}

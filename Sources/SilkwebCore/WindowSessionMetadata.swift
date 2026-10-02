import Foundation

/// Rebuildable window state, separate from the older library navigation format.
public struct WindowSessionMetadata: Codable, Equatable, Sendable {
    public var formatVersion = 1
    public var tabs: [DocumentTabMetadata] = []
    public var activeDocumentID: UUID?
    public var selectedFolderID: UUID?
    public var selectedFolder: String? = ""
    public var viewMode = "editor"

    public init() {}
    private enum CodingKeys: String, CodingKey {
        case formatVersion, tabs, activeDocumentID, selectedFolderID, selectedFolder, viewMode
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? values.decodeIfPresent(Int.self, forKey: .formatVersion)) ?? 1
        guard formatVersion == 1 else { throw LibraryError.unsupportedMetadataVersion(formatVersion) }
        if var entries = try? values.nestedUnkeyedContainer(forKey: .tabs) {
            while !entries.isAtEnd {
                // Advance before decoding: one invalid value must not discard later tabs.
                let entry = try entries.superDecoder()
                if let tab = try? DocumentTabMetadata(from: entry) { tabs.append(tab) }
            }
        }
        activeDocumentID = try? values.decodeIfPresent(UUID.self, forKey: .activeDocumentID)
        if !tabs.contains(where: { $0.documentID == activeDocumentID }) {
            activeDocumentID = tabs.first?.documentID
        }
        selectedFolderID = try? values.decodeIfPresent(UUID.self, forKey: .selectedFolderID)
        selectedFolder = values.contains(.selectedFolder) ? (try? values.decodeIfPresent(String.self, forKey: .selectedFolder)) : ""
        viewMode = (try? values.decodeIfPresent(String.self, forKey: .viewMode)) ?? "editor"
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(formatVersion, forKey: .formatVersion)
        try values.encode(tabs, forKey: .tabs)
        try values.encodeIfPresent(activeDocumentID, forKey: .activeDocumentID)
        try values.encodeIfPresent(selectedFolderID, forKey: .selectedFolderID)
        try values.encode(selectedFolder, forKey: .selectedFolder)
        try values.encode(viewMode, forKey: .viewMode)
    }

    /// Resolve IDs before paths: a moved file must not bind to a replacement at its old path.
    public func resolving(in snapshot: LibrarySnapshot) -> Self {
        var result = self
        let documents = Dictionary(uniqueKeysWithValues: snapshot.documents.map { ($0.id, $0) })
        var seen: Set<UUID> = []
        var hasPreview = false
        result.tabs = tabs.compactMap { tab in
            guard let document = documents[tab.documentID], seen.insert(document.id).inserted else { return nil }
            var tab = tab
            tab.relativePath = document.relativePath
            if tab.isPreview {
                if hasPreview { tab.isPreview = false }
                hasPreview = true
            }
            return tab
        }
        if !result.tabs.contains(where: { $0.documentID == activeDocumentID }) {
            result.activeDocumentID = result.tabs.first?.documentID
        }
        if let id = selectedFolderID {
            result.selectedFolder = snapshot.folders.first { $0.id == id }?.relativePath ?? ""
        } else if let path = selectedFolder, !snapshot.folders.contains(where: { $0.relativePath == path }) {
            result.selectedFolder = ""
        }
        if !["editor", "split", "preview"].contains(viewMode) { result.viewMode = "editor" }
        return result
    }

    private static func file(root: URL) throws -> URL {
        try LibraryMetadataStore.rejectLink(root)
        let file = root.appendingPathComponent(".silkweb/window-session.json")
        try LibraryMetadataStore.rejectLink(file.deletingLastPathComponent())
        try LibraryMetadataStore.rejectLink(file)
        return file
    }
    public static func load(root: URL) async throws -> Self? {
        try await Task.detached {
            let file = try file(root: root)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        }.value
    }
    public func save(root: URL) async throws {
        try await Task.detached {
            let file = try Self.file(root: root)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: file, options: .atomic)
        }.value
    }
}

public struct DocumentTabMetadata: Codable, Equatable, Sendable {
    public var documentID: UUID
    public var relativePath: String
    public var isPreview: Bool
    public var selectionLocation: Int = 0
    public var selectionLength: Int = 0
    public var scrollY: Double = 0

    public init(documentID: UUID, relativePath: String, isPreview: Bool) {
        self.documentID = documentID
        self.relativePath = relativePath
        self.isPreview = isPreview
    }
    private enum CodingKeys: String, CodingKey {
        case documentID, relativePath, isPreview, selectionLocation, selectionLength, scrollY
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        documentID = try values.decode(UUID.self, forKey: .documentID)
        relativePath = try values.decodeIfPresent(String.self, forKey: .relativePath) ?? ""
        isPreview = try values.decodeIfPresent(Bool.self, forKey: .isPreview) ?? false
        selectionLocation = max(0, try values.decodeIfPresent(Int.self, forKey: .selectionLocation) ?? 0)
        selectionLength = max(0, try values.decodeIfPresent(Int.self, forKey: .selectionLength) ?? 0)
        let offset = try values.decodeIfPresent(Double.self, forKey: .scrollY) ?? 0
        scrollY = offset.isFinite ? max(0, offset) : 0
    }
}

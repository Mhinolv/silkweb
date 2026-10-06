import Foundation

/// Paths keep navigation usable even when a read-only library cannot save its identity index.
public struct LibrarySession: Codable, Equatable, Sendable {
    public var formatVersion = 3
    /// Folder UUIDs survive moves/renames; virtual collections have separate namespaced keys.
    public var listPreferences: [String: LibraryListPreference] = [:]
    public var selectedTagID: UUID?
    public var selectedFolder: String? = ""
    public var selectedDocuments: Set<String> = []
    public var expandedFolders: Set<String> = [""]

    public init() {}

    public func applying(_ changes: LibraryChangeSet) -> LibrarySession {
        var result = self
        result.selectedFolder = selectedFolder.map { changes.remapping($0) }
        result.selectedDocuments = Set(selectedDocuments.map { changes.remapping($0) })
        result.expandedFolders = Set(expandedFolders.map { changes.remapping($0) })
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, selectedFolder, selectedDocuments, expandedFolders, listPreferences, selectedTagID
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard (1...3).contains(version) else { throw LibraryError.unsupportedMetadataVersion(version) }
        formatVersion = 3
        selectedTagID = try values.decodeIfPresent(UUID.self, forKey: .selectedTagID)
        listPreferences =
            try values.decodeIfPresent([String: LibraryListPreference].self, forKey: .listPreferences) ?? [:]
        selectedFolder =
            values.contains(.selectedFolder) ? try values.decodeIfPresent(String.self, forKey: .selectedFolder) : ""
        selectedDocuments = try values.decodeIfPresent(Set<String>.self, forKey: .selectedDocuments) ?? []
        expandedFolders = try values.decodeIfPresent(Set<String>.self, forKey: .expandedFolders) ?? [""]
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(3, forKey: .formatVersion)
        try values.encodeIfPresent(selectedTagID, forKey: .selectedTagID)
        try values.encode(listPreferences, forKey: .listPreferences)
        try values.encode(selectedFolder, forKey: .selectedFolder)
        try values.encode(selectedDocuments, forKey: .selectedDocuments)
        try values.encode(expandedFolders, forKey: .expandedFolders)
    }

    public func pruningPreferences(folderIDs: Set<UUID>, tagIDs: Set<UUID>) -> LibrarySession {
        var result = self
        let valid = Set(folderIDs.map { "folder:" + $0.uuidString }).union(tagIDs.map { "tag:" + $0.uuidString }).union(
            ["all"])
        result.listPreferences = listPreferences.filter { valid.contains($0.key) }
        if let id = selectedTagID, !tagIDs.contains(id) { result.selectedTagID = nil }
        return result
    }

    public static func load(root: URL) async throws -> LibrarySession {
        try await Task.detached {
            try LibraryMetadataStore.rejectLink(root)
            let file = root.appendingPathComponent(".silkweb/session.json")
            try LibraryMetadataStore.rejectLink(file.deletingLastPathComponent())
            try LibraryMetadataStore.rejectLink(file)
            guard FileManager.default.fileExists(atPath: file.path) else { return LibrarySession() }
            let session = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            guard (1...3).contains(session.formatVersion) else {
                throw LibraryError.unsupportedMetadataVersion(session.formatVersion)
            }
            return session
        }.value
    }

    public func save(root: URL) async throws {
        try await Task.detached {
            try LibraryMetadataStore.rejectLink(root)
            let file = root.appendingPathComponent(".silkweb/session.json")
            try LibraryMetadataStore.rejectLink(file.deletingLastPathComponent())
            try LibraryMetadataStore.rejectLink(file)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: file, options: .atomic)
        }.value
    }
}

public struct DocumentSummary: Sendable {
    public let modified: Date?
    public let firstLine: String
    /// Up to ≈240 characters of body text for the two-line list excerpt (silkweb-1.64).
    public let excerpt: String

    public static func load(document: LibraryDocument, root: URL) async -> DocumentSummary {
        await Task.detached(priority: .utility) {
            let url = root.appendingPathComponent(document.relativePath)
            // Bound IO per visible row; never read every body while scanning a large library.
            do {
                try LibraryMetadataStore.rejectLink(root)
                var ancestor = root
                for component in document.relativePath.split(separator: "/") {
                    guard component != ".", component != ".." else { throw LibraryError.invalidRelativePath }
                    ancestor.appendPathComponent(String(component))
                    try LibraryMetadataStore.rejectLink(ancestor)
                }
                let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var data = try handle.read(upToCount: 4096) ?? Data()
                // A bounded read can end inside a UTF-8 scalar. Drop only that incomplete tail.
                for _ in 0..<3 where String(data: data, encoding: .utf8) == nil && !data.isEmpty {
                    data.removeLast()
                }
                let title = URL(fileURLWithPath: document.name).deletingPathExtension().lastPathComponent
                let text = String(decoding: data, as: UTF8.self)
                return DocumentSummary(
                    modified: date, firstLine: DocumentRowPresentation.snippet(text, title: title),
                    excerpt: DocumentRowPresentation.excerpt(text, title: title))
            } catch {
                return DocumentSummary(modified: nil, firstLine: "No additional text", excerpt: "No additional text")
            }
        }.value
    }
}

extension LibraryChangeSet {
    /// Nested changes (e.g. an import renaming a folder and its child) use the most specific match.
    public func remapping(_ path: String) -> String {
        var best: LibraryPathChange?
        for change in changes {
            guard let old = change.oldPath, old.count > (best?.oldPath?.count ?? -1) else { continue }
            if path == old || (change.isFolder && path.hasPrefix(old + "/")) { best = change }
        }
        guard let best, let old = best.oldPath else { return path }
        return best.newPath + path.dropFirst(old.count)
    }
}

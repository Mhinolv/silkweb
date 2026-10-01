import Foundation

/// Paths keep navigation usable even when a read-only library cannot save its identity index.
public struct LibrarySession: Codable, Equatable, Sendable {
    public var formatVersion = 1
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
        case formatVersion, selectedFolder, selectedDocuments, expandedFolders
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        selectedFolder = values.contains(.selectedFolder) ? try values.decodeIfPresent(String.self, forKey: .selectedFolder) : ""
        selectedDocuments = try values.decodeIfPresent(Set<String>.self, forKey: .selectedDocuments) ?? []
        expandedFolders = try values.decodeIfPresent(Set<String>.self, forKey: .expandedFolders) ?? [""]
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(formatVersion, forKey: .formatVersion)
        try values.encode(selectedFolder, forKey: .selectedFolder)
        try values.encode(selectedDocuments, forKey: .selectedDocuments)
        try values.encode(expandedFolders, forKey: .expandedFolders)
    }

    public static func load(root: URL) async throws -> LibrarySession {
        try await Task.detached {
            try LibraryMetadataStore.rejectLink(root)
            let file = root.appendingPathComponent(".silkweb/session.json")
            try LibraryMetadataStore.rejectLink(file.deletingLastPathComponent())
            try LibraryMetadataStore.rejectLink(file)
            guard FileManager.default.fileExists(atPath: file.path) else { return LibrarySession() }
            let session = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            guard session.formatVersion == 1 else {
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
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: file, options: .atomic)
        }.value
    }
}

public struct DocumentSummary: Sendable {
    public let modified: Date?
    public let firstLine: String

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
                let line = DocumentRowPresentation.snippet(String(decoding: data, as: UTF8.self), title: title)
                return DocumentSummary(modified: date, firstLine: line)
            } catch {
                return DocumentSummary(modified: nil, firstLine: "No additional text")
            }
        }.value
    }
}

extension LibraryChangeSet {
    public func remapping(_ path: String) -> String {
        for change in changes {
            guard let old = change.oldPath else { continue }
            if path == old || (change.isFolder && path.hasPrefix(old + "/")) {
                return change.newPath + path.dropFirst(old.count)
            }
        }
        return path
    }
}

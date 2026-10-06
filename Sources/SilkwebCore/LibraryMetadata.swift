import Foundation

/// Rebuildable identity index. Markdown bodies are never stored here.
public struct LibraryMetadata: Codable, Equatable, Sendable {
    public static let currentVersion = 3
    public var formatVersion: Int
    public var tags: [LibraryTag] = []
    /// Most recently applied first; IDs keep history stable through renames.
    public var tagRecency: [UUID] = []
    public var tagsByDocument: [String: Set<UUID>] = [:]
    public var IDsByPath: [String: UUID]

    public init(IDsByPath: [String: UUID] = [:]) {
        formatVersion = Self.currentVersion
        self.IDsByPath = IDsByPath
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, IDsByPath, tags, tagsByDocument, tagRecency }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        // Retain unsupported versions so the store refuses to overwrite them.
        formatVersion = (1...Self.currentVersion).contains(version) ? Self.currentVersion : version
        tags = try values.decodeIfPresent([LibraryTag].self, forKey: .tags) ?? []
        tagsByDocument = try values.decodeIfPresent([String: Set<UUID>].self, forKey: .tagsByDocument) ?? [:]
        tagRecency = (try? values.decode([UUID].self, forKey: .tagRecency)) ?? []
        IDsByPath = try values.decodeIfPresent([String: UUID].self, forKey: .IDsByPath) ?? [:]
    }
}

enum LibraryMetadataStore {
    static func locations(root: URL) throws -> (directory: URL, file: URL) {
        let directory = root.appendingPathComponent(".silkweb", isDirectory: true)
        let file = directory.appendingPathComponent("index.json")
        try rejectLink(directory)
        try rejectLink(file)
        return (directory, file)
    }

    static func rejectLink(_ url: URL) throws {
        // attributesOfItem uses lstat, including for dangling symlinks.
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
        {
            return
        }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw LibraryError.symbolicLink(url)
        }
    }

    static func load(root: URL) throws -> (LibraryMetadata, URL?) {
        let (_, file) = try locations(root: root)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError
        {
            return (LibraryMetadata(), nil)
        }
        let metadata: LibraryMetadata
        do {
            metadata = try JSONDecoder().decode(LibraryMetadata.self, from: data)
        } catch {
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent("index.corrupt-\(UUID().uuidString).json")
            guard FileManager.default.isWritableFile(atPath: file.deletingLastPathComponent().path) else {
                return (LibraryMetadata(), nil)
            }
            try FileManager.default.moveItem(at: file, to: backup)
            return (LibraryMetadata(), backup)
        }
        // Never overwrite a newer format this build cannot understand.
        guard metadata.formatVersion <= LibraryMetadata.currentVersion,
            metadata.formatVersion >= 1
        else {
            throw LibraryError.unsupportedMetadataVersion(metadata.formatVersion)
        }
        return (metadata, nil)
    }

    static func save(_ metadata: LibraryMetadata, root: URL) throws {
        let (directory, file) = try locations(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: file, options: .atomic)
    }
}

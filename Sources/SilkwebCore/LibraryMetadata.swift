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
        // One bad entry drops only that entry (#107); a field of the wrong shape still fails the whole file.
        tags = try values.decodeIfPresent([Lossy<LibraryTag>].self, forKey: .tags)?.compactMap(\.value) ?? []
        tagsByDocument =
            try values.decodeIfPresent([String: Lossy<[Lossy<UUID>]>].self, forKey: .tagsByDocument)?
            .compactMapValues { $0.value.map { Set($0.compactMap(\.value)) } } ?? [:]
        tagRecency = (try? values.decode([Lossy<UUID>].self, forKey: .tagRecency))?.compactMap(\.value) ?? []
        IDsByPath =
            try values.decodeIfPresent([String: Lossy<UUID>].self, forKey: .IDsByPath)?.compactMapValues(\.value)
            ?? [:]
    }
}

/// Decodes one collection entry, or `nil` when that entry alone is invalid.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Value.self) }
}

/// What `LibraryMetadataStore` read. `wasReset`: an existing index couldn't be decoded and was replaced by empty
/// metadata; `recoveredURL` names the set-aside copy when the folder allowed one.
struct LoadedLibraryMetadata {
    var metadata: LibraryMetadata
    var recoveredURL: URL? = nil
    var wasReset = false
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
        let loaded = try loadReportingReset(root: root)
        return (loaded.metadata, loaded.recoveredURL)
    }

    /// `repair: false` is the headless read path (#131): an undecodable index reads as empty metadata
    /// with `wasReset` set, and stays exactly where it is. Recovery belongs to the app.
    static func loadReportingReset(root: URL, repair: Bool = true) throws -> LoadedLibraryMetadata {
        let (_, file) = try locations(root: root)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileReadNoSuchFileError
        {
            return LoadedLibraryMetadata(metadata: LibraryMetadata())
        }
        let metadata: LibraryMetadata
        do {
            metadata = try JSONDecoder().decode(LibraryMetadata.self, from: data)
        } catch {
            let backup = file.deletingLastPathComponent()
                .appendingPathComponent("index.corrupt-\(UUID().uuidString).json")
            guard repair, FileManager.default.isWritableFile(atPath: file.deletingLastPathComponent().path) else {
                return LoadedLibraryMetadata(metadata: LibraryMetadata(), wasReset: true)
            }
            try FileManager.default.moveItem(at: file, to: backup)
            return LoadedLibraryMetadata(metadata: LibraryMetadata(), recoveredURL: backup, wasReset: true)
        }
        // Never overwrite a newer format this build cannot understand.
        guard metadata.formatVersion <= LibraryMetadata.currentVersion,
            metadata.formatVersion >= 1
        else {
            throw LibraryError.unsupportedMetadataVersion(metadata.formatVersion)
        }
        return LoadedLibraryMetadata(metadata: metadata)
    }

    static func save(_ metadata: LibraryMetadata, root: URL) throws {
        let (directory, file) = try locations(root: root)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(metadata).write(to: file, options: .atomic)
    }
}

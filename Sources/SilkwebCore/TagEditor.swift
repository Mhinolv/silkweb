import Foundation

public struct LibraryTag: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

/// Sidecar-only editing rules, shared by the token field and context menus.
public enum TagEditor {
    public static func normalize(_ input: String) -> String? {
        let name = input.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !name.isEmpty, name.count <= 64, !name.contains(",") else { return nil }
        return name
    }
    public static func existing(_ name: String, in tags: [LibraryTag]) -> LibraryTag? {
        tags.first { $0.name.compare(name, options: [.caseInsensitive]) == .orderedSame }
    }
    public static func commonTags(documents: Set<UUID>, metadata: LibraryMetadata) -> Set<UUID> {
        guard let first = documents.first else { return [] }
        return documents.dropFirst().reduce(metadata.tagsByDocument[first.uuidString] ?? []) {
            $0.intersection(metadata.tagsByDocument[$1.uuidString] ?? [])
        }
    }
    /// Changes only the common tokens: non-common tags on a multi-selection remain intact.
    public static func edit(_ names: [String], documents: Set<UUID>, metadata: LibraryMetadata) -> LibraryMetadata {
        guard !documents.isEmpty else { return metadata }
        var result = metadata
        let old = commonTags(documents: documents, metadata: metadata)
        var desired = Set<UUID>()
        var orderedIDs: [UUID] = []
        for input in names {
            guard let name = normalize(input) else { continue }
            let tag = existing(name, in: result.tags) ?? LibraryTag(name: name)
            if !result.tags.contains(where: { $0.id == tag.id }) { result.tags.append(tag) }
            if desired.insert(tag.id).inserted { orderedIDs.append(tag.id) }
        }
        let applied = desired.subtracting(old)
        // Preserve input order for deterministic multi-tag commits. Only new applications count.
        let appliedIDs = orderedIDs.filter { applied.contains($0) }
        result.tagRecency = appliedIDs + result.tagRecency.filter { !applied.contains($0) }
        for id in documents {
            var tags = result.tagsByDocument[id.uuidString] ?? []
            tags.subtract(old.subtracting(desired)); tags.formUnion(desired)
            result.tagsByDocument[id.uuidString] = tags
        }
        return pruning(result)
    }
    public static func rename(_ id: UUID, to input: String, metadata: LibraryMetadata) -> LibraryMetadata {
        guard let name = normalize(input), let index = metadata.tags.firstIndex(where: { $0.id == id }) else { return metadata }
        var result = metadata
        if let existing = existing(name, in: result.tags), existing.id != id {
            for key in result.tagsByDocument.keys where result.tagsByDocument[key]?.contains(id) == true {
                result.tagsByDocument[key]?.remove(id); result.tagsByDocument[key]?.insert(existing.id)
            }
            result.tagRecency = result.tagRecency.map { $0 == id ? existing.id : $0 }
            result.tags.remove(at: index)
        } else { result.tags[index].name = name }
        return pruning(result)
    }
    public static func delete(_ id: UUID, metadata: LibraryMetadata) -> LibraryMetadata {
        var result = metadata
        for key in result.tagsByDocument.keys { result.tagsByDocument[key]?.remove(id) }
        return pruning(result)
    }
    public static func pruning(_ metadata: LibraryMetadata) -> LibraryMetadata {
        var result = metadata
        let live = Set(result.IDsByPath.values.map(\.uuidString))
        let known = Set(result.tags.map(\.id))
        result.tagsByDocument = result.tagsByDocument.filter { live.contains($0.key) }.mapValues { $0.intersection(known) }.filter { !$0.value.isEmpty }
        let used = result.tagsByDocument.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        result.tags.removeAll { !used.contains($0.id) }
        var seen = Set<UUID>()
        result.tagRecency = result.tagRecency.filter { used.contains($0) && seen.insert($0).inserted }
        result.formatVersion = LibraryMetadata.currentVersion
        return result
    }
    /// Choose by application history, fill missing history by usage, then display naturally sorted.
    public static func recentTags(metadata: LibraryMetadata, limit: Int = 6) -> [LibraryTag] {
        guard limit > 0 else { return [] }
        let byID = Dictionary(metadata.tags.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [UUID: Int] = [:]
        for ids in metadata.tagsByDocument.values { for id in ids { counts[id, default: 0] += 1 } }
        let fallback = metadata.tags.sorted {
            let a = counts[$0.id, default: 0], b = counts[$1.id, default: 0]
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a > b
        }
        var seen = Set<UUID>()
        return (metadata.tagRecency.compactMap { byID[$0] } + fallback)
            .filter { seen.insert($0.id).inserted }.prefix(limit)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func matches(_ document: LibraryDocument, folder: LibraryFolder?, includeSubfolders: Bool,
                               tags: Set<UUID>, metadata: LibraryMetadata, searchIDs: Set<UUID>? = nil) -> Bool {
        if let folder {
            let inFolder = document.folderID == folder.id || (includeSubfolders && (folder.relativePath.isEmpty || document.relativePath.hasPrefix(folder.relativePath + "/")))
            if !inFolder { return false }
        }
        return tags.isSubset(of: metadata.tagsByDocument[document.id.uuidString] ?? []) && (searchIDs?.contains(document.id) ?? true)
    }
}

public enum TagStore {
    /// Read-modify-write against the current identity index, never a stale scan snapshot.
    public static func update(root: URL, transform: @escaping @Sendable (LibraryMetadata) -> LibraryMetadata) async throws -> LibraryMetadata {
        try await Task.detached(priority: .userInitiated) {
            let current = try LibraryMetadataStore.load(root: root).0
            let updated = TagEditor.pruning(transform(current))
            if updated != current { try LibraryMetadataStore.save(updated, root: root) }
            return updated
        }.value
    }
}

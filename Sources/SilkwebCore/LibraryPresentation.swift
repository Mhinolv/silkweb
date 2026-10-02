import Foundation

public enum DocumentSortKey: String, Codable, CaseIterable, Sendable {
    case name, modified, created
    public var title: String {
        switch self { case .name: return "Name"; case .modified: return "Date Modified"; case .created: return "Date Created" }
    }
}

public struct LibraryListPreference: Codable, Equatable, Sendable {
    public var key: DocumentSortKey = .modified
    public var descending = true
    public var includeSubfolders = false
    public init() {}
    public mutating func select(_ key: DocumentSortKey) {
        guard self.key != key else { return }
        self.key = key
        descending = key != .name
    }
    public var directionTitle: String {
        key == .name ? (descending ? "Z to A" : "A to Z") : (descending ? "Newest First" : "Oldest First")
    }
    private enum CodingKeys: String, CodingKey { case key, descending, includeSubfolders }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decodeIfPresent(DocumentSortKey.self, forKey: .key) ?? .modified
        descending = try values.decodeIfPresent(Bool.self, forKey: .descending) ?? (key != .name)
        includeSubfolders = try values.decodeIfPresent(Bool.self, forKey: .includeSubfolders) ?? false
    }
}

public struct FolderDocumentCount: Equatable, Sendable {
    public var direct: Int
    public var recursive: Int
    public init(direct: Int = 0, recursive: Int = 0) { self.direct = direct; self.recursive = recursive }
    /// Shared visible suffix for sidebar folder rows and future tag rows, including zero.
    public var inlineSuffix: String { " (\(direct.formatted()))" }
    public var badge: String { direct == 0 ? "" : direct.formatted() }
    public var accessibilityValue: String { "\(CountPresentation.label(direct, unit: .document)), \(recursive.formatted()) including subfolders" }
    public var tooltip: String { "\(CountPresentation.label(direct, unit: .document)) · \(recursive.formatted()) including subfolders" }
}

/// Built once on the scan worker. Views never sort or read file attributes.
public struct LibraryPresentation: Sendable {
    public let counts: [UUID: FolderDocumentCount]
    public let children: [UUID: [LibraryFolder]]
    private let ordered: [DocumentSortKey: [[LibraryDocument]]]
    private let directDocuments: [DocumentSortKey: [[UUID: [LibraryDocument]]]]

    public init(folders: [LibraryFolder], documents: [LibraryDocument]) {
        var counts = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, FolderDocumentCount()) })
        for document in documents { counts[document.folderID, default: FolderDocumentCount()].direct += 1 }
        for folder in folders {
            let direct = counts[folder.id]?.direct ?? 0
            counts[folder.id]?.recursive = direct
        }
        // Scanner guarantees parents precede children, so each subtree is added once.
        for folder in folders.reversed() {
            if let parent = folder.parentID {
                let recursive = counts[folder.id]?.recursive ?? 0
                counts[parent]?.recursive += recursive
            }
        }
        self.counts = counts
        children = Dictionary(grouping: folders.filter { $0.parentID != nil }, by: { $0.parentID! })
            .mapValues { $0.sorted { Self.naturalOrder($0.name, $1.name, pathA: $0.relativePath, pathB: $1.relativePath) } }
        var ordered: [DocumentSortKey: [[LibraryDocument]]] = [:]
        var direct: [DocumentSortKey: [[UUID: [LibraryDocument]]]] = [:]
        for key in DocumentSortKey.allCases {
            let modes = [false, true].map { descending in
                documents.sorted { a, b in
                    let result: ComparisonResult
                    switch key {
                    case .name: result = a.name.localizedStandardCompare(b.name)
                    case .modified: result = Self.compare(a.modified, b.modified)
                    case .created: result = Self.compare(a.created, b.created)
                    }
                    if result != .orderedSame { return descending ? result == .orderedDescending : result == .orderedAscending }
                    return Self.naturalOrder(a.name, b.name, pathA: a.relativePath, pathB: b.relativePath)
                }
            }
            ordered[key] = modes
            direct[key] = modes.map { Dictionary(grouping: $0, by: \.folderID) }
        }
        self.ordered = ordered
        directDocuments = direct
    }

    public static func naturalOrder(_ a: String, _ b: String, pathA: String, pathB: String) -> Bool {
        let result = a.localizedStandardCompare(b)
        return result == .orderedSame ? pathA < pathB : result == .orderedAscending
    }
    private static func compare(_ a: Date?, _ b: Date?) -> ComparisonResult {
        let a = a ?? .distantPast, b = b ?? .distantPast
        return a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }
    public func documents(in folder: LibraryFolder?, preference: LibraryListPreference) -> [LibraryDocument] {
        let index = preference.descending ? 1 : 0
        let all = ordered[preference.key]?[index] ?? []
        guard let folder else { return all }
        guard preference.includeSubfolders else { return directDocuments[preference.key]?[index][folder.id] ?? [] }
        return folder.relativePath.isEmpty ? all : all.filter { $0.relativePath.hasPrefix(folder.relativePath + "/") }
    }
    public static func breadcrumb(for document: LibraryDocument, in folderPath: String?) -> String? {
        guard let folderPath else { return nil }
        let parent = (document.relativePath as NSString).deletingLastPathComponent
        guard parent != folderPath else { return nil }
        let relative = folderPath.isEmpty ? parent : String(parent.dropFirst(folderPath.count + 1))
        return relative.isEmpty ? nil : relative.split(separator: "/").joined(separator: " › ")
    }
}

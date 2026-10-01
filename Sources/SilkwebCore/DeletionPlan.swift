import Foundation

public struct DeletionCounts: Equatable, Sendable {
    public var documents = 0
    public var folders = 0
    public var otherFiles = 0
    public var summary: String {
        [(documents, "document"), (folders, "folder"), (otherFiles, "other file")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
            .joined(separator: ", ")
    }
}

public struct DeletionPlan: Sendable {
    public let root: URL
    public let paths: [String]
    public let counts: DeletionCounts
    public let nonemptyFolders: [String]
    let inventory: Set<String>
    public var needsConfirmation: Bool { !nonemptyFolders.isEmpty }
    public func contains(_ path: String) -> Bool {
        paths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}

public enum DeletionSelection {
    /// Next surviving row below the selection, otherwise the preceding row.
    public static func successor(in rows: [String], removing paths: Set<String>) -> String? {
        guard let first = rows.firstIndex(where: { paths.contains($0) }) else { return nil }
        return rows.dropFirst(first).first { !paths.contains($0) }
            ?? rows.prefix(first).last { !paths.contains($0) }
    }
}

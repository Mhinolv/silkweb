import Foundation

public struct UnsupportedMarkdownLink: Equatable, Sendable {
    public let document: String
    public let syntax: String
}

/// When bytes cannot be read, guard the file identity and stat information instead.
/// These documents are never staged for a rewrite.
struct UnreadableMoveDocument: Equatable, Sendable {
    let size: UInt64?
    let modified: Date?
    let fileNumber: UInt64?

    init(attributes: [FileAttributeKey: Any]) {
        size = (attributes[.size] as? NSNumber)?.uint64Value
        modified = attributes[.modificationDate] as? Date
        fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

public struct MovePlan: Sendable {
    public let root: URL
    public let changes: LibraryChangeSet
    public let unsupportedLinks: [UnsupportedMarkdownLink]
    public let collisions: [String]
    let metadata: LibraryMetadata
    let before: [String: Data]
    let after: [String: Data]
    let fingerprints: [String: Data]
    let newFingerprints: [String: Data]
    let unreadableDocuments: [String: UnreadableMoveDocument]
    let inventory: Set<String>

    public var reversed: MovePlan {
        let reverse = LibraryChangeSet(
            changes: changes.changes.map {
                LibraryPathChange(id: $0.id, oldPath: $0.newPath, newPath: $0.oldPath!, isFolder: $0.isFolder)
            })
        return MovePlan(
            root: root, changes: reverse, unsupportedLinks: [], collisions: [],
            metadata: changes.applying(to: metadata),
            before: Dictionary(uniqueKeysWithValues: after.map { (changes.remapping($0.key), $0.value) }),
            after: Dictionary(uniqueKeysWithValues: before.map { (changes.remapping($0.key), $0.value) }),
            fingerprints: Dictionary(
                uniqueKeysWithValues: newFingerprints.map { (changes.remapping($0.key), $0.value) }),
            newFingerprints: Dictionary(
                uniqueKeysWithValues: fingerprints.map { (changes.remapping($0.key), $0.value) }),
            unreadableDocuments: Dictionary(
                uniqueKeysWithValues: unreadableDocuments.map { (changes.remapping($0.key), $0.value) }),
            inventory: Set(inventory.map { changes.remapping($0) }))
    }
}

public enum MovePlanError: Error, LocalizedError {
    case changed, noOp
    public var errorDescription: String? {
        switch self {
        case .changed: return "The move can’t be completed because items have changed since."
        case .noOp: return "The items are already in this folder."
        }
    }
}

/// Shared cheap validation for the picker and drop delegates. The actor rechecks
/// real volume identities and collisions before committing.
public enum MoveSelection {
    public static func topLevel(_ paths: [String]) -> [String] {
        let selected = Set(paths)
        return selected.sorted().filter { path in
            var ancestor = (path as NSString).deletingLastPathComponent
            while !ancestor.isEmpty {
                if selected.contains(ancestor) { return false }
                ancestor = (ancestor as NSString).deletingLastPathComponent
            }
            return true
        }
    }
    public static func permits(_ paths: [String], destination: String) -> Bool {
        !paths.isEmpty
            && paths.allSatisfy {
                !$0.isEmpty && $0 != destination && !destination.hasPrefix($0 + "/")
                    && ($0 as NSString).deletingLastPathComponent != destination
            }
    }
}

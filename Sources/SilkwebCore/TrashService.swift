import Foundation

public struct TrashedItem: Sendable {
    public let originalPath: String
    public let trashURL: URL
    let identities: [String: UUID]
}

public struct TrashFailure: Sendable {
    public let path: String
    public let reason: String
}

public struct TrashResult: Sendable {
    public var items: [TrashedItem] = []
    public var failures: [TrashFailure] = []
}

public enum TrashError: Error, LocalizedError {
    case changed
    case occupied(String)
    public var errorDescription: String? {
        switch self {
        case .changed: return "Items changed while preparing to move them to the Trash. Try again to review their contents."
        case .occupied(let path): return "“\((path as NSString).lastPathComponent)” can’t be put back because an item with that name now exists."
        }
    }
}

/// Foundation-only filesystem work. The injectable operation lets tests exercise
/// failures and restoration without touching the user's system Trash.
public actor TrashService {
    private let root: URL
    private let trash: @Sendable (URL) throws -> URL

    public init(root: URL, trash: @escaping @Sendable (URL) throws -> URL = { url in
        var destination: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &destination)
        guard let destination else { throw TrashError.changed }
        return destination as URL
    }) throws {
        guard root.isFileURL else { throw LibraryError.invalidRoot }
        try LibraryMetadataStore.rejectLink(root.standardizedFileURL)
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try self.root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw LibraryError.invalidRoot }
        self.trash = trash
    }

    private func item(_ path: String) throws -> URL {
        guard !path.isEmpty else { throw LibraryMutationError.libraryRoot }
        var url = root
        try LibraryMetadataStore.rejectLink(url)
        for component in path.split(separator: "/", omittingEmptySubsequences: false) {
            // Structural checks only: on-disk names may predate the rules for new names.
            try LibraryMutations.validateExistingComponent(String(component))
            url.appendPathComponent(String(component))
            try LibraryMetadataStore.rejectLink(url)
        }
        return url
    }

    public func plan(_ selection: [String]) throws -> DeletionPlan {
        // Validate every supplied path before reducing ancestor/descendant selections.
        for path in selection { _ = try item(path) }
        let paths = MoveSelection.topLevel(selection)
        guard !paths.isEmpty else { throw LibraryError.invalidRelativePath }
        var counts = DeletionCounts()
        var inventory = Set<String>()
        var nonempty: [String] = []
        for path in paths {
            let url = try item(path)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            guard values.isDirectory == true || (values.isRegularFile == true && ["md", "markdown"].contains(url.pathExtension.lowercased())) else {
                throw LibraryError.invalidRelativePath
            }
            inventory.insert(path + (values.isDirectory == true ? "/directory" : "/document"))
            guard values.isDirectory == true else { continue }
            var pending = [url]
            var hasChildren = false
            while let parent = pending.popLast() {
                // Includes hidden files and attachments; never follows symlinks.
                for child in try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
                    hasChildren = true
                    let attributes = try FileManager.default.attributesOfItem(atPath: child.path)
                    let relative = String(child.path.dropFirst(root.path.count + 1))
                    let type = attributes[.type] as? FileAttributeType
                    inventory.insert(relative + "/" + (type?.rawValue ?? "unknown"))
                    if type == .typeDirectory {
                        counts.folders += 1
                        pending.append(child)
                    } else if type == .typeRegular && ["md", "markdown"].contains(child.pathExtension.lowercased()) {
                        counts.documents += 1
                    } else { counts.otherFiles += 1 }
                }
            }
            if hasChildren { nonempty.append(path) }
        }
        return DeletionPlan(root: root, paths: paths, counts: counts, nonemptyFolders: nonempty, inventory: inventory)
    }

    public func execute(_ plan: DeletionPlan) throws -> TrashResult {
        guard plan.root == root, try self.plan(plan.paths).inventory == plan.inventory else { throw TrashError.changed }
        let (metadata, _) = try LibraryMetadataStore.load(root: root)
        var result = TrashResult()
        for path in plan.paths {
            do {
                let url = try item(path)
                let destination = try trash(url)
                result.items.append(TrashedItem(originalPath: path, trashURL: destination,
                    identities: metadata.IDsByPath.filter { $0.key == path || $0.key.hasPrefix(path + "/") }))
            } catch { result.failures.append(TrashFailure(path: path, reason: error.localizedDescription)) }
        }
        return result
    }

    /// Successful restores are removed from the retry list even if another fails.
    public func restore(_ items: [TrashedItem]) -> TrashResult {
        var result = TrashResult()
        for record in items {
            do {
                let destination = try item(record.originalPath)
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw TrashError.occupied(record.originalPath) }
                try LibraryMetadataStore.rejectLink(record.trashURL)
                var metadata = try LibraryMetadataStore.load(root: root).0
                try FileManager.default.moveItem(at: record.trashURL, to: destination)
                result.items.append(record)
                for (path, id) in record.identities { metadata.IDsByPath[path] = id }
                // A rebuildable index failure must not report a restored file as
                // still in Trash. The next scan can reconstruct its identity.
                try? LibraryMetadataStore.save(metadata, root: root)
            } catch { result.failures.append(TrashFailure(path: record.originalPath, reason: error.localizedDescription)) }
        }
        return result
    }
}

import Foundation

public enum LibraryScanner {
    /// All enumeration, metadata IO and encoding run away from the caller's actor.
    public static func scan(root: URL) async throws -> LibrarySnapshot {
        let worker = Task.detached(priority: .userInitiated) {
            try scanOnWorker(root: root)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public static func readDocument(_ document: LibraryDocument, root: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let components = document.relativePath.split(separator: "/", omittingEmptySubsequences: false)
            guard !components.isEmpty,
                  components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                throw LibraryError.invalidRelativePath
            }
            var url = root.standardizedFileURL
            try LibraryMetadataStore.rejectLink(url)
            for component in components {
                url.appendPathComponent(String(component))
                try LibraryMetadataStore.rejectLink(url)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    private static func scanOnWorker(root: URL) throws -> LibrarySnapshot {
        precondition(!Thread.isMainThread, "Library enumeration must run off the main thread")
        let root = root.standardizedFileURL
        try LibraryMetadataStore.rejectLink(root)
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LibraryError.invalidRoot
        }
        let (previous, recoveredURL) = try LibraryMetadataStore.load(root: root)
        var metadata = LibraryMetadata()
        var usedIDs = Set<UUID>()
        func identity(for path: String) -> UUID {
            var id = previous.IDsByPath[path] ?? UUID()
            // Damaged indexes must not produce duplicate Identifiable records.
            if usedIDs.contains(id) { id = UUID() }
            usedIDs.insert(id)
            metadata.IDsByPath[path] = id
            return id
        }
        let rootID = identity(for: "")
        var folders = [LibraryFolder(id: rootID, parentID: nil, relativePath: "", name: root.lastPathComponent)]
        var documents: [LibraryDocument] = []
        var pending = [(url: root, path: "", id: rootID)]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey]
        while let parent = pending.popLast() {
            try Task.checkCancellation()
            let children = try FileManager.default.contentsOfDirectory(
                at: parent.url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            for child in children {
                try Task.checkCancellation()
                let values = try child.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true, values.isHidden != true,
                      !child.lastPathComponent.hasPrefix(".") else { continue }
                let path = parent.path.isEmpty ? child.lastPathComponent : parent.path + "/" + child.lastPathComponent
                if values.isDirectory == true {
                    let id = identity(for: path)
                    folders.append(LibraryFolder(id: id, parentID: parent.id, relativePath: path, name: child.lastPathComponent))
                    pending.append((child, path, id))
                } else if values.isRegularFile == true,
                          ["md", "markdown"].contains(child.pathExtension.lowercased()) {
                    documents.append(LibraryDocument(id: identity(for: path), folderID: parent.id,
                                                     relativePath: path, name: child.lastPathComponent))
                }
            }
        }
        try Task.checkCancellation()
        try LibraryMetadataStore.save(metadata, root: root)
        return LibrarySnapshot(rootURL: root, folders: folders, documents: documents,
                               metadata: metadata, recoveredMetadataURL: recoveredURL)
    }
}

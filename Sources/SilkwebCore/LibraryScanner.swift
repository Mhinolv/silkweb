import Foundation

public enum LibraryScanner {
    /// Shared with move staleness checks so ignored filesystem entries cannot
    /// invalidate a transaction. Symlinks are never library-owned items.
    static func isManagedItem(_ url: URL, values: URLResourceValues) -> Bool {
        guard values.isSymbolicLink != true, values.isHidden != true,
              !url.lastPathComponent.hasPrefix(".") else { return false }
        if values.isDirectory == true, MediaDirectory.isMarked(url) { return false }
        return values.isDirectory == true || (values.isRegularFile == true
            && ["md", "markdown"].contains(url.pathExtension.lowercased()))
    }

    /// All enumeration, metadata IO and encoding run away from the caller's actor.
    public static func scan(root: URL, previousSnapshot: LibrarySnapshot? = nil, progress: (@Sendable (Int) -> Void)? = nil) async throws -> LibrarySnapshot {
        let worker = Task.detached(priority: .userInitiated) {
            try scanOnWorker(root: root, previousSnapshot: previousSnapshot, progress: progress)
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
            var url = root.standardizedFileURL.resolvingSymlinksInPath()
            try LibraryMetadataStore.rejectLink(url)
            for component in components {
                url.appendPathComponent(String(component))
                try LibraryMetadataStore.rejectLink(url)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    /// Refresh one saved file without enumerating the library or reading document bodies.
    public static func refreshingDates(in snapshot: LibrarySnapshot, documentID: UUID) async throws -> LibrarySnapshot {
        try await Task.detached(priority: .utility) {
            guard let index = snapshot.documents.firstIndex(where: { $0.id == documentID }) else { return snapshot }
            let document = snapshot.documents[index]
            try LibraryMetadataStore.rejectLink(snapshot.rootURL)
            var url = snapshot.rootURL
            for component in document.relativePath.split(separator: "/") {
                guard component != ".", component != ".." else { throw LibraryError.invalidRelativePath }
                url.appendPathComponent(String(component))
                try LibraryMetadataStore.rejectLink(url)
            }
            let values = try url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            var documents = snapshot.documents
            documents[index].created = values.creationDate
            documents[index].modified = values.contentModificationDate
            return LibrarySnapshot(rootURL: snapshot.rootURL, folders: snapshot.folders, documents: documents,
                                   presentation: LibraryPresentation(folders: snapshot.folders, documents: documents),
                                   metadata: snapshot.metadata, recoveredMetadataURL: snapshot.recoveredMetadataURL,
                                   isReadOnly: snapshot.isReadOnly)
        }.value
    }

    private static func scanOnWorker(root: URL, previousSnapshot: LibrarySnapshot?, progress: (@Sendable (Int) -> Void)?) throws -> LibrarySnapshot {
        precondition(!Thread.isMainThread, "Library enumeration must run off the main thread")
        try LibraryMetadataStore.rejectLink(root.standardizedFileURL)
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        try LibraryMetadataStore.rejectLink(root)
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LibraryError.invalidRoot
        }
        let (previous, recoveredURL) = try LibraryMetadataStore.load(root: root)
        var metadata = previous
        metadata.formatVersion = LibraryMetadata.currentVersion
        metadata.IDsByPath = [:]
        var usedIDs = Set<UUID>()
        var liveIDs: [String: UUID] = [:]
        for folder in previousSnapshot?.folders ?? [] {
            if let key = folder.fileIdentity { liveIDs[key] = folder.id }
        }
        for document in previousSnapshot?.documents ?? [] {
            if let key = document.fileIdentity { liveIDs[key] = document.id }
        }
        func fileIdentity(_ url: URL) throws -> String {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? "")"
        }
        func identity(for path: String, key: String? = nil) -> UUID {
            var id = key.flatMap { liveIDs[$0] } ?? previous.IDsByPath[path] ?? UUID()
            // Damaged indexes must not produce duplicate Identifiable records.
            if usedIDs.contains(id) { id = UUID() }
            usedIDs.insert(id)
            metadata.IDsByPath[path] = id
            return id
        }
        let rootID = identity(for: "")
        var folders = [LibraryFolder(id: rootID, parentID: nil, relativePath: "", name: root.lastPathComponent)]
        folders[0].fileIdentity = try fileIdentity(root)
        var documents: [LibraryDocument] = []
        var pending = [(url: root, path: "", id: rootID, folderIndex: 0)]
        var unreadablePaths = Set<String>()
        var nextProgress = Date().addingTimeInterval(1)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .creationDateKey, .contentModificationDateKey]
        while let parent = pending.popLast() {
            try Task.checkCancellation()
            let children: [(url: URL, values: URLResourceValues)]
            do {
                children = try FileManager.default.contentsOfDirectory(
                    at: parent.url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }.map {
                    try Task.checkCancellation()
                    return try ($0, $0.resourceValues(forKeys: keys))
                }
            } catch {
                let cocoa = error as NSError
                let isPermissionError = (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileReadNoPermissionError)
                    || (cocoa.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(cocoa.code))
                guard !parent.path.isEmpty, isPermissionError else { throw error }
                folders[parent.folderIndex].isUnreadable = true
                unreadablePaths.insert(parent.path)
                continue
            }
            if Date() >= nextProgress {
                progress?(documents.count)
                nextProgress = Date().addingTimeInterval(0.5)
            }
            for (child, values) in children {
                try Task.checkCancellation()
                guard isManagedItem(child, values: values) else { continue }
                let path = parent.path.isEmpty ? child.lastPathComponent : parent.path + "/" + child.lastPathComponent
                let key = try fileIdentity(child)
                if values.isDirectory == true {
                    let id = identity(for: path, key: key)
                    folders.append(LibraryFolder(id: id, parentID: parent.id, relativePath: path, name: child.lastPathComponent))
                    folders[folders.count - 1].fileIdentity = key
                    pending.append((child, path, id, folders.count - 1))
                } else if values.isRegularFile == true,
                          ["md", "markdown"].contains(child.pathExtension.lowercased()) {
                    documents.append(LibraryDocument(id: identity(for: path, key: key), folderID: parent.id,
                                                     relativePath: path, name: child.lastPathComponent,
                                                     created: values.creationDate, modified: values.contentModificationDate))
                    documents[documents.count - 1].fileIdentity = key
                }
            }
        }
        // Absence beneath a blocked folder does not mean deletion. Keep those identities
        // without exposing stale documents, and still prune paths in readable folders.
        if !unreadablePaths.isEmpty {
            for path in previous.IDsByPath.keys.sorted() where metadata.IDsByPath[path] == nil {
                try Task.checkCancellation()
                var ancestor = path[...]
                while let slash = ancestor.lastIndex(of: "/") {
                    ancestor = ancestor[..<slash]
                    if unreadablePaths.contains(String(ancestor)) {
                        _ = identity(for: path)
                        break
                    }
                }
            }
        }
        // Resolve identities after enumeration so a replacement at an old path
        // cannot steal the ID of the original file moved elsewhere in this batch.
        let keysByPath = Dictionary(uniqueKeysWithValues:
            folders.compactMap { item in item.fileIdentity.map { (item.relativePath, $0) } }
            + documents.compactMap { item in item.fileIdentity.map { (item.relativePath, $0) } })
        let presentLiveIDs = Set(keysByPath.values.compactMap { liveIDs[$0] })
        var resolved: [String: UUID] = [:]
        var assigned = Set<UUID>()
        for path in metadata.IDsByPath.keys.sorted() {
            let liveID = keysByPath[path].flatMap { liveIDs[$0] }
            var id = liveID ?? previous.IDsByPath[path] ?? metadata.IDsByPath[path]!
            if assigned.contains(id) || (liveID == nil && presentLiveIDs.contains(id)) { id = UUID() }
            assigned.insert(id)
            resolved[path] = id
        }
        metadata.IDsByPath = resolved
        folders = folders.map { folder in
            var updated = LibraryFolder(id: resolved[folder.relativePath]!,
                parentID: folder.parentID == nil ? nil : resolved[(folder.relativePath as NSString).deletingLastPathComponent],
                relativePath: folder.relativePath, name: folder.name)
            updated.fileIdentity = folder.fileIdentity
            updated.isUnreadable = folder.isUnreadable
            return updated
        }
        documents = documents.map { document in
            var updated = LibraryDocument(id: resolved[document.relativePath]!,
                folderID: resolved[(document.relativePath as NSString).deletingLastPathComponent]!,
                relativePath: document.relativePath, name: document.name, created: document.created, modified: document.modified)
            updated.fileIdentity = document.fileIdentity
            return updated
        }
        try Task.checkCancellation()
        metadata = TagEditor.pruning(metadata)
        let locations = try LibraryMetadataStore.locations(root: root)
        let metadataTarget = FileManager.default.fileExists(atPath: locations.file.path) ? locations.file :
            (FileManager.default.fileExists(atPath: locations.directory.path) ? locations.directory : root)
        var isReadOnly = !FileManager.default.isWritableFile(atPath: root.path)
            || !FileManager.default.isWritableFile(atPath: metadataTarget.path)
        if metadata != previous && !isReadOnly {
            do {
                try LibraryMetadataStore.save(metadata, root: root)
            } catch let error as NSError where error.domain == NSCocoaErrorDomain
                && [NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError].contains(error.code) {
                isReadOnly = true
            }
        }
        return LibrarySnapshot(rootURL: root, folders: folders, documents: documents,
                               presentation: LibraryPresentation(folders: folders, documents: documents),
                               metadata: metadata, recoveredMetadataURL: recoveredURL, isReadOnly: isReadOnly)
    }
}

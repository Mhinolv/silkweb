import Foundation

public struct AssetMigrationResult: Sendable {
    public var directoryName = "media"
    public var failures: [AssetFailure] = []
    public var completed = false
}

/// Durable reservations precede copying. Originals remain available until every
/// document has been rewritten, including after a crash between any two writes.
private struct AssetMigrationJournal: Codable {
    var formatVersion = 1
    var directoryName: String
    var destinations: [String: String] = [:]
    var completed = false

    init(directoryName: String) { self.directoryName = directoryName }
    enum CodingKeys: String, CodingKey { case formatVersion, directoryName, destinations, completed }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        guard version == 1 else { throw LibraryError.unsupportedMetadataVersion(version) }
        directoryName = try values.decode(String.self, forKey: .directoryName)
        destinations = try values.decodeIfPresent([String: String].self, forKey: .destinations) ?? [:]
        completed = try values.decodeIfPresent(Bool.self, forKey: .completed) ?? false
    }
}

extension AssetStore {
    /// All filesystem work executes on this serial asset executor. UI clients save
    /// dirty buffers in beforeRewrite, then reload them outside their undo stacks.
    public func migrate(
        root: URL, documents: [String], readOnly: Bool = false,
        progress: @Sendable (String, Int, Int) -> Void = { _, _, _ in },
        beforeRewrite: @Sendable () async -> Bool = { true },
        afterRewrite: @Sendable () async -> Void = {}
    ) async -> AssetMigrationResult {
        await migrate(
            root: root, documents: documents, readOnly: readOnly, fileLimit: nil,
            progress: progress, beforeRewrite: beforeRewrite, afterRewrite: afterRewrite)
    }

    // A deterministic interruption boundary for offscreen Core regression tests.
    func migrate(
        root: URL, documents: [String], readOnly: Bool = false, fileLimit: Int?,
        progress: @Sendable (String, Int, Int) -> Void = { _, _, _ in },
        beforeRewrite: @Sendable () async -> Bool = { true },
        afterRewrite: @Sendable () async -> Void = {}
    ) async -> AssetMigrationResult {
        var result = AssetMigrationResult()
        let fm = FileManager.default
        let old = root.appendingPathComponent(".silkweb-assets", isDirectory: true)
        guard !readOnly, fm.isWritableFile(atPath: root.path), fm.fileExists(atPath: old.path) else { return result }
        var lockedBuffers = false
        do {
            try LibraryMetadataStore.rejectLink(root)
            try LibraryMetadataStore.rejectLink(old)
            let metadata = try LibraryMetadataStore.locations(root: root).directory
            try fm.createDirectory(at: metadata, withIntermediateDirectories: true)
            let journalURL = metadata.appendingPathComponent("media-migration.json")
            try LibraryMetadataStore.rejectLink(journalURL)
            var journal: AssetMigrationJournal
            if fm.fileExists(atPath: journalURL.path) {
                journal = try JSONDecoder().decode(AssetMigrationJournal.self, from: Data(contentsOf: journalURL))
            } else {
                journal = AssetMigrationJournal(directoryName: try MediaDirectory.prepare(root: root).lastPathComponent)
            }
            result.directoryName = journal.directoryName
            // Validate persisted paths before using them, including every ancestor.
            func checked(_ path: String) throws -> URL {
                let parts = path.split(separator: "/", omittingEmptySubsequences: false)
                guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    throw LibraryError.invalidRelativePath
                }
                var url = root
                for part in parts { url.appendPathComponent(String(part)); try LibraryMetadataStore.rejectLink(url) }
                return url
            }
            let target = try checked(journal.directoryName)
            guard MediaDirectory.isMarked(target) else { throw LibraryMutationError.unsupportedItem(target.path) }
            func saveJournal() throws { try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic) }
            var files: [String] = []
            func walk(_ directory: URL, path: String) throws {
                for url in try fm.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey])
                {
                    try LibraryMetadataStore.rejectLink(url)
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
                    let relative = path + "/" + url.lastPathComponent
                    if values.isDirectory == true {
                        try walk(url, path: relative)
                    } else if values.isRegularFile == true {
                        files.append(relative)
                    } else {
                        throw LibraryMutationError.unsupportedItem(url.path)
                    }
                }
            }
            try walk(old, path: ".silkweb-assets")
            files.sort()
            progress(journal.directoryName, 0, files.count)
            var copied = 0
            var nextProgress = Date.distantPast
            for path in files {
                try Task.checkCancellation()
                if let fileLimit, copied >= fileLimit { return result }
                do {
                    if journal.destinations[path] == nil {
                        let suffix = String(path.dropFirst(".silkweb-assets/".count))
                        let base = journal.directoryName + "/" + suffix
                        let original = try checked(base)
                        try fm.createDirectory(
                            at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
                        var candidate = base
                        let ext = (base as NSString).pathExtension
                        let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
                        var number = 2
                        while fm.fileExists(atPath: try checked(candidate).path)
                            || journal.destinations.values.contains(candidate)
                        {
                            candidate = stem + " \(number)" + (ext.isEmpty ? "" : "." + ext)
                            number += 1
                        }
                        journal.destinations[path] = candidate
                        journal.completed = false
                        try saveJournal()
                    }
                    let destination = try checked(journal.destinations[path]!)
                    if !fm.fileExists(atPath: destination.path) {
                        let staging = destination.deletingLastPathComponent().appendingPathComponent(
                            ".migration-" + UUID().uuidString)
                        defer { try? fm.removeItem(at: staging) }
                        try fm.copyItem(at: checked(path), to: staging)
                        try fm.moveItem(at: staging, to: destination)
                    }
                    guard try Data(contentsOf: checked(path)) == Data(contentsOf: destination) else {
                        throw LibraryMutationError.unsupportedItem(destination.path)
                    }
                    copied += 1
                    if Date() >= nextProgress || copied == files.count {
                        progress(journal.directoryName, copied, files.count)
                        nextProgress = Date().addingTimeInterval(0.1)
                    }
                } catch { result.failures.append(AssetFailure(name: path, reason: error.localizedDescription)) }
            }
            guard result.failures.isEmpty else { return result }
            guard await beforeRewrite() else {
                result.failures.append(AssetFailure(name: "Documents", reason: "Unsaved changes couldn’t be saved."))
                return result
            }
            lockedBuffers = true
            let changes = LibraryChangeSet(
                changes: journal.destinations.sorted { $0.key < $1.key }.map {
                    LibraryPathChange(id: UUID(), oldPath: $0.key, newPath: $0.value, isFolder: false)
                })
            let current = try await LibraryScanner.scan(root: root)
            if current.folders.contains(where: \.isUnreadable) {
                result.failures.append(AssetFailure(name: "Documents", reason: "Some documents couldn’t be read."))
            }
            for path in Set(documents + current.documents.map(\.relativePath)).sorted() {
                try Task.checkCancellation()
                do {
                    let url = try checked(path)
                    let text = try String(contentsOf: url, encoding: .utf8)
                    let rewrite = MarkdownDestinations.rewrite(text, source: path, changes: changes)
                    if rewrite.text != text { try Data(rewrite.text.utf8).write(to: url, options: .atomic) }
                    // Unknown syntax can still point at the legacy store. Retain it.
                    if !rewrite.unsupported.isEmpty && text.contains(".silkweb-assets") {
                        result.failures.append(
                            AssetFailure(name: path, reason: "An unsupported link still uses the old image location."))
                    }
                } catch { result.failures.append(AssetFailure(name: path, reason: error.localizedDescription)) }
            }
            await afterRewrite()
            lockedBuffers = false
            guard result.failures.isEmpty else { return result }
            journal.completed = true
            try saveJournal()
            // Removing individual originals allows safe resumption during cleanup.
            for path in files { try fm.removeItem(at: checked(path)) }
            func removeEmpty(_ directory: URL) throws {
                for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey]) {
                    try LibraryMetadataStore.rejectLink(url)
                    if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { try removeEmpty(url) }
                }
                if try fm.contentsOfDirectory(atPath: directory.path).isEmpty { try fm.removeItem(at: directory) }
            }
            try removeEmpty(old)
            result.completed = true
        } catch {
            result.failures.append(AssetFailure(name: "Images", reason: error.localizedDescription))
        }
        if lockedBuffers { await afterRewrite() }
        return result
    }
}

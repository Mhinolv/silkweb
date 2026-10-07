import Foundation

public struct ImportPlan: Sendable {
    public struct Entry: Sendable {
        public let sourcePath: String
        public let copyPath: String
        public let isFolder: Bool
        public let isDocument: Bool
    }
    public let source: URL
    public let library: URL
    public let destination: String
    public let folderName: String
    public let folderNameCollision: Bool
    public let entries: [Entry]
    public let renamed: [String]
    public let skipped: [String]
    public let outsideLinks: [String]
    public let emptyFolders: Int
    public var documentCount: Int { entries.filter(\.isDocument).count }
    public var assetCount: Int {
        entries.filter {
            !$0.isFolder && !$0.isDocument && ($0.sourcePath as NSString).lastPathComponent != MediaDirectory.marker
        }.count
    }
    public var folderCount: Int { entries.filter(\.isFolder).count }

    /// The review sheet's summary line.
    public var summary: String {
        Self.summary(
            documents: documentCount, attachments: assetCount, folders: folderCount, emptyFolders: emptyFolders,
            folderName: folderName)
    }

    /// Zero attachment and folder parts, and “(0 empty)”, are left out.
    public static func summary(documents: Int, attachments: Int, folders: Int, emptyFolders: Int, folderName: String)
        -> String
    {
        var parts = [CountPresentation.label(documents, unit: .document)]
        if attachments > 0 { parts.append(CountPresentation.label(attachments, unit: .attachment)) }
        if folders > 0 {
            parts.append(
                CountPresentation.label(folders, unit: .folder)
                    + (emptyFolders > 0 ? " (\(emptyFolders.formatted()) empty)" : ""))
        }
        let list = ListFormatter.localizedString(byJoining: parts)
        return "\(list) will be copied into a new folder “\(folderName)”."
    }
}

public enum FolderImportError: LocalizedError {
    case alreadyInLibrary, containsLibrary, noDocuments, destinationChanged
    public var errorDescription: String? {
        switch self {
        case .alreadyInLibrary: return "This folder is already in your library. Use Move To… to reorganize it instead."
        case .containsLibrary: return "You can’t import a folder that contains your library."
        case .noDocuments: return "No Markdown documents found."
        case .destinationChanged: return "The source or destination changed. Review the import again."
        }
    }
}

/// Synchronous worker operations. Call from a detached task, never the UI actor.
public enum FolderImporter {
    private static let fm = FileManager.default
    private static func inside(_ url: URL, _ root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }
    private static func checked(_ root: URL, _ path: String) throws -> URL {
        guard root.standardizedFileURL.resolvingSymlinksInPath() == root,
            try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        else { throw FolderImportError.destinationChanged }
        var url = root
        guard
            path.isEmpty
                || path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({
                    !$0.isEmpty && $0 != "." && $0 != ".."
                })
        else { throw LibraryError.invalidRelativePath }
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw LibraryError.symbolicLink(url)
            }
        }
        return url
    }
    private static func safeName(_ input: String, folder: Bool) -> String {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        name = String(
            name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) || $0 == ":" ? "_" : String($0) }
                .joined())
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "Untitled" }
        let ext = folder ? "" : (name as NSString).pathExtension
        var stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        if suffix.utf8.count < 200 {
            while (stem + suffix).utf8.count > 230 { stem.removeLast() }
            name = stem + suffix
        } else {
            while name.utf8.count > 230 { name.removeLast() }
        }
        return name
    }
    private static func unique(_ name: String, used: inout Set<String>, folder: Bool) -> String {
        let base = safeName(name, folder: folder)
        let ext = folder ? "" : (base as NSString).pathExtension
        let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
        var result = base
        var n = 2
        while !used.insert(result.precomposedStringWithCanonicalMapping.lowercased()).inserted {
            result = stem + " \(n)" + (ext.isEmpty ? "" : "." + ext); n += 1
        }
        return result
    }
    public static func plan(source: URL, library: URL, destination: String) throws -> ImportPlan {
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let library = library.standardizedFileURL.resolvingSymlinksInPath()
        if inside(source, library) { throw FolderImportError.alreadyInLibrary }
        if inside(library, source) { throw FolderImportError.containsLibrary }
        let target = try checked(library, destination)
        var used = Set(
            try fm.contentsOfDirectory(atPath: target.path).map {
                $0.precomposedStringWithCanonicalMapping.lowercased()
            })
        let folderNameCollision = used.contains(
            safeName(source.lastPathComponent, folder: true).precomposedStringWithCanonicalMapping.lowercased())
        let folderName = unique(source.lastPathComponent, used: &used, folder: true)
        var items: [(String, Bool)] = []
        var documents: [String: String] = [:]
        var skipped: [String] = []
        func walk(_ path: String, assets: Bool = false) throws {
            try Task.checkCancellation()
            let directory = source.appendingPathComponent(path)
            let children: [URL]
            do {
                children = try fm.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isRegularFileKey])
            } catch { if path.isEmpty { throw error }; skipped.append(path + " — Couldn’t be read"); return }
            for url in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try Task.checkCancellation()
                let relative = path.isEmpty ? url.lastPathComponent : path + "/" + url.lastPathComponent
                do {
                    let values = try url.resourceValues(forKeys: [
                        .isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey, .isRegularFileKey,
                    ])
                    if values.isSymbolicLink == true { skipped.append(relative + " — Symbolic link"); continue }
                    if assets && url.lastPathComponent == MediaDirectory.marker {
                        items.append((relative, false)); continue
                    }
                    if values.isHidden == true || url.lastPathComponent.hasPrefix(".") {
                        skipped.append(relative + " — Hidden item"); continue
                    }
                    if values.isDirectory == true {
                        items.append((relative, true));
                        try walk(relative, assets: assets || MediaDirectory.isMarked(url))
                    } else if values.isRegularFile == true {
                        if !assets && ["md", "markdown"].contains(url.pathExtension.lowercased()) {
                            documents[relative] = try String(contentsOf: url, encoding: .utf8)
                        }
                        items.append((relative, false))
                    } else {
                        skipped.append(relative + " — Not a Markdown document or a linked image")
                    }
                } catch is CancellationError { throw CancellationError() } catch {
                    skipped.append(relative + " — Couldn’t be read")
                }
            }
        }
        try walk("", assets: MediaDirectory.isMarked(source))
        let files = Set(items.filter { !$0.1 }.map { $0.0 })
        var canonicalFiles: [String: String] = [:]
        for path in files.sorted().reversed() {
            canonicalFiles[path.precomposedStringWithCanonicalMapping.lowercased()] = path
        }
        var linked: Set<String> = []
        var outside: [String] = []
        for path in documents.keys.sorted() {
            try Task.checkCancellation()
            let parsed = MarkdownDestinations.rewrite(
                documents[path]!, source: path, changes: LibraryChangeSet(changes: []),
                visit: { link in
                    guard !link.hasPrefix("#"), !link.isEmpty else { return }
                    if link.contains(":") && !link.lowercased().hasPrefix("file:") { return }
                    if link.hasPrefix("/") || link.lowercased().hasPrefix("file:") {
                        outside.append(path + " › " + link); return
                    }
                    let raw = String(link.prefix(while: { $0 != "#" && $0 != "?" }))
                    guard let decoded = raw.removingPercentEncoding else { return }
                    let url: URL
                    if decoded.lowercased().hasPrefix("file:"), let absolute = URL(string: decoded) {
                        url = absolute
                    } else if decoded.hasPrefix("/") {
                        url = URL(fileURLWithPath: decoded)
                    } else {
                        url = source.appendingPathComponent(path).deletingLastPathComponent().appendingPathComponent(
                            decoded)
                    }
                    let normalized = url.standardizedFileURL
                    guard inside(normalized, source), inside(normalized.resolvingSymlinksInPath(), source) else {
                        outside.append(path + " › " + link); return
                    }
                    let relative = String(normalized.path.dropFirst(source.path.count + 1))
                    if files.contains(relative) {
                        linked.insert(relative)
                    } else if let canonical = canonicalFiles[
                        relative.precomposedStringWithCanonicalMapping.lowercased()]
                    {
                        linked.insert(canonical)
                    } else {
                        skipped.append(path + " › " + link + " — Couldn’t be read")
                    }
                })
            skipped += parsed.unsupported.map { path + " › " + $0 + " — Unsupported link; stays as written" }
        }
        var mapped: [String: String] = ["": ""]
        var names: [String: Set<String>] = [:]
        var entries: [ImportPlan.Entry] = []
        var renamed: [String] = []
        for (path, folder) in items {
            guard
                folder || documents[path] != nil || linked.contains(path)
                    || (path as NSString).lastPathComponent == MediaDirectory.marker
            else { skipped.append(path + " — Not a Markdown document or a linked image"); continue }
            let parent = (path as NSString).deletingLastPathComponent
            var siblingNames = names[parent] ?? []
            let name =
                (path as NSString).lastPathComponent == MediaDirectory.marker
                ? MediaDirectory.marker
                : unique((path as NSString).lastPathComponent, used: &siblingNames, folder: folder)
            names[parent] = siblingNames
            let mappedParent = mapped[parent] ?? parent
            let copy = mappedParent.isEmpty ? name : mappedParent + "/" + name
            mapped[path] = copy
            if copy != path { renamed.append(path + " → " + copy) }
            entries.append(
                .init(sourcePath: path, copyPath: copy, isFolder: folder, isDocument: documents[path] != nil))
        }
        let parents = Set(items.map { ($0.0 as NSString).deletingLastPathComponent })
        return ImportPlan(
            source: source, library: library, destination: destination, folderName: folderName,
            folderNameCollision: folderNameCollision, entries: entries, renamed: renamed, skipped: skipped,
            outsideLinks: outside,
            emptyFolders: entries.filter { $0.isFolder && !parents.contains($0.sourcePath) }.count)
    }

    public static func copy(_ plan: ImportPlan, progress: @Sendable (Int, Int) -> Void = { _, _ in }) throws -> String {
        guard plan.documentCount > 0 else { throw FolderImportError.noDocuments }
        let target = try checked(plan.library, plan.destination)
        let final = target.appendingPathComponent(plan.folderName)
        guard
            !(try fm.contentsOfDirectory(atPath: target.path)).contains(where: {
                $0.precomposedStringWithCanonicalMapping.lowercased()
                    == plan.folderName.precomposedStringWithCanonicalMapping.lowercased()
            })
        else { throw FolderImportError.destinationChanged }
        let staging = target.appendingPathComponent(".silkweb-import-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let changes = LibraryChangeSet(
            changes: plan.entries.filter { $0.sourcePath != $0.copyPath }.map {
                LibraryPathChange(id: UUID(), oldPath: $0.sourcePath, newPath: $0.copyPath, isFolder: $0.isFolder)
            })
        let total = plan.documentCount
        var canonicalPaths: [String: String] = [:]
        for entry in plan.entries.reversed() {
            canonicalPaths[entry.sourcePath.precomposedStringWithCanonicalMapping.lowercased()] = entry.sourcePath
        }
        for entry in plan.entries { canonicalPaths[entry.sourcePath] = entry.sourcePath }
        var count = 0
        var lastProgress = Date.distantPast
        for entry in plan.entries {
            try Task.checkCancellation()
            let source = try checked(plan.source, entry.sourcePath)
            let output = staging.appendingPathComponent(entry.copyPath)
            if entry.isFolder {
                try fm.createDirectory(at: output, withIntermediateDirectories: false)
            } else if entry.isDocument {
                let text = try String(contentsOf: source, encoding: .utf8)
                let rewritten = MarkdownDestinations.rewrite(
                    text, source: entry.sourcePath, changes: changes, canonicalPaths: canonicalPaths
                ).text
                try Data(rewritten.utf8).write(to: output, options: .atomic)
                count += 1
            } else {
                try fm.copyItem(at: source, to: output)
            }
            if Date().timeIntervalSince(lastProgress) >= 0.1 || count == total && entry.isDocument {
                progress(count, total); lastProgress = Date()
            }
        }
        try Task.checkCancellation()
        guard try checked(plan.library, plan.destination) == target else { throw FolderImportError.destinationChanged }
        guard
            !(try fm.contentsOfDirectory(atPath: target.path)).contains(where: {
                $0.precomposedStringWithCanonicalMapping.lowercased()
                    == plan.folderName.precomposedStringWithCanonicalMapping.lowercased()
            })
        else { throw FolderImportError.destinationChanged }
        try fm.moveItem(at: staging, to: final)
        return plan.destination.isEmpty ? plan.folderName : plan.destination + "/" + plan.folderName
    }
}

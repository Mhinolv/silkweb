import Foundation
import Darwin
import CryptoKit

public enum LibraryNameFailure: Equatable, Sendable {
    case empty, separator, leadingPeriod, tooLong, controlCharacter
}

public enum LibraryMutationError: Error, Equatable, LocalizedError {
    case invalidName(LibraryNameFailure)
    case collision(path: String, isFolder: Bool, folderName: String)
    case folderCycle(String)
    case libraryRoot
    case outsideRoot
    case sourceVanished(String)
    case filesystemFailure(name: String, operation: String, reason: String)
    case unsupportedItem(String)
    case rollbackFailed(original: String, current: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let reason):
            switch reason {
            case .empty: return "A name can’t be empty."
            case .separator: return "Names can’t contain “/” or “:”."
            case .leadingPeriod: return "Names can’t begin with a period."
            case .tooLong: return "That name is too long."
            case .controlCharacter: return "Names can’t contain control characters."
            }
        case let .collision(path, isFolder, folderName):
            let name = Self.displayName((path as NSString).lastPathComponent, isFolder: isFolder)
            return "A \(isFolder ? "folder" : "document") named “\(name)” already exists in “\(folderName)”."
        case .folderCycle(let name): return "“\(name)” can’t be moved into itself or one of its subfolders."
        case .libraryRoot: return "The library folder itself can’t be moved or renamed here."
        case .outsideRoot: return "Silkweb can only move items within this library."
        case .sourceVanished(let name): return "“\(name)” no longer exists."
        case let .filesystemFailure(name, operation, _): return "“\(name)” couldn’t be \(operation)."
        case .unsupportedItem(let path): return "“\((path as NSString).lastPathComponent)” isn’t a folder or Markdown document."
        case .rollbackFailed: return "The change couldn’t be rolled back."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .libraryRoot: return "Use Finder to rename the library folder."
        case .sourceVanished: return "It may have been moved or deleted in Finder."
        case .filesystemFailure(_, _, let reason): return reason
        case let .rollbackFailed(original, current): return "The item is preserved at “\(current)”. Its original location was “\(original)”."
        default: return nil
        }
    }

    static func displayName(_ name: String, isFolder: Bool = false) -> String {
        guard !isFolder, ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) else { return name }
        return (name as NSString).deletingPathExtension
    }
}

public struct LibraryPathChange: Equatable, Sendable {
    public let id: UUID
    public let oldPath: String?
    public let newPath: String
    public let isFolder: Bool
}

public struct LibraryChangeSet: Equatable, Sendable {
    public let changes: [LibraryPathChange]

    public init(changes: [LibraryPathChange]) { self.changes = changes }

    /// Folder descendants retain their identities without enumerating their bodies.
    public func applying(to metadata: LibraryMetadata) -> LibraryMetadata {
        var result = metadata
        for change in changes {
            guard let old = change.oldPath else {
                result.IDsByPath[change.newPath] = change.id
                continue
            }
            let affected = result.IDsByPath.filter {
                $0.key == old || (change.isFolder && $0.key.hasPrefix(old + "/"))
            }
            for (path, _) in affected { result.IDsByPath.removeValue(forKey: path) }
            result.IDsByPath[change.newPath] = change.id
            for (path, id) in affected {
                result.IDsByPath[change.newPath + path.dropFirst(old.count)] = id
            }
        }
        return result
    }
}

/// Serializes mutations for one open library. Filesystem work runs on the actor's
/// executor, away from the UI. Callers must save dirty documents before moving them.
/// Batch moves also stage supported link rewrites. Use one instance per library.
public actor LibraryMutations {
    private let root: URL

    public init(root: URL) throws {
        guard root.isFileURL else { throw LibraryError.invalidRoot }
        try LibraryMetadataStore.rejectLink(root.standardizedFileURL)
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        guard try canonical.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LibraryError.invalidRoot
        }
        self.root = canonical
    }

    public func createFolder(named name: String, in parentPath: String = "") throws -> LibraryChangeSet {
        let name = try Self.validateName(name)
        return try perform(operation: "created", name: name) {
            let parent = try directory(parentPath)
            let path = joined(parentPath, name)
            let destination = parent.appendingPathComponent(name)
            let (metadata, _) = try LibraryMetadataStore.load(root: root)
            // mkdir is exclusive, including when the existing item is a file or symlink.
            guard mkdir(destination.path, 0o755) == 0 else { throw operationError(path, isFolder: true) }
            let changes = LibraryChangeSet(changes: [LibraryPathChange(id: UUID(), oldPath: nil, newPath: path, isFolder: true)])
            try persist(changes, metadata: metadata, original: nil, current: destination)
            return changes
        }
    }

    /// Used only by Undo New Folder. rmdir atomically refuses nonempty folders.
    public func removeEmptyFolder(_ path: String) throws {
        let source = try item(path)
        let (metadata, _) = try LibraryMetadataStore.load(root: root)
        guard rmdir(source.path) == 0 else { throw operationError(path, isFolder: true) }
        var updated = metadata
        updated.IDsByPath.removeValue(forKey: path)
        do { try LibraryMetadataStore.save(updated, root: root) }
        catch {
            // Restore the empty folder if its index could not be committed.
            guard mkdir(source.path, 0o755) == 0 else {
                throw LibraryMutationError.rollbackFailed(original: path, current: path)
            }
            throw error
        }
    }

    public func createDocument(named name: String, in parentPath: String = "", text: String = "") throws -> LibraryChangeSet {
        let name = try Self.validateName(name)
        return try perform(operation: "created", name: LibraryMutationError.displayName(name)) {
            guard ["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) else {
                throw LibraryMutationError.unsupportedItem(name)
            }
            let parent = try directory(parentPath)
            let path = joined(parentPath, name)
            let destination = parent.appendingPathComponent(name)
            let (metadata, _) = try LibraryMetadataStore.load(root: root)
            // Publish the complete UTF-8 file atomically, without replacing a competing file.
            let staging = parent.appendingPathComponent(".silkweb-create-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try Data(text.utf8).write(to: staging, options: .withoutOverwriting)
            try exclusiveRename(staging, destination, path: path)
            let changes = LibraryChangeSet(changes: [LibraryPathChange(id: UUID(), oldPath: nil, newPath: path, isFolder: false)])
            try persist(changes, metadata: metadata, original: nil, current: destination)
            return changes
        }
    }

    public func rename(_ path: String, to name: String) throws -> LibraryChangeSet {
        let name = try Self.validateName(name)
        return try perform(operation: "renamed", name: LibraryMutationError.displayName((path as NSString).lastPathComponent)) {
            let components = try Self.components(path, allowRoot: false)
            return try relocate(path, parentPath: components.dropLast().joined(separator: "/"), name: name)
        }
    }

    /// Read-only preflight for live rename feedback, using the volume's lookup rules.
    public func validateRename(_ path: String, to name: String) throws {
        let name = try Self.validateName(name)
        let source = try item(path)
        let isFolder = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        let parent = source.deletingLastPathComponent()
        let destination = parent.appendingPathComponent(name)
        if !isFolder && !["md", "markdown"].contains(destination.pathExtension.lowercased()) {
            throw LibraryMutationError.unsupportedItem(name)
        }
        guard try entryExists(destination), source.path != destination.path else { return }
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        if !names.contains(name), try sameItem(source, destination) { return }
        throw LibraryMutationError.collision(path: destination.path, isFolder: isFolder, folderName: parent.lastPathComponent)
    }

    public func move(_ path: String, toFolder parentPath: String) throws -> LibraryChangeSet {
        return try perform(operation: "moved", name: LibraryMutationError.displayName((path as NSString).lastPathComponent)) {
            let components = try Self.components(path, allowRoot: false)
            return try relocate(path, parentPath: parentPath, name: String(components.last!))
        }
    }

    /// Pure, cheap validation for inline rename fields. Returns the committed spelling.
    @discardableResult
    public static func validateName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { throw LibraryMutationError.invalidName(.empty) }
        if name.contains("/") || name.contains(":") { throw LibraryMutationError.invalidName(.separator) }
        if name.hasPrefix(".") { throw LibraryMutationError.invalidName(.leadingPeriod) }
        if name.utf8.count > 255 { throw LibraryMutationError.invalidName(.tooLong) }
        if name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) {
            throw LibraryMutationError.invalidName(.controlCharacter)
        }
        return name
    }

    /// Inline fields edit only the base name, preserving a document's original extension.
    public static func renameFilename(_ input: String, for path: String, isFolder: Bool) throws -> String {
        let base = try validateName(input)
        return try validateName(isFolder ? base : base + "." + (path as NSString).pathExtension)
    }

    /// Uses the actual volume's lookup rules, including case and Unicode equivalence.
    /// This is a suggestion; create/move still recheck collisions atomically.
    public func uniqueName(base: String, in parentPath: String = "") throws -> String {
        let base = try Self.validateName(base)
        return try perform(operation: "created", name: LibraryMutationError.displayName(base)) {
            let parent = try directory(parentPath)
            let ext = (base as NSString).pathExtension
            let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
            var candidate = base
            var number = 2
            while try entryExists(parent.appendingPathComponent(candidate)) {
                candidate = try Self.validateName(stem + " \(number)" + (ext.isEmpty ? "" : "." + ext))
                number += 1
            }
            return candidate
        }
    }

    private func entryExists(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return false
        }
    }

    private func perform<T>(operation: String, name: String, body: () throws -> T) throws -> T {
        do { return try body() }
        catch let error as LibraryMutationError { throw error }
        catch LibraryError.invalidRelativePath { throw LibraryMutationError.outsideRoot }
        catch LibraryError.symbolicLink { throw LibraryMutationError.outsideRoot }
        catch {
            let underlying = error as NSError
            if (underlying.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(underlying.code))
                || (underlying.domain == NSPOSIXErrorDomain && underlying.code == Int(ENOENT)) {
                throw LibraryMutationError.sourceVanished(name)
            }
            throw LibraryMutationError.filesystemFailure(name: name, operation: operation, reason: underlying.localizedDescription)
        }
    }

    private static func components(_ path: String, allowRoot: Bool) throws -> [String] {
        if path.isEmpty {
            if allowRoot { return [] }
            throw LibraryMutationError.libraryRoot
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { throw LibraryError.invalidRelativePath }
        for part in parts {
            do { try validateName(part) } catch { throw LibraryError.invalidRelativePath }
        }
        return parts
    }

    private func item(_ path: String, allowRoot: Bool = false) throws -> URL {
        var url = root
        try LibraryMetadataStore.rejectLink(url)
        for part in try Self.components(path, allowRoot: allowRoot) {
            url.appendPathComponent(part)
            try LibraryMetadataStore.rejectLink(url)
        }
        return url
    }

    private func directory(_ path: String) throws -> URL {
        let url = try item(path, allowRoot: true)
        guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw LibraryMutationError.unsupportedItem(path)
        }
        return url
    }

    private func relocate(_ path: String, parentPath: String, name: String) throws -> LibraryChangeSet {
        let source = try item(path)
        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        let isFolder = values.isDirectory == true
        guard isFolder || (values.isRegularFile == true && ["md", "markdown"].contains(source.pathExtension.lowercased())) else {
            throw LibraryMutationError.unsupportedItem(path)
        }
        if !isFolder && !["md", "markdown"].contains((name as NSString).pathExtension.lowercased()) {
            throw LibraryMutationError.unsupportedItem(name)
        }
        let parent = try directory(parentPath)
        if isFolder {
            // Identity checks also catch differently-cased ancestor paths on APFS.
            var ancestor = parent
            while true {
                if try sameItem(source, ancestor) { throw LibraryMutationError.folderCycle(source.lastPathComponent) }
                if ancestor.path == root.path { break }
                ancestor.deleteLastPathComponent()
            }
        }
        let newPath = joined(parentPath, name)
        if path == newPath { return LibraryChangeSet(changes: []) }
        let destination = parent.appendingPathComponent(name)
        let (metadata, _) = try LibraryMetadataStore.load(root: root)
        try relocateOnDisk(source, destination, oldPath: path, newPath: newPath)
        let changes = LibraryChangeSet(changes: [LibraryPathChange(id: metadata.IDsByPath[path] ?? UUID(), oldPath: path, newPath: newPath, isFolder: isFolder)])
        try persist(changes, metadata: metadata, original: source, current: destination)
        return changes
    }

    private func relocateOnDisk(_ source: URL, _ destination: URL, oldPath: String, newPath: String) throws {
        // A case-insensitive lookup may refer to the source itself. Only allow this
        // when the destination spelling does not already have a directory entry;
        // distinct hard links must still be treated as collisions.
        let parent = destination.deletingLastPathComponent()
        let name = destination.lastPathComponent
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        let caseAlias = try source.lastPathComponent.compare(name, options: .caseInsensitive) == .orderedSame
            && sameItem(source.deletingLastPathComponent(), parent)
            && !names.contains(name) && FileManager.default.fileExists(atPath: destination.path)
            && sameItem(source, destination)
        if caseAlias {
            let staging = source.deletingLastPathComponent().appendingPathComponent(".silkweb-rename-\(UUID().uuidString)")
            try exclusiveRename(source, staging, path: oldPath)
            do {
                try exclusiveRename(staging, destination, path: newPath)
            } catch {
                do { try exclusiveRename(staging, source, path: oldPath) }
                catch { throw LibraryMutationError.rollbackFailed(original: oldPath, current: staging.path) }
                throw error
            }
        } else {
            try exclusiveRename(source, destination, path: newPath)
        }
    }

    private func persist(_ changes: LibraryChangeSet, metadata: LibraryMetadata, original: URL?, current: URL) throws {
        do {
            try LibraryMetadataStore.save(changes.applying(to: metadata), root: root)
        } catch {
            do {
                if let original {
                    try relocateOnDisk(current, original, oldPath: current.path, newPath: original.path)
                } else {
                    try FileManager.default.removeItem(at: current)
                }
            } catch {
                throw LibraryMutationError.rollbackFailed(original: original?.path ?? "", current: current.path)
            }
            throw error
        }
    }

    private func sameItem(_ first: URL, _ second: URL) throws -> Bool {
        let a = try FileManager.default.attributesOfItem(atPath: first.path)
        let b = try FileManager.default.attributesOfItem(atPath: second.path)
        return a[.systemNumber] as? NSNumber == b[.systemNumber] as? NSNumber
            && a[.systemFileNumber] as? NSNumber == b[.systemFileNumber] as? NSNumber
    }

    private func exclusiveRename(_ source: URL, _ destination: URL, path: String) throws {
        // Unlike ordinary POSIX rename, RENAME_EXCL cannot overwrite even if a
        // Finder operation creates the destination after our preflight.
        let isFolder = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        guard renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw operationError(path, isFolder: isFolder)
        }
    }

    private func operationError(_ path: String, isFolder: Bool) -> Error {
        let code = errno
        if code == EEXIST {
            let parent = (path as NSString).deletingLastPathComponent
            return LibraryMutationError.collision(path: path, isFolder: isFolder,
                folderName: parent.isEmpty ? root.lastPathComponent : (parent as NSString).lastPathComponent)
        }
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }

    private func joined(_ parent: String, _ name: String) -> String {
        parent.isEmpty ? name : parent + "/" + name
    }
}

extension LibraryMutations {
    /// Preflight performs all body reads on this actor, never in a drag callback.
    /// Keep Both is opt-in; every collision is returned for review before execution.
    public func planMove(_ paths: [String], toFolder destination: String, keepBoth: Bool = false) throws -> MovePlan {
        _ = try directory(destination)
        let paths = MoveSelection.topLevel(paths)
        guard !paths.contains("") else { throw LibraryMutationError.libraryRoot }
        guard MoveSelection.permits(paths, destination: destination) else {
            if let cycle = paths.first(where: { destination == $0 || destination.hasPrefix($0 + "/") }) {
                throw LibraryMutationError.folderCycle(cycle)
            }
            throw MovePlanError.noOp
        }
        let (metadata, _) = try LibraryMetadataStore.load(root: root)
        var changes: [LibraryPathChange] = []
        var collisions: [String] = []
        var reserved = Set<String>()
        let parent = try directory(destination)
        for path in paths {
            let source = try item(path)
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            let folder = values.isDirectory == true
            guard folder || (values.isRegularFile == true && ["md", "markdown"].contains(source.pathExtension.lowercased())) else {
                throw LibraryMutationError.unsupportedItem(path)
            }
            if folder {
                var ancestor = parent
                while true {
                    if try sameItem(source, ancestor) { throw LibraryMutationError.folderCycle(path) }
                    if ancestor.path == root.path { break }
                    ancestor.deleteLastPathComponent()
                }
            }
            guard !(try sameItem(source.deletingLastPathComponent(), parent)) else { throw MovePlanError.noOp }
            let base = source.lastPathComponent
            var name = base
            let ext = folder ? "" : source.pathExtension
            let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
            var number = 2
            func occupied(_ name: String) throws -> Bool {
                try entryExists(parent.appendingPathComponent(name)) || reserved.contains(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
            }
            if try occupied(name) {
                collisions.append(path)
                if keepBoth {
                    repeat {
                        name = try Self.validateName(stem + " \(number)" + (ext.isEmpty ? "" : "." + ext)); number += 1
                    } while try occupied(name)
                }
            }
            reserved.insert(name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil))
            changes.append(LibraryPathChange(id: metadata.IDsByPath[path] ?? UUID(), oldPath: path,
                                            newPath: joined(destination, name), isFolder: folder))
        }
        let changeSet = LibraryChangeSet(changes: changes)
        let inventory = try moveInventory()
        let caseSensitive = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames == true
        var canonicalPaths: [String: String] = [:]
        if !caseSensitive {
            for path in inventory { canonicalPaths[path.precomposedStringWithCanonicalMapping.lowercased()] = path }
        }
        var before: [String: Data] = [:]
        var after: [String: Data] = [:]
        var fingerprints: [String: Data] = [:]
        var newFingerprints: [String: Data] = [:]
        var unreadableDocuments: [String: UnreadableMoveDocument] = [:]
        var unsupported: [UnsupportedMarkdownLink] = []
        for path in inventory.sorted() {
            let candidate = root.appendingPathComponent(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                if changeSet.remapping(path) != path {
                    unsupported.append(UnsupportedMarkdownLink(document: path, syntax: "Symbolic link destination is preserved as written."))
                }
                continue
            }
            guard ["md", "markdown"].contains((path as NSString).pathExtension.lowercased()),
                  !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            let url = try item(path)
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data: Data
            do { data = try Data(contentsOf: url) }
            catch {
                unreadableDocuments[path] = UnreadableMoveDocument(attributes: attributes)
                unsupported.append(UnsupportedMarkdownLink(document: path, syntax: "This document couldn’t be read. Its links can’t be checked and will stay as written."))
                continue
            }
            fingerprints[path] = Data(SHA256.hash(data: data))
            newFingerprints[path] = fingerprints[path]
            guard let text = String(data: data, encoding: .utf8) else {
                unsupported.append(UnsupportedMarkdownLink(document: path, syntax: "This document isn’t UTF-8. Its links can’t be checked and will stay as written."))
                continue
            }
            let result = MarkdownDestinations.rewrite(text, source: path, changes: changeSet, canonicalPaths: canonicalPaths)
            if result.text != text {
                before[path] = data
                let rewritten = Data(result.text.utf8)
                after[path] = rewritten
                newFingerprints[path] = Data(SHA256.hash(data: rewritten))
            } else { newFingerprints[path] = fingerprints[path] }
            unsupported += result.unsupported.map { UnsupportedMarkdownLink(document: path, syntax: $0) }
        }
        return MovePlan(root: root, changes: changeSet, unsupportedLinks: unsupported, collisions: collisions,
                        metadata: metadata, before: before, after: after, fingerprints: fingerprints, newFingerprints: newFingerprints,
                        unreadableDocuments: unreadableDocuments, inventory: inventory)
    }

    /// One commit point for the index; on any error restore rewritten bodies and
    /// reverse all completed renames. An immutable plan also supplies guarded undo.
    public func executeMove(_ plan: MovePlan) throws -> LibraryChangeSet {
        guard plan.root == root, try moveInventory() == plan.inventory,
              try LibraryMetadataStore.load(root: root).0 == plan.metadata else { throw MovePlanError.changed }
        for (path, fingerprint) in plan.fingerprints {
            guard try Data(SHA256.hash(data: Data(contentsOf: item(path)))) == fingerprint else { throw MovePlanError.changed }
        }
        for (path, snapshot) in plan.unreadableDocuments {
            let url = try item(path)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard UnreadableMoveDocument(attributes: attributes) == snapshot,
                  (try? Data(contentsOf: url)) == nil else { throw MovePlanError.changed }
        }
        // Revalidate destinations on the real volume before touching any body.
        for change in plan.changes.changes {
            _ = try item(change.oldPath!)
            let target = try item(change.newPath)
            guard !(try entryExists(target)) else {
                throw LibraryMutationError.collision(path: change.newPath, isFolder: change.isFolder,
                                                     folderName: target.deletingLastPathComponent().lastPathComponent)
            }
        }
        var rewritten: [String] = []
        var moved: [LibraryPathChange] = []
        do {
            for path in plan.before.keys.sorted() where plan.before[path] != plan.after[path] {
                try plan.after[path]!.write(to: item(path), options: .atomic)
                rewritten.append(path)
            }
            for change in plan.changes.changes {
                try exclusiveRename(item(change.oldPath!), item(change.newPath), path: change.newPath)
                moved.append(change)
            }
            try LibraryMetadataStore.save(plan.changes.applying(to: plan.metadata), root: root)
            return plan.changes
        } catch {
            let originalError = error
            var rollbackError: Error?
            for change in moved.reversed() {
                do { try exclusiveRename(item(change.newPath), item(change.oldPath!), path: change.oldPath!) }
                catch { rollbackError = error }
            }
            for path in rewritten {
                // If a reverse rename failed, restore text wherever it survived.
                let current = LibraryChangeSet(changes: moved.filter {
                    !FileManager.default.fileExists(atPath: root.appendingPathComponent($0.oldPath!).path)
                }).remapping(path)
                do { try plan.before[path]!.write(to: item(current), options: .atomic) }
                catch { rollbackError = error }
            }
            if let rollbackError {
                throw LibraryMutationError.rollbackFailed(original: originalError.localizedDescription, current: rollbackError.localizedDescription)
            }
            throw originalError
        }
    }

    private func moveInventory() throws -> Set<String> {
        var result = Set<String>()
        var pending = [(url: root, path: "")]
        while let parent = pending.popLast() {
            for url in try FileManager.default.contentsOfDirectory(at: parent.url, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
                if parent.path.isEmpty && url.lastPathComponent == ".silkweb" { continue }
                let path = joined(parent.path, url.lastPathComponent)
                result.insert(path)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if attributes[.type] as? FileAttributeType == .typeDirectory { pending.append((url, path)) }
            }
        }
        return result
    }
}

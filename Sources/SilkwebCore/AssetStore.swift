import Foundation

public struct AssetInput: Sendable {
    public let name: String
    public let isImage: Bool
    public let file: URL?
    public let data: Data?
    public let alt: String

    public init(name: String, isImage: Bool, file: URL? = nil, data: Data? = nil, alt: String? = nil) {
        self.name = name
        self.isImage = isImage
        self.file = file
        self.data = data
        self.alt = alt ?? (isImage ? (name as NSString).deletingPathExtension : name)
    }
}

public struct StoredAsset: Sendable {
    public let url: URL
    public let path: String
    public let alt: String
    public let isImage: Bool
    public var markdown: String { "\(isImage ? "!" : "")[\(alt)](\(path))" }
}

public struct AssetFailure: Sendable {
    public let name: String
    public let reason: String
    public init(name: String, reason: String) { self.name = name; self.reason = reason }
}

public struct AssetBatch: Sendable {
    public var assets: [StoredAsset] = []
    public var failures: [AssetFailure] = []
    public init() {}
}

/// A single serial executor reserves filenames and publishes only complete files.
/// Assets are retained through undo and are never collected automatically.
public actor AssetStore {
    public static let shared = AssetStore()
    public init() {}

    public func add(_ inputs: [AssetInput], root: URL, document: URL, id: UUID) -> AssetBatch {
        var result = AssetBatch()
        for input in inputs {
            do {
                let root = root.standardizedFileURL
                guard document.standardizedFileURL.path.hasPrefix(root.path + "/") else { throw LibraryMutationError.outsideRoot }
                try LibraryMetadataStore.rejectLink(root)
                let assets = root.appendingPathComponent(".silkweb-assets", isDirectory: true)
                let directory = assets.appendingPathComponent(id.uuidString, isDirectory: true)
                for folder in [assets, directory] {
                    try LibraryMetadataStore.rejectLink(folder)
                    if !FileManager.default.fileExists(atPath: folder.path) {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    }
                    guard try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                        throw LibraryMutationError.unsupportedItem(folder.path)
                    }
                }
                let base = try LibraryMutations.validateName(input.name)
                let ext = (base as NSString).pathExtension
                let stem = ext.isEmpty ? base : (base as NSString).deletingPathExtension
                var name = base
                var number = 2
                while try Self.occupied(directory.appendingPathComponent(name)) {
                    name = try LibraryMutations.validateName(stem + " \(number)" + (ext.isEmpty ? "" : "." + ext))
                    number += 1
                }
                let target = directory.appendingPathComponent(name)
                let staging = directory.appendingPathComponent(".staging-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staging) }
                if let file = input.file {
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryMutationError.unsupportedItem(file.path) }
                    try FileManager.default.copyItem(at: file, to: staging)
                } else if let data = input.data { try data.write(to: staging, options: .atomic) }
                else { throw LibraryMutationError.unsupportedItem(input.name) }
                // moveItem refuses to overwrite a destination created concurrently.
                try FileManager.default.moveItem(at: staging, to: target)
                let parent = document.deletingLastPathComponent().standardizedFileURL.pathComponents
                let destination = target.pathComponents
                var common = 0
                while common < min(parent.count, destination.count), parent[common] == destination[common] { common += 1 }
                let relative = (Array(repeating: "..", count: parent.count - common) + destination.dropFirst(common)).joined(separator: "/")
                result.assets.append(StoredAsset(url: target, path: Self.encodePath(relative), alt: Self.escapeLabel(input.alt), isImage: input.isImage))
            } catch { result.failures.append(AssetFailure(name: input.name, reason: error.localizedDescription)) }
        }
        return result
    }

    private static func occupied(_ url: URL) throws -> Bool {
        do {
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
            return true
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return false
        }
    }

    public static func encodePath(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "()<>#?%\\[]:")
        return path.precomposedStringWithCanonicalMapping.unicodeScalars.map { scalar in
            if scalar.value > 127 && !CharacterSet.whitespacesAndNewlines.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar) { return String(scalar) }
            return String(scalar).addingPercentEncoding(withAllowedCharacters: allowed) ?? String(scalar)
        }.joined()
    }

    private static func escapeLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
    }

    public static func insertion(_ assets: [StoredAsset], text: String, selection: NSRange) -> MarkdownEdit? {
        guard !assets.isEmpty else { return nil }
        let source = text as NSString
        let range = MarkdownEditing.safeRange(selection, in: source)
        let prefix = range.location > 0 && source.character(at: range.location - 1) != 10 ? "\n" : ""
        let end = NSMaxRange(range)
        let suffix = end < source.length && source.character(at: end) == 10 ? "" : "\n"
        let lines = assets.map(\.markdown)
        let replacement = prefix + lines.joined(separator: "\n") + suffix
        var selected = NSRange(location: range.location + replacement.utf16.count, length: 0)
        var offset = range.location + prefix.utf16.count
        for asset in assets {
            if asset.isImage { selected = NSRange(location: offset + 2, length: asset.alt.utf16.count) }
            offset += asset.markdown.utf16.count + 1
        }
        return MarkdownEdit(range: range, replacement: replacement, selection: selected)
    }
}

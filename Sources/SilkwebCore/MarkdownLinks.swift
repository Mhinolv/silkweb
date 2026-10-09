import Foundation

/// A link or image exactly as the renderer reads it, or a reference definition, with UTF-16 source ranges (#176).
/// Code spans, fenced code and escaped syntax never produce one.
public struct MarkdownLink: Equatable, Sendable {
    public enum Kind: String, Sendable {
        case link, image
        /// `[label]: destination`. The renderer shows these as text, so they never resolve (`unsupported`),
        /// but the rename rewrite keeps them pointing at moved items.
        case referenceDefinition
    }

    public let kind: Kind
    /// The whole syntax, from `[` (or `!`) through `)`, or the definition line.
    public let range: NSRange
    /// The destination as written, inside any angle brackets.
    public let destinationRange: NSRange
    /// The text at `destinationRange`: backslash escapes and percent-encoding intact.
    public let written: String
    /// What the renderer links to: `written` with backslash escapes removed.
    public let destination: String
    public let isAngleBracketed: Bool
    public let title: String?
}

/// Every link in a document, plus link-like syntax the renderer shows as text.
public struct MarkdownLinkScan: Sendable {
    public struct Unsupported: Equatable, Sendable {
        public let range: NSRange
        public let syntax: String
    }

    public let links: [MarkdownLink]
    /// Wikilinks, HTML `href`/`src`, malformed or multi-line link syntax outside code. Never resolved.
    public let unsupported: [Unsupported]
}

/// Collects source ranges during `MarkdownParser.parse(_:recorder:)`.
final class MarkdownLinkRecorder {
    var links: [MarkdownLink] = []
    var code: [NSRange] = []

    private static let definition = try! NSRegularExpression(
        pattern: #"^\[(?!\^)[^\]\n]+\]:\s*(?:<([^>\n]*)>|([^\s()]+))(?:\s+(?:"([^"\n]*)"|'([^'\n]*)'))?\s*$"#)

    /// `line` is a block-level line the parser keeps as text because it starts a reference definition.
    func definition(_ line: String, start: Int) {
        let text = (line as NSString).substring(from: MarkdownParser.leadingSpace(line))
        let ns = text as NSString
        guard let match = Self.definition.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return }
        let angled = match.range(at: 1).location != NSNotFound
        let destination = match.range(at: angled ? 1 : 2)
        let title = [3, 4].map { match.range(at: $0) }.first { $0.location != NSNotFound }.map {
            ns.substring(with: $0)
        }
        func shifted(_ range: NSRange) -> NSRange { NSRange(location: range.location + start, length: range.length) }
        let written = ns.substring(with: destination)
        links.append(
            MarkdownLink(
                kind: .referenceDefinition, range: shifted(match.range), destinationRange: shifted(destination),
                written: written, destination: written, isAngleBracketed: angled, title: title))
    }
}

public enum MarkdownLinks {
    private static let candidates = try! NSRegularExpression(
        pattern:
            #"!?\[(?:\\.|[^\]\\\n])*\]\([^\n]*?(?:\)|$)|^ {0,3}\[(?!\^)[^\]\n]+\]:[^\n]*|!?\[\[[^\]\n]+\]\]|<[^>\n]+(?:href|src)\s*=[^>\n]*>"#,
        options: .caseInsensitive)
    private static let delimiters = try! NSRegularExpression(pattern: #"\]\("#)

    /// Parses like the renderer, off the main thread for whole documents.
    public static func scan(_ text: String) -> MarkdownLinkScan {
        let recorder = MarkdownLinkRecorder()
        _ = MarkdownParser.parse(text, recorder: recorder)
        let source = text as NSString
        var links: [MarkdownLink] = []
        var unsupported: [MarkdownLinkScan.Unsupported] = []
        var seen = Set<Int>()
        for link in recorder.links.sorted(by: { $0.range.location < $1.range.location })
        where seen.insert(link.range.location).inserted {
            // Ranges come from the parse; a range that doesn't hold what was parsed is never rewritten.
            let valid = [link.range, link.destinationRange].allSatisfy {
                $0.location >= 0 && NSMaxRange($0) <= source.length
            }
            if valid, source.substring(with: link.destinationRange).utf16.elementsEqual(link.written.utf16) {
                links.append(link)
            } else if valid {
                unsupported.append(.init(range: link.range, syntax: source.substring(with: link.range)))
            }
        }
        // Code ranges are disjoint, as are link ranges, so sorted by start they are sorted by end too.
        let code = recorder.code.sorted { $0.location < $1.location }
        func overlaps(_ ranges: [NSRange], _ range: NSRange) -> Bool {
            // The last range starting before `range` ends is the only one that can reach into it.
            var low = 0
            var high = ranges.count
            while low < high {
                let middle = (low + high) / 2
                if ranges[middle].location < NSMaxRange(range) { low = middle + 1 } else { high = middle }
            }
            return low > 0 && NSIntersectionRange(ranges[low - 1], range).length > 0
        }
        let linkRanges = links.map(\.range)
        func escaped(_ location: Int) -> Bool {
            var offset = location
            var count = 0
            while offset > 0, source.character(at: offset - 1) == 92 { count += 1; offset -= 1 }
            return count % 2 == 1
        }
        // Link-like text outside code that the parser didn't read as a link can't be checked or updated.
        var offset = 0
        while offset < source.length {
            let lineRange = source.lineRange(for: NSRange(location: offset, length: 0))
            offset = NSMaxRange(lineRange)
            var contentsEnd = 0
            source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
            let content = NSRange(location: lineRange.location, length: contentsEnd - lineRange.location)
            let line = source.substring(with: content)
            let full = NSRange(location: 0, length: content.length)
            func absolute(_ range: NSRange) -> NSRange {
                NSRange(location: range.location + content.location, length: range.length)
            }
            let matches = candidates.matches(in: line, range: full).map { absolute($0.range) }
            for match in matches where !overlaps(code, match) && !overlaps(linkRanges, match) {
                // An escaped `!` still leaves a link-shaped `[`.
                let opening = source.character(at: match.location) == 33 ? match.location + 1 : match.location
                if !escaped(opening) {
                    unsupported.append(.init(range: match, syntax: source.substring(with: match)))
                }
            }
            let stray = delimiters.matches(in: line, range: full).map { absolute($0.range) }.contains {
                !overlaps(code, $0) && !escaped($0.location) && !overlaps(linkRanges, $0) && !overlaps(matches, $0)
            }
            if stray { unsupported.append(.init(range: content, syntax: line)) }
        }
        return MarkdownLinkScan(links: links, unsupported: unsupported)
    }
}

/// How a destination resolves in a library. These identifiers are fixed (#175 contract, #176 UX notes).
public enum MarkdownLinkStatus: String, Sendable, CaseIterable, Codable {
    /// Exactly one library item; a Markdown document makes a `links_to` edge (see `MarkdownLinkResolver.linksTo`).
    case resolved
    /// The same document: only a `#fragment`, or nothing.
    case anchor
    /// Inside the library, but no item has that path.
    case missing
    /// Several case- or Unicode-folded matches and no exact spelling.
    case ambiguous
    /// Escapes the library root through `..` or a symbolic link.
    case outsideLibrary
    /// `http(s)`, `mailto:` or an allowed `data:` image.
    case external
    /// Reference definitions, folders, `file:`/absolute paths, blocked schemes, malformed encoding.
    case unsupported
}

public struct MarkdownLinkResolution: Equatable, Sendable {
    public let status: MarkdownLinkStatus
    /// Library-relative. The on-disk spelling when `resolved`; the path as written (decoded, `.`/`..` applied)
    /// when `missing` or `ambiguous`; otherwise nil.
    public let path: String?
    /// The decoded `#fragment`, if any.
    public let fragment: String?
    /// The item `path` names when `resolved`.
    public let item: MarkdownLinkResolver.Item?
    /// Every matching spelling when `ambiguous`, sorted.
    public let candidates: [String]

    init(
        _ status: MarkdownLinkStatus, path: String? = nil, fragment: String? = nil,
        item: MarkdownLinkResolver.Item? = nil, candidates: [String] = []
    ) {
        self.status = status
        self.path = path
        self.fragment = fragment
        self.item = item
        self.candidates = candidates
    }
}

/// A `links_to` edge (#175): a resolved inline link to another Markdown document.
public struct MarkdownLinkEdge: Hashable, Sendable {
    public let target: String
    /// The `#fragment`, kept as the edge's section.
    public let section: String?
}

/// Resolves destinations against one library's items. Pure and `Sendable`: build it off the main thread
/// from a scan, and reuse it for every document.
public struct MarkdownLinkResolver: Sendable {
    public enum Item: Sendable, Equatable {
        case document, file, folder, symbolicLink
    }

    public enum Match: Equatable, Sendable {
        /// The on-disk spelling: byte-exact, or the only Unicode/case-folded match the volume accepts.
        case item(String)
        case ambiguous([String])
        case none
    }

    public let caseSensitive: Bool
    private let items: [String: [(path: String, item: Item)]]
    private let folded: [String: [String]]

    /// `items` maps library-relative paths to what they are. On a case-sensitive volume only the exact
    /// (Unicode-normalised) spelling resolves; several case-folded matches are still reported as ambiguous.
    public init(items: [String: Item], caseSensitive: Bool) {
        self.caseSensitive = caseSensitive
        var byPath: [String: [(path: String, item: Item)]] = [:]
        var folded: [String: [String]] = [:]
        // Swift compares strings by canonical equivalence, so NFC and NFD spellings share a bucket.
        for (path, item) in items {
            byPath[path, default: []].append((path, item))
            folded[Self.fold(path), default: []].append(path)
        }
        self.items = byPath
        self.folded = folded
    }

    /// Documents and folders of a scan. `caseSensitive` defaults to the library volume's rule.
    public init(snapshot: LibrarySnapshot, caseSensitive: Bool? = nil) {
        var items: [String: Item] = [:]
        for folder in snapshot.folders where !folder.relativePath.isEmpty { items[folder.relativePath] = .folder }
        for document in snapshot.documents { items[document.relativePath] = .document }
        self.init(items: items, caseSensitive: caseSensitive ?? snapshot.caseSensitive)
    }

    static func fold(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// The one rule for picking a spelling, shared with `LibrarySnapshot.document(linkedAt:)`.
    static func match(_ path: String, equivalent: [String], folded: [String], caseSensitive: Bool) -> Match {
        if let exact = equivalent.first(where: { $0.utf8.elementsEqual(path.utf8) }) { return .item(exact) }
        if equivalent.count == 1 { return .item(equivalent[0]) }
        if equivalent.count > 1 { return .ambiguous(equivalent.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }) }
        if folded.count > 1 { return .ambiguous(folded.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }) }
        if folded.count == 1, !caseSensitive { return .item(folded[0]) }
        return .none
    }

    public func match(_ path: String) -> Match {
        Self.match(
            path, equivalent: items[path]?.map(\.path) ?? [], folded: folded[Self.fold(path)] ?? [],
            caseSensitive: caseSensitive)
    }

    private func item(_ path: String) -> Item? {
        guard case .item(let spelling) = match(path) else { return nil }
        return items[spelling]?.first { $0.path.utf8.elementsEqual(spelling.utf8) }?.item
    }

    public func resolve(_ link: MarkdownLink, from source: String) -> MarkdownLinkResolution {
        guard link.kind != .referenceDefinition else { return .init(.unsupported) }
        return resolve(link.destination, image: link.kind == .image, from: source)
    }

    /// `destination` as the renderer receives it (escapes removed); `source` is the linking document's path.
    public func resolve(_ destination: String, image: Bool = false, from source: String) -> MarkdownLinkResolution {
        switch HTMLRenderer.destination(destination, image: image) {
        case nil, .file: return .init(.unsupported)
        case .external: return .init(.external)
        case .relative:
            // As the preview builds its URL: Foundation would escape `%` again in a path that mixes raw Unicode
            // and escapes.
            guard let encoded = PreviewResource.encoded(destination),
                let components = URLComponents(string: encoded),
                let decoded = components.percentEncodedPath.removingPercentEncoding
            else { return .init(.unsupported) }
            let fragment = components.percentEncodedFragment.map { $0.removingPercentEncoding ?? $0 }
            if decoded.isEmpty { return .init(.anchor, fragment: fragment) }
            guard let target = Self.join(source, decoded) else { return .init(.outsideLibrary, fragment: fragment) }
            guard !target.isEmpty else { return .init(.unsupported, fragment: fragment) }
            // A symbolic link anywhere along the path leaves the library.
            var prefix = ""
            for component in target.split(separator: "/") {
                prefix += (prefix.isEmpty ? "" : "/") + component
                if item(prefix) == .symbolicLink { return .init(.outsideLibrary, fragment: fragment) }
            }
            switch match(target) {
            case .item(let path):
                let kind = item(path)
                if kind == .folder { return .init(.unsupported, path: path, fragment: fragment) }
                return .init(.resolved, path: path, fragment: fragment, item: kind)
            case .ambiguous(let candidates):
                return .init(.ambiguous, path: target, fragment: fragment, candidates: candidates)
            case .none:
                return .init(.missing, path: target, fragment: fragment)
            }
        }
    }

    /// `decoded` relative to the folder of `source`, with `.`, `..` and empty segments applied; nil above the root.
    static func join(_ source: String, _ decoded: String) -> String? {
        var parts = source.split(separator: "/").dropLast().map(String.init)
        for component in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }

    /// `links_to` edges from `source`, in document order, once per target and section. Images, external,
    /// unresolved and self links, links to other files and reference definitions are not edges.
    public func linksTo(_ scan: MarkdownLinkScan, from source: String) -> [MarkdownLinkEdge] {
        var seen = Set<MarkdownLinkEdge>()
        return scan.links.compactMap { link in
            guard link.kind == .link else { return nil }
            let resolution = resolve(link, from: source)
            guard resolution.status == .resolved, resolution.item == .document, let path = resolution.path,
                !path.utf8.elementsEqual(source.utf8)
            else { return nil }
            let edge = MarkdownLinkEdge(target: path, section: resolution.fragment)
            return seen.insert(edge).inserted ? edge : nil
        }
    }
}

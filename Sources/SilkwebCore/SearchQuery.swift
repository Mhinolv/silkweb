import Foundation

public struct SearchQuery: Sendable {
    public enum Scope: Sendable { case library, folder(UUID, includeSubfolders: Bool) }
    public enum Mode: Sendable { case library, quickOpen }
    public var text: String
    public var scope: Scope
    public var mode: Mode
    public var limit: Int
    /// Library mode (#179): BM25 inputs from the knowledge index. Without them results keep the title tiers.
    public var ranking: KnowledgeTermStatistics?
    /// Library mode: the Tags `tag:` matches. Without it no Document carries a Tag.
    public var metadata: LibraryMetadata?

    public init(
        _ text: String, scope: Scope = .library, mode: Mode = .library, limit: Int = 100,
        ranking: KnowledgeTermStatistics? = nil, metadata: LibraryMetadata? = nil
    ) {
        self.text = text
        self.scope = scope
        self.mode = mode
        self.limit = limit
        self.ranking = ranking
        self.metadata = metadata
    }
}

/// The query syntax shared by Search Library and the helper's ranked `memory_search` (#179): free words,
/// `"phrases"` and `key:value` filters. Keys are case-insensitive, values may be quoted, repeated keys are OR'd
/// and different keys AND'd. Nothing is ever an error: unknown keys, empty values, bad dates and an unclosed
/// quote are literal words. #32 adds `folder:`, negation and grammar help on top of this.
public struct ParsedSearchQuery: Equatable, Sendable {
    public static let keys: Set<String> = ["tag", "type", "status", "project", "after", "before"]

    /// Free words as typed, in order; each must appear in the title or body.
    public private(set) var words: [String] = []
    /// Phrases as typed, inner whitespace collapsed; their words must appear adjacent.
    public private(set) var phrases: [String] = []
    public private(set) var tags: [String] = []
    public private(set) var types: [String] = []
    public private(set) var statuses: [String] = []
    public private(set) var projects: [String] = []
    /// Inclusive: the earliest of repeated `after:` values.
    public private(set) var after: Date?
    /// Exclusive: the latest of repeated `before:` values.
    public private(set) var before: Date?
    /// Words and phrases in typed order, for the exact-title rule and highlighting.
    public private(set) var free: [String] = []
    private(set) var foldedWords: [String] = []
    private(set) var foldedPhrases: [String] = []
    /// Each folded phrase's words as UTF-8, for the byte matcher.
    private var phraseBytes: [[[UInt8]]] = []

    public init(_ text: String) {
        defer {
            foldedWords = words.map {
                var word = searchFold($0); word.makeContiguousUTF8(); return word
            }
            foldedPhrases = phrases.map(searchFold)
            phraseBytes = foldedPhrases.map { $0.split(separator: " ").map { Array($0.utf8) } }
        }
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            if characters[index].isWhitespace {
                index += 1
                continue
            }
            if characters[index] == "\"" {
                guard let close = characters[(index + 1)...].firstIndex(of: "\"") else {
                    literal(characters[index...])
                    return
                }
                let phrase = Self.collapse(String(characters[(index + 1)..<close]))
                if phrase.isEmpty {
                    add(word: String(characters[index...close]))
                } else {
                    phrases.append(phrase)
                    free.append(phrase)
                }
                index = close + 1
                continue
            }
            var end = index
            while end < characters.count, !characters[end].isWhitespace { end += 1 }
            let token = String(characters[index..<end])
            if let colon = token.firstIndex(of: ":"), Self.keys.contains(token[..<colon].lowercased()) {
                var value = String(token[token.index(after: colon)...])
                if value.hasPrefix("\"") {
                    // A quoted value may hold spaces: `project:"Side Work"`.
                    let open = index + token.distance(from: token.startIndex, to: colon) + 1
                    guard let close = characters[(open + 1)...].firstIndex(of: "\"") else {
                        literal(characters[index...])
                        return
                    }
                    value = Self.collapse(String(characters[(open + 1)..<close]))
                    end = close + 1
                }
                if value.isEmpty || !filter(token[..<colon].lowercased(), value) {
                    add(word: String(characters[index..<end]))
                }
                index = end
                continue
            }
            add(word: token)
            index = end
        }
    }

    /// An unclosed quote: the rest of the query is plain words, quote characters included.
    private mutating func literal(_ rest: ArraySlice<Character>) {
        for word in String(rest).split(whereSeparator: \.isWhitespace) { add(word: String(word)) }
    }

    private mutating func add(word: String) {
        words.append(word)
        free.append(word)
    }

    /// False when the value can't be a filter (a bad date), so the token stays a word.
    private mutating func filter(_ key: String, _ value: String) -> Bool {
        switch key {
        case "tag": tags.append(value)
        case "type": types.append(value)
        case "status": statuses.append(value)
        case "project": projects.append(value)
        case "after":
            guard let date = AgentMemorySearchRequest.date(value) else { return false }
            after = min(after ?? date, date)
        case "before":
            guard let date = AgentMemorySearchRequest.date(value) else { return false }
            before = max(before ?? date, date)
        default: return false
        }
        return true
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Words or phrases. Without them the filters alone list every Document that passes them.
    public var hasText: Bool { !free.isEmpty }

    public var hasFilters: Bool {
        !tags.isEmpty || !types.isEmpty || !statuses.isEmpty || !projects.isEmpty || after != nil || before != nil
    }

    /// Folded free text in typed order: an exact title match ranks first.
    public var foldedText: String { searchFold(free.joined(separator: " ")) }

    /// What results highlight: words and phrases (a phrase as one range), never filter keys or values.
    public var highlightTerms: [String] { free }

    /// The text to find in an opened Document: the first phrase, otherwise the free words; nil for filters only.
    public var findText: String? {
        phrases.first ?? (words.isEmpty ? nil : words.joined(separator: " "))
    }

    /// BM25 query tokens (`KnowledgeTokenizer`), each once, in typed order.
    public var rankingTerms: [String] {
        var seen = Set<String>()
        return free.flatMap(KnowledgeTokenizer.tokens).filter { seen.insert($0).inserted }
    }

    /// Words and phrases against a folded title and body. Words match anywhere, as in #134; a phrase's
    /// words must be adjacent, separated only by whitespace.
    public func matchesText(title: String, body: String) -> Bool {
        foldedWords.allSatisfy { searchContains(title, $0) || searchContains(body, $0) }
            && phraseBytes.allSatisfy { Self.contains(title, parts: $0) || Self.contains(body, parts: $0) }
    }

    /// Every word and phrase is in the folded title.
    public func matchesTitle(_ title: String) -> Bool {
        hasText && foldedWords.allSatisfy { searchContains(title, $0) }
            && phraseBytes.allSatisfy { Self.contains(title, parts: $0) }
    }

    /// `phrase` (folded, single spaces) in folded `text`, where any run of whitespace separates its words.
    static func contains(_ text: String, phrase: String) -> Bool {
        contains(text, parts: phrase.split(separator: " ").map { Array($0.utf8) })
    }

    /// A phrase's words as UTF-8, adjacent in `text`.
    static func contains(_ text: String, parts: [[UInt8]]) -> Bool {
        guard let first = parts.first else { return true }
        var text = text
        return text.withUTF8 { bytes in
            // Every word must be there before the adjacency walk runs.
            guard parts.allSatisfy({ find($0, in: bytes, from: 0) != nil }) else { return false }
            var start = 0
            while let hit = find(first, in: bytes, from: start) {
                var cursor = hit + first.count
                var matched = true
                for part in parts.dropFirst() {
                    let next = skipWhitespace(bytes, from: cursor)
                    guard next > cursor, next + part.count <= bytes.count,
                        part.indices.allSatisfy({ bytes[next + $0] == part[$0] })
                    else {
                        matched = false
                        break
                    }
                    cursor = next + part.count
                }
                if matched { return true }
                start = hit + 1
            }
            return false
        }
    }

    /// The offset of `needle` in `bytes` at or after `start`.
    private static func find(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard start <= bytes.count, let base = bytes.baseAddress else { return needle.isEmpty ? start : nil }
        return needle.withUnsafeBytes { pattern in
            memmem(base + start, bytes.count - start, pattern.baseAddress, pattern.count).map {
                base.distance(to: $0.assumingMemoryBound(to: UInt8.self))
            }
        }
    }

    /// The offset after the whitespace scalars starting at `offset` in valid UTF-8.
    private static func skipWhitespace(_ bytes: UnsafeBufferPointer<UInt8>, from offset: Int) -> Int {
        var offset = offset
        while offset < bytes.count {
            let lead = bytes[offset]
            let length = lead < 0x80 ? 1 : lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : 2
            guard offset + length <= bytes.count else { break }
            var value = UInt32(length == 1 ? lead : lead & (0xFF >> (length + 1)))
            for index in 1..<length { value = value << 6 | UInt32(bytes[offset + index] & 0x3F) }
            guard let scalar = Unicode.Scalar(value), scalar.properties.isWhitespace else { break }
            offset += length
        }
        return offset
    }

    /// The envelope and date filters, with the #134 rules: `type:`/`status:` drop Documents without one;
    /// `project:` keeps the envelope's project, or a Document without one inside that project's Folder (like
    /// `memory_search`'s `project`); dates compare `created_at`, else the modified date. Types and statuses
    /// ignore case.
    public func admits(
        type: String?, status: String?, project: String?, path: String, date: Date?, caseSensitive: Bool = false
    ) -> Bool {
        if !types.isEmpty, !types.contains(where: { $0.lowercased() == type?.lowercased() }) { return false }
        if !statuses.isEmpty, !statuses.contains(where: { $0.lowercased() == status?.lowercased() }) { return false }
        if !projects.isEmpty {
            let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            let admitted = projects.contains { wanted in
                if let project { return project.compare(wanted, options: options) == .orderedSame }
                return AgentScope.contains(AgentMemoryContract.projectRoot(wanted), path, caseSensitive: caseSensitive)
            }
            if !admitted { return false }
        }
        if after != nil || before != nil {
            guard let date else { return false }
            if let after, date < after { return false }
            if let before, date >= before { return false }
        }
        return true
    }

    /// `tag:` against the names of a Document's Tags, ignoring case like the Tag editor.
    public func admits(tags names: Set<String>) -> Bool {
        tags.isEmpty
            || tags.contains { wanted in
                names.contains { $0.compare(wanted, options: .caseInsensitive) == .orderedSame }
            }
    }
}

public struct SearchResult: Identifiable, Equatable, Sendable {
    public enum MatchKind: String, Sendable { case title, body }
    public let id: UUID
    public let displayName: String
    public let folderPathComponents: [String]
    public let modified: Date?
    public let matchKind: MatchKind
    public let snippet: String
    /// UTF-16 offsets into snippet, suitable for attributed text; never pre-styled.
    public let matchRanges: [NSRange]
}

public enum SearchIndexState: Equatable, Sendable {
    public enum RebuildReason: Equatable, Sendable { case corrupt, unsupportedVersion }
    case building(indexed: Int, total: Int)
    case rebuilding(reason: RebuildReason)
    case ready
}

// Fixed locale makes matching and ranking independent of the user's system locale.
func searchFold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
}

/// Byte search over folded UTF-8, as `memory_search` does: `String.contains` bridges to `NSString` and is far
/// slower on 10,000 bodies.
func searchContains(_ haystack: String, _ needle: String) -> Bool {
    var haystack = haystack
    var needle = needle
    return needle.withUTF8 { pattern in
        haystack.withUTF8 { bytes in
            pattern.isEmpty || memmem(bytes.baseAddress, bytes.count, pattern.baseAddress, pattern.count) != nil
        }
    }
}

func searchSnippet(_ body: String, terms: [String]) -> (String, [NSRange]) {
    let clean = body.filter { !"#*`".contains($0) }.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    let full = clean as NSString
    let options: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    let first = terms.map { full.range(of: $0, options: options) }.filter { $0.location != NSNotFound }
        .min { $0.location < $1.location }
    let start = max(0, (first?.location ?? 0) - 40)
    let range = full.rangeOfComposedCharacterSequences(
        for: NSRange(location: start, length: min(120, full.length - start)))
    let snippet =
        (range.location > 0 ? "…" : "") + full.substring(with: range)
        + (NSMaxRange(range) < full.length ? "…" : "")
    let text = snippet as NSString
    var matches: [NSRange] = []
    for term in terms where !term.isEmpty {
        var cursor = 0
        while cursor < text.length {
            let hit = text.range(
                of: term, options: options, range: NSRange(location: cursor, length: text.length - cursor))
            guard hit.location != NSNotFound else { break }
            matches.append(hit)
            cursor = NSMaxRange(hit)
        }
    }
    return (snippet, Array(Set(matches)).sorted { $0.location < $1.location })
}

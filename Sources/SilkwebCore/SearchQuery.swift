import Foundation

public struct SearchQuery: Sendable {
    public enum Scope: Sendable { case library, folder(UUID, includeSubfolders: Bool) }
    public enum Mode: Sendable { case library, quickOpen }
    public var text: String
    public var scope: Scope
    public var mode: Mode
    public var limit: Int

    public init(_ text: String, scope: Scope = .library, mode: Mode = .library, limit: Int = 100) {
        self.text = text
        self.scope = scope
        self.mode = mode
        self.limit = limit
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

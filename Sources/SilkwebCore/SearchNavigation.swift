import Foundation

public enum SearchNavigation {
    /// Keep a surviving selection when refreshed hits reorder or change snippets.
    public static func selection(_ selected: UUID?, in results: [SearchResult]) -> UUID? {
        selected.flatMap { id in results.contains { $0.id == id } ? id : nil } ?? results.first?.id
    }

    /// Wrap selection without indexing an empty result set.
    public static func nextIndex(current: Int?, count: Int, delta: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return delta < 0 ? count - 1 : 0 }
        let offset = delta % count
        if offset >= 0 {
            return current >= count - offset ? current - (count - offset) : current + offset
        }
        return current < -offset ? count + offset + current : current + offset
    }

    public static func matchRanges(in text: String, query: String) -> [NSRange] {
        let source = text as NSString
        var ranges: [NSRange] = []
        for term in query.split(whereSeparator: { $0.isWhitespace }) {
            var cursor = 0
            while cursor < source.length {
                let range = source.range(
                    of: String(term), options: [.caseInsensitive, .diacriticInsensitive],
                    range: NSRange(location: cursor, length: source.length - cursor))
                guard range.location != NSNotFound, range.length > 0 else { break }
                ranges.append(range)
                cursor = NSMaxRange(range)
            }
        }
        return ranges
    }
}

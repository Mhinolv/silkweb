import Foundation

/// What BM25 needs from a knowledge index for one query: the postings of the query's tokens and every indexed
/// Document's field lengths, by Library-relative path. Taking only the query's postings keeps the copy small.
public struct KnowledgeTermStatistics: Equatable, Sendable {
    /// Term → path → per-field frequency.
    public var postings: [String: [String: KnowledgePosting]]
    /// Token counts per field, per indexed path.
    public var lengths: [String: KnowledgePosting]

    public init(postings: [String: [String: KnowledgePosting]] = [:], lengths: [String: KnowledgePosting] = [:]) {
        self.postings = postings
        self.lengths = lengths
    }
}

extension KnowledgeGraph {
    /// Postings for `terms` and all field lengths. Documents not read yet have neither and score zero.
    public func termStatistics(for terms: [String]) -> KnowledgeTermStatistics {
        var selected: [String: [String: KnowledgePosting]] = [:]
        for term in terms { selected[term] = postings[term] }
        return KnowledgeTermStatistics(postings: selected, lengths: lengths)
    }
}

/// Field-weighted BM25 (BM25F, #179; `knowledge-graph-retrieval.md` › Ranking signals). Each field's term
/// frequency is normalized by that field's length against its average, weighted (title 3, heading 2, body 1)
/// and summed before saturation. Statistics — the Document count, document frequencies and average lengths —
/// come from `candidates` alone (scope-local IDF): nothing outside them changes a score.
public enum KnowledgeBM25 {
    public static let k1 = 1.2
    public static let b = 0.75
    public static let weights = (title: 3.0, heading: 2.0, body: 1.0)
    /// Reported by ranked responses; changes with any weight or formula change.
    public static let rankingVersion = "bm25f-1"

    /// Scores of the `candidates` (paths) that hold at least one term; absent paths score zero. Candidates
    /// the index hasn't read yet don't count towards the statistics.
    public static func scores(
        terms: [String], candidates: some Sequence<String>, statistics: KnowledgeTermStatistics
    ) -> [String: Double] {
        var documents = 0
        var total = (title: 0, heading: 0, body: 0)
        var indexed = Set<String>()
        for path in candidates {
            guard let length = statistics.lengths[path], indexed.insert(path).inserted else { continue }
            documents += 1
            total.title += length.title
            total.heading += length.heading
            total.body += length.body
        }
        guard documents > 0 else { return [:] }
        let count = Double(documents)
        let average = (
            title: Double(total.title) / count, heading: Double(total.heading) / count,
            body: Double(total.body) / count
        )
        func normalized(_ frequency: Int, _ length: Int, _ average: Double) -> Double {
            guard frequency > 0, average > 0 else { return 0 }
            return Double(frequency) / (1 - b + b * Double(length) / average)
        }
        var scores: [String: Double] = [:]
        var seen = Set<String>()
        for term in terms where seen.insert(term).inserted {
            let postings = (statistics.postings[term] ?? [:]).filter { indexed.contains($0.key) }
            guard !postings.isEmpty else { continue }
            let frequency = Double(postings.count)
            let idf = log(1 + (count - frequency + 0.5) / (frequency + 0.5))
            for (path, posting) in postings {
                let length = statistics.lengths[path] ?? KnowledgePosting()
                let weighted =
                    weights.title * normalized(posting.title, length.title, average.title)
                    + weights.heading * normalized(posting.heading, length.heading, average.heading)
                    + weights.body * normalized(posting.body, length.body, average.body)
                guard weighted > 0 else { continue }
                scores[path, default: 0] += idf * weighted * (k1 + 1) / (weighted + k1)
            }
        }
        return scores
    }
}

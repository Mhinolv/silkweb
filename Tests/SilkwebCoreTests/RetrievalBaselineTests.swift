import Darwin
import Foundation
import XCTest

@testable import SilkwebCore

/// #175: the knowledge-graph golden set and the frozen #134 `memory_search` baseline
/// (`docs/knowledge-graph-retrieval.md` › Evaluation set, Baseline). The fixture library is generated
/// in a temporary folder from `docs/knowledge-graph-eval/library.json`; `Test_Library/` is never used.
///
/// The ranked paths and totals in `baseline-134.json` are compared exactly, so a change to the default
/// `memory_search` ranking fails here. Latency and resource figures are recorded, never compared.
/// To re-record (only with a contract change, never to tune), delete or empty `baseline-134.json` and run
/// `./scripts/build.sh test --filter RetrievalBaselineTests`: it writes a new file and fails once.
final class RetrievalBaselineTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    private static let fixtures = repository.appendingPathComponent("docs/knowledge-graph-eval")
    private static let baselineURL = fixtures.appendingPathComponent("baseline-134.json")

    static let categories = [
        "exact", "paraphrase", "multi-hop", "supersession", "malformed-metadata", "injection-neighbor",
        "scope-leak", "unanswerable",
    ]
    static let splits = ["dev", "heldout"]
    /// Results requested per query: enough for Recall@20 and for the leak check beyond it.
    static let requestLimit = 50
    static let warmRuns = 5

    // MARK: Fixture formats (version 1, sorted keys)

    struct Library: Decodable {
        struct Grant: Decodable {
            var extraReadFolders: [String]
            private enum CodingKeys: String, CodingKey { case extraReadFolders = "extra_read_folders" }
        }
        struct Document: Decodable {
            var path: String
            var text: String
            var modified: String
            var review: String?
            var pinned: Bool?
            var canary: String?
            /// Relevant-looking text that carries instructions for agents.
            var injection: Bool?
        }
        var version: Int
        var project: String
        var grants: [String: Grant]
        var documents: [Document]
    }

    struct GoldenSet: Decodable {
        struct Query: Decodable {
            var id: String
            var query: String
            var category: String
            var grant: String
            var expected: [String]
            var forbidden: [String]
        }
        var version: Int
        var split: String
        var library: String
        var queries: [Query]
    }

    private func load<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent(name)))
    }

    private func goldenSets() throws -> [GoldenSet] {
        try Self.splits.map { try load(GoldenSet.self, "\($0).json") }
    }

    /// Read folders of a fixture grant: the default project folder plus its extra read folders.
    private func readRoots(_ library: Library, grant: String) -> [String] {
        ["Memory/Projects/\(library.project)"] + (library.grants[grant]?.extraReadFolders ?? [])
    }

    /// The scope rule the fixture expects (`agent-memory.md` › Grants): per path component, no hidden items.
    private func readable(_ path: String, roots: [String]) -> Bool {
        let components = path.split(separator: "/")
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        return roots.contains { root in
            let prefix = root.split(separator: "/")
            return components.count > prefix.count && Array(components.prefix(prefix.count)) == prefix
        }
    }

    // MARK: Golden set

    func testGoldenSetIsWellFormed() throws {
        let library = try load(Library.self, "library.json")
        XCTAssertEqual(library.version, 1)
        let paths = library.documents.map(\.path)
        XCTAssertEqual(Set(paths).count, paths.count, "document paths are unique")
        for path in paths {
            XCTAssertTrue(path.hasSuffix(".md") && !path.hasPrefix("/") && !path.contains(".."), path)
        }
        XCTAssertGreaterThanOrEqual(library.documents.count, 60)

        // Every document outside a grant carries a canary that no readable document repeats, so a
        // leaked excerpt is detectable even when its path isn't.
        let everyRoot = library.grants.keys.flatMap { readRoots(library, grant: $0) }
        let defaultRoots = readRoots(library, grant: "harbor")
        for document in library.documents where !readable(document.path, roots: defaultRoots) {
            let canary = try XCTUnwrap(document.canary, "\(document.path) needs a canary")
            for other in library.documents where readable(other.path, roots: defaultRoots) {
                XCTAssertFalse(other.text.contains(canary), "\(other.path) repeats \(canary)")
            }
        }
        XCTAssertTrue(library.documents.contains { !readable($0.path, roots: everyRoot) })

        let sets = try goldenSets()
        var ids = Set<String>()
        var perSplit: [String: [String: Int]] = [:]
        for set in sets {
            XCTAssertEqual(set.version, 1)
            XCTAssertEqual(set.library, "library.json")
            for query in set.queries {
                XCTAssertTrue(ids.insert(query.id).inserted, "duplicate id \(query.id)")
                XCTAssertTrue(Self.categories.contains(query.category), query.id)
                XCTAssertTrue(query.id.hasPrefix(query.category + "-"), query.id)
                XCTAssertFalse(query.query.trimmingCharacters(in: .whitespaces).isEmpty, query.id)
                XCTAssertNotNil(library.grants[query.grant], query.id)
                let roots = readRoots(library, grant: query.grant)
                for path in query.expected {
                    XCTAssertTrue(paths.contains(path), "\(query.id): \(path) isn't in the fixture")
                    XCTAssertTrue(readable(path, roots: roots), "\(query.id): expected \(path) is out of scope")
                }
                for path in query.forbidden {
                    XCTAssertTrue(paths.contains(path), "\(query.id): \(path) isn't in the fixture")
                    XCTAssertFalse(readable(path, roots: roots), "\(query.id): forbidden \(path) is in scope")
                }
                XCTAssertEqual(Set(query.expected).count, query.expected.count, query.id)
                switch query.category {
                case "unanswerable": XCTAssertEqual(query.expected, [], query.id)
                case "scope-leak": XCTAssertFalse(query.forbidden.isEmpty, query.id)
                default: XCTAssertFalse(query.expected.isEmpty, query.id)
                }
                if query.category == "multi-hop" { XCTAssertGreaterThanOrEqual(query.expected.count, 2, query.id) }
                perSplit[set.split, default: [:]][query.category, default: 0] += 1
            }
        }
        XCTAssertEqual(sets.map(\.split), Self.splits)
        XCTAssertEqual(ids.count, 200, "about 200 queries")
        for category in Self.categories {
            let dev = perSplit["dev"]?[category] ?? 0
            let heldout = perSplit["heldout"]?[category] ?? 0
            XCTAssertGreaterThan(heldout, 0, "\(category) has held-out queries")
            XCTAssertGreaterThan(dev, heldout, "\(category): development is the larger split")
        }
    }

    // MARK: Baseline

    /// One query's raw outcome: ranked paths (top 20), the in-scope total, and the median warm latency.
    struct QueryRun: Codable, Equatable {
        var results: [String]
        var total: Int
        var latencyMS: Double

        private enum CodingKeys: String, CodingKey { case results, total, latencyMS = "latency_ms" }
    }

    /// Metrics for one category or a whole split. Rates are 0…1, rounded to three places.
    struct Summary: Codable, Equatable {
        var queries: Int
        /// Queries with expected evidence; Recall, MRR and completion average over these.
        var answerable: Int
        var recallAt5: Double?
        var recallAt10: Double?
        var recallAt20: Double?
        var mrrAt10: Double?
        /// Every expected document in the top 10.
        var evidenceComplete: Double?
        /// Queries that returned no results (the right outcome for `unanswerable`).
        var emptyResults: Int
        /// Forbidden or out-of-grant paths, or out-of-grant canaries, in any returned result.
        var leaks: Int
        /// Answerable queries where an `injection` document ranks above the first expected document.
        var injectionAboveEvidence: Int
        var latencyP50MS: Double
        var latencyP95MS: Double

        private enum CodingKeys: String, CodingKey {
            case queries, answerable, recallAt5 = "recall_at_5", recallAt10 = "recall_at_10",
                recallAt20 = "recall_at_20", mrrAt10 = "mrr_at_10", evidenceComplete = "evidence_complete",
                emptyResults = "empty_results", leaks,
                injectionAboveEvidence = "injection_above_evidence", latencyP50MS = "latency_p50_ms", latencyP95MS =
                "latency_p95_ms"
        }

        /// The fields compared against the recorded baseline: everything except latency.
        var deterministic: Summary {
            var copy = self
            copy.latencyP50MS = 0
            copy.latencyP95MS = 0
            return copy
        }
    }

    struct Baseline: Codable {
        var version = 1
        var retrieval = "memory_search contract_version 1 (#134 lexical, default request)"
        var goldenSetVersion = 1
        /// The envelope reading outcome per fixture document: `envelope`, `missing` or an `error.code`.
        var envelopes: [String: String]
        var queries: [String: QueryRun]
        var summary: [String: [String: Summary]]
        var resources: [String: String]

        private enum CodingKeys: String, CodingKey {
            case version, retrieval, goldenSetVersion = "golden_set_version", envelopes, queries, summary, resources
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RetrievalBaseline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes the fixture library with fixed modification dates (documents without an envelope rank by them).
    private func materialize(_ library: Library) throws -> URL {
        let folder = root.appendingPathComponent("Writing")
        for document in library.documents {
            let url = folder.appendingPathComponent(document.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(document.text.utf8).write(to: url)
            let modified = try XCTUnwrap(AgentMemorySearchRequest.date(document.modified), document.path)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return folder
    }

    /// One helper session per fixture grant, with review state from the fixture. Rate limits are lifted so
    /// the warm runs measure search, not the limiter.
    private func session(_ library: Library, grant: String, folder: URL) throws -> AgentSession {
        let grantsURL = root.appendingPathComponent("grants/\(grant).json")
        try AgentGrantFile(grants: [
            AgentGrant(
                project: library.project, library: LibraryLocation(path: folder.path), access: .read,
                extraReadFolders: library.grants[grant]?.extraReadFolders ?? [], label: "Harbor project",
                limits: AgentGrantLimits(requestsPerMinute: 1_000_000))
        ]).write(to: grantsURL)
        return AgentSession(project: library.project, store: AgentGrantStore(url: grantsURL))
    }

    private func reviews(_ library: Library) -> AgentMemoryReviewLookup {
        var hints: [String: AgentMemoryReviewHint] = [:]
        for document in library.documents where document.review != nil || document.pinned == true {
            let revision: String? =
                switch document.review {
                case "reviewed": AgentMemoryIndex.revision(Data(document.text.utf8))
                case "reviewed-earlier-revision": "sha256:" + String(repeating: "0", count: 64)
                default: nil
                }
            hints[document.path] = AgentMemoryReviewHint(reviewedRevision: revision, pinned: document.pinned == true)
        }
        let lookup = hints
        return { _, path in lookup[path] }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) * 1000 + Double(attoseconds) / 1e15
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(max(rank, 0), sorted.count - 1)]
    }

    private static func round3(_ value: Double) -> Double { (value * 1000).rounded() / 1000 }
    private static func round2(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    func testRecordsMemorySearchBaselineOnTheGoldenSet() throws {
        let library = try load(Library.self, "library.json")
        let sets = try goldenSets()
        let folder = try materialize(library)
        let lookup = reviews(library)
        let clock = ContinuousClock()

        var resources: [String: String] = [
            "documents": String(library.documents.count),
            "fixture_bytes": String(library.documents.reduce(0) { $0 + $1.text.utf8.count }),
            "processors": String(ProcessInfo.processInfo.activeProcessorCount),
            "memory_gb": String(ProcessInfo.processInfo.physicalMemory / 1_073_741_824),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "warm_runs_per_query": String(Self.warmRuns),
        ]
        var model = [CChar](repeating: 0, count: 64)
        var size = model.count
        if sysctlbyname("hw.model", &model, &size, nil, 0) == 0 { resources["machine"] = String(cString: model) }

        var services: [String: AgentMemoryService] = [:]
        var components: [String: [String: [Double]]] = [:]
        var probes: [String: (AgentSession, AgentMemoryIndex)] = [:]
        for grant in library.grants.keys.sorted() {
            let session = try session(library, grant: grant, folder: folder)
            let service = AgentMemoryService(
                session: session, cacheDirectory: root.appendingPathComponent("cache-\(grant)"), reviews: lookup)
            let start = clock.now
            let first = try service.search(AgentMemorySearchRequest(limit: Self.requestLimit))
            resources["cold_build_ms.\(grant)"] = String(Self.round2(Self.milliseconds(clock.now - start)))
            XCTAssertEqual(first.index.state, .ready, grant)
            let cacheBytes = (try? FileManager.default.attributesOfItem(atPath: service.cacheURL.path)[.size]) as? Int
            resources["cache_bytes.\(grant)"] = String(cacheBytes ?? 0)
            services[grant] = service
            // A second, private index over the same scope times the stages of one search separately.
            let context = try session.authorize(.search)
            let index = AgentMemoryIndex(
                url: root.appendingPathComponent("probe-\(grant).json"), library: context.library.path,
                project: library.project)
            _ = index.refresh(context, options: AgentMemoryIndexOptions())
            probes[grant] = (session, index)
        }

        var runs: [String: QueryRun] = [:]
        var leaks: [String: Int] = [:]
        for query in sets.flatMap(\.queries) {
            let service = try XCTUnwrap(services[query.grant])
            let request = AgentMemorySearchRequest(query: query.query, limit: Self.requestLimit)
            var response = try service.search(request)
            var samples: [Double] = []
            for _ in 0..<Self.warmRuns {
                let start = clock.now
                response = try service.search(request)
                samples.append(Self.milliseconds(clock.now - start))
            }
            let (session, index) = try XCTUnwrap(probes[query.grant])
            var start = clock.now
            let context = try session.authorize(.search)
            components["authorize", default: [:]][query.grant, default: []].append(
                Self.milliseconds(clock.now - start))
            start = clock.now
            let freshness = index.refresh(context, options: AgentMemoryIndexOptions())
            components["refresh", default: [:]][query.grant, default: []].append(Self.milliseconds(clock.now - start))
            start = clock.now
            _ = try index.search(request, context: context, freshness: freshness, reviews: lookup)
            components["rank", default: [:]][query.grant, default: []].append(Self.milliseconds(clock.now - start))

            // Leaks: a forbidden or out-of-grant path, or an out-of-grant canary in any title or excerpt.
            let roots = readRoots(library, grant: query.grant)
            let canaries = library.documents.filter { !readable($0.path, roots: roots) }.compactMap(\.canary)
            leaks[query.id] =
                response.results.filter { result in
                    query.forbidden.contains(result.document.path) || !readable(result.document.path, roots: roots)
                        || canaries.contains { result.excerpt.contains($0) || result.document.title.contains($0) }
                }.count
            runs[query.id] = QueryRun(
                results: response.results.prefix(20).map(\.document.path), total: response.total,
                latencyMS: Self.round3(Self.percentile(samples, 0.5)))
        }
        for (stage, byGrant) in components {
            for (grant, samples) in byGrant {
                resources["\(stage)_p50_ms.\(grant)"] = String(Self.round3(Self.percentile(samples, 0.5)))
            }
        }
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        resources["peak_rss_mb_test_process"] = String(Int(usage.ru_maxrss) / 1_048_576)

        // Scope is a hard rule, not a metric to improve: zero leaks on every query.
        XCTAssertEqual(leaks.values.reduce(0, +), 0, "scope leaks: \(leaks.filter { $0.value > 0 })")

        let injections = Set(library.documents.filter { $0.injection == true }.map(\.path))
        var summary: [String: [String: Summary]] = [:]
        for set in sets {
            var groups = Dictionary(grouping: set.queries, by: \.category)
            groups["overall"] = set.queries
            for (category, queries) in groups {
                summary[set.split, default: [:]][category] = summarize(
                    queries, runs: runs, leaks: leaks, injections: injections)
            }
        }
        var envelopes: [String: String] = [:]
        for document in library.documents {
            switch MemoryEnvelope.parse(document.text) {
            case .missing: envelopes[document.path] = "missing"
            case .envelope: envelopes[document.path] = "envelope"
            case .failure(let error): envelopes[document.path] = error.code
            }
        }
        let current = Baseline(envelopes: envelopes, queries: runs, summary: summary, resources: resources)
        print(Self.table(summary))

        let saved = (try? Data(contentsOf: Self.baselineURL)) ?? Data()
        guard !saved.isEmpty else {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try (encoder.encode(current) + Data("\n".utf8)).write(to: Self.baselineURL, options: .atomic)
            XCTFail("Recorded \(Self.baselineURL.lastPathComponent). Review it, update the contract table, run again.")
            return
        }
        let recorded = try JSONDecoder().decode(Baseline.self, from: saved)
        XCTAssertEqual(recorded.version, 1)
        XCTAssertEqual(recorded.envelopes, current.envelopes, "fixture envelope outcomes changed")
        XCTAssertEqual(Set(recorded.queries.keys), Set(current.queries.keys))
        for (id, run) in current.queries.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(recorded.queries[id]?.results, run.results, "\(id): ranked results changed")
            XCTAssertEqual(recorded.queries[id]?.total, run.total, "\(id): total changed")
        }
        for (split, categories) in current.summary {
            for (category, metrics) in categories {
                XCTAssertEqual(
                    recorded.summary[split]?[category]?.deterministic, metrics.deterministic, "\(split) \(category)")
            }
        }
    }

    private func summarize(
        _ queries: [GoldenSet.Query], runs: [String: QueryRun], leaks: [String: Int], injections: Set<String>
    ) -> Summary {
        let answerable = queries.filter { !$0.expected.isEmpty }
        func mean(_ value: (GoldenSet.Query, [String]) -> Double) -> Double? {
            guard !answerable.isEmpty else { return nil }
            let total = answerable.reduce(0.0) { $0 + value($1, runs[$1.id]?.results ?? []) }
            return Self.round3(total / Double(answerable.count))
        }
        func recall(_ k: Int) -> Double? {
            mean { query, results in
                Double(Set(results.prefix(k)).intersection(query.expected).count) / Double(query.expected.count)
            }
        }
        let latencies = queries.compactMap { runs[$0.id]?.latencyMS }
        return Summary(
            queries: queries.count, answerable: answerable.count, recallAt5: recall(5), recallAt10: recall(10),
            recallAt20: recall(20),
            mrrAt10: mean { query, results in
                (results.prefix(10).firstIndex { query.expected.contains($0) }).map { 1 / Double($0 + 1) } ?? 0
            },
            evidenceComplete: mean { query, results in
                Set(query.expected).isSubset(of: results.prefix(10)) ? 1 : 0
            },
            emptyResults: queries.filter { runs[$0.id]?.results.isEmpty ?? true }.count,
            leaks: queries.reduce(0) { $0 + (leaks[$1.id] ?? 0) },
            injectionAboveEvidence: answerable.filter { query in
                let results = runs[query.id]?.results ?? []
                let first = results.firstIndex { query.expected.contains($0) } ?? results.count
                return results[..<first].contains { injections.contains($0) }
            }.count,
            latencyP50MS: Self.round2(Self.percentile(latencies, 0.5)),
            latencyP95MS: Self.round2(Self.percentile(latencies, 0.95)))
    }

    /// The Markdown table pasted into the contract's Baseline section.
    static func table(_ summary: [String: [String: Summary]]) -> String {
        func rate(_ value: Double?) -> String { value.map { String(format: "%.3f", $0) } ?? "—" }
        func percent(_ value: Double?) -> String { value.map { String(format: "%.0f%%", $0 * 100) } ?? "—" }
        var lines: [String] = []
        for split in splits {
            lines.append("\n\(split)")
            lines.append(
                "| Category | Queries | Recall@5 | Recall@10 | Recall@20 | MRR@10 | Evidence complete | No results "
                    + "| Injection first | p50 ms | p95 ms |")
            lines.append("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
            for category in categories + ["overall"] {
                guard let row = summary[split]?[category] else { continue }
                let name = category == "overall" ? "**Overall**" : "`\(category)`"
                lines.append(
                    "| \(name) | \(row.queries) | \(rate(row.recallAt5)) | \(rate(row.recallAt10)) | "
                        + "\(rate(row.recallAt20)) | \(rate(row.mrrAt10)) | \(percent(row.evidenceComplete)) | "
                        + "\(row.emptyResults) | \(row.injectionAboveEvidence) | \(String(format: "%.2f", row.latencyP50MS)) | "
                        + "\(String(format: "%.2f", row.latencyP95MS)) |")
            }
            let probes = summary[split]?["scope-leak"]
            lines.append(
                "Scope: \(summary[split]?["overall"]?.leaks ?? 0) leaks / \(probes?.queries ?? 0) probes "
                    + "(all \(summary[split]?["overall"]?.queries ?? 0) queries checked)")
        }
        return lines.joined(separator: "\n")
    }
}

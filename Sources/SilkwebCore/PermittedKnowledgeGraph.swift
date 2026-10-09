import Foundation

extension AgentScope {
    /// The effective scope (#178): project, case rule and read roots after MCP roots narrowed them. Caches and
    /// cursors carry it, so narrowing roots or grant folders never reuses either.
    public var key: String {
        let roots = readRoots.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let text = ([project, caseSensitive ? "case-sensitive" : "case-insensitive"] + roots).joined(separator: "\n")
        return String(DocumentRevision(data: Data(text.utf8)).digest.prefix(32))
    }
}

extension AgentAccessError {
    /// A graph cursor from another scope or snapshot. One message for every reason (narrowed roots, a rebuilt
    /// cache, an edited grant, a changed Document), so the refusal never says why.
    public static let cursorExpired = Self(
        code: "invalid_argument", title: "Invalid Request",
        message: "That cursor has expired. Search again without “cursor”.")
}

/// The permitted graph view (#178) that every helper retrieval goes through. It is a smaller Library, not a
/// redacted one: Documents outside the grant's effective scope are absent, and every lookup, edge, degree,
/// statistic, traversal budget, truncation signal and cursor is computed on the permitted Documents alone. A
/// hidden Document can't connect two permitted ones, and nothing here depends on whether it exists.
///
/// Build it over a graph listed from the permitted Documents (`AgentMemoryService.permittedGraph()`), so links
/// resolve against them alone; filtering again here keeps a wider graph from leaking through. The app's own
/// backlinks and graph (#30, #184) are the owner's full Library and never use this view.
public struct PermittedKnowledgeGraph: Sendable {
    public enum Seed: Equatable, Sendable {
        case path(String)
        case documentID(UUID)
        case memoryID(String)
    }

    public enum Direction: String, Sendable {
        /// The neighbor is the edge's target (“Links to”).
        case out
        /// The neighbor is the edge's source (“Linked from”).
        case `in`
    }

    /// Why a neighbor is in a traversal (`knowledge-graph-retrieval.md` › Retrieval reasons).
    public struct Reason: Equatable, Sendable {
        public let kind: KnowledgeEdgeKind
        public let direction: Direction
        /// The permitted Document the neighbor was reached from.
        public let via: String
    }

    public struct Neighbor: Equatable, Sendable {
        public let path: String
        public let hops: Int
        /// In traversal order.
        public let reasons: [Reason]
    }

    /// Work limits per traversal (`knowledge-graph-retrieval.md` › Budgets). They count permitted Documents and
    /// permitted edges only.
    public struct Budget: Equatable, Sendable {
        public static let maxHops = 2

        /// 1 or 2.
        public var hops: Int
        public var maxDocuments: Int
        public var maxEdges: Int
        /// New neighbors taken from any one Document.
        public var maxNeighborsPerDocument: Int

        public init(hops: Int = 1, maxDocuments: Int = 200, maxEdges: Int = 1_000, maxNeighborsPerDocument: Int = 20) {
            self.hops = hops
            self.maxDocuments = maxDocuments
            self.maxEdges = maxEdges
            self.maxNeighborsPerDocument = maxNeighborsPerDocument
        }
    }

    public struct Traversal: Equatable, Sendable {
        /// Breadth first; seeds are never listed.
        public let neighbors: [Neighbor]
        /// A budget cut a permitted neighbor or a permitted edge.
        public let truncated: Bool
    }

    public struct Degree: Equatable, Sendable {
        /// Distinct permitted sources.
        public let incoming: Int
        /// Distinct permitted targets.
        public let outgoing: Int
    }

    /// Inputs for BM25 (#179) from the permitted Documents only: never Library-wide.
    public struct Statistics: Equatable, Sendable {
        public let documents: Int
        /// Token counts per field, summed.
        public let lengths: KnowledgePosting
    }

    public let scope: AgentScope
    /// Names exactly what the permitted Documents are now: the scope plus every permitted path and stamp. It
    /// changes with a narrowed scope, a rebuilt cache or a changed permitted Document, never with hidden ones.
    public let snapshot: String
    private let graph: KnowledgeGraph
    private let records: [String: KnowledgeRecord]
    private let pending: [String: KnowledgeGraph.Listing.Document]

    public init(graph: KnowledgeGraph, scope: AgentScope) {
        self.graph = graph
        self.scope = scope
        records = graph.records.filter { (try? scope.checkRead($0.key)) != nil }
        pending = graph.pending.filter { (try? scope.checkRead($0.key)) != nil }
        var text = scope.key
        for path in records.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            text += "\n" + path + "\t" + (records[path]?.stamp ?? "-")
        }
        for path in pending.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            text += "\n" + path + "\tpending"
        }
        snapshot = DocumentRevision(data: Data(text.utf8)).digest
    }

    /// Every permitted Document is indexed.
    public var isReady: Bool { pending.isEmpty }

    /// Permitted Documents, indexed or not.
    public var count: Int { records.count + pending.count }

    // MARK: Lookup

    /// A path is checked against the scope from its string alone before anything is looked up, so
    /// `out_of_scope` and `invalid_path` never reveal whether it exists. Never returns `.notFound`: a missing
    /// Document throws `not_found`.
    public func resolve(_ seed: Seed) throws -> KnowledgeLookup<KnowledgeRecord> {
        let lookup: KnowledgeLookup<KnowledgeRecord>
        switch seed {
        case .path(let path):
            let normalized: String
            do {
                normalized = try scope.checkRead(path)
            } catch let error as AgentScopeError {
                throw AgentAccessError.scope(error, in: scope)
            }
            lookup = document(normalized)
        case .documentID(let id):
            // An ID the index doesn't know and one outside the read folders look the same, so an ID
            // never reveals whether a document exists elsewhere in the Library.
            lookup = document(id: id)
        case .memoryID(let id):
            // An ID the index doesn't know and one outside the read folders look the same, so an ID
            // never reveals whether a document exists elsewhere in the Library.
            if let matches = documents(memoryID: id) {
                lookup = matches.first.map { .ready($0) } ?? .notFound
            } else {
                lookup = .notReady
            }
        }
        if case .notFound = lookup { throw AgentAccessError.notFound }
        return lookup
    }

    public func document(_ path: String) -> KnowledgeLookup<KnowledgeRecord> {
        if let record = records[path] { return .ready(record) }
        return pending[path] != nil ? .notReady : .notFound
    }

    /// Unknown and out-of-scope IDs are both `.notFound`.
    public func document(id: UUID) -> KnowledgeLookup<KnowledgeRecord> {
        if let record = records.values.first(where: { $0.documentID == id }) { return .ready(record) }
        return pending.values.contains { $0.documentID == id } ? .notReady : .notFound
    }

    /// Permitted Documents with this `memory_id`, by path; empty when none. Nil (not ready) while a permitted
    /// Document is still unread and none matched yet.
    public func documents(memoryID: String) -> [KnowledgeRecord]? {
        let matches = records.values.filter { $0.content.memoryID == memoryID }.sorted {
            $0.path.utf8.lexicographicallyPrecedes($1.path.utf8)
        }
        return matches.isEmpty && !pending.isEmpty ? nil : matches
    }

    // MARK: Edges

    /// Outgoing edges to permitted Documents, in document order.
    public func links(from path: String, kind: KnowledgeEdgeKind = .linksTo) -> KnowledgeLookup<[KnowledgeEdge]> {
        guard records[path] != nil else { return pending[path] != nil ? .notReady : .notFound }
        return .ready(outgoing(path, kind: kind))
    }

    /// Incoming edges from permitted Documents, by source then section. Not ready while a permitted Document is
    /// unread; hidden ones never change readiness.
    public func links(to path: String, kind: KnowledgeEdgeKind = .linksTo) -> KnowledgeLookup<[KnowledgeEdge]> {
        guard records[path] != nil || pending[path] != nil else { return .notFound }
        guard pending.isEmpty else { return .notReady }
        return .ready(incoming(path, kind: kind))
    }

    public func degree(of path: String, kind: KnowledgeEdgeKind = .linksTo) -> KnowledgeLookup<Degree> {
        guard records[path] != nil || pending[path] != nil else { return .notFound }
        guard pending.isEmpty else { return .notReady }
        return .ready(
            Degree(
                incoming: Set(incoming(path, kind: kind).map(\.source)).count,
                outgoing: Set(outgoing(path, kind: kind).map(\.target)).count))
    }

    private func outgoing(_ path: String, kind: KnowledgeEdgeKind) -> [KnowledgeEdge] {
        (graph.outgoing[kind]?[path] ?? []).filter { records[$0.target] != nil }
    }

    private func incoming(_ path: String, kind: KnowledgeEdgeKind) -> [KnowledgeEdge] {
        (graph.incoming[kind]?[path] ?? []).filter { records[$0.source] != nil }.sorted {
            $0.source != $1.source
                ? $0.source.utf8.lexicographicallyPrecedes($1.source.utf8)
                : ($0.section ?? "").utf8.lexicographicallyPrecedes(($1.section ?? "").utf8)
        }
    }

    // MARK: Terms

    /// Postings for one token from permitted Documents. Not ready while a permitted Document is unread.
    public func postings(for term: String) -> KnowledgeLookup<[String: KnowledgePosting]> {
        guard pending.isEmpty else { return .notReady }
        return .ready((graph.postings[term] ?? [:]).filter { records[$0.key] != nil })
    }

    /// BM25 inputs (#179) from permitted Documents only, whether or not others are still unread: a hidden
    /// Document never adds a posting or a length.
    public func termStatistics(for terms: [String]) -> KnowledgeTermStatistics {
        var postings: [String: [String: KnowledgePosting]] = [:]
        for term in terms {
            let permitted = (graph.postings[term] ?? [:]).filter { records[$0.key] != nil }
            if !permitted.isEmpty { postings[term] = permitted }
        }
        return KnowledgeTermStatistics(
            postings: postings, lengths: graph.lengths.filter { records[$0.key] != nil })
    }

    public var statistics: KnowledgeLookup<Statistics> {
        guard pending.isEmpty else { return .notReady }
        var total = KnowledgePosting()
        for path in records.keys {
            let length = graph.lengths[path] ?? KnowledgePosting()
            total.title += length.title
            total.heading += length.heading
            total.body += length.body
        }
        return .ready(Statistics(documents: records.count, lengths: total))
    }

    // MARK: Traversal

    /// The induced subgraph around permitted `seeds` (resolve them first; others are ignored): `links_to` in both
    /// directions, outgoing edges in document order, then incoming by source. Every hop lands on a permitted
    /// Document, and budgets count permitted Documents and edges only. A cancelled traversal throws
    /// `CancellationError` and returns nothing partial. Not ready while a permitted Document is unread.
    public func neighbors(
        of seeds: [String], budget: Budget = Budget(), kind: KnowledgeEdgeKind = .linksTo,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> KnowledgeLookup<Traversal> {
        guard (1...Budget.maxHops).contains(budget.hops) else { throw AgentAccessError.invalidArgument("hops") }
        guard pending.isEmpty else { return .notReady }
        var origins: [String] = []
        for seed in seeds where records[seed] != nil && !origins.contains(seed) { origins.append(seed) }
        let seen = Set(origins)
        var order: [String] = []
        var found: [String: (hops: Int, reasons: [Reason])] = [:]
        var frontier = origins
        var examined = 0
        var truncated = false
        traversal: for hop in 1...budget.hops {
            var next: [String] = []
            for node in frontier {
                if isCancelled() { throw CancellationError() }
                let steps =
                    outgoing(node, kind: kind).map { ($0.target, Direction.out) }
                    + incoming(node, kind: kind).map { ($0.source, Direction.in) }
                var taken = 0
                for (path, direction) in steps {
                    guard examined < budget.maxEdges else {
                        truncated = true
                        break traversal
                    }
                    examined += 1
                    guard !seen.contains(path) else { continue }
                    let reason = Reason(kind: kind, direction: direction, via: node)
                    if let existing = found[path] {
                        if existing.hops == hop, !existing.reasons.contains(reason) {
                            found[path]?.reasons.append(reason)
                        }
                        continue
                    }
                    guard taken < budget.maxNeighborsPerDocument, order.count < budget.maxDocuments else {
                        truncated = true
                        continue
                    }
                    taken += 1
                    found[path] = (hop, [reason])
                    order.append(path)
                    next.append(path)
                }
            }
            frontier = next
        }
        if isCancelled() { throw CancellationError() }
        return .ready(
            Traversal(
                neighbors: order.map { path in
                    let entry = found[path] ?? (0, [])
                    return Neighbor(path: path, hops: entry.hops, reasons: entry.reasons)
                },
                truncated: truncated))
    }

    // MARK: Pages

    /// One page of `items` from a cursor this view issued. `request` names the query the cursor belongs to. A
    /// cursor from another scope, snapshot or request is `cursorExpired`; a malformed one is
    /// `invalidArgument("cursor")`.
    public func page<Item>(_ items: [Item], cursor: String?, limit: Int, request: String = "") throws -> (
        items: ArraySlice<Item>, nextCursor: String?
    ) {
        guard limit >= 1 else { throw AgentAccessError.invalidArgument("limit") }
        var offset = 0
        if let cursor {
            guard let parsed = Self.parseCursor(cursor) else { throw AgentAccessError.invalidArgument("cursor") }
            guard parsed.binding == binding(request) else { throw AgentAccessError.cursorExpired }
            guard parsed.offset <= items.count else { throw AgentAccessError.invalidArgument("cursor") }
            offset = parsed.offset
        }
        let end = min(items.count, offset + limit)
        return (items[offset..<end], end < items.count ? "g1.\(end)." + binding(request) : nil)
    }

    private func binding(_ request: String) -> String {
        DocumentRevision(data: Data((snapshot + "\n" + request).utf8)).digest
    }

    static func parseCursor(_ cursor: String) -> (offset: Int, binding: String)? {
        let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "g1", let offset = Int(parts[1]), offset >= 0, parts[2].count == 64,
            parts[2].allSatisfy(\.isHexDigit)
        else { return nil }
        return (offset, String(parts[2]))
    }
}

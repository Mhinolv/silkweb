import Foundation

/// Graph edge kinds (#175 contract › Relations). Only `links_to` is stored until the owner can accept a
/// `supersedes` claim (#141); claims are kept on the record, never as edges.
public enum KnowledgeEdgeKind: String, Codable, Sendable, CaseIterable {
    case linksTo = "links_to"
}

/// One edge between two Documents, by Library-relative path. `section` is the link's `#fragment`.
public struct KnowledgeEdge: Hashable, Codable, Sendable {
    public let kind: KnowledgeEdgeKind
    public let source: String
    public let target: String
    public let section: String?

    public init(kind: KnowledgeEdgeKind, source: String, target: String, section: String?) {
        self.kind = kind
        self.source = source
        self.target = target
        self.section = section
    }
}

/// The text under one heading, up to the next heading of the same or a higher level (#175 › Units).
/// `start`/`end` are UTF-8 byte offsets `[start, end)` in the body after the envelope.
public struct KnowledgeSection: Equatable, Codable, Sendable {
    public let headings: [String]
    public let start: Int
    public let end: Int

    public init(headings: [String], start: Int, end: Int) {
        self.headings = headings
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey { case headings, start, end }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        headings = try values.decodeIfPresent([String].self, forKey: .headings) ?? []
        start = try values.decodeIfPresent(Int.self, forKey: .start) ?? 0
        end = try values.decodeIfPresent(Int.self, forKey: .end) ?? 0
    }
}

/// An internal passage unit: a run of whole lines inside one Section's own text (never across a heading),
/// at most `KnowledgeContent.chunkBytes` unless a single line is longer. Chunks never overlap.
public struct KnowledgeChunk: Equatable, Codable, Sendable {
    /// Index into the record's `sections`: the innermost Section holding this text.
    public let section: Int
    public let start: Int
    public let end: Int

    public init(section: Int, start: Int, end: Int) {
        self.section = section
        self.start = start
        self.end = end
    }

    private enum CodingKeys: String, CodingKey { case section, start, end }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        section = try values.decodeIfPresent(Int.self, forKey: .section) ?? 0
        start = try values.decodeIfPresent(Int.self, forKey: .start) ?? 0
        end = try values.decodeIfPresent(Int.self, forKey: .end) ?? 0
    }
}

/// Term frequencies, or token counts, per field. Title 3, heading 2, body 1 are #179's weights, not applied here.
public struct KnowledgePosting: Equatable, Codable, Sendable {
    public var title = 0
    public var heading = 0
    public var body = 0

    public init(title: Int = 0, heading: Int = 0, body: Int = 0) {
        self.title = title
        self.heading = heading
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case title, heading, body }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decodeIfPresent(Int.self, forKey: .title) ?? 0
        heading = try values.decodeIfPresent(Int.self, forKey: .heading) ?? 0
        body = try values.decodeIfPresent(Int.self, forKey: .body) ?? 0
    }
}

/// Lexical tokens for postings. Folds case and diacritics like search; an identifier such as `library.lock`
/// stays one whole token and also yields its parts (#175 › Ranking signals). No stemming.
public enum KnowledgeTokenizer {
    private static let joiners: Set<Unicode.Scalar> = [".", "_", "-", "/", ":", "@"]

    public static func tokens(_ text: String) -> [String] {
        var result: [String] = []
        var word: [Unicode.Scalar] = []
        func string(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            return String(view)
        }
        func flush() {
            defer { word.removeAll(keepingCapacity: true) }
            var start = 0
            var end = word.count
            while start < end, joiners.contains(word[start]) { start += 1 }
            while end > start, joiners.contains(word[end - 1]) { end -= 1 }
            guard start < end else { return }
            let parts = word[start..<end].split(whereSeparator: { joiners.contains($0) })
            if parts.count > 1 { result.append(string(word[start..<end])) }
            for part in parts { result.append(string(part)) }
        }
        for scalar in searchFold(text).unicodeScalars {
            if joiners.contains(scalar) || scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                word.append(scalar)
            } else if !word.isEmpty {
                flush()
            }
        }
        if !word.isEmpty { flush() }
        return result
    }

    static func counts(_ text: String) -> [String: Int] {
        var counts: [String: Int] = [:]
        for token in tokens(text) { counts[token, default: 0] += 1 }
        return counts
    }
}

/// What the index keeps from one Document's text. It doesn't depend on the Document's path, so a moved
/// Document keeps it without being read again.
public struct KnowledgeContent: Equatable, Codable, Sendable {
    public static let chunkBytes = 1024
    public static let empty = KnowledgeContent()

    /// The envelope's `memory_id` and its `supersedes` claims (never edges by themselves).
    public var memoryID: String?
    public var supersedes: [String] = []
    public var sections: [KnowledgeSection] = []
    public var chunks: [KnowledgeChunk] = []
    /// Inline link destinations as the renderer receives them, in document order. They resolve against the
    /// current Library on every change of the items they name, so they are stored unresolved.
    public var links: [String] = []
    public var headingTerms: [String: Int] = [:]
    public var bodyTerms: [String: Int] = [:]

    init() {}

    /// A whole file: the envelope is read as in #132. A malformed or newer envelope leaves no Sections, links
    /// or body terms; the Document still has its title.
    public init(text: String) {
        switch MemoryEnvelope.parse(text) {
        case .missing:
            self.init(body: text)
        case .envelope(let envelope, let body):
            var supersedes: [String] = []
            if case .list(let items) = envelope["supersedes"] { supersedes = items }
            self.init(body: String(text[body]), memoryID: envelope.memoryID, supersedes: supersedes)
        case .failure:
            self.init()
        }
    }

    /// `body` is the text after the envelope.
    public init(body: String, memoryID: String? = nil, supersedes: [String] = []) {
        self.memoryID = memoryID
        self.supersedes = supersedes
        guard !body.isEmpty else { return }
        let (scan, document) = MarkdownLinks.scanDocument(body)
        links = scan.links.filter { $0.kind == .link }.map(\.destination)
        let headings = document.headings.filter { $0.sourceRange.location != NSNotFound }
        let utf8 = Array(body.utf8)
        let total = utf8.count
        let starts = headings.map { heading -> Int in
            let index = String.Index(utf16Offset: heading.sourceRange.location, in: body)
            return body.utf8.distance(from: body.utf8.startIndex, to: index)
        }
        // The end of each Section: the next heading of the same or a higher level (a lower or equal number).
        var ends = Array(repeating: total, count: headings.count)
        var later: [Int] = []
        for index in headings.indices.reversed() {
            while let last = later.last, headings[last].level > headings[index].level { later.removeLast() }
            if let last = later.last { ends[index] = starts[last] }
            later.append(index)
        }
        let firstStart = starts.first ?? total
        let preamble = utf8[0..<firstStart].contains { !(0x20 == $0 || (0x09...0x0D).contains($0)) }
        var leaves: [(section: Int, start: Int, end: Int)] = []
        if preamble {
            sections.append(KnowledgeSection(headings: [], start: 0, end: firstStart))
            leaves.append((0, 0, firstStart))
        }
        var stack: [(level: Int, text: String)] = []
        for (index, heading) in headings.enumerated() {
            while let last = stack.last, last.level >= heading.level { stack.removeLast() }
            stack.append((heading.level, heading.text))
            leaves.append((sections.count, starts[index], index + 1 < starts.count ? starts[index + 1] : total))
            sections.append(KnowledgeSection(headings: stack.map(\.text), start: starts[index], end: ends[index]))
        }
        for leaf in leaves where leaf.start < leaf.end {
            var start = leaf.start
            var offset = leaf.start
            while offset < leaf.end {
                var lineEnd = offset
                while lineEnd < leaf.end, utf8[lineEnd] != 0x0A { lineEnd += 1 }
                lineEnd = min(lineEnd + 1, leaf.end)
                if lineEnd - start > Self.chunkBytes, offset > start {
                    chunks.append(KnowledgeChunk(section: leaf.section, start: start, end: offset))
                    start = offset
                }
                offset = lineEnd
            }
            chunks.append(KnowledgeChunk(section: leaf.section, start: start, end: leaf.end))
        }
        for heading in headings {
            for (term, count) in KnowledgeTokenizer.counts(heading.text) { headingTerms[term, default: 0] += count }
        }
        bodyTerms = KnowledgeTokenizer.counts(body)
    }

    private enum CodingKeys: String, CodingKey {
        case memoryID = "memory_id", supersedes, sections, chunks, links, headingTerms, bodyTerms
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        memoryID = try values.decodeIfPresent(String.self, forKey: .memoryID)
        supersedes = try values.decodeIfPresent([String].self, forKey: .supersedes) ?? []
        sections = try values.decodeIfPresent([KnowledgeSection].self, forKey: .sections) ?? []
        chunks = try values.decodeIfPresent([KnowledgeChunk].self, forKey: .chunks) ?? []
        links = try values.decodeIfPresent([String].self, forKey: .links) ?? []
        headingTerms = try values.decodeIfPresent([String: Int].self, forKey: .headingTerms) ?? [:]
        bodyTerms = try values.decodeIfPresent([String: Int].self, forKey: .bodyTerms) ?? [:]
    }
}

/// One indexed Document (#175 › Units).
public struct KnowledgeRecord: Equatable, Codable, Sendable {
    public var path: String
    /// What the content was read from: a file identity and date (app) or a revision (helper). Nil when it
    /// can't be told, so the Document is read again on every change.
    public var stamp: String?
    public var documentID: UUID?
    public var content: KnowledgeContent

    public init(path: String, stamp: String?, documentID: UUID?, content: KnowledgeContent) {
        self.path = path
        self.stamp = stamp
        self.documentID = documentID
        self.content = content
    }

    public var title: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

    private enum CodingKeys: String, CodingKey { case path, stamp, documentID, content }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        path = try values.decode(String.self, forKey: .path)
        stamp = try values.decodeIfPresent(String.self, forKey: .stamp)
        documentID = try values.decodeIfPresent(UUID.self, forKey: .documentID)
        content = try values.decodeIfPresent(KnowledgeContent.self, forKey: .content) ?? .empty
    }
}

/// A query answer. `notReady`: the Document is listed but is being (re)indexed, so nothing from its previous
/// revision is served (#184 shows a loading state for it). `notFound`: no such Document in the index.
public enum KnowledgeLookup<Value: Sendable>: Sendable {
    case ready(Value)
    case notReady
    case notFound

    public var value: Value? {
        if case .ready(let value) = self { return value }
        return nil
    }
}

extension KnowledgeLookup: Equatable where Value: Equatable {}

/// The disposable knowledge index (#177): Document records with Sections and chunks, forward and reverse
/// adjacency per edge kind, field postings, and the target-path dependency map that says which Documents'
/// links must be resolved again when an item appears, disappears or changes kind — including broken and
/// ambiguous destinations. A value type with no I/O: callers list the Library, read the Documents it asks
/// for, and keep it off the main thread.
///
/// Incremental updates leave it equal to one built from scratch from the same listing and contents.
public struct KnowledgeGraph: Sendable, Equatable {
    public struct Listing: Sendable {
        public struct Document: Equatable, Sendable {
            public var path: String
            public var stamp: String?
            public var documentID: UUID?

            public init(path: String, stamp: String?, documentID: UUID? = nil) {
                self.path = path
                self.stamp = stamp
                self.documentID = documentID
            }
        }

        public var documents: [Document]
        /// Library-relative Folder paths. They count for resolution: a link to a Folder is no edge, and a Folder
        /// can make a case alias ambiguous.
        public var folders: [String]
        public var caseSensitive: Bool

        public init(documents: [Document], folders: [String], caseSensitive: Bool) {
            self.documents = documents
            self.folders = folders
            self.caseSensitive = caseSensitive
        }
    }

    public private(set) var records: [String: KnowledgeRecord] = [:]
    /// Listed Documents whose content is still to be installed, with the listing it must match.
    public private(set) var pending: [String: Listing.Document] = [:]
    public private(set) var outgoing: [KnowledgeEdgeKind: [String: [KnowledgeEdge]]] = [:]
    public private(set) var incoming: [KnowledgeEdgeKind: [String: Set<KnowledgeEdge>]] = [:]
    /// Folded target path → Documents with a link destination that resolved through it (to an edge or not).
    private(set) var dependents: [String: Set<String>] = [:]
    private var dependencies: [String: Set<String>] = [:]
    /// Term → path → per-field frequency.
    public private(set) var postings: [String: [String: KnowledgePosting]] = [:]
    /// Token counts per field, per path.
    public private(set) var lengths: [String: KnowledgePosting] = [:]
    private var items: [String: MarkdownLinkResolver.Item] = [:]
    private var caseSensitive: Bool?
    private var resolver = MarkdownLinkResolver(items: [:], caseSensitive: true)
    /// Bumped by every change to `records`; a cache writer compares it.
    public private(set) var revision = 0

    public init() {}

    /// Records from a checkpoint. Their links resolve on the first `apply`, against the Library as it is then.
    public init(records: [KnowledgeRecord]) {
        for record in records where self.records[record.path] == nil {
            self.records[record.path] = record
            index(record.path)
        }
    }

    public static func == (lhs: KnowledgeGraph, rhs: KnowledgeGraph) -> Bool {
        lhs.records == rhs.records && lhs.pending == rhs.pending && lhs.outgoing == rhs.outgoing
            && lhs.incoming == rhs.incoming && lhs.dependents == rhs.dependents
            && lhs.dependencies == rhs.dependencies && lhs.postings == rhs.postings && lhs.lengths == rhs.lengths
            && lhs.items == rhs.items && lhs.caseSensitive == rhs.caseSensitive
    }

    public var isReady: Bool { pending.isEmpty }

    // MARK: Updates

    /// Installs a new listing of the Library. Removed and changed Documents lose their edges and postings at
    /// once (changed ones become `pending` until `install`); a moved Document whose stamp is unchanged keeps
    /// its content; links that resolve through an added, removed or retyped item are resolved again.
    /// Returns the Documents to read, in listing order.
    @discardableResult
    public mutating func apply(_ listing: Listing) -> [Listing.Document] {
        var items: [String: MarkdownLinkResolver.Item] = [:]
        for folder in listing.folders where !folder.isEmpty { items[folder] = .folder }
        for document in listing.documents { items[document.path] = .document }
        let full = caseSensitive != listing.caseSensitive
        var changed = Set<String>()
        if !full {
            for (path, item) in items where self.items[path] != item { changed.insert(MarkdownLinkResolver.fold(path)) }
            for path in self.items.keys where items[path] == nil { changed.insert(MarkdownLinkResolver.fold(path)) }
        }
        if full || !changed.isEmpty {
            self.items = items
            caseSensitive = listing.caseSensitive
            resolver = MarkdownLinkResolver(items: items, caseSensitive: listing.caseSensitive)
        }

        var listed: [String: Listing.Document] = [:]
        for document in listing.documents where listed[document.path] == nil { listed[document.path] = document }
        // Content of Documents that left their path, by stamp: a move or rename reads nothing again.
        var departed: [String: KnowledgeContent] = [:]
        for path in records.keys.sorted() where listed[path] == nil {
            if let record = records[path], let stamp = record.stamp { departed[stamp] = record.content }
            remove(path)
        }
        for path in pending.keys where listed[path] == nil { pending[path] = nil }

        var needed: [Listing.Document] = []
        var linked = Set<String>()
        for document in listing.documents where listed[document.path] == document {
            listed[document.path] = nil
            if let record = records[document.path], let stamp = document.stamp, record.stamp == stamp {
                if record.documentID != document.documentID {
                    records[document.path]?.documentID = document.documentID
                    revision += 1
                }
                continue
            }
            if records[document.path] != nil { remove(document.path) }
            if let stamp = document.stamp, let content = departed[stamp] {
                pending[document.path] = nil
                put(
                    KnowledgeRecord(
                        path: document.path, stamp: stamp, documentID: document.documentID, content: content))
                linked.insert(document.path)
                continue
            }
            pending[document.path] = document
            needed.append(document)
        }

        let sources =
            full ? Set(records.keys) : changed.reduce(into: Set<String>()) { $0.formUnion(dependents[$1] ?? []) }
        for source in sources where records[source] != nil && !linked.contains(source) { link(source) }
        return needed
    }

    /// Installs content read for a pending Document. False when the listing moved on (the Document changed
    /// again, moved or was removed) since it was asked for: the content is dropped.
    @discardableResult
    public mutating func install(_ document: Listing.Document, content: KnowledgeContent) -> Bool {
        guard pending[document.path] == document else { return false }
        pending[document.path] = nil
        put(
            KnowledgeRecord(
                path: document.path, stamp: document.stamp, documentID: document.documentID, content: content))
        return true
    }

    private mutating func put(_ record: KnowledgeRecord) {
        records[record.path] = record
        revision += 1
        index(record.path)
        link(record.path)
    }

    private mutating func remove(_ path: String) {
        guard records[path] != nil else { return }
        unlink(path)
        unindex(path)
        records[path] = nil
        revision += 1
    }

    private mutating func link(_ source: String) {
        unlink(source)
        guard let record = records[source] else { return }
        var edges: [KnowledgeEdge] = []
        var seen = Set<KnowledgeEdge>()
        var keys = Set<String>()
        for destination in record.content.links {
            let (edge, resolution) = resolver.edge(destination, from: source)
            if let path = resolution.path { keys.insert(MarkdownLinkResolver.fold(path)) }
            guard let edge else { continue }
            let knowledge = KnowledgeEdge(kind: .linksTo, source: source, target: edge.target, section: edge.section)
            if seen.insert(knowledge).inserted { edges.append(knowledge) }
        }
        if !edges.isEmpty { outgoing[.linksTo, default: [:]][source] = edges }
        for edge in edges { incoming[.linksTo, default: [:]][edge.target, default: []].insert(edge) }
        if !keys.isEmpty { dependencies[source] = keys }
        for key in keys { dependents[key, default: []].insert(source) }
    }

    private mutating func unlink(_ source: String) {
        for kind in KnowledgeEdgeKind.allCases {
            for edge in outgoing[kind]?[source] ?? [] {
                incoming[kind]?[edge.target]?.remove(edge)
                if incoming[kind]?[edge.target]?.isEmpty == true { incoming[kind]?[edge.target] = nil }
            }
            outgoing[kind]?[source] = nil
            if outgoing[kind]?.isEmpty == true { outgoing[kind] = nil }
            if incoming[kind]?.isEmpty == true { incoming[kind] = nil }
        }
        for key in dependencies[source] ?? [] {
            dependents[key]?.remove(source)
            if dependents[key]?.isEmpty == true { dependents[key] = nil }
        }
        dependencies[source] = nil
    }

    private func fields(_ path: String) -> [String: KnowledgePosting] {
        guard let record = records[path] else { return [:] }
        var fields: [String: KnowledgePosting] = [:]
        for (term, count) in KnowledgeTokenizer.counts(record.title) { fields[term, default: .init()].title = count }
        for (term, count) in record.content.headingTerms { fields[term, default: .init()].heading = count }
        for (term, count) in record.content.bodyTerms { fields[term, default: .init()].body = count }
        return fields
    }

    private mutating func index(_ path: String) {
        var length = KnowledgePosting()
        for (term, posting) in fields(path) {
            postings[term, default: [:]][path] = posting
            length.title += posting.title
            length.heading += posting.heading
            length.body += posting.body
        }
        lengths[path] = length
    }

    private mutating func unindex(_ path: String) {
        for term in fields(path).keys {
            postings[term]?[path] = nil
            if postings[term]?.isEmpty == true { postings[term] = nil }
        }
        lengths[path] = nil
    }

    // MARK: Queries

    public func document(_ path: String) -> KnowledgeLookup<KnowledgeRecord> {
        if let record = records[path] { return .ready(record) }
        return pending[path] != nil ? .notReady : .notFound
    }

    /// Outgoing edges in document order.
    public func links(from path: String, kind: KnowledgeEdgeKind = .linksTo) -> KnowledgeLookup<[KnowledgeEdge]> {
        guard records[path] != nil else { return pending[path] != nil ? .notReady : .notFound }
        return .ready(outgoing[kind]?[path] ?? [])
    }

    /// Incoming edges, by source path then section. Not ready while any Document is pending: until it is read,
    /// whether it links here is unknown, and the answer would be incomplete rather than stale.
    public func links(to path: String, kind: KnowledgeEdgeKind = .linksTo) -> KnowledgeLookup<[KnowledgeEdge]> {
        guard records[path] != nil || pending[path] != nil else { return .notFound }
        guard pending.isEmpty else { return .notReady }
        return .ready(
            (incoming[kind]?[path] ?? []).sorted {
                $0.source != $1.source
                    ? $0.source.utf8.lexicographicallyPrecedes($1.source.utf8)
                    : ($0.section ?? "").utf8.lexicographicallyPrecedes(($1.section ?? "").utf8)
            })
    }

    /// Postings for one token (see `KnowledgeTokenizer`). Not ready while any Document is pending.
    public func postings(for term: String) -> KnowledgeLookup<[String: KnowledgePosting]> {
        guard pending.isEmpty else { return .notReady }
        return .ready(postings[term] ?? [:])
    }
}

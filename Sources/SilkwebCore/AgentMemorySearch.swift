import Darwin
import Foundation

/// `memory_search` input (#134, `docs/agent-memory.md` › Search and read). Filters narrow the grant's
/// read folders; they never widen them.
public struct AgentMemorySearchRequest: Equatable, Sendable {
    public static let defaultLimit = 10
    public static let maxLimit = 50

    /// Free text; empty lists every in-scope document that passes the filters.
    public var query: String
    /// Must name the grant's own project. Keeps documents whose envelope `project` matches, and
    /// documents without an envelope inside that project's Folder.
    public var project: String?
    /// `memory`, `decision`, `progress` or `handoff`. Documents without an envelope drop out once set.
    public var types: [String]
    /// Envelope `status` values, compared without regard to case. Documents without one drop out once set.
    public var statuses: [String]
    /// Inclusive lower bound on `created_at` (the modified date for documents without an envelope).
    public var createdAfter: Date?
    /// Exclusive upper bound on the same date.
    public var createdBefore: Date?
    /// 1…50, and never more than the grant's `max_results`.
    public var limit: Int

    public init(
        query: String = "", project: String? = nil, types: [String] = [], statuses: [String] = [],
        createdAfter: Date? = nil, createdBefore: Date? = nil, limit: Int = defaultLimit
    ) {
        self.query = query
        self.project = project
        self.types = types
        self.statuses = statuses
        self.createdAfter = createdAfter
        self.createdBefore = createdBefore
        self.limit = limit
    }

    /// `2026-10-07` (midnight UTC) or a full ISO 8601 timestamp, with or without fractional seconds.
    public static func date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds], [.withFullDate],
        ] {
            formatter.formatOptions = options
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

/// Human review state from app metadata. Missing metadata reads as `unreviewed`, never as an error.
public enum AgentMemoryReview: String, Sendable {
    case reviewed
    case unreviewed
    /// The owner reviewed an older revision; the text changed since.
    case reviewedEarlierRevision = "reviewed-earlier-revision"
}

/// What app metadata knows about one document. Review and pin controls arrive with #137/#140.
public struct AgentMemoryReviewHint: Equatable, Sendable {
    /// `sha256:…` of the revision the owner reviewed, if any.
    public var reviewedRevision: String?
    public var pinned: Bool

    public init(reviewedRevision: String? = nil, pinned: Bool = false) {
        self.reviewedRevision = reviewedRevision
        self.pinned = pinned
    }
}

/// Looks up review hints by native document ID and Library-relative path.
public typealias AgentMemoryReviewLookup = @Sendable (_ documentID: UUID?, _ path: String) -> AgentMemoryReviewHint?

/// The metadata every search result and read response carries, in the documented field order.
public struct AgentMemoryDocumentInfo: Equatable, Sendable {
    public let title: String
    /// Library-relative POSIX path.
    public let path: String
    /// The app index's native UUID; `nil` until the app has seen the document.
    public let documentID: UUID?
    public let memoryID: String?
    /// `sha256:` + hex digest of the file's bytes.
    public let revision: String
    public let type: String?
    public let project: String?
    public let status: String?
    public let agent: String?
    public let session: String?
    /// The envelope's `created_at`, as written.
    public let createdAt: String?
    public let modified: Date
    public let review: AgentMemoryReview
    public let pinned: Bool
    /// `memory_id`s of in-scope documents whose `supersedes` names this one, sorted.
    public let supersededBy: [String]
}

public struct AgentMemorySearchResult: Equatable, Sendable {
    public let document: AgentMemoryDocumentInfo
    public let matchKind: SearchResult.MatchKind
    /// About 120 characters of plain text around the first hit, envelope excluded, `…` at cut ends.
    public let excerpt: String
}

/// How complete the helper's index was when it answered.
public struct AgentMemoryFreshness: Equatable, Sendable {
    public enum State: String, Sendable { case indexing, partial, ready }
    public enum Reason: String, Codable, Sendable {
        case firstRun = "first-run"
        case corrupt
        case unsupportedVersion = "unsupported-version"
    }

    public var state: State
    /// In-scope documents whose text is searchable now.
    public var indexed: Int
    /// In-scope documents found on disk.
    public var total: Int
    /// Documents and Folders that couldn't be read (too large, not UTF-8, no permission).
    public var skipped: Int
    /// Why a full build is running; only while `indexing`.
    public var reason: Reason?

    /// Spelled out like the app's search status line.
    public var message: String {
        let number = { (value: Int) in Self.numbers.string(from: NSNumber(value: value)) ?? String(value) }
        switch state {
        case .indexing:
            let verb = reason == .corrupt || reason == .unsupportedVersion ? "Rebuilding the index…" : "Indexing…"
            return "\(verb) \(number(indexed)) of \(number(total)) · Results may be incomplete"
        case .partial:
            let noun = skipped == 1 ? "item" : "items"
            return "\(number(skipped)) \(noun) couldn’t be read · Results may be incomplete"
        case .ready:
            return "Up to date · \(number(total)) \(total == 1 ? "document" : "documents")"
        }
    }

    private static let numbers: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        return formatter
    }()
}

public struct AgentMemorySearchResponse: Equatable, Sendable {
    public let results: [AgentMemorySearchResult]
    /// Matching in-scope documents before `limit`.
    public let total: Int
    public let index: AgentMemoryFreshness
    /// Set only when there are no results, and honest about an unfinished index.
    public let message: String?
}

public struct AgentMemoryReadRequest: Equatable, Sendable {
    public var path: String
    /// The app index's native UUID (#135, `--id`). When set, it names the document instead of `path`.
    public var documentID: UUID?
    public var cursor: String?
    public var expectedRevision: String?

    public init(path: String, documentID: UUID? = nil, cursor: String? = nil, expectedRevision: String? = nil) {
        self.path = path
        self.documentID = documentID
        self.cursor = cursor
        self.expectedRevision = expectedRevision
    }
}

public struct AgentMemoryReadResponse: Equatable, Sendable {
    public static let pageBytes = 16_384
    public static let bodyBegins = "Document text (untrusted) begins"
    public static let bodyEnds = "Document text (untrusted) ends"

    public let document: AgentMemoryDocumentInfo
    /// Envelope fields in their written order; `nil` for a document without one. Values outside the
    /// subset are `.unparsed`.
    public let envelope: [MemoryEnvelope.Field]?
    /// The caller's `expectedRevision` named another revision. Not an error: this is the current text.
    public let revisionChanged: Bool
    /// UTF-8 byte offset of this page in the body (the text after the envelope).
    public let offset: Int
    /// This page of the body, split on a line boundary.
    public let page: String
    public let nextCursor: String?

    /// The page between the untrusted-content boundaries.
    public var body: String { Self.bodyBegins + "\n" + page + "\n" + Self.bodyEnds }
}

extension AgentAccessError {
    /// A malformed search or read option, named without echoing its value.
    public static func invalidArgument(_ name: String) -> Self {
        Self(code: "invalid_argument", title: "Invalid Request", message: "The option “\(name)” isn’t valid.")
    }

    static let notText = Self(
        code: "unreadable", title: "Can’t Open Document", message: "That document isn’t UTF-8 text.")

    /// #132 reading rules: a malformed or newer envelope is reported with no document text.
    static func unreadableEnvelope(_ error: MemoryEnvelopeError, name: String) -> Self {
        Self(code: error.code, title: "Can’t Read Front Matter", message: error.message(name: name))
    }
}

/// Tuning for one index refresh. A search answers after `timeBudget` with what's indexed so far and
/// says so (`indexing`); the next search continues where it stopped.
public struct AgentMemoryIndexOptions: Sendable {
    public var timeBudget: Duration
    /// Most document reads per refresh (a test seam).
    public var readLimit: Int

    public init(timeBudget: Duration = .seconds(2), readLimit: Int = .max) {
        self.timeBudget = timeBudget
        self.readLimit = readLimit
    }
}

/// Scoped lexical search and paged reads for one helper session (#134). The CLI (#135) and MCP
/// server (#136) present its fields as they are.
///
/// The index is the helper's own: one cache per grant under
/// `~/Library/Application Support/Silkweb/agent-index/<grant-id>.json` (mode 0600, outside the Library).
/// It never reads or writes the app's `.silkweb/search-index.json`, never takes the Library gate and
/// never touches a document. A corrupt or newer cache is discarded and rebuilt; a revoked grant's
/// cache is deleted.
public final class AgentMemoryService: @unchecked Sendable {
    public let session: AgentSession
    public let cacheDirectory: URL
    private let options: AgentMemoryIndexOptions
    private let reviews: AgentMemoryReviewLookup
    private let lock = NSLock()
    private var index: AgentMemoryIndex?

    public init(
        session: AgentSession, cacheDirectory: URL, options: AgentMemoryIndexOptions = AgentMemoryIndexOptions(),
        reviews: @escaping AgentMemoryReviewLookup = { _, _ in nil }
    ) {
        self.session = session
        self.cacheDirectory = cacheDirectory
        self.options = options
        self.reviews = reviews
    }

    public static func defaultCacheDirectory(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Silkweb/agent-index", isDirectory: true)
    }

    /// A stable, filename-safe ID for the grant's project key.
    public static func grantID(project: String) -> String {
        String(DocumentRevision(data: Data(project.utf8)).digest.prefix(32))
    }

    public var cacheURL: URL {
        cacheDirectory.appendingPathComponent(Self.grantID(project: session.project) + ".json")
    }

    public func search(_ request: AgentMemorySearchRequest) throws -> AgentMemorySearchResponse {
        lock.lock()
        defer { lock.unlock() }
        let context = try authorize(.search)
        let index = loadedIndex(for: context)
        let freshness = index.refresh(context, options: options)
        index.save()
        return try index.search(request, context: context, freshness: freshness, reviews: reviews)
    }

    public func read(_ request: AgentMemoryReadRequest) throws -> AgentMemoryReadResponse {
        lock.lock()
        defer { lock.unlock() }
        guard let documentID = request.documentID else {
            let context = try authorize(.read, path: request.path)
            return try loadedIndex(for: context).read(request, context: context, reviews: reviews)
        }
        // An ID the index doesn't know and one outside the read folders look the same, so an ID
        // never reveals whether a document exists elsewhere in the Library.
        let context = try authorize(.read)
        let index = loadedIndex(for: context)
        guard let path = index.path(forDocumentID: documentID, library: context.library),
            let normalized = try? context.scope.checkRead(path)
        else { throw AgentAccessError.notFound }
        var resolved = request
        resolved.path = normalized
        return try index.read(resolved, context: context, reviews: reviews)
    }

    /// Call right after this session publishes a document (#133) with that create's authorization, so
    /// read-after-create works even while a first build is still running. Paths outside the read
    /// folders are ignored.
    public func didCreate(_ path: String, authorization context: AgentAuthorization) {
        lock.lock()
        defer { lock.unlock() }
        guard let normalized = try? context.scope.checkRead(path) else { return }
        let index = loadedIndex(for: context)
        index.indexNow(normalized, context: context)
        index.save()
    }

    /// Re-checks the grant first. Turning access off or removing the grant deletes its cache.
    private func authorize(_ operation: AgentOperation, path: String? = nil) throws -> AgentAuthorization {
        do {
            return try session.authorize(operation, path: path)
        } catch let error as AgentAccessError where ["grant_revoked", "no_grant"].contains(error.code) {
            index = nil
            try? FileManager.default.removeItem(at: cacheURL)
            throw error
        }
    }

    private func loadedIndex(for context: AgentAuthorization) -> AgentMemoryIndex {
        if let index, index.library == context.library.path { return index }
        let loaded = AgentMemoryIndex(url: cacheURL, library: context.library.path, project: session.project)
        index = loaded
        return loaded
    }
}

/// The helper's per-grant index: records keyed by Library-relative path, refreshed by `stat` and
/// re-read only when a file's size, date or identity changes.
final class AgentMemoryIndex {
    static let version = 1

    struct Envelope: Codable, Equatable {
        var memoryID: String?
        var type: String?
        var project: String?
        var agent: String?
        var session: String?
        var createdAt: String?
        var status: String?
        var supersedes: [String] = []

        init(_ envelope: MemoryEnvelope) {
            memoryID = envelope.memoryID
            type = envelope.string("type")
            project = envelope.string("project")
            agent = envelope.string("agent")
            session = envelope.string("session")
            createdAt = envelope.string("created_at")
            status = envelope.string("status")
            if case .list(let items) = envelope["supersedes"] { supersedes = items }
        }

        private enum CodingKeys: String, CodingKey {
            case memoryID = "memory_id", type, project, agent, session, createdAt = "created_at", status, supersedes
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            memoryID = try values.decodeIfPresent(String.self, forKey: .memoryID)
            type = try values.decodeIfPresent(String.self, forKey: .type)
            project = try values.decodeIfPresent(String.self, forKey: .project)
            agent = try values.decodeIfPresent(String.self, forKey: .agent)
            session = try values.decodeIfPresent(String.self, forKey: .session)
            createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
            status = try values.decodeIfPresent(String.self, forKey: .status)
            supersedes = try values.decodeIfPresent([String].self, forKey: .supersedes) ?? []
        }
    }

    struct Record: Codable, Equatable {
        var path: String
        var size: Int
        var modified: Double
        var identity: String
        var revision: String
        /// Searchable text: the body after a v1 envelope; empty for a malformed or newer envelope.
        var body: String
        var envelope: Envelope?
        /// Too large, not UTF-8 or unreadable. Kept so it isn't retried until the file changes.
        var skipped: Bool

        init(
            _ document: AgentSecureFiles.Document, revision: String = "", body: String = "",
            envelope: Envelope? = nil, skipped: Bool = false
        ) {
            path = document.path
            size = document.size
            modified = document.modified.timeIntervalSince1970
            identity = document.identity
            self.revision = revision
            self.body = body
            self.envelope = envelope
            self.skipped = skipped
        }

        func matches(_ document: AgentSecureFiles.Document) -> Bool {
            size == document.size && modified == document.modified.timeIntervalSince1970
                && identity == document.identity
        }

        var title: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }

        private enum CodingKeys: String, CodingKey {
            case path, size, modified, identity, revision, body, envelope, skipped
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = try values.decode(String.self, forKey: .path)
            size = try values.decodeIfPresent(Int.self, forKey: .size) ?? -1
            modified = try values.decodeIfPresent(Double.self, forKey: .modified) ?? 0
            identity = try values.decodeIfPresent(String.self, forKey: .identity) ?? ""
            revision = try values.decodeIfPresent(String.self, forKey: .revision) ?? ""
            body = try values.decodeIfPresent(String.self, forKey: .body) ?? ""
            envelope = try values.decodeIfPresent(Envelope.self, forKey: .envelope)
            skipped = try values.decodeIfPresent(Bool.self, forKey: .skipped) ?? false
        }
    }

    /// The cache file, `version: 1`. Missing keys decode to defaults.
    struct Cache: Codable {
        var version = AgentMemoryIndex.version
        var library: String
        var project: String
        /// Set while a full build hasn't finished, so a later process reports the same reason.
        var building: AgentMemoryFreshness.Reason?
        var records: [Record]

        init(library: String, project: String, building: AgentMemoryFreshness.Reason?, records: [Record]) {
            self.library = library
            self.project = project
            self.building = building
            self.records = records
        }

        private enum CodingKeys: String, CodingKey { case version, library, project, building, records }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            library = try values.decodeIfPresent(String.self, forKey: .library) ?? ""
            project = try values.decodeIfPresent(String.self, forKey: .project) ?? ""
            building = try? values.decodeIfPresent(AgentMemoryFreshness.Reason.self, forKey: .building)
            records =
                version > AgentMemoryIndex.version
                ? [] : try values.decodeIfPresent([Record].self, forKey: .records) ?? []
        }
    }

    let url: URL
    let library: String
    let project: String
    private(set) var records: [String: Record] = [:]
    /// Per-process search form of each record: folded title, folded body bytes and its date.
    private var folded: [String: (title: String, body: [UInt8], date: Date)] = [:]
    private var building: AgentMemoryFreshness.Reason?
    private var dirty = false
    private var metadata: (stamp: [Int], ids: [String: UUID])?

    init(url: URL, library: String, project: String) {
        self.url = url
        self.library = library
        self.project = project
        load()
    }

    // MARK: Cache file

    private func load() {
        guard let data = try? Data(contentsOf: url) else {
            building = .firstRun
            return
        }
        guard let cache = try? JSONDecoder().decode(Cache.self, from: data) else {
            discard(.corrupt)
            return
        }
        guard cache.version <= Self.version else {
            discard(.unsupportedVersion)
            return
        }
        // A cache for another Library (the grant was repointed) is a fresh start, not corruption.
        guard cache.library == library, cache.project == project else {
            discard(.firstRun)
            return
        }
        building = cache.building
        records = Dictionary(cache.records.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func discard(_ reason: AgentMemoryFreshness.Reason) {
        records = [:]
        building = reason
        dirty = true
    }

    /// Atomic replace with mode 0600 in a 0700 folder. A failure only costs a rebuild next time.
    func save() {
        guard dirty else { return }
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try LibraryMetadataStore.rejectLink(directory)
            try LibraryMetadataStore.rejectLink(url)
            let cache = Cache(
                library: library, project: project, building: building,
                records: records.values.sorted { $0.path < $1.path })
            let data = try JSONEncoder().encode(cache)
            let staging = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
            guard fileManager.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600])
            else { return }
            guard rename(staging.path, url.path) == 0 else {
                try? fileManager.removeItem(at: staging)
                return
            }
            dirty = false
        } catch {}
    }

    // MARK: Refresh

    /// Walks the grant's read folders (one `stat` per entry), drops records that left the scope and
    /// reads new or changed documents, newest first, until the budget runs out.
    func refresh(_ context: AgentAuthorization, options: AgentMemoryIndexOptions) -> AgentMemoryFreshness {
        var unreadableFolders = 0
        var found: [String: AgentSecureFiles.Document] = [:]
        for root in context.scope.readRoots {
            do {
                for document in try AgentSecureFiles.documents(
                    library: context.library, under: root, unreadableFolders: &unreadableFolders)
                {
                    found[document.path] = document
                }
            } catch let error as AgentAccessError where error == .unreadable {
                unreadableFolders += 1
            } catch {
                // A read folder reached through a link (or a file in its place) is skipped, like `list`.
                continue
            }
        }
        let live = context.scope.readable(found.values, path: \.path)
        let livePaths = Set(live.map(\.path))
        let kept = records.filter { livePaths.contains($0.key) }
        if kept.count != records.count {
            records = kept
            folded = folded.filter { livePaths.contains($0.key) }
            dirty = true
        }
        let pending = live.filter { records[$0.path]?.matches($0) != true }.sorted {
            $0.modified != $1.modified ? $0.modified > $1.modified : $0.path < $1.path
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: options.timeBudget)
        var reads = 0
        for document in pending {
            guard reads < options.readLimit, clock.now < deadline else { break }
            reads += 1
            index(document, context: context)
        }
        let remaining = pending.count - reads
        if remaining == 0, building != nil {
            building = nil
            dirty = true
        }
        let skipped = live.filter { records[$0.path]?.skipped == true }.count + unreadableFolders
        let searchable = live.filter { document in
            guard let record = records[document.path] else { return false }
            return !record.skipped && record.matches(document)
        }.count
        let state: AgentMemoryFreshness.State = remaining > 0 ? .indexing : skipped > 0 ? .partial : .ready
        return AgentMemoryFreshness(
            state: state, indexed: searchable, total: live.count, skipped: skipped,
            reason: state == .indexing ? building : nil)
    }

    /// Indexes one document now (read-after-create), whatever the refresh budget.
    func indexNow(_ path: String, context: AgentAuthorization) {
        let components = path.split(separator: "/")
        var unreadable = 0
        let parent = components.dropLast().joined(separator: "/")
        guard
            let document =
                (try? AgentSecureFiles.documents(
                    library: context.library, under: parent, unreadableFolders: &unreadable))?
                .first(where: { $0.path == path })
        else { return }
        index(document, context: context)
    }

    private func index(_ document: AgentSecureFiles.Document, context: AgentAuthorization) {
        dirty = true
        folded[document.path] = nil
        let data: Data
        do {
            data = try AgentSecureFiles.readDocument(
                library: context.library, path: document.path, maxBytes: context.grant.limits.maxReadBytes)
        } catch let error as AgentAccessError where error == .notFound {
            records[document.path] = nil
            return
        } catch {
            records[document.path] = Record(document, skipped: true)
            return
        }
        guard let text = String(data: data, encoding: .utf8) else {
            records[document.path] = Record(document, skipped: true)
            return
        }
        let revision = Self.revision(data)
        switch MemoryEnvelope.parse(text) {
        case .missing:
            records[document.path] = Record(document, revision: revision, body: text)
        case .envelope(let envelope, let body):
            records[document.path] = Record(
                document, revision: revision, body: String(text[body]), envelope: Envelope(envelope))
        case .failure:
            // #132: no document text for a malformed or newer envelope; it still matches by title.
            records[document.path] = Record(document, revision: revision)
        }
    }

    static func revision(_ data: Data) -> String { "sha256:" + DocumentRevision(data: data).digest }

    // MARK: Search

    func search(
        _ request: AgentMemorySearchRequest, context: AgentAuthorization, freshness: AgentMemoryFreshness,
        reviews: AgentMemoryReviewLookup
    ) throws -> AgentMemorySearchResponse {
        let scope = context.scope
        let compare: String.CompareOptions = scope.caseSensitive ? [] : [.caseInsensitive]
        if let project = request.project, project.compare(scope.project, options: compare) != .orderedSame {
            throw AgentAccessError.outOfScope(scope.readRoots)
        }
        let types = Set(request.types)
        guard types.isSubset(of: MemoryEnvelope.types) else { throw AgentAccessError.invalidArgument("type") }
        guard (1...).contains(request.limit) else { throw AgentAccessError.invalidArgument("limit") }
        let statuses = Set(request.statuses.map { $0.lowercased() })
        let limit = min(request.limit, AgentMemorySearchRequest.maxLimit, context.grant.limits.maxResults)

        // Scope first: nothing outside the read folders is matched, ranked, counted or excerpted.
        let candidates = scope.readable(records.values.filter { !$0.skipped }, path: \.path)
        let ids = documentIDs(context.library)
        let projectRoot = AgentMemoryContract.projectRoot(scope.project)
        var supersededBy: [String: Set<String>] = [:]
        for record in candidates {
            guard let memoryID = record.envelope?.memoryID else { continue }
            for target in record.envelope?.supersedes ?? [] { supersededBy[target, default: []].insert(memoryID) }
        }
        var reviewByMemoryID: [String: AgentMemoryReview] = [:]
        func review(_ record: Record) -> (AgentMemoryReview, Bool) {
            let hint = reviews(ids[record.path], record.path)
            guard let reviewed = hint?.reviewedRevision else { return (.unreviewed, hint?.pinned ?? false) }
            return (reviewed == record.revision ? .reviewed : .reviewedEarlierRevision, hint?.pinned ?? false)
        }
        for record in candidates {
            if let memoryID = record.envelope?.memoryID { reviewByMemoryID[memoryID] = review(record).0 }
        }

        let text = searchFold(request.query).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let terms = text.split(separator: " ").map(String.init)
        struct Hit {
            let record: Record
            let tier: Int
            let sinks: Bool
            let category: Int
            let date: Date
            let documentID: UUID?
            let review: AgentMemoryReview
            let pinned: Bool
        }
        var hits: [Hit] = []
        for record in candidates {
            let envelope = record.envelope
            if !types.isEmpty, !types.contains(envelope?.type ?? "") { continue }
            if !statuses.isEmpty, !statuses.contains(envelope?.status?.lowercased() ?? "\u{0}") { continue }
            if request.project != nil {
                if let owner = envelope?.project {
                    guard owner.compare(scope.project, options: compare) == .orderedSame else { continue }
                } else if !AgentScope.contains(projectRoot, record.path, caseSensitive: scope.caseSensitive) {
                    continue
                }
            }
            let fold =
                folded[record.path]
                ?? (
                    searchFold(record.title), Array(searchFold(record.body).utf8),
                    envelope?.createdAt.flatMap(AgentMemorySearchRequest.date)
                        ?? Date(timeIntervalSince1970: record.modified)
                )
            folded[record.path] = fold
            let date = fold.date
            if let after = request.createdAfter, date < after { continue }
            if let before = request.createdBefore, date >= before { continue }
            guard terms.allSatisfy({ fold.title.contains($0) || Self.contains(fold.body, $0) }) else { continue }
            let tier: Int
            if text.isEmpty || fold.title == text {
                tier = 0
            } else if fold.title.hasPrefix(text) {
                tier = 1
            } else if terms.allSatisfy({ term in
                fold.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(term) }
            }) {
                tier = 2
            } else if terms.allSatisfy({ fold.title.contains($0) }) {
                tier = 3
            } else {
                tier = 4
            }
            let (state, pinned) = review(record)
            let sinks =
                (envelope?.memoryID).flatMap { supersededBy[$0] }?.contains {
                    reviewByMemoryID[$0] == .reviewed
                } ?? false
            let category: Int
            switch envelope?.type {
            case _ where pinned: category = 0
            case "handoff": category = 3
            case "progress": category = 4
            default: category = state == .reviewed ? 1 : 2
            }
            hits.append(
                Hit(
                    record: record, tier: tier, sinks: sinks, category: category, date: date,
                    documentID: ids[record.path], review: state, pinned: pinned))
        }
        // Deterministic: tier, superseded last, kind, newest first, then document ID and path.
        hits.sort { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            if a.sinks != b.sinks { return !a.sinks }
            if a.category != b.category { return a.category < b.category }
            if a.date != b.date { return a.date > b.date }
            let left = a.documentID?.uuidString ?? "~", right = b.documentID?.uuidString ?? "~"
            if left != right { return left < right }
            return a.record.path < b.record.path
        }
        let results = hits.prefix(limit).map { hit in
            AgentMemorySearchResult(
                document: info(
                    hit.record, documentID: hit.documentID, review: hit.review, pinned: hit.pinned,
                    supersededBy: (hit.record.envelope?.memoryID).flatMap { supersededBy[$0] }.map { $0.sorted() }
                        ?? []),
                matchKind: hit.tier == 4 ? .body : .title, excerpt: searchSnippet(hit.record.body, terms: terms).0)
        }
        var message: String?
        if results.isEmpty {
            message =
                freshness.state == .ready
                ? "No matches in " + scope.readRoots.map(AgentMemoryContract.displayPath).joined(separator: ", ") + "."
                : "No matches yet. The index isn’t finished, so this doesn’t mean no memory exists."
        }
        return AgentMemorySearchResponse(results: results, total: hits.count, index: freshness, message: message)
    }

    /// Byte search over folded UTF-8: `String.contains` compares Characters and is far slower on
    /// 10,000 bodies.
    static func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
        var needle = needle
        return needle.withUTF8 { pattern in
            haystack.withUnsafeBytes { bytes in
                pattern.isEmpty || memmem(bytes.baseAddress, bytes.count, pattern.baseAddress, pattern.count) != nil
            }
        }
    }

    private func info(
        _ record: Record, documentID: UUID?, review: AgentMemoryReview, pinned: Bool, supersededBy: [String]
    ) -> AgentMemoryDocumentInfo {
        let envelope = record.envelope
        return AgentMemoryDocumentInfo(
            title: record.title, path: record.path, documentID: documentID, memoryID: envelope?.memoryID,
            revision: record.revision, type: envelope?.type, project: envelope?.project, status: envelope?.status,
            agent: envelope?.agent, session: envelope?.session, createdAt: envelope?.createdAt,
            modified: Date(timeIntervalSince1970: record.modified), review: review, pinned: pinned,
            supersededBy: supersededBy)
    }

    /// Native IDs from the app's `.silkweb/index.json`, decoded again only when that file changes.
    /// A read only: nothing is repaired or created (#131).
    private func documentIDs(_ library: URL) -> [String: UUID] {
        guard let file = try? LibraryMetadataStore.locations(root: library).file else { return [:] }
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return [:] }
        let stamp = [
            Int(info.st_dev), Int(info.st_ino), Int(info.st_size), info.st_mtimespec.tv_sec,
            info.st_mtimespec.tv_nsec,
        ]
        if let metadata, metadata.stamp == stamp { return metadata.ids }
        let loaded = try? LibraryMetadataStore.loadReportingReset(root: library, repair: false)
        let ids = loaded.map { $0.wasReset ? [:] : $0.metadata.IDsByPath } ?? [:]
        metadata = (stamp, ids)
        return ids
    }

    // MARK: Read

    /// The Library-relative path the app index records for a native document ID.
    func path(forDocumentID id: UUID, library: URL) -> String? {
        documentIDs(library).first { $0.value == id }?.key
    }

    func read(
        _ request: AgentMemoryReadRequest, context: AgentAuthorization, reviews: AgentMemoryReviewLookup
    ) throws -> AgentMemoryReadResponse {
        let path = context.path ?? request.path
        guard (path as NSString).pathExtension.lowercased() == "md" else { throw AgentAccessError.notFound }
        let data = try AgentSecureFiles.readDocument(
            library: context.library, path: path, maxBytes: context.grant.limits.maxReadBytes)
        guard let text = String(data: data, encoding: .utf8) else { throw AgentAccessError.notText }
        let revision = Self.revision(data)
        let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var parsed: MemoryEnvelope?
        var body = text
        switch MemoryEnvelope.parse(text) {
        case .missing: break
        case .envelope(let envelope, let range):
            parsed = envelope
            body = String(text[range])
        case .failure(let error): throw AgentAccessError.unreadableEnvelope(error, name: title)
        }
        var offset = 0
        if let cursor = request.cursor {
            guard let parsed = Self.parseCursor(cursor) else { throw AgentAccessError.invalidArgument("cursor") }
            guard parsed.revision == revision else { throw AgentAccessError.staleSnapshot }
            offset = parsed.offset
        }
        let bytes = Array(body.utf8)
        guard offset <= bytes.count else { throw AgentAccessError.invalidArgument("cursor") }
        let end = Self.pageEnd(bytes, from: offset, size: AgentMemoryReadResponse.pageBytes)
        let modified = (try? modificationDate(context.library, path)) ?? Date(timeIntervalSince1970: 0)
        let ids = documentIDs(context.library)
        let hint = reviews(ids[path], path)
        let review: AgentMemoryReview =
            hint?.reviewedRevision.map { $0 == revision ? .reviewed : .reviewedEarlierRevision } ?? .unreviewed
        let envelope = parsed.map(Envelope.init)
        var superseders: [String] = []
        if let memoryID = envelope?.memoryID {
            superseders = context.scope.readable(records.values, path: \.path).compactMap { record in
                record.envelope?.supersedes.contains(memoryID) == true ? record.envelope?.memoryID : nil
            }.sorted()
        }
        let record = Record(
            AgentSecureFiles.Document(path: path, size: data.count, modified: modified), revision: revision,
            body: body, envelope: envelope)
        return AgentMemoryReadResponse(
            document: info(
                record, documentID: ids[path], review: review, pinned: hint?.pinned ?? false,
                supersededBy: superseders),
            envelope: parsed?.fields,
            revisionChanged: request.cursor == nil && request.expectedRevision.map { $0 != revision } == true,
            offset: offset, page: String(decoding: bytes[offset..<end], as: UTF8.self),
            nextCursor: end < bytes.count ? Self.cursor(offset: end, revision: revision) : nil)
    }

    private func modificationDate(_ library: URL, _ path: String) throws -> Date {
        let folder = try AgentSecureFiles.openFolder(
            library: library, path: (path as NSString).deletingLastPathComponent)
        defer { close(folder) }
        var info = stat()
        guard fstatat(folder, (path as NSString).lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw AgentAccessError.notFound
        }
        let time = info.st_mtimespec
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
    }

    /// The end of a page: after the last line break within `size` bytes, or on a UTF-8 scalar boundary
    /// for a single longer line.
    static func pageEnd(_ bytes: [UInt8], from offset: Int, size: Int) -> Int {
        guard bytes.count - offset > size else { return bytes.count }
        var end = offset + size
        if let newline = bytes[offset..<end].lastIndex(of: 0x0A) { return newline + 1 }
        while end > offset + 1, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return end
    }

    /// Opaque to callers: the page offset and the revision it belongs to.
    static func cursor(offset: Int, revision: String) -> String {
        "c1." + String(offset) + "." + revision.dropFirst("sha256:".count)
    }

    static func parseCursor(_ cursor: String) -> (offset: Int, revision: String)? {
        let parts = cursor.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "c1", let offset = Int(parts[1]), offset >= 0, parts[2].count == 64,
            parts[2].allSatisfy(\.isHexDigit)
        else { return nil }
        return (offset, "sha256:" + parts[2])
    }
}

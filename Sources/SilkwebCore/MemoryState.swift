import Foundation

/// The owner's lifecycle decisions for agent memory Documents (#141): `.silkweb/memory-state.json`, `version: 1`,
/// keyed by native document ID. Silkweb suggests and the owner decides: these choices never rewrite file text, and a
/// missing file or key means “unreviewed, not pinned”. The helper reads this file and never writes it.
public struct MemoryStateFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    /// Keyed by `LibraryDocument.id.uuidString`.
    public var documents: [String: MemoryLifecycleEntry]

    public init(documents: [String: MemoryLifecycleEntry] = [:]) {
        version = Self.currentVersion
        self.documents = documents
    }

    public subscript(id: UUID) -> MemoryLifecycleEntry {
        get { documents[id.uuidString] ?? MemoryLifecycleEntry() }
        set { documents[id.uuidString] = newValue.isEmpty ? nil : newValue }
    }

    private enum CodingKeys: String, CodingKey { case version, documents }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // One bad entry drops only that entry.
        documents =
            (try? values.decodeIfPresent([String: MemoryLossy<MemoryLifecycleEntry>].self, forKey: .documents))?
            .compactMapValues(\.value) ?? [:]
    }
}

/// One Document's lifecycle state. Every field is optional on disk.
public struct MemoryLifecycleEntry: Codable, Equatable, Sendable {
    public struct Reviewed: Codable, Equatable, Sendable {
        /// `sha256:…` of the revision the owner reviewed.
        public var revision: String
        public var at: Date
        public init(revision: String, at: Date) {
            self.revision = revision
            self.at = at
        }
    }

    /// A supersession claim as the owner decided it. `claimed` is never saved: it's what an envelope claim without a
    /// matching decision reads as.
    public enum ClaimState: String, Codable, Sendable {
        case claimed
        case accepted
        case declined
    }

    /// The owner's decision on one successor's `supersedes` claim against this Document. Revision-bound: it applies
    /// only while this Document and the successor still have the revisions it was made for.
    public struct Supersession: Codable, Equatable, Sendable {
        /// The successor's `memory_id`.
        public var by: String
        public var state: ClaimState
        public var at: Date
        /// This Document's revision when the owner decided.
        public var revision: String
        /// The successor's revision when the owner decided.
        public var successorRevision: String

        public init(by: String, state: ClaimState, at: Date, revision: String, successorRevision: String) {
            self.by = by
            self.state = state
            self.at = at
            self.revision = revision
            self.successorRevision = successorRevision
        }
    }

    public struct Archived: Codable, Equatable, Sendable {
        public var at: Date
        /// The Library-relative Folder the Document was archived from; Restore moves it back there.
        public var fromPath: String
        public init(at: Date, fromPath: String) {
            self.at = at
            self.fromPath = fromPath
        }
    }

    /// A suggestion the owner dismissed for one revision (Keep, Not a Duplicate, Decline).
    public struct Dismissal: Codable, Equatable, Sendable {
        public var kind: String
        public var revision: String
        public init(kind: String, revision: String) {
            self.kind = kind
            self.revision = revision
        }
    }

    public var reviewed: Reviewed?
    public var pinned = false
    /// The owner's review date. It wins over the envelope's `review_after` (the agent's suggestion).
    public var reviewAfter: Date?
    /// The owner cleared the review date: the envelope's suggestion no longer applies either.
    public var reviewAfterCleared = false
    public var supersession: [Supersession] = []
    public var archived: Archived?
    public var dismissed: [Dismissal] = []

    public init(
        reviewed: Reviewed? = nil, pinned: Bool = false, reviewAfter: Date? = nil, reviewAfterCleared: Bool = false,
        supersession: [Supersession] = [], archived: Archived? = nil, dismissed: [Dismissal] = []
    ) {
        self.reviewed = reviewed
        self.pinned = pinned
        self.reviewAfter = reviewAfter
        self.reviewAfterCleared = reviewAfterCleared
        self.supersession = supersession
        self.archived = archived
        self.dismissed = dismissed
    }

    public var isEmpty: Bool { self == MemoryLifecycleEntry() }

    /// The owner's decision on `successor`'s claim, while both revisions still match; otherwise `claimed`.
    public func claimState(by successor: String, revision: String, successorRevision: String) -> ClaimState {
        guard
            let decision = supersession.last(where: { $0.by == successor }), decision.revision == revision,
            decision.successorRevision == successorRevision
        else { return .claimed }
        return decision.state
    }

    /// Records the owner's decision on one successor's claim, replacing an earlier one.
    public mutating func decide(
        _ state: ClaimState, by successor: String, revision: String, successorRevision: String, at date: Date
    ) {
        supersession.removeAll { $0.by == successor }
        guard state != .claimed else { return }
        supersession.append(
            Supersession(
                by: successor, state: state, at: date, revision: revision, successorRevision: successorRevision))
        supersession.sort { $0.by < $1.by }
    }

    /// The review date in force: the owner's, unless cleared, else the agent's suggestion.
    public func reviewDate(suggested: Date?) -> Date? {
        if let reviewAfter { return reviewAfter }
        return reviewAfterCleared ? nil : suggested
    }

    /// A review date passed and the owner hasn't reviewed since. Only prompts and ranking read this; it never
    /// changes or deletes text.
    public func reviewDue(suggested: Date?, now: Date) -> Bool {
        guard let date = reviewDate(suggested: suggested), date <= now else { return false }
        return (reviewed?.at ?? .distantPast) < date
    }

    private enum CodingKeys: String, CodingKey {
        case reviewed, pinned, reviewAfter, reviewAfterCleared, supersession, archived, dismissed
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reviewed = try? values.decodeIfPresent(Reviewed.self, forKey: .reviewed)
        pinned = (try? values.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        reviewAfter = try? values.decodeIfPresent(Date.self, forKey: .reviewAfter)
        reviewAfterCleared = (try? values.decodeIfPresent(Bool.self, forKey: .reviewAfterCleared)) ?? false
        supersession =
            (try? values.decodeIfPresent([MemoryLossy<Supersession>].self, forKey: .supersession))?
            .compactMap(\.value) ?? []
        archived = try? values.decodeIfPresent(Archived.self, forKey: .archived)
        dismissed =
            (try? values.decodeIfPresent([MemoryLossy<Dismissal>].self, forKey: .dismissed))?.compactMap(\.value)
            ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(reviewed, forKey: .reviewed)
        if pinned { try values.encode(pinned, forKey: .pinned) }
        try values.encodeIfPresent(reviewAfter, forKey: .reviewAfter)
        if reviewAfterCleared { try values.encode(reviewAfterCleared, forKey: .reviewAfterCleared) }
        if !supersession.isEmpty { try values.encode(supersession, forKey: .supersession) }
        try values.encodeIfPresent(archived, forKey: .archived)
        if !dismissed.isEmpty { try values.encode(dismissed, forKey: .dismissed) }
    }
}

/// Decodes one entry, or `nil` when that entry alone is invalid.
struct MemoryLossy<Value: Decodable>: Decodable {
    let value: Value?
    init(from decoder: Decoder) throws { value = try? decoder.singleValueContainer().decode(Value.self) }
}

/// Reads and writes `.silkweb/memory-state.json`. Writes are atomic with sorted keys and ISO 8601 dates.
public enum MemoryStateStore {
    public static let fileName = "memory-state.json"

    public static func url(root: URL) throws -> URL {
        let (directory, _) = try LibraryMetadataStore.locations(root: root)
        let file = directory.appendingPathComponent(fileName)
        try LibraryMetadataStore.rejectLink(file)
        return file
    }

    /// A missing file is an empty state. A file that isn't JSON reads as empty; a newer version throws, so the app
    /// never overwrites what it can't read.
    public static func load(root: URL) throws -> MemoryStateFile {
        let data: Data
        do {
            data = try Data(contentsOf: url(root: root))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            return MemoryStateFile()
        }
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> MemoryStateFile {
        guard let state = try? decoder.decode(MemoryStateFile.self, from: data) else { return MemoryStateFile() }
        guard state.version <= MemoryStateFile.currentVersion else {
            throw LibraryError.unsupportedMetadataVersion(state.version)
        }
        return state
    }

    public static func save(_ state: MemoryStateFile, root: URL) throws {
        let file = try url(root: root)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var saved = state
        saved.version = MemoryStateFile.currentVersion
        try encoder.encode(saved).write(to: file, options: .atomic)
    }

    /// Loads, changes and saves in one step. Returns the saved state.
    @discardableResult
    public static func update(root: URL, _ change: (inout MemoryStateFile) -> Void) throws -> MemoryStateFile {
        var state = try load(root: root)
        change(&state)
        try save(state, root: root)
        return state
    }

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = AgentMemorySearchRequest.date(text) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(), debugDescription: "Not an ISO 8601 date")
            }
            return date
        }
        return decoder
    }()

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// The reserved Folder archived memory moves into: `Memory/Projects/<Project>/Archive` (#141). A real Folder,
/// readable without Silkweb. Agent search leaves out what's in it unless asked.
public enum MemoryArchive {
    public static let folderName = "Archive"

    /// The project a Document belongs to by its path, `nil` outside `Memory/Projects/<Project>/`.
    public static func project(of path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 4, parts[0] == "Memory", parts[1] == "Projects", !parts[2].isEmpty else { return nil }
        return String(parts[2])
    }

    /// `Memory/Projects/<Project>/Archive` for a Document inside a project, else `nil`.
    public static func folder(for path: String) -> String? {
        project(of: path).map { AgentMemoryContract.projectRoot($0) + "/" + folderName }
    }

    /// The Document is inside its project's Archive Folder.
    public static func contains(_ path: String, caseSensitive: Bool = false) -> Bool {
        guard let folder = folder(for: path) else { return false }
        return AgentScope.contains(folder, path, caseSensitive: caseSensitive)
    }
}

/// Integrity problems in the in-scope memory graph (#141): reported, never repaired.
public struct AgentMemoryDiagnostic: Equatable, Sendable {
    public enum Code: String, Sendable {
        /// Two or more Documents carry the same `memory_id`.
        case duplicateMemoryID = "duplicate_memory_id"
        /// `supersedes` claims form a loop.
        case supersessionCycle = "supersession_cycle"
        /// More than one Document claims to replace the same one, and the owner declined none of them.
        case conflictingSuccessors = "conflicting_successors"
    }

    public let code: Code
    /// Duplicate: the shared ID. Cycle: the members, sorted. Conflict: the replaced Document's ID.
    public let memoryIDs: [String]
    /// Duplicate: the Documents' paths. Conflict: the successors' `memory_id`s. Cycle: empty.
    public let related: [String]

    public init(code: Code, memoryIDs: [String], related: [String] = []) {
        self.code = code
        self.memoryIDs = memoryIDs
        self.related = related
    }

    /// One line for people: Info and the CLI's stderr.
    public var message: String {
        switch code {
        case .duplicateMemoryID:
            return "\(related.count) documents share the memory ID \(memoryIDs.first ?? "")."
        case .supersessionCycle:
            return "These documents replace each other in a loop: " + memoryIDs.joined(separator: ", ") + "."
        case .conflictingSuccessors:
            return "\(related.count) documents claim to replace \(memoryIDs.first ?? "")."
        }
    }

    /// Duplicate IDs, cycles and conflicting successors among `documents` (memory ID, its `supersedes` claims and
    /// path). `declined(target, successor)` is true when the owner declined that claim.
    public static func find(
        _ documents: [(memoryID: String, supersedes: [String], path: String)],
        declined: (_ target: String, _ successor: String) -> Bool = { _, _ in false }
    ) -> [AgentMemoryDiagnostic] {
        var results: [AgentMemoryDiagnostic] = []
        var paths: [String: [String]] = [:]
        var claims: [String: Set<String>] = [:]
        for document in documents {
            paths[document.memoryID, default: []].append(document.path)
            claims[document.memoryID, default: []].formUnion(document.supersedes)
        }
        for (id, list) in paths.sorted(by: { $0.key < $1.key }) where list.count > 1 {
            results.append(AgentMemoryDiagnostic(code: .duplicateMemoryID, memoryIDs: [id], related: list.sorted()))
        }
        // Cycles: each strongly connected loop once, by its sorted members.
        var seen = Set<[String]>()
        for start in claims.keys.sorted() {
            var stack: [(String, [String])] = [(start, [start])]
            var visited = Set<String>()
            while let (node, trail) = stack.popLast() {
                for next in (claims[node] ?? []).sorted() {
                    if next == start {
                        let members = trail.sorted()
                        if seen.insert(members).inserted {
                            results.append(AgentMemoryDiagnostic(code: .supersessionCycle, memoryIDs: members))
                        }
                    } else if claims[next] != nil, visited.insert(next).inserted {
                        stack.append((next, trail + [next]))
                    }
                }
            }
        }
        var successors: [String: Set<String>] = [:]
        for (successor, targets) in claims {
            for target in targets where target != successor && !declined(target, successor) {
                successors[target, default: []].insert(successor)
            }
        }
        for (target, list) in successors.sorted(by: { $0.key < $1.key }) where list.count > 1 {
            results.append(
                AgentMemoryDiagnostic(code: .conflictingSuccessors, memoryIDs: [target], related: list.sorted()))
        }
        return results
    }
}

/// One Document's portable identity and its `supersedes` claims, as the app's knowledge index read them (#141).
public struct MemoryLink: Equatable, Sendable {
    public var memoryID: String
    public var supersedes: [String]

    public init(memoryID: String, supersedes: [String] = []) {
        self.memoryID = memoryID
        self.supersedes = supersedes
    }
}

/// Lookups over the Library's memory links: who carries an ID, and who claims to replace it.
public struct MemoryLinkMap: Equatable, Sendable {
    public private(set) var links: [String: MemoryLink] = [:]
    /// `memory_id` → paths, sorted.
    public private(set) var paths: [String: [String]] = [:]
    /// `memory_id` → paths of Documents whose `supersedes` names it, sorted.
    public private(set) var claimants: [String: [String]] = [:]

    public init(_ links: [String: MemoryLink] = [:]) {
        self.links = links
        for (path, link) in links {
            paths[link.memoryID, default: []].append(path)
            for target in Set(link.supersedes) where target != link.memoryID {
                claimants[target, default: []].append(path)
            }
        }
        for key in paths.keys { paths[key]?.sort() }
        for key in claimants.keys { claimants[key]?.sort() }
    }

    /// The first Document carrying `memoryID`, by path.
    public func path(of memoryID: String) -> String? { paths[memoryID]?.first }

    /// Integrity problems across the whole Library (#141), as agent search reports them for its scope.
    public func diagnostics(declined: (_ target: String, _ successor: String) -> Bool = { _, _ in false })
        -> [AgentMemoryDiagnostic]
    {
        AgentMemoryDiagnostic.find(
            links.sorted { $0.key < $1.key }.map { ($0.value.memoryID, $0.value.supersedes, $0.key) },
            declined: declined)
    }
}

extension MemoryStateStore {
    /// `sha256:` + hex digest of a Document's bytes, the revision lifecycle decisions are bound to.
    public static func revision(_ data: Data) -> String { "sha256:" + DocumentRevision(data: data).digest }
}

/// #141: the summary Document an applied merge creates. Its sources stay where they are unless the owner archives or
/// trashes them.
public enum MemoryConsolidation {
    public struct Source: Equatable, Sendable {
        public var title: String
        /// Library-relative path.
        public var path: String
        public var memoryID: String?

        public init(title: String, path: String, memoryID: String?) {
            self.title = title
            self.path = path
            self.memoryID = memoryID
        }
    }

    /// The merged text: when any source carries a `memory_id`, a v1 envelope with `consolidates`, then the body, then
    /// a “Sources” list of relative links. `folder` is the Library-relative Folder the summary goes into.
    public static func document(
        body: String, sources: [Source], folder: String, project: String, agent: String, session: String,
        createdAt: Date, memoryID: String? = nil
    ) -> String {
        let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
        let links = sources.map { "- [\($0.title)](<\(relativeLink(from: folder, to: $0.path))>)" }
        let text = trimmed + "\n\n## Sources\n\n" + links.joined(separator: "\n") + "\n"
        let ids = sources.compactMap(\.memoryID)
        guard !ids.isEmpty else { return text }
        var envelope = MemoryEnvelope(
            memoryID: memoryID ?? AgentCreateService.memoryID(), type: "memory", project: project, agent: agent,
            session: session, createdAt: createdAt)
        envelope["consolidates"] = .list(ids)
        return (try? envelope.document(body: text)) ?? text
    }

    /// A relative link from a Document in `folder` to `path`, both Library-relative.
    public static func relativeLink(from folder: String, to path: String) -> String {
        let from = folder.split(separator: "/").map(String.init)
        let to = path.split(separator: "/").map(String.init)
        var shared = 0
        while shared < from.count, shared < to.count - 1, from[shared] == to[shared] { shared += 1 }
        return (Array(repeating: "..", count: from.count - shared) + to[shared...]).joined(separator: "/")
    }
}

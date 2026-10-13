import Darwin
import Foundation

/// One owner-reviewed **Proposal** (#140, `docs/agent-memory.md` › Proposals): an agent suggests a body edit, a
/// move, a rename or a merge, and only the owner applies it in Silkweb. Stored as versioned JSON in
/// `.silkweb/proposals/<proposalId>.json`, so a Proposal never shows up as a Document, in search or in the tree.
/// Decoded tolerantly: missing keys get defaults, so files saved by earlier builds still load.
public struct AgentProposal: Codable, Equatable, Sendable, Identifiable {
    public static let currentVersion = 1

    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Replace the body (everything after a Silkweb envelope, else the whole text) of one Document.
        case edit
        /// Move one Document into another Folder, keeping its identity and rewriting links.
        case move
        /// Rename one Document, keeping its identity and rewriting links.
        case rename
        /// Create one new Document from several; the sources stay unless the owner asks to trash them.
        case merge
    }

    public enum Status: String, Codable, Sendable {
        case pending, applied, rejected
    }

    /// A Document the Proposal is about, as the agent read it.
    public struct Target: Codable, Equatable, Sendable {
        /// Library-relative, as spelled on disk when the Proposal was made.
        public var path: String
        /// The app index's document UUID, which follows renames and moves; `nil` when the index didn't know it.
        public var documentId: UUID?
        /// `sha256:` of the Document's bytes when the Proposal was made. Apply needs the same bytes.
        public var baseRevision: String

        public init(path: String, documentId: UUID?, baseRevision: String) {
            self.path = path
            self.documentId = documentId
            self.baseRevision = baseRevision
        }

        private enum CodingKeys: String, CodingKey { case path, documentId, baseRevision }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            path = (try? values.decodeIfPresent(String.self, forKey: .path)) ?? nil ?? ""
            documentId = ((try? values.decodeIfPresent(String.self, forKey: .documentId)) ?? nil)
                .flatMap(UUID.init(uuidString:))
            baseRevision = (try? values.decodeIfPresent(String.self, forKey: .baseRevision)) ?? nil ?? ""
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(path, forKey: .path)
            try values.encode(documentId?.uuidString, forKey: .documentId)
            try values.encode(baseRevision, forKey: .baseRevision)
        }
    }

    public var version = currentVersion
    /// `prop_` + 32 hex characters, derived from the grant and the idempotency key.
    public var proposalId: String
    public var kind: Kind
    public var status: Status
    /// ISO 8601 UTC.
    public var createdAt: String
    /// When the owner applied or rejected it (ISO 8601 UTC); `nil` while pending.
    public var decidedAt: String?
    /// Claims, never authentication.
    public var agent: String
    public var session: String
    public var client: String
    /// The grant's project key.
    public var grantId: String
    public var idempotencyKey: String
    public var requestDigest: String
    /// The agent's one-paragraph reason, plain text.
    public var reason: String
    /// One Document for edit, move and rename; the sources, in order, for merge.
    public var targets: [Target]
    /// Edit: the new body. Merge: the new Document's text.
    public var body: String?
    /// Move and merge: the Library-relative Folder (`""` is the Library itself).
    public var destination: String?
    /// Rename: the new title (the filename without `.md`). Merge: the new Document's title.
    public var title: String?
    /// Set by the app on apply: where the result is (the moved or renamed Document, the merged one).
    public var appliedPath: String?

    public var id: String { proposalId }
    public var isPending: Bool { status == .pending }

    public init(
        proposalId: String, kind: Kind, status: Status = .pending, createdAt: String, decidedAt: String? = nil,
        agent: String, session: String, client: String, grantId: String, idempotencyKey: String,
        requestDigest: String, reason: String, targets: [Target], body: String? = nil, destination: String? = nil,
        title: String? = nil, appliedPath: String? = nil
    ) {
        self.proposalId = proposalId
        self.kind = kind
        self.status = status
        self.createdAt = createdAt
        self.decidedAt = decidedAt
        self.agent = agent
        self.session = session
        self.client = client
        self.grantId = grantId
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
        self.reason = reason
        self.targets = targets
        self.body = body
        self.destination = destination
        self.title = title
        self.appliedPath = appliedPath
    }

    private enum CodingKeys: String, CodingKey {
        case version, proposalId, kind, status, createdAt, decidedAt, agent, session, client, grantId
        case idempotencyKey, requestDigest, reason, targets, body, destination, title, appliedPath
    }

    /// An unknown `kind` from a newer build can't be reviewed here, so the file is skipped; an unknown `status`
    /// reads as rejected, so nothing unknown is ever applicable.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let string = { (key: CodingKeys) in (try? values.decodeIfPresent(String.self, forKey: key)) ?? nil }
        version = (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? nil ?? 1
        proposalId = string(.proposalId) ?? ""
        guard let kind = string(.kind).flatMap(Kind.init(rawValue:)) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: values, debugDescription: "Unknown proposal kind")
        }
        self.kind = kind
        status = string(.status).map { Status(rawValue: $0) ?? .rejected } ?? .pending
        createdAt = string(.createdAt) ?? ""
        decidedAt = string(.decidedAt)
        agent = string(.agent) ?? ""
        session = string(.session) ?? ""
        client = string(.client) ?? ""
        grantId = string(.grantId) ?? ""
        idempotencyKey = string(.idempotencyKey) ?? ""
        requestDigest = string(.requestDigest) ?? ""
        reason = string(.reason) ?? ""
        targets = (try? values.decodeIfPresent([Target].self, forKey: .targets)) ?? nil ?? []
        body = string(.body)
        destination = string(.destination)
        title = string(.title)
        appliedPath = string(.appliedPath)
    }

    /// Every key is written, `null` included, so Proposals from one version all have the same shape.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(proposalId, forKey: .proposalId)
        try values.encode(kind, forKey: .kind)
        try values.encode(status, forKey: .status)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(decidedAt, forKey: .decidedAt)
        try values.encode(agent, forKey: .agent)
        try values.encode(session, forKey: .session)
        try values.encode(client, forKey: .client)
        try values.encode(grantId, forKey: .grantId)
        try values.encode(idempotencyKey, forKey: .idempotencyKey)
        try values.encode(requestDigest, forKey: .requestDigest)
        try values.encode(reason, forKey: .reason)
        try values.encode(targets, forKey: .targets)
        try values.encode(body, forKey: .body)
        try values.encode(destination, forKey: .destination)
        try values.encode(title, forKey: .title)
        try values.encode(appliedPath, forKey: .appliedPath)
    }

    public var created: Date? { AgentActivity.date(createdAt) }
    public var decided: Date? { decidedAt.flatMap(AgentActivity.date) }

    /// The list row's verb phrase (design notes): Edit “Fix sidebar drag” · Rename “Notes” to “Sidebar Notes” ·
    /// Move “X” to Memory › Projects › Silkweb › Archive · Merge 3 Documents into “Y”. `name` gives a target's
    /// current title (it may have been renamed since); the Proposal's own path is the fallback.
    public func headline(name: (Target) -> String? = { _ in nil }) -> String {
        let first = targets.first.map { name($0) ?? Self.title(of: $0.path) } ?? ""
        switch kind {
        case .edit: return "Edit “\(first)”"
        case .rename: return "Rename “\(first)” to “\(title ?? "")”"
        case .move:
            let folder = destination ?? ""
            return "Move “\(first)” to " + (folder.isEmpty ? "the Library" : AgentMemoryContract.displayPath(folder))
        case .merge: return "Merge \(targets.count) Documents into “\(title ?? "")”"
        }
    }

    /// “Pending”, “Applied” or “Rejected”; the app says “Out of Date” instead of Pending when a base changed.
    public var statusLabel: String {
        switch status {
        case .pending: return "Pending"
        case .applied: return "Applied"
        case .rejected: return "Rejected"
        }
    }

    /// A Document's title: its filename without the extension.
    public static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// The bytes an edit leaves: the current envelope (and the blank line after it) kept byte for byte, then the
    /// proposed body. `nil` for another kind, or when the current text's envelope can't be read.
    public func editedText(current: String) -> String? {
        guard kind == .edit, let body else { return nil }
        switch MemoryEnvelope.parse(current) {
        case .missing: return body
        case .failure: return nil
        case .envelope(_, let range): return String(current[..<range.lowerBound]) + body
        }
    }
}

/// `.silkweb/proposals/`: read for display without writing anything, and written atomically (sorted keys) by the
/// helper's propose and the app's apply and reject. Never followed through links.
public enum AgentProposalStore {
    public static let folder = "proposals"
    /// One Proposal file, body included, is read up to this size; anything bigger is skipped.
    static let maxFileBytes = 8 << 20

    /// Every readable Proposal, newest first. Unreadable, oversized, temporary and undecodable files are skipped,
    /// never repaired.
    public static func load(root: URL) -> [AgentProposal] {
        guard let library = try? AgentCreateFiles.openRoot(root) else { return [] }
        defer { close(library) }
        guard let descriptor = try? AgentCreateFiles.metadataFolder(library, folder, create: false) else { return [] }
        defer { close(descriptor) }
        let decoder = JSONDecoder()
        return AgentCreateFiles.names(descriptor).compactMap { name -> AgentProposal? in
            guard name.hasSuffix(".json"), !name.hasPrefix("."), !name.contains(".tmp-"),
                let data = AgentCreateFiles.read(descriptor, name, maxBytes: maxFileBytes + 1),
                data.count <= maxFileBytes,
                let proposal = try? decoder.decode(AgentProposal.self, from: data),
                proposal.proposalId + ".json" == name
            else { return nil }
            return proposal
        }.sorted(by: isNewer)
    }

    /// Whether any Proposal file exists, without decoding anything.
    public static func exists(root: URL) -> Bool {
        guard let library = try? AgentCreateFiles.openRoot(root) else { return false }
        defer { close(library) }
        guard let descriptor = try? AgentCreateFiles.metadataFolder(library, folder, create: false) else {
            return false
        }
        defer { close(descriptor) }
        return AgentCreateFiles.names(descriptor).contains { $0.hasSuffix(".json") && !$0.contains(".tmp-") }
    }

    /// Newest `createdAt` first, then by ID, so the order never depends on directory order.
    static func isNewer(_ lhs: AgentProposal, _ rhs: AgentProposal) -> Bool {
        let left = lhs.created ?? .distantPast
        let right = rhs.created ?? .distantPast
        if left != right { return left > right }
        return lhs.proposalId < rhs.proposalId
    }

    static func read(_ id: String, root: Int32) -> AgentProposal? {
        guard let descriptor = try? AgentCreateFiles.metadataFolder(root, folder, create: false) else { return nil }
        defer { close(descriptor) }
        return AgentCreateFiles.read(descriptor, id + ".json", maxBytes: maxFileBytes).flatMap {
            try? JSONDecoder().decode(AgentProposal.self, from: $0)
        }
    }

    static func write(_ proposal: AgentProposal, root: Int32) throws {
        let descriptor = try AgentCreateFiles.metadataFolder(root, folder, create: true)!
        defer { close(descriptor) }
        try AgentCreateFiles.writeAtomic(descriptor, proposal.proposalId + ".json", AgentReceipt.encoded(proposal))
    }

    /// The app's decision (apply, reject or an undo of either): rereads the file inside the Library gate, changes
    /// it and replaces it atomically. Returns the Proposal as saved.
    @discardableResult
    public static func update(
        _ id: String, root: URL, timeout: Duration = LibraryGate.defaultTimeout,
        _ change: (inout AgentProposal) throws -> Void
    ) throws -> AgentProposal {
        try LibraryGate(root: root).withLease(timeout: timeout) {
            let library = try AgentCreateFiles.openRoot(root)
            defer { close(library) }
            guard var proposal = read(id, root: library) else { throw AgentProposalError.missing }
            try change(&proposal)
            try write(proposal, root: library)
            return proposal
        }
    }
}

/// The owner's apply path for a body edit (#140) and its undo: one atomic replace of a Document, holding the
/// Library gate, only while its bytes are still `expected` and Silkweb has no unsaved changes for it. The file's
/// permissions are kept. Returns the bytes it replaced, for Undo.
public enum AgentProposalApply {
    @discardableResult
    public static func replace(
        root: URL, path: String, expected: String, with data: Data, timeout: Duration = LibraryGate.defaultTimeout
    ) throws -> Data {
        let name = AgentProposal.title(of: path)
        return try LibraryGate(root: root).withLease(timeout: timeout) {
            let library = try AgentCreateFiles.openRoot(root)
            defer { close(library) }
            guard
                let folder = try AgentCreateFiles.folder(
                    library, (path as NSString).deletingLastPathComponent, create: false)
            else { throw AgentProposalError.sourceMissing }
            defer { close(folder.descriptor) }
            let file = (path as NSString).lastPathComponent
            var info = stat()
            guard fstatat(folder.descriptor, file, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG,
                let current = AgentCreateFiles.read(folder.descriptor, file, maxBytes: Int(info.st_size) + 1)
            else { throw AgentProposalError.sourceMissing }
            guard AgentCreateService.digest(current) == expected else { throw AgentProposalError.outOfDate(name) }
            guard !DocumentEditingMarker.isHeld(library: root, relativePath: path) else {
                throw AgentProposalError.unsavedChanges(name)
            }
            let staged = ".silkweb-proposal-" + UUID().uuidString
            try AgentCreateFiles.writeExclusive(folder.descriptor, staged, data)
            _ = fchmodat(folder.descriptor, staged, info.st_mode & 0o7777, 0)
            guard renameat(folder.descriptor, staged, folder.descriptor, file) == 0 else {
                let code = errno
                _ = unlinkat(folder.descriptor, staged, 0)
                throw AgentCreateFiles.posix(code)
            }
            _ = fsync(folder.descriptor)
            return current
        }
    }

    /// The current revision of a Document, or `nil` when it isn't a readable regular file. Never follows links.
    public static func revision(root: URL, path: String) -> (revision: String, text: String?)? {
        guard let library = try? AgentCreateFiles.openRoot(root) else { return nil }
        defer { close(library) }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        var data: Data?
        if parent.isEmpty {
            data = AgentCreateFiles.read(library, name, maxBytes: maxPreviewBytes)
        } else if let folder = try? AgentCreateFiles.folder(library, parent, create: false) {
            data = AgentCreateFiles.read(folder.descriptor, name, maxBytes: maxPreviewBytes)
            close(folder.descriptor)
        }
        guard let data, data.count < maxPreviewBytes else { return nil }
        return (AgentCreateService.digest(data), String(data: data, encoding: .utf8))
    }

    /// The review pane reads a target whole to compare revisions; anything larger can't be reviewed.
    public static let maxPreviewBytes = 16 << 20

    /// `sha256:` + hex, the revision form Proposals record.
    public static func revision(of data: Data) -> String { AgentCreateService.digest(data) }
}

/// Why the app can't apply or decide a Proposal. Messages are the review pane's banner sentences.
public enum AgentProposalError: Error, Equatable, LocalizedError {
    /// The Proposal file is gone (another window or a Finder change).
    case missing
    /// A target's bytes aren't the Proposal's base revision any more.
    case outOfDate(String)
    /// A target has unsaved changes in Silkweb.
    case unsavedChanges(String)
    /// A target isn't in the Library any more.
    case sourceMissing
    /// The Proposal was already applied or rejected.
    case decided

    public var errorDescription: String? {
        switch self {
        case .missing: return "This proposal is no longer in the Library."
        case .outOfDate(let name): return "“\(name)” changed after this proposal was made."
        case .unsavedChanges(let name): return "“\(name)” has unsaved changes. Save or discard them before applying."
        case .sourceMissing: return "This Document is no longer in the Library."
        case .decided: return "This proposal was already decided."
        }
    }
}

/// One `memory propose-change` or `memory propose-organization` request (#140).
public struct AgentProposeRequest: Equatable, Sendable {
    public var kind: AgentProposal.Kind
    public var idempotencyKey: String
    /// The Document (edit, move, rename): a Library-relative path, or `documentID`.
    public var path: String?
    public var documentID: UUID?
    /// Merge: the source Documents' Library-relative paths, in order.
    public var sources: [String]
    /// The `revision` from `memory_read`. Required for edits; checked when given for the other kinds.
    public var expectedRevision: String?
    public var body: String?
    public var destination: String?
    public var title: String?
    public var reason: String
    public var agent: String
    public var session: String
    /// Recorded only; not part of the payload.
    public var client: String

    public init(
        kind: AgentProposal.Kind, idempotencyKey: String, path: String? = nil, documentID: UUID? = nil,
        sources: [String] = [], expectedRevision: String? = nil, body: String? = nil, destination: String? = nil,
        title: String? = nil, reason: String, agent: String, session: String, client: String = "cli"
    ) {
        self.kind = kind
        self.idempotencyKey = idempotencyKey
        self.path = path
        self.documentID = documentID
        self.sources = sources
        self.expectedRevision = expectedRevision
        self.body = body
        self.destination = destination
        self.title = title
        self.reason = reason
        self.agent = agent
        self.session = session
        self.client = client
    }

    /// `sha256:` over the payload as canonical JSON. Everything the agent chose counts except `client`.
    public var digest: String {
        let payload: [String: Any] = [
            "kind": kind.rawValue, "path": path ?? NSNull(), "document_id": documentID?.uuidString ?? NSNull(),
            "sources": sources, "expected_revision": expectedRevision ?? NSNull(), "body": body ?? NSNull(),
            "destination": destination ?? NSNull(), "title": title ?? NSNull(), "reason": reason, "agent": agent,
            "session": session,
        ]
        let data =
            (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return AgentCreateService.digest(data)
    }
}

/// What a propose returns. A replay is the original Proposal with `replayed`, never an error.
public struct AgentProposeResult: Equatable, Sendable {
    public let proposal: AgentProposal
    public let replayed: Bool

    /// `{"createdAt", "kind", "proposalId", "replayed", "status"}`. Never document text.
    public var json: AgentJSON {
        let fields: [String: Any] = [
            "proposalId": proposal.proposalId, "kind": proposal.kind.rawValue, "status": proposal.status.rawValue,
            "createdAt": proposal.createdAt, "replayed": replayed,
        ]
        return AgentJSON(sortingKeysOf: fields)
    }
}

/// Saves an agent's Proposal (#140) for the owner to review. Nothing in the Library changes: the helper validates
/// the targets (inside the read folders, `.md`, at the revision the agent read) and writes one JSON file under
/// `.silkweb/proposals/`, holding the Library gate. Only the owner applies a Proposal, in Silkweb.
public struct AgentProposeService: Sendable {
    /// At most this many pending Proposals per Library; more is `too_many_proposals` until the owner reviews.
    public static let maxPending = 100
    /// The reason is one paragraph of plain text.
    public static let maxReasonLength = 1_000
    /// A merge takes 2 to 10 Documents.
    public static let mergeSources = 2...10

    let library: URL
    let grantId: String
    let scope: AgentScope
    /// The largest Document a Proposal may leave behind (an edit's finished text, a merge's new Document).
    let maxBytes: Int
    let maxReadBytes: Int
    var now: @Sendable () -> Date = { Date() }
    var gateTimeout = LibraryGate.defaultTimeout

    public init(authorization: AgentAuthorization) {
        self.init(
            library: authorization.library, grantId: authorization.grant.project, scope: authorization.scope,
            maxBytes: authorization.grant.limits.maxCreateBytes, maxReadBytes: authorization.grant.limits.maxReadBytes)
    }

    init(library: URL, grantId: String, scope: AgentScope, maxBytes: Int, maxReadBytes: Int) {
        self.library = library
        self.grantId = grantId
        self.scope = scope
        self.maxBytes = maxBytes
        self.maxReadBytes = maxReadBytes
    }

    private var creates: AgentCreateService {
        AgentCreateService(library: library, grantId: grantId, scope: scope, maxBytes: maxBytes)
    }

    public func propose(_ request: AgentProposeRequest) throws -> AgentProposeResult {
        try AgentCreateService.validateKey(request.idempotencyKey)
        let reason = try Self.reason(request.reason)
        let id = proposalID(request.idempotencyKey)
        let digest = request.digest
        return try creates.mapFilesystemErrors {
            try LibraryGate(root: library).withLease(timeout: gateTimeout) {
                let root = try AgentCreateFiles.openRoot(library)
                defer { close(root) }
                if let existing = AgentProposalStore.read(id, root: root) {
                    guard existing.requestDigest == digest else { throw AgentAccessError.idempotencyConflict }
                    return AgentProposeResult(proposal: existing, replayed: true)
                }
                let pending = AgentProposalStore.load(root: library).filter(\.isPending).count
                guard pending < Self.maxPending else { throw AgentAccessError.tooManyProposals(Self.maxPending) }
                let proposal = try plan(request, id: id, digest: digest, reason: reason)
                try AgentProposalStore.write(proposal, root: root)
                return AgentProposeResult(proposal: proposal, replayed: false)
            }
        }
    }

    /// Scope, identity, revision, name and size checks, and the Proposal as it's saved.
    private func plan(_ request: AgentProposeRequest, id: String, digest: String, reason: String) throws
        -> AgentProposal
    {
        var proposal = AgentProposal(
            proposalId: id, kind: request.kind, createdAt: MemoryEnvelope.timestamp(now()), agent: request.agent,
            session: request.session, client: request.client, grantId: grantId,
            idempotencyKey: request.idempotencyKey, requestDigest: digest, reason: reason, targets: [])
        switch request.kind {
        case .edit:
            guard let expected = request.expectedRevision else {
                throw AgentAccessError.invalidArgument("expected-revision")
            }
            let (target, text) = try resolve(request.path, id: request.documentID, expected: expected)
            let body = request.body ?? ""
            try Self.checkNoEnvelope(body, name: AgentProposal.title(of: target.path))
            proposal.targets = [target]
            proposal.body = body
            guard let edited = proposal.editedText(current: text) else {
                if case .failure(let error) = MemoryEnvelope.parse(text) {
                    throw AgentAccessError.envelope(error, name: AgentProposal.title(of: target.path))
                }
                throw AgentAccessError.invalidArgument("body")
            }
            guard edited != text else {
                throw AgentAccessError.invalidRequest(
                    "The proposed text is the same as the document’s. Nothing was saved.")
            }
            guard edited.utf8.count <= maxBytes else { throw Self.tooLarge(maxBytes) }
        case .move:
            let (target, _) = try resolve(request.path, id: request.documentID, expected: request.expectedRevision)
            let folder = try existingFolder(request.destination)
            guard !Self.same((target.path as NSString).deletingLastPathComponent, folder, scope) else {
                throw AgentAccessError.invalidRequest("The document is already in that folder. Nothing was saved.")
            }
            proposal.targets = [target]
            proposal.destination = folder
        case .rename:
            let (target, _) = try resolve(request.path, id: request.documentID, expected: request.expectedRevision)
            let title = try Self.validTitle(request.title, extension: (target.path as NSString).pathExtension)
            guard title.compare(AgentProposal.title(of: target.path)) != .orderedSame else {
                throw AgentAccessError.invalidRequest("The document already has that name. Nothing was saved.")
            }
            proposal.targets = [target]
            proposal.title = title
        case .merge:
            let sources = request.sources.map(AgentHelper.nfc)
            guard Self.mergeSources.contains(sources.count) else {
                throw AgentAccessError.invalidRequest("A merge needs 2 to 10 source documents.")
            }
            var targets: [AgentProposal.Target] = []
            for source in sources {
                let (target, _) = try resolve(source, id: nil, expected: nil)
                guard !targets.contains(where: { Self.same($0.path, target.path, scope) }) else {
                    throw AgentAccessError.invalidRequest("Each source document can be named only once.")
                }
                targets.append(target)
            }
            let title = try Self.validTitle(request.title, extension: "md")
            let folder = try existingFolder(request.destination)
            let body = request.body ?? ""
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentAccessError.invalidArgument("body")
            }
            try Self.checkNoEnvelope(body, name: title)
            guard body.utf8.count <= maxBytes else { throw Self.tooLarge(maxBytes) }
            proposal.targets = targets
            proposal.title = title
            proposal.destination = folder
            proposal.body = body
        }
        return proposal
    }

    /// One Document inside the read folders: its on-disk path, index identity and current revision, and its text.
    private func resolve(_ path: String?, id: UUID?, expected: String?) throws -> (AgentProposal.Target, String) {
        let index = AgentCreateService.index(library)
        var requested = path ?? ""
        if let id {
            // An ID the index doesn't know and one outside the read folders look the same.
            guard let known = index?.IDsByPath.first(where: { $0.value == id })?.key,
                (try? scope.checkRead(known)) != nil
            else { throw AgentAccessError.notFound }
            requested = known
        }
        let normalized: String
        do {
            normalized = try scope.checkRead(requested)
        } catch let error as AgentScopeError {
            throw AgentAccessError.scope(error, in: scope)
        }
        guard ["md", "markdown"].contains((normalized as NSString).pathExtension.lowercased()) else {
            throw AgentAccessError.notFound
        }
        let root = try AgentCreateFiles.openRoot(library)
        defer { close(root) }
        guard
            let folder = try AgentCreateFiles.folder(
                root, (normalized as NSString).deletingLastPathComponent, create: false)
        else { throw AgentAccessError.notFound }
        defer { close(folder.descriptor) }
        let requestedName = (normalized as NSString).lastPathComponent
        var info = stat()
        guard fstatat(folder.descriptor, requestedName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw AgentAccessError.notFound
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw AgentAccessError.invalidPath }
        let name =
            AgentCreateFiles.entries(folder.descriptor).first { $0.inode == UInt64(info.st_ino) }?.name ?? requestedName
        let stored = folder.path.isEmpty ? name : folder.path + "/" + name
        guard let data = AgentCreateFiles.read(folder.descriptor, name, maxBytes: maxReadBytes + 1) else {
            throw AgentAccessError.notFound
        }
        guard data.count <= maxReadBytes else { throw AgentAccessError.tooLarge(limit: maxReadBytes) }
        guard let text = String(data: data, encoding: .utf8) else { throw AgentAccessError.notText }
        let revision = AgentCreateService.digest(data)
        if let expected, expected != revision { throw AgentAccessError.revisionChanged(current: revision) }
        return (
            AgentProposal.Target(path: stored, documentId: index?.IDsByPath[stored], baseRevision: revision), text
        )
    }

    /// A Folder inside the read folders that exists. `""` (the Library itself) is only allowed when a read folder
    /// is the Library, which `AgentScope` never allows, so it's refused like any other out-of-scope Folder.
    private func existingFolder(_ path: String?) throws -> String {
        guard let path = path.map(AgentHelper.nfc), !path.isEmpty else {
            throw AgentAccessError.invalidArgument("destination")
        }
        let normalized: String
        do {
            normalized = try scope.checkRead(path)
        } catch let error as AgentScopeError {
            throw AgentAccessError.scope(error, in: scope)
        }
        let root = try AgentCreateFiles.openRoot(library)
        defer { close(root) }
        guard let folder = try AgentCreateFiles.folder(root, normalized, create: false) else {
            throw AgentAccessError(
                code: "not_found", title: "Folder Not Found", message: "There’s no folder at that location.")
        }
        close(folder.descriptor)
        return folder.path
    }

    /// A Document title the owner's rename rules accept, never an instruction file.
    static func validTitle(_ title: String?, extension ext: String) throws -> String {
        let trimmed = AgentHelper.nfc(title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = trimmed + "." + (ext.isEmpty ? "md" : ext)
        guard !trimmed.isEmpty, (try? LibraryMutations.validateName(fileName)) == fileName else {
            throw AgentAccessError.invalidArgument("title")
        }
        guard !AgentMemoryContract.instructionFiles.contains(fileName.lowercased()) else {
            throw AgentAccessError.excluded
        }
        return trimmed
    }

    /// One line of plain text: control characters (line breaks included) become spaces, runs collapse, and it
    /// must be 1 to 1,000 characters.
    static func reason(_ text: String) throws -> String {
        let flattened = String(
            String.UnicodeScalarView(
                text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }))
        let reason = flattened.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard !reason.isEmpty, reason.count <= maxReasonLength else {
            throw AgentAccessError.invalidRequest("The reason must be 1 to \(maxReasonLength) characters.")
        }
        return reason
    }

    /// The helper keeps the only envelope; text that brings a Silkweb envelope is refused, never merged.
    static func checkNoEnvelope(_ text: String, name: String) throws {
        switch MemoryEnvelope.parse(text) {
        case .missing: return
        case .failure(let error): throw AgentAccessError.envelope(error, name: name)
        case .envelope: throw AgentAccessError.envelope(.invalidField("schema"), name: name)
        }
    }

    static func tooLarge(_ limit: Int) -> AgentAccessError {
        AgentAccessError(
            code: "too_large", title: "Proposal Too Large",
            message: "This proposal is larger than the grant allows (\(max(1, limit / 1024)) KB). Nothing was saved.")
    }

    /// Paths compared like the volume: whole components, case only on a case-sensitive one.
    static func same(_ lhs: String, _ rhs: String, _ scope: AgentScope) -> Bool {
        let left = lhs.split(separator: "/")
        let right = rhs.split(separator: "/")
        let options: String.CompareOptions = scope.caseSensitive ? [] : [.caseInsensitive]
        return left.count == right.count
            && zip(left, right).allSatisfy { $0.compare($1, options: options) == .orderedSame }
    }

    /// Proposal keys never collide with create or update keys, or with another grant's.
    func proposalID(_ key: String) -> String {
        "prop_" + DocumentRevision(data: Data("silkweb-propose/v1\n\(grantId)\n\(key)".utf8)).digest.prefix(32)
    }
}

import CryptoKit
import Darwin
import Foundation

/// What one create operation ended as (`docs/agent-memory.md` › Create and receipts).
public enum AgentCreateOutcome: String, Codable, Sendable {
    case created, duplicate, reconciled, abandoned, refused

    /// A document was published for this key, so the key can never create another one.
    public var isPublished: Bool { self == .created || self == .duplicate || self == .reconciled }
}

/// The audit record for one idempotency key, `.silkweb/agent-events/<operationId>.json`. It never
/// holds document text. Versioned and decoded tolerantly; keys are sorted so it diffs cleanly.
public struct AgentReceipt: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = currentVersion
    /// Derived from the grant and the idempotency key, so a retry finds its receipt without an index.
    public var operationId: String
    public var idempotencyKey: String
    /// The grant's project key.
    public var grantId: String
    public var client: String
    public var agent: String
    public var session: String
    /// ISO 8601 UTC; the envelope's `created_at` for published documents.
    public var createdAt: String
    /// Library-relative POSIX path at publish time.
    public var destination: String?
    /// The app index's document UUID, which follows renames and moves.
    public var documentId: UUID?
    /// The envelope's `memory_id`, which stays with the file even when the index doesn't know it.
    public var memoryId: String?
    /// `sha256:` + hex of the published bytes.
    public var contentDigest: String?
    /// `sha256:` + hex of the request payload; the same key with another payload is a conflict.
    public var requestDigest: String
    public var byteCount: Int
    public var outcome: AgentCreateOutcome
    /// The refusal's `error.code` for a `refused` receipt.
    public var refusal: String?

    public init(
        operationId: String, idempotencyKey: String, grantId: String, client: String, agent: String,
        session: String, createdAt: String, destination: String? = nil, documentId: UUID? = nil,
        memoryId: String? = nil, contentDigest: String? = nil, requestDigest: String, byteCount: Int = 0,
        outcome: AgentCreateOutcome, refusal: String? = nil
    ) {
        self.operationId = operationId
        self.idempotencyKey = idempotencyKey
        self.grantId = grantId
        self.client = client
        self.agent = agent
        self.session = session
        self.createdAt = createdAt
        self.destination = destination
        self.documentId = documentId
        self.memoryId = memoryId
        self.contentDigest = contentDigest
        self.requestDigest = requestDigest
        self.byteCount = byteCount
        self.outcome = outcome
        self.refusal = refusal
    }

    private enum CodingKeys: String, CodingKey {
        case version, operationId, idempotencyKey, grantId, client, agent, session, createdAt, destination
        case documentId, memoryId, contentDigest, requestDigest, byteCount, outcome, refusal
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let string = { (key: CodingKeys) in (try? values.decodeIfPresent(String.self, forKey: key)) ?? nil }
        version = (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? nil ?? 1
        operationId = string(.operationId) ?? ""
        idempotencyKey = string(.idempotencyKey) ?? ""
        grantId = string(.grantId) ?? ""
        client = string(.client) ?? ""
        agent = string(.agent) ?? ""
        session = string(.session) ?? ""
        createdAt = string(.createdAt) ?? ""
        destination = string(.destination)
        documentId = string(.documentId).flatMap(UUID.init(uuidString:))
        memoryId = string(.memoryId)
        contentDigest = string(.contentDigest)
        requestDigest = string(.requestDigest) ?? ""
        byteCount = (try? values.decodeIfPresent(Int.self, forKey: .byteCount)) ?? nil ?? 0
        // An outcome from a newer build counts as published, so a retry can never duplicate a document.
        outcome = string(.outcome).flatMap(AgentCreateOutcome.init(rawValue:)) ?? .created
        refusal = string(.refusal)
    }

    /// Every field is written, `null` included, so receipts from one version all have the same shape.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(operationId, forKey: .operationId)
        try values.encode(idempotencyKey, forKey: .idempotencyKey)
        try values.encode(grantId, forKey: .grantId)
        try values.encode(client, forKey: .client)
        try values.encode(agent, forKey: .agent)
        try values.encode(session, forKey: .session)
        try values.encode(createdAt, forKey: .createdAt)
        try values.encode(destination, forKey: .destination)
        try values.encode(documentId?.uuidString, forKey: .documentId)
        try values.encode(memoryId, forKey: .memoryId)
        try values.encode(contentDigest, forKey: .contentDigest)
        try values.encode(requestDigest, forKey: .requestDigest)
        try values.encode(byteCount, forKey: .byteCount)
        try values.encode(outcome, forKey: .outcome)
        try values.encode(refusal, forKey: .refusal)
    }

    static func encoded(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

/// One `memory create` request. The helper assigns `memory_id`, `created_at` and `project`.
public struct AgentCreateRequest: Equatable, Sendable {
    public var idempotencyKey: String
    public var type: String
    public var title: String
    public var body: String
    public var agent: String
    public var session: String
    /// Recorded in the receipt only; not part of the payload.
    public var client: String
    /// Library-relative Folder inside a create folder. Defaults to the type's entry folder.
    public var folder: String?
    public var status: String?
    public var observedAt: String?
    public var reviewAfter: String?
    public var supersedes: [String]?

    public init(
        idempotencyKey: String, type: String, title: String, body: String, agent: String, session: String,
        client: String = "cli", folder: String? = nil, status: String? = nil, observedAt: String? = nil,
        reviewAfter: String? = nil, supersedes: [String]? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.type = type
        self.title = title
        self.body = body
        self.agent = agent
        self.session = session
        self.client = client
        self.folder = folder
        self.status = status
        self.observedAt = observedAt
        self.reviewAfter = reviewAfter
        self.supersedes = supersedes
    }

    /// `sha256:` over the payload as canonical JSON. Everything the agent chose counts except `client`.
    public var digest: String {
        let payload: [String: Any] = [
            "type": type, "title": title, "body": body, "agent": agent, "session": session,
            "folder": folder ?? NSNull(), "status": status ?? NSNull(), "observed_at": observedAt ?? NSNull(),
            "review_after": reviewAfter ?? NSNull(), "supersedes": supersedes ?? NSNull(),
        ]
        let data =
            (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return AgentCreateService.digest(data)
    }
}

/// What a create returns. A replay is the original receipt with `replayed`, never an error.
public struct AgentCreateResult: Equatable, Sendable {
    public let receipt: AgentReceipt
    /// Where the document is now, following renames and moves. `nil` when it was trashed, deleted or
    /// moved outside the grant's read folders.
    public let path: String?
    public let replayed: Bool

    public var outcome: AgentCreateOutcome { replayed ? .duplicate : receipt.outcome }
}

/// The interrupted-create journal entry, `.silkweb/agent-staging/<attempt>.json`, written once the
/// staged file is complete and removed after the receipt. Its staged file `<attempt>.md` sits next
/// to it: if that's still there the document was never published.
struct AgentCreateIntent: Codable, Equatable {
    static let currentVersion = 1

    var version = currentVersion
    var operationId: String
    var idempotencyKey: String
    var requestDigest: String
    var grantId: String
    var client: String
    var agent: String
    var session: String
    var createdAt: String
    /// The destination Folder, Library-relative.
    var folder: String
    var memoryId: String
    var documentId: UUID
    var contentDigest: String
    var byteCount: Int

    init(
        operationId: String, idempotencyKey: String, requestDigest: String, grantId: String, client: String,
        agent: String, session: String, createdAt: String, folder: String, memoryId: String, documentId: UUID,
        contentDigest: String, byteCount: Int
    ) {
        self.operationId = operationId
        self.idempotencyKey = idempotencyKey
        self.requestDigest = requestDigest
        self.grantId = grantId
        self.client = client
        self.agent = agent
        self.session = session
        self.createdAt = createdAt
        self.folder = folder
        self.memoryId = memoryId
        self.documentId = documentId
        self.contentDigest = contentDigest
        self.byteCount = byteCount
    }

    private enum CodingKeys: String, CodingKey {
        case version, operationId, idempotencyKey, requestDigest, grantId, client, agent, session, createdAt
        case folder, memoryId, documentId, contentDigest, byteCount
    }

    /// Only the operation, folder and identities are required: without them nothing can be reconciled.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let string = { (key: CodingKeys) in (try? values.decodeIfPresent(String.self, forKey: key)) ?? nil }
        version = (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? nil ?? 1
        operationId = try values.decode(String.self, forKey: .operationId)
        folder = try values.decode(String.self, forKey: .folder)
        memoryId = try values.decode(String.self, forKey: .memoryId)
        documentId = try values.decode(UUID.self, forKey: .documentId)
        idempotencyKey = string(.idempotencyKey) ?? ""
        requestDigest = string(.requestDigest) ?? ""
        grantId = string(.grantId) ?? ""
        client = string(.client) ?? ""
        agent = string(.agent) ?? ""
        session = string(.session) ?? ""
        createdAt = string(.createdAt) ?? ""
        contentDigest = string(.contentDigest) ?? ""
        byteCount = (try? values.decodeIfPresent(Int.self, forKey: .byteCount)) ?? nil ?? 0
    }

    func receipt(_ outcome: AgentCreateOutcome, destination: String? = nil, documentId: UUID? = nil) -> AgentReceipt {
        AgentReceipt(
            operationId: operationId, idempotencyKey: idempotencyKey, grantId: grantId, client: client, agent: agent,
            session: session, createdAt: createdAt, destination: destination, documentId: documentId,
            memoryId: outcome.isPublished ? memoryId : nil, contentDigest: outcome.isPublished ? contentDigest : nil,
            requestDigest: requestDigest, byteCount: outcome.isPublished ? byteCount : 0, outcome: outcome)
    }
}

/// Idempotent, create-only publication for agents (#133). A create stages the complete file under
/// `.silkweb/agent-staging/`, records its intent, publishes it with an exclusive rename (a taken
/// name gets the next “ 2” suffix, never a replacement), records the identity in the app index and
/// writes a receipt under `.silkweb/agent-events/`. The whole commit holds the Library gate (#131).
///
/// Recovery never deletes, renames or rewrites a published document: an interrupted create is either
/// still staged (recorded `abandoned`, then discarded) or published (kept and recorded `reconciled`).
public struct AgentCreateService: Sendable {
    /// The points a test can interrupt, as if the process died right after that step. `stage` comes before
    /// anything is written, so an error thrown there acts like a staging write that failed (a full disk).
    enum Step: Sendable { case stage, intent, published, indexed, receipt }

    static let stagingFolder = "agent-staging"
    static let eventsFolder = "agent-events"
    static let maxKeyLength = 200

    public let library: URL
    public let grantId: String
    public let scope: AgentScope
    /// The largest document (envelope included) this grant may create.
    public let maxBytes: Int
    var now: @Sendable () -> Date = { Date() }
    /// Progress filenames use the owner's local time.
    var timeZone = TimeZone.current
    var gateTimeout = LibraryGate.defaultTimeout
    /// Test-only failure injection. Throwing here stops the create with nothing cleaned up.
    var fault: (@Sendable (Step) throws -> Void)?

    public init(authorization: AgentAuthorization) {
        self.init(
            library: authorization.library, grantId: authorization.grant.project, scope: authorization.scope,
            maxBytes: authorization.grant.limits.maxCreateBytes)
    }

    init(library: URL, grantId: String, scope: AgentScope, maxBytes: Int) {
        self.library = library
        self.grantId = grantId
        self.scope = scope
        self.maxBytes = maxBytes
    }

    private var gate: LibraryGate { LibraryGate(root: library) }

    // MARK: Create

    public func create(_ request: AgentCreateRequest) throws -> AgentCreateResult {
        try Self.validateKey(request.idempotencyKey)
        let operationId = operationID(request.idempotencyKey)
        let digest = request.digest
        // Validation needs no gate. A refusal is reported after the replay check, so a retry of a
        // created key is a replay or a conflict whatever its payload.
        let plan: Result<Plan, AgentAccessError>
        do {
            plan = .success(try self.plan(request))
        } catch let refusal as AgentAccessError {
            plan = .failure(refusal)
        }
        return try mapFilesystemErrors {
            try gate.withLease(timeout: gateTimeout) {
                _ = reconcileHoldingGate()
                if let existing = receipt(operationId), existing.outcome.isPublished {
                    guard existing.requestDigest == digest else { throw AgentAccessError.idempotencyConflict }
                    return AgentCreateResult(receipt: existing, path: currentPath(of: existing), replayed: true)
                }
                switch plan {
                case .failure(let refusal):
                    try? writeReceipt(
                        AgentReceipt(
                            operationId: operationId, idempotencyKey: request.idempotencyKey, grantId: grantId,
                            client: request.client, agent: request.agent, session: request.session,
                            createdAt: MemoryEnvelope.timestamp(now()), requestDigest: digest, outcome: .refused,
                            refusal: refusal.code))
                    throw refusal
                case .success(let plan):
                    return try publish(plan, request: request, operationId: operationId, digest: digest)
                }
            }
        }
    }

    private struct Plan {
        var folder: String
        var fileName: String
        var data: Data
        var memoryID: String
        var createdAt: String
    }

    /// Scope, filename, envelope and size checks, and the complete file's bytes.
    private func plan(_ request: AgentCreateRequest) throws -> Plan {
        let date = now()
        guard let entryFolder = Self.entryFolder(for: request.type) else {
            throw AgentAccessError.envelope(.invalidField("type"), name: request.title)
        }
        let title = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var fileName = title + ".md"
        if request.type == "progress" {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "yyyy-MM-dd HHmm"
            fileName = formatter.string(from: date) + " — " + fileName
        }
        guard !title.isEmpty, (try? LibraryMutations.validateName(fileName)) == fileName else {
            throw AgentAccessError.invalidPath
        }
        let folder = request.folder ?? AgentMemoryContract.projectRoot(grantId) + "/" + entryFolder
        let path: String
        do {
            path = try scope.checkCreate(folder + "/" + fileName)
        } catch let error as AgentScopeError {
            throw AgentAccessError.scope(error, in: scope)
        }
        // The helper writes the only envelope; a body that brings its own is refused, never merged.
        switch MemoryEnvelope.parse(request.body) {
        case .missing: break
        case .failure(let error): throw AgentAccessError.envelope(error, name: title)
        case .envelope: throw AgentAccessError.envelope(.invalidField("schema"), name: title)
        }
        let memoryID = Self.memoryID()
        var envelope = MemoryEnvelope(
            memoryID: memoryID, type: request.type, project: grantId, agent: request.agent, session: request.session,
            createdAt: date)
        envelope["observed_at"] = request.observedAt.map(MemoryEnvelope.Value.string)
        envelope["status"] = request.status.map(MemoryEnvelope.Value.string)
        envelope["supersedes"] = request.supersedes.map(MemoryEnvelope.Value.list)
        envelope["review_after"] = request.reviewAfter.map(MemoryEnvelope.Value.string)
        // The body starts with `# <Title>`, matching the filename; an agent's own heading is kept as is.
        let heading = "# " + title
        let body =
            request.body == heading || request.body.hasPrefix(heading + "\n")
            ? request.body : request.body.isEmpty ? heading + "\n" : heading + "\n\n" + request.body
        let text: String
        do {
            text = try envelope.document(body: body)
        } catch let error as MemoryEnvelopeError {
            throw AgentAccessError.envelope(error, name: title)
        }
        let data = Data(text.utf8)
        guard data.count <= maxBytes else { throw AgentAccessError.createTooLarge(limit: maxBytes) }
        return Plan(
            folder: (path as NSString).deletingLastPathComponent, fileName: fileName, data: data, memoryID: memoryID,
            createdAt: envelope.string("created_at") ?? "")
    }

    /// Runs holding the gate: stage, journal, publish without replacing, index, receipt.
    private func publish(_ plan: Plan, request: AgentCreateRequest, operationId: String, digest: String) throws
        -> AgentCreateResult
    {
        let root = try AgentCreateFiles.openRoot(library)
        defer { close(root) }
        let staging = try AgentCreateFiles.metadataFolder(root, Self.stagingFolder, create: true)!
        defer { close(staging) }
        let attempt = UUID().uuidString
        try fault?(.stage)
        try AgentCreateFiles.writeExclusive(staging, attempt + ".md", plan.data)
        let intent = AgentCreateIntent(
            operationId: operationId, idempotencyKey: request.idempotencyKey, requestDigest: digest, grantId: grantId,
            client: request.client, agent: request.agent, session: request.session, createdAt: plan.createdAt,
            folder: plan.folder, memoryId: plan.memoryID, documentId: UUID(), contentDigest: Self.digest(plan.data),
            byteCount: plan.data.count)
        do {
            try AgentCreateFiles.writeAtomic(staging, attempt + ".json", AgentReceipt.encoded(intent))
        } catch {
            _ = unlinkat(staging, attempt + ".md", 0)
            throw error
        }
        try fault?(.intent)

        let folder: (descriptor: Int32, path: String, created: [String])
        let name: String
        do {
            folder = try AgentCreateFiles.folder(root, plan.folder, create: true)!
            do {
                name = try AgentCreateFiles.publish(staging, attempt + ".md", to: folder.descriptor, as: plan.fileName)
            } catch {
                close(folder.descriptor)
                throw error
            }
        } catch {
            // Never published: record it abandoned and discard the staged file now.
            reconcile(attempt: attempt, intent: intent, staging: staging, root: root)
            throw error
        }
        defer { close(folder.descriptor) }
        _ = fsync(folder.descriptor)
        _ = fsync(staging)
        try fault?(.published)

        // From here on the document is published and is never removed, whatever fails next.
        let path = folder.path + "/" + name
        let documentID = recordIdentity(path: path, id: intent.documentId, folders: folder.created)
        try fault?(.indexed)
        let receipt = intent.receipt(.created, destination: path, documentId: documentID)
        do {
            try writeReceipt(receipt)
        } catch {
            // The journal entry stays, so the next operation records the receipt as `reconciled`.
            throw AgentAccessError.writeFailed
        }
        try fault?(.receipt)
        _ = unlinkat(staging, attempt + ".json", 0)
        return AgentCreateResult(receipt: receipt, path: readable(path), replayed: false)
    }

    // MARK: Create folder

    public struct FolderResult: Equatable, Sendable {
        public let path: String
        public let created: Bool
    }

    /// Makes a Folder (and any missing parents) inside a create folder. An existing Folder isn't an error.
    public func createFolder(_ requested: String) throws -> FolderResult {
        let path: String
        do {
            path = try scope.checkCreateFolder(requested)
        } catch let error as AgentScopeError {
            throw AgentAccessError.scope(error, in: scope)
        }
        return try mapFilesystemErrors {
            try gate.withLease(timeout: gateTimeout) {
                let root = try AgentCreateFiles.openRoot(library)
                defer { close(root) }
                let folder = try AgentCreateFiles.folder(root, path, create: true)!
                close(folder.descriptor)
                if !folder.created.isEmpty { _ = recordIdentity(path: nil, id: UUID(), folders: folder.created) }
                return FolderResult(path: folder.path, created: !folder.created.isEmpty)
            }
        }
    }

    // MARK: Reconciliation

    /// Finishes or abandons interrupted creates, silently. Runs before every create and on demand.
    @discardableResult
    public func reconcile() throws -> [AgentReceipt] {
        try mapFilesystemErrors { try gate.withLease(timeout: gateTimeout) { reconcileHoldingGate() } }
    }

    /// Each journal entry is settled on its own; one that can't be read or settled stays for next time.
    /// Holding the gate means no live create owns anything in the staging folder.
    private func reconcileHoldingGate() -> [AgentReceipt] {
        guard let root = try? AgentCreateFiles.openRoot(library) else { return [] }
        defer { close(root) }
        guard let staging = try? AgentCreateFiles.metadataFolder(root, Self.stagingFolder, create: false) else {
            return []
        }
        defer { close(staging) }
        let names = Set(AgentCreateFiles.names(staging))
        var settled: [AgentReceipt] = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.contains(".tmp-") {
            let attempt = String(name.dropLast(5))
            guard let data = AgentCreateFiles.read(staging, name, maxBytes: 65_536),
                let intent = try? JSONDecoder().decode(AgentCreateIntent.self, from: data)
            else { continue }
            if let receipt = reconcile(attempt: attempt, intent: intent, staging: staging, root: root) {
                settled.append(receipt)
            }
        }
        // A staged file without an intent never got as far as being published, and no create is live.
        for name in names {
            let orphan = name.hasSuffix(".md") && !names.contains(String(name.dropLast(3)) + ".json")
            if orphan || name.contains(".tmp-") { _ = unlinkat(staging, name, 0) }
        }
        return settled
    }

    @discardableResult
    private func reconcile(attempt: String, intent: AgentCreateIntent, staging: Int32, root: Int32) -> AgentReceipt? {
        let staged = attempt + ".md"
        let existing = receipt(intent.operationId)
        var settled: AgentReceipt?
        if existing?.outcome.isPublished == true {
            // Already settled: another attempt published this key, or only the journal cleanup was lost.
        } else if AgentCreateFiles.isRegularFile(staging, staged) {
            let receipt = intent.receipt(.abandoned)
            guard (try? writeReceipt(receipt)) != nil else { return nil }
            settled = receipt
        } else {
            let found = findPublished(intent, root: root)
            let receipt = intent.receipt(.reconciled, destination: found?.path, documentId: found?.id)
            guard (try? writeReceipt(receipt)) != nil else { return nil }
            settled = receipt
        }
        _ = unlinkat(staging, staged, 0)
        _ = unlinkat(staging, attempt + ".json", 0)
        return settled
    }

    /// The published document, by its index identity first, then by its `memory_id` in the intent's
    /// Folder (the identity may not have been recorded before the interruption).
    private func findPublished(_ intent: AgentCreateIntent, root: Int32) -> (path: String, id: UUID)? {
        let metadata = Self.index(library)
        if let path = metadata?.IDsByPath.first(where: { $0.value == intent.documentId })?.key,
            AgentCreateFiles.isRegularFile(root, path)
        {
            return (path, intent.documentId)
        }
        guard let folder = try? AgentCreateFiles.folder(root, intent.folder, create: false) else { return nil }
        defer { close(folder.descriptor) }
        for name in AgentCreateFiles.names(folder.descriptor).sorted() where name.hasSuffix(".md") {
            guard !name.hasPrefix("."), Self.memoryID(in: folder.descriptor, name) == intent.memoryId else { continue }
            let path = folder.path + "/" + name
            return (path, recordIdentity(path: path, id: intent.documentId, folders: []))
        }
        return nil
    }

    // MARK: Activity

    public struct ActivityPage: Equatable, Sendable {
        /// Newest first, at most the requested limit.
        public let receipts: [AgentReceipt]
        /// Matching receipts before the limit.
        public let total: Int
    }

    /// This grant's receipts, newest first (`memory activity`). Receipts that name a destination
    /// outside the read folders are left out before counting. A read: it never takes the gate and
    /// never writes; a Library without receipts is an empty page.
    public func activity(since: Date? = nil, limit: Int) -> ActivityPage {
        guard let root = try? AgentCreateFiles.openRoot(library) else { return ActivityPage(receipts: [], total: 0) }
        defer { close(root) }
        guard let events = try? AgentCreateFiles.metadataFolder(root, Self.eventsFolder, create: false) else {
            return ActivityPage(receipts: [], total: 0)
        }
        defer { close(events) }
        var receipts: [AgentReceipt] = []
        for name in AgentCreateFiles.names(events) where name.hasPrefix("op_") && name.hasSuffix(".json") {
            guard let data = AgentCreateFiles.read(events, name, maxBytes: 65_536),
                let receipt = try? JSONDecoder().decode(AgentReceipt.self, from: data), receipt.grantId == grantId,
                receipt.destination.map({ readable($0) != nil }) ?? true
            else { continue }
            if let since {
                guard let date = AgentMemorySearchRequest.date(receipt.createdAt), date >= since else { continue }
            }
            receipts.append(receipt)
        }
        receipts.sort {
            $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.operationId < $1.operationId
        }
        return ActivityPage(receipts: Array(receipts.prefix(max(0, limit))), total: receipts.count)
    }

    // MARK: Receipts and identities

    /// The operation ID for a key: a retry finds its receipt by file name, and keys never collide across grants.
    func operationID(_ key: String) -> String {
        let hash = SHA256.hash(data: Data("silkweb-create/v1\n\(grantId)\n\(key)".utf8))
        return "op_" + hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func receipt(_ operationId: String) -> AgentReceipt? {
        guard let root = try? AgentCreateFiles.openRoot(library) else { return nil }
        defer { close(root) }
        guard let events = try? AgentCreateFiles.metadataFolder(root, Self.eventsFolder, create: false) else {
            return nil
        }
        defer { close(events) }
        return AgentCreateFiles.read(events, operationId + ".json", maxBytes: 65_536).flatMap {
            try? JSONDecoder().decode(AgentReceipt.self, from: $0)
        }
    }

    private func writeReceipt(_ receipt: AgentReceipt) throws {
        let root = try AgentCreateFiles.openRoot(library)
        defer { close(root) }
        let events = try AgentCreateFiles.metadataFolder(root, Self.eventsFolder, create: true)!
        defer { close(events) }
        try AgentCreateFiles.writeAtomic(events, receipt.operationId + ".json", AgentReceipt.encoded(receipt))
    }

    /// Where the receipt's document is now, inside the grant's read folders, or `nil`.
    func currentPath(of receipt: AgentReceipt) -> String? {
        guard let root = try? AgentCreateFiles.openRoot(library) else { return nil }
        defer { close(root) }
        if let id = receipt.documentId, let path = Self.index(library)?.IDsByPath.first(where: { $0.value == id })?.key,
            AgentCreateFiles.isRegularFile(root, path)
        {
            return readable(path)
        }
        // The index may not know it (it was unreadable at publish); a file at the destination only
        // counts if it's the same document.
        guard let destination = receipt.destination, let memoryID = receipt.memoryId,
            let folder = try? AgentCreateFiles.folder(
                root, (destination as NSString).deletingLastPathComponent, create: false)
        else { return nil }
        defer { close(folder.descriptor) }
        let name = (destination as NSString).lastPathComponent
        return Self.memoryID(in: folder.descriptor, name) == memoryID ? readable(destination) : nil
    }

    private func readable(_ path: String) -> String? { (try? scope.checkRead(path)) != nil ? path : nil }

    /// Adds identities to the app index like any new document or Folder. Best effort: the document
    /// is already published, and an unreadable or newer index is left alone for the app to recover.
    /// Returns the identity the index holds for `path`.
    private func recordIdentity(path: String?, id: UUID, folders: [String]) -> UUID {
        guard let loaded = try? LibraryMetadataStore.loadReportingReset(root: library, repair: false),
            !loaded.wasReset
        else { return id }
        var metadata = loaded.metadata
        if let path, let known = metadata.IDsByPath[path] { return known }
        for folder in folders where metadata.IDsByPath[folder] == nil { metadata.IDsByPath[folder] = UUID() }
        if let path { metadata.IDsByPath[path] = id }
        try? LibraryMetadataStore.save(metadata, root: library)
        return id
    }

    private static func index(_ library: URL) -> LibraryMetadata? {
        guard let loaded = try? LibraryMetadataStore.loadReportingReset(root: library, repair: false),
            !loaded.wasReset
        else { return nil }
        return loaded.metadata
    }

    // MARK: Helpers

    /// Filesystem failures become one stable refusal; a link where a Folder should be is `invalid_path`.
    private func mapFilesystemErrors<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as AgentAccessError {
            throw error
        } catch let error as LibraryGateError {
            throw AgentAccessError(error)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            switch Int32(error.code) {
            case ELOOP, ENOTDIR: throw AgentAccessError.invalidPath
            case ENOSPC, EDQUOT: throw AgentAccessError.diskFull
            case EACCES, EPERM, EROFS: throw AgentAccessError.permissionDenied
            default: throw AgentAccessError.writeFailed
            }
        } catch {
            throw AgentAccessError.writeFailed
        }
    }

    static func entryFolder(for type: String) -> String? {
        switch type {
        case "memory", "decision": return "Memories"
        case "progress": return "Progress"
        case "handoff": return "Handoffs"
        default: return nil
        }
    }

    static func validateKey(_ key: String) throws {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty, key.count <= maxKeyLength,
            !key.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw AgentAccessError.invalidRequest(
                "The request key must be 1 to \(maxKeyLength) characters, without control characters.")
        }
    }

    static func digest(_ data: Data) -> String {
        "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// `mem_` and 26 Crockford base32 characters of randomness.
    static func memoryID() -> String {
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        var generator = SystemRandomNumberGenerator()
        return "mem_" + String((0..<26).map { _ in alphabet[Int(generator.next() % 32)] })
    }

    /// The `memory_id` of a document's envelope, reading only its start.
    static func memoryID(in folder: Int32, _ name: String) -> String? {
        guard let data = AgentCreateFiles.read(folder, name, maxBytes: 65_536),
            case .envelope(let envelope, _) = MemoryEnvelope.parse(String(decoding: data, as: UTF8.self))
        else { return nil }
        return envelope.memoryID
    }
}

/// Descriptor-based writes for creates. Every component is opened relative to its parent with
/// `O_NOFOLLOW`, so a link swapped in after the scope check can't redirect a write out of the Library.
enum AgentCreateFiles {
    static func posix(_ code: Int32 = errno) -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }

    static func openRoot(_ library: URL) throws -> Int32 {
        let descriptor = open(library.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw posix() }
        return descriptor
    }

    /// `.silkweb/<name>`; `nil` when it's missing and `create` is false.
    static func metadataFolder(_ root: Int32, _ name: String, create: Bool) throws -> Int32? {
        guard let metadata = try child(root, ".silkweb", create: create) else { return nil }
        defer { close(metadata.descriptor) }
        return try child(metadata.descriptor, name, create: create)?.descriptor
    }

    /// One child Folder, made first when `create` is set. `nil` when it's missing and `create` is false.
    static func child(_ parent: Int32, _ name: String, create: Bool) throws -> (descriptor: Int32, created: Bool)? {
        var created = false
        if create {
            if mkdirat(parent, name, 0o755) == 0 {
                created = true
            } else if errno != EEXIST {
                throw posix()
            }
        }
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT && !create { return nil }
            throw posix()
        }
        return (descriptor, created)
    }

    /// Opens a Library-relative Folder, making missing ones when `create` is set. Returns its
    /// on-disk spelling (which may differ in case from the request) and the Folders it made.
    static func folder(_ root: Int32, _ path: String, create: Bool) throws -> (
        descriptor: Int32, path: String, created: [String]
    )? {
        var descriptor = dup(root)
        guard descriptor >= 0 else { throw posix() }
        var parts: [String] = []
        var created: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            let next: (descriptor: Int32, created: Bool)?
            do {
                next = try child(descriptor, component, create: create)
            } catch {
                close(descriptor)
                throw error
            }
            guard let next else {
                close(descriptor)
                return nil
            }
            parts.append(next.created ? component : storedName(descriptor, next.descriptor) ?? component)
            close(descriptor)
            descriptor = next.descriptor
            if next.created { created.append(parts.joined(separator: "/")) }
        }
        return (descriptor, parts.joined(separator: "/"), created)
    }

    /// The directory entry name for `child` inside `parent`, as stored on disk.
    private static func storedName(_ parent: Int32, _ child: Int32) -> String? {
        var info = stat()
        guard fstat(child, &info) == 0 else { return nil }
        return entries(parent).first { $0.inode == info.st_ino }?.name
    }

    static func names(_ folder: Int32) -> [String] { entries(folder).map(\.name) }

    private static func entries(_ folder: Int32) -> [(name: String, inode: UInt64)] {
        let copy = dup(folder)
        guard copy >= 0 else { return [] }
        guard let directory = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer { closedir(directory) }
        rewinddir(directory)
        var result: [(String, UInt64)] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { result.append((name, UInt64(entry.pointee.d_ino))) }
        }
        return result
    }

    /// Writes a new file that must not exist yet, and flushes it to disk.
    static func writeExclusive(_ folder: Int32, _ name: String, _ data: Data) throws {
        let descriptor = openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw posix() }
        defer { close(descriptor) }
        var failure: Int32 = 0
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == 0, fsync(descriptor) != 0 { failure = errno }
        guard failure == 0 else {
            _ = unlinkat(folder, name, 0)
            throw posix(failure)
        }
    }

    /// Write a temporary file, then rename it over `name`: readers see the old file or the new one.
    /// Only used for Silkweb's own files under `.silkweb/`, never for documents.
    static func writeAtomic(_ folder: Int32, _ name: String, _ data: Data) throws {
        let temporary = name + ".tmp-" + UUID().uuidString
        try writeExclusive(folder, temporary, data)
        guard renameat(folder, temporary, folder, name) == 0 else {
            let code = errno
            _ = unlinkat(folder, temporary, 0)
            throw posix(code)
        }
        _ = fsync(folder)
    }

    /// Moves the staged file to `fileName`, or the first free “ 2”, “ 3” … name. `RENAME_EXCL`
    /// re-checks every name atomically, so it can't replace a file that appears meanwhile.
    static func publish(_ staging: Int32, _ staged: String, to folder: Int32, as fileName: String) throws -> String {
        let ext = (fileName as NSString).pathExtension
        let stem = (fileName as NSString).deletingPathExtension
        var number = 1
        while true {
            let candidate =
                number == 1 ? fileName : try LibraryMutations.validateName(LibraryMutations.numbered(stem, number, ext))
            if renameatx_np(staging, staged, folder, candidate, UInt32(RENAME_EXCL)) == 0 { return candidate }
            guard errno == EEXIST, number < 10_000 else { throw posix() }
            number += 1
        }
    }

    static func read(_ folder: Int32, _ name: String, maxBytes: Int) -> Data? {
        let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        // `nil` from the read is an empty file.
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }

    /// Whether a Library-relative path (or a name in `folder`) is a regular file, without following links.
    static func isRegularFile(_ folder: Int32, _ path: String) -> Bool {
        let parent = (path as NSString).deletingLastPathComponent
        var descriptor = folder
        if !parent.isEmpty {
            guard let opened = try? self.folder(folder, parent, create: false) else { return false }
            descriptor = opened.descriptor
        }
        defer { if descriptor != folder { close(descriptor) } }
        var info = stat()
        return fstatat(descriptor, (path as NSString).lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0
            && info.st_mode & S_IFMT == S_IFREG
    }
}

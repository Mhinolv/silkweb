import Darwin
import Foundation

/// One `memory update` request (#204): the new body for a document an agent created.
public struct AgentUpdateRequest: Equatable, Sendable {
    public var idempotencyKey: String
    /// Library-relative path, or `nil` when `documentID` names the document.
    public var path: String?
    /// The app index's document UUID, from a search or read.
    public var documentID: UUID?
    /// The `revision` from `memory_read`. Anything else is refused with `revision_changed`.
    public var expectedRevision: String
    /// Everything after the envelope and its blank line, as `memory_read` returns it.
    public var body: String
    public var agent: String
    public var session: String
    /// Recorded in the receipt only; not part of the payload.
    public var client: String

    public init(
        idempotencyKey: String, path: String? = nil, documentID: UUID? = nil, expectedRevision: String, body: String,
        agent: String, session: String, client: String = "cli"
    ) {
        self.idempotencyKey = idempotencyKey
        self.path = path
        self.documentID = documentID
        self.expectedRevision = expectedRevision
        self.body = body
        self.agent = agent
        self.session = session
        self.client = client
    }

    /// `sha256:` over the payload as canonical JSON. Everything the agent chose counts except `client`.
    public var digest: String {
        let payload: [String: Any] = [
            "path": path ?? NSNull(), "document_id": documentID?.uuidString ?? NSNull(),
            "expected_revision": expectedRevision, "body": body, "agent": agent, "session": session,
        ]
        let data =
            (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data()
        return AgentCreateService.digest(data)
    }
}

/// What an update returns. A replay is the original receipt with `replayed`, never an error.
public struct AgentUpdateResult: Equatable, Sendable {
    public let receipt: AgentReceipt
    /// Where the document is now, or `nil` when it left the grant's read folders.
    public let path: String?
    public let replayed: Bool

    public var outcome: AgentCreateOutcome { replayed ? .duplicate : receipt.outcome }
    /// The document's revision right after this update.
    public var revision: String? { receipt.contentDigest }
}

/// The interrupted-update journal entry, `.silkweb/agent-update-staging/<attempt>.json`, written before the
/// earlier version is saved and the document replaced. Its staged file `<attempt>.md` sits next to it: if
/// that's still there the document was never replaced.
struct AgentUpdateIntent: Codable, Equatable {
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
    var path: String
    var documentId: UUID?
    var memoryId: String
    var contentDigest: String
    var baseDigest: String
    var byteCount: Int
    var sequence: Int
    /// Library-relative, under `.silkweb/agent-history/`.
    var previousVersion: String

    func receipt(_ outcome: AgentCreateOutcome) -> AgentReceipt {
        let published = outcome.isPublished
        return AgentReceipt(
            operationId: operationId, idempotencyKey: idempotencyKey, grantId: grantId, client: client, agent: agent,
            session: session, createdAt: createdAt, destination: path, documentId: documentId, memoryId: memoryId,
            contentDigest: published ? contentDigest : nil, requestDigest: requestDigest,
            byteCount: published ? byteCount : 0, outcome: outcome, operation: .update, sequence: sequence,
            baseDigest: baseDigest, previousVersion: published ? previousVersion : nil)
    }
}

/// Direct updates for agents (#204, owner decision 2026-10-09: hybrid). An agent may replace the body of a
/// document only when Silkweb holds an agent receipt for it and its bytes are exactly what an agent last
/// wrote; anything the owner wrote or edited is refused with `update_requires_proposal` (#140 proposals).
///
/// Every update is a compare-and-swap on the revision the agent read, holds the Library gate (#131), never
/// overwrites unsaved changes in the app (`DocumentEditingMarker`), keeps the envelope's bytes, saves the
/// replaced text as a plain `.md` under `.silkweb/agent-history/<documentId>/`, replaces the document with
/// one atomic rename and writes a receipt. Idempotency keys work as for creates.
public struct AgentUpdateService: Sendable {
    /// The points a test can interrupt, as if the process died right after that step.
    enum Step: Sendable { case staged, replaced, receipt }

    static let stagingFolder = "agent-update-staging"
    public static let historyFolder = "agent-history"

    let creates: AgentCreateService
    /// The largest existing document an update reads.
    let maxReadBytes: Int
    var now: @Sendable () -> Date = { Date() }
    var gateTimeout = LibraryGate.defaultTimeout
    /// Test-only failure injection. Throwing here stops the update with nothing cleaned up.
    var fault: (@Sendable (Step) throws -> Void)?

    public init(authorization: AgentAuthorization) {
        creates = AgentCreateService(authorization: authorization)
        maxReadBytes = authorization.grant.limits.maxReadBytes
    }

    init(library: URL, grantId: String, scope: AgentScope, maxBytes: Int, maxReadBytes: Int) {
        creates = AgentCreateService(library: library, grantId: grantId, scope: scope, maxBytes: maxBytes)
        self.maxReadBytes = maxReadBytes
    }

    var library: URL { creates.library }
    var scope: AgentScope { creates.scope }

    // MARK: Update

    public func update(_ request: AgentUpdateRequest) throws -> AgentUpdateResult {
        try AgentCreateService.validateKey(request.idempotencyKey)
        let operationId = operationID(request.idempotencyKey)
        let digest = request.digest
        return try creates.mapFilesystemErrors {
            try LibraryGate(root: library).withLease(timeout: gateTimeout) {
                _ = reconcileHoldingGate()
                if let existing = creates.receipt(operationId), existing.outcome.isPublished {
                    guard existing.requestDigest == digest else { throw AgentAccessError.idempotencyConflict }
                    return AgentUpdateResult(receipt: existing, path: creates.currentPath(of: existing), replayed: true)
                }
                do {
                    return try commit(plan(request), request: request, operationId: operationId, digest: digest)
                } catch let refusal as AgentAccessError where refusal != .writeFailed {
                    try? creates.writeReceipt(
                        AgentReceipt(
                            operationId: operationId, idempotencyKey: request.idempotencyKey,
                            grantId: creates.grantId, client: request.client, agent: request.agent,
                            session: request.session, createdAt: MemoryEnvelope.timestamp(now()),
                            requestDigest: digest, outcome: .refused, refusal: refusal.code, operation: .update))
                    throw refusal
                }
            }
        }
    }

    private struct Plan {
        /// Library-relative, as spelled on disk.
        var path: String
        var folder: String
        var name: String
        var base: String
        var data: Data
        var mode: mode_t
        var memoryID: String
        var documentID: UUID?
        var sequence: Int
    }

    /// Scope, identity, compare-and-swap, eligibility and unsaved-changes checks, and the new bytes. Runs
    /// holding the gate, so nothing a cooperating writer does can slip in before the commit.
    private func plan(_ request: AgentUpdateRequest) throws -> Plan {
        let index = AgentCreateService.index(library)
        var requested = request.path ?? ""
        if let id = request.documentID {
            // An ID the index doesn't know and one outside the read folders look the same.
            guard let path = index?.IDsByPath.first(where: { $0.value == id })?.key,
                (try? scope.checkRead(path)) != nil
            else { throw AgentAccessError.notFound }
            requested = path
        }
        let normalized: String
        do {
            normalized = try scope.checkUpdate(requested)
        } catch let error as AgentScopeError {
            throw AgentAccessError.scope(error, in: scope)
        }
        let title = ((normalized as NSString).lastPathComponent as NSString).deletingPathExtension
        // The helper keeps the only envelope; a body that brings its own is refused, never merged.
        switch MemoryEnvelope.parse(request.body) {
        case .missing: break
        case .failure(let error): throw AgentAccessError.envelope(error, name: title)
        case .envelope: throw AgentAccessError.envelope(.invalidField("schema"), name: title)
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
        let path = folder.path + "/" + name
        guard let old = AgentCreateFiles.read(folder.descriptor, name, maxBytes: maxReadBytes + 1) else {
            throw AgentAccessError.notFound
        }
        guard old.count <= maxReadBytes else { throw AgentAccessError.tooLarge(limit: maxReadBytes) }
        guard let text = String(data: old, encoding: .utf8) else { throw AgentAccessError.notText }

        let envelope: MemoryEnvelope
        let body: Range<String.Index>
        switch MemoryEnvelope.parse(text) {
        case .missing: throw AgentAccessError.updateRequiresProposal(edited: false)
        case .failure(let error): throw AgentAccessError.envelope(error, name: title)
        case .envelope(let parsed, let range): (envelope, body) = (parsed, range)
        }
        guard let memoryID = envelope.memoryID else { throw AgentAccessError.updateRequiresProposal(edited: false) }

        let base = AgentCreateService.digest(old)
        guard request.expectedRevision == base else { throw AgentAccessError.revisionChanged(current: base) }

        let indexID = index?.IDsByPath[path]
        guard let latest = latestReceipt(memoryID: memoryID, documentID: indexID) else {
            throw AgentAccessError.updateRequiresProposal(edited: false)
        }
        guard latest.contentDigest == base else { throw AgentAccessError.updateRequiresProposal(edited: true) }
        guard !DocumentEditingMarker.isHeld(library: library, relativePath: path) else {
            throw AgentAccessError.documentHasUnsavedChanges
        }

        // The envelope's bytes (and the blank line after it) stay exactly as they are; only the body is replaced.
        let data = Data((String(text[..<body.lowerBound]) + request.body).utf8)
        guard data.count <= creates.maxBytes else { throw AgentAccessError.updateTooLarge(limit: creates.maxBytes) }
        return Plan(
            path: path, folder: folder.path, name: name, base: base, data: data, mode: info.st_mode & 0o7777,
            memoryID: memoryID, documentID: indexID ?? latest.documentId, sequence: latest.sequence + 1)
    }

    /// The newest published receipt (create or update) for a document, by its envelope's `memory_id`. A
    /// receipt naming another index identity belongs to a copy, not this document.
    func latestReceipt(memoryID: String, documentID: UUID?) -> AgentReceipt? {
        AgentActivity.load(root: library).receipts.filter { receipt in
            receipt.outcome.isPublished && receipt.memoryId == memoryID && receipt.contentDigest != nil
                && (documentID == nil || receipt.documentId == nil || receipt.documentId == documentID)
        }.max(by: AgentActivity.isEarlier)
    }

    /// Stage, journal, save the earlier version, re-check, replace atomically, receipt.
    private func commit(_ plan: Plan, request: AgentUpdateRequest, operationId: String, digest: String) throws
        -> AgentUpdateResult
    {
        let root = try AgentCreateFiles.openRoot(library)
        defer { close(root) }
        let staging = try AgentCreateFiles.metadataFolder(root, Self.stagingFolder, create: true)!
        defer { close(staging) }
        guard let folder = try AgentCreateFiles.folder(root, plan.folder, create: false) else {
            throw AgentAccessError.notFound
        }
        defer { close(folder.descriptor) }
        let historyRoot = try AgentCreateFiles.metadataFolder(root, Self.historyFolder, create: true)!
        defer { close(historyRoot) }
        let historyKey = plan.documentID?.uuidString ?? plan.memoryID
        let history = try AgentCreateFiles.child(historyRoot, historyKey, create: true)!.descriptor
        defer { close(history) }
        let date = now()
        let versionName = Self.versionName(
            sequence: plan.sequence - 1, date: date, existing: AgentCreateFiles.names(history))
        let attempt = UUID().uuidString

        try AgentCreateFiles.writeExclusive(staging, attempt + ".md", plan.data)
        _ = fchmodat(staging, attempt + ".md", plan.mode, 0)
        let intent = AgentUpdateIntent(
            operationId: operationId, idempotencyKey: request.idempotencyKey, requestDigest: digest,
            grantId: creates.grantId, client: request.client, agent: request.agent, session: request.session,
            createdAt: MemoryEnvelope.timestamp(date), path: plan.path, documentId: plan.documentID,
            memoryId: plan.memoryID, contentDigest: AgentCreateService.digest(plan.data), baseDigest: plan.base,
            byteCount: plan.data.count, sequence: plan.sequence,
            previousVersion: ".silkweb/\(Self.historyFolder)/\(historyKey)/\(versionName)")
        var crashed = false
        let discard = {
            _ = unlinkat(history, versionName, 0)
            _ = unlinkat(staging, attempt + ".md", 0)
            _ = unlinkat(staging, attempt + ".json", 0)
        }
        do {
            try AgentCreateFiles.writeAtomic(staging, attempt + ".json", AgentReceipt.encoded(intent))
            guard let earlier = AgentCreateFiles.read(folder.descriptor, plan.name, maxBytes: maxReadBytes + 1) else {
                throw AgentAccessError.notFound
            }
            // The earlier version, readable without Silkweb. Never indexed: it lives under `.silkweb/`.
            try AgentCreateFiles.writeExclusive(history, versionName, earlier)
            do {
                try fault?(.staged)
            } catch {
                crashed = true
                throw error
            }
            // A writer that doesn't take the gate may have changed the document since the plan read it.
            guard let current = AgentCreateFiles.read(folder.descriptor, plan.name, maxBytes: maxReadBytes + 1) else {
                throw AgentAccessError.notFound
            }
            let revision = AgentCreateService.digest(current)
            guard revision == plan.base, earlier == current else {
                throw AgentAccessError.revisionChanged(current: revision)
            }
            guard !DocumentEditingMarker.isHeld(library: library, relativePath: plan.path) else {
                throw AgentAccessError.documentHasUnsavedChanges
            }
            guard renameat(staging, attempt + ".md", folder.descriptor, plan.name) == 0 else {
                throw AgentCreateFiles.posix()
            }
            _ = fsync(folder.descriptor)
            _ = fsync(staging)
        } catch {
            if !crashed { discard() }
            throw error
        }
        try fault?(.replaced)

        // From here on the document is updated, whatever fails next.
        let receipt = intent.receipt(.updated)
        do {
            try creates.writeReceipt(receipt)
        } catch {
            // The journal entry stays, so the next operation records the receipt.
            throw AgentAccessError.writeFailed
        }
        try fault?(.receipt)
        _ = unlinkat(staging, attempt + ".json", 0)
        return AgentUpdateResult(receipt: receipt, path: creates.readable(plan.path), replayed: false)
    }

    /// `v0 2026-10-09 151000Z.md`: the agent write it replaced (0 is the create), then when, in UTC.
    static func versionName(sequence: Int, date: Date, existing: [String]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        let stem = "v\(sequence) " + formatter.string(from: date) + "Z"
        var name = stem + ".md"
        var number = 2
        while existing.contains(name) {
            name = stem + " \(number).md"
            number += 1
        }
        return name
    }

    // MARK: Reconciliation

    /// Finishes or abandons interrupted updates, silently. Runs before every update and on demand.
    @discardableResult
    public func reconcile() throws -> [AgentReceipt] {
        try creates.mapFilesystemErrors {
            try LibraryGate(root: library).withLease(timeout: gateTimeout) { reconcileHoldingGate() }
        }
    }

    /// An entry whose staged file is still there never replaced the document: recorded `abandoned`, with its
    /// staged file and saved version removed. Otherwise the document was replaced and gets its receipt.
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
                let intent = try? JSONDecoder().decode(AgentUpdateIntent.self, from: data)
            else { continue }
            let staged = attempt + ".md"
            if creates.receipt(intent.operationId)?.outcome.isPublished == true {
                // Already settled; only the journal cleanup was lost.
            } else if AgentCreateFiles.isRegularFile(staging, staged) {
                let receipt = intent.receipt(.abandoned)
                guard (try? creates.writeReceipt(receipt)) != nil else { continue }
                removeVersion(intent.previousVersion, root: root)
                settled.append(receipt)
            } else {
                let receipt = intent.receipt(.updated)
                guard (try? creates.writeReceipt(receipt)) != nil else { continue }
                settled.append(receipt)
            }
            _ = unlinkat(staging, staged, 0)
            _ = unlinkat(staging, name, 0)
        }
        for name in names {
            let orphan = name.hasSuffix(".md") && !names.contains(String(name.dropLast(3)) + ".json")
            if orphan || name.contains(".tmp-") { _ = unlinkat(staging, name, 0) }
        }
        return settled
    }

    private func removeVersion(_ path: String, root: Int32) {
        let parent = (path as NSString).deletingLastPathComponent
        guard let folder = try? AgentCreateFiles.folder(root, parent, create: false) else { return }
        _ = unlinkat(folder.descriptor, (path as NSString).lastPathComponent, 0)
        close(folder.descriptor)
    }

    /// Update keys never collide with create keys or with another grant's.
    func operationID(_ key: String) -> String {
        "op_" + DocumentRevision(data: Data("silkweb-update/v1\n\(creates.grantId)\n\(key)".utf8)).digest.prefix(32)
    }
}

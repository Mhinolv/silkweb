import Darwin
import Foundation

/// One agent-created Document the app shows (#137): its published receipts matched to a scanned Document.
public struct AgentActivityEntry: Equatable, Sendable {
    public let document: LibraryDocument
    /// The latest agent write: its create, or its newest update (#204).
    public let receipt: AgentReceipt
    /// The latest receipt's `createdAt`, or `nil` when it can't be read as ISO 8601.
    public let date: Date?
    /// Every published receipt for this Document, earliest first; the last one is `receipt`.
    public var receipts: [AgentReceipt] = []

    public init(document: LibraryDocument, receipt: AgentReceipt, date: Date?, receipts: [AgentReceipt]? = nil) {
        self.document = document
        self.receipt = receipt
        self.date = date
        self.receipts = receipts ?? [receipt]
    }

    /// The claimed agent of the latest write, as the app shows it; an empty claim reads “Unknown agent”.
    public var agent: String { AgentActivity.displayName(receipt.agent) }
    /// The latest write was an update (#204), so the list row says “Updated”.
    public var isUpdate: Bool { receipt.operation == .update }
}

/// The receipts under `.silkweb/agent-events/` (and, #230, the interrupted creates under `.silkweb/agent-staging/`),
/// read for display only (#137). Loading never writes, repairs or
/// creates anything, never takes the Library gate and never follows a link, so a receipt arriving can't feed
/// back into the watcher, the index or autosave.
public struct AgentActivity: Equatable, Sendable {
    public var receipts: [AgentReceipt]
    /// #230: content digests of helper creates still in `.silkweb/agent-staging/`: published (or about to be) but
    /// without a receipt until the helper reconciles them. Such a Document isn't “outside Silkweb”.
    public var pendingDigests: Set<String> = []

    public init(receipts: [AgentReceipt] = [], pendingDigests: Set<String> = []) {
        self.receipts = receipts
        self.pendingDigests = pendingDigests
    }

    /// The Library has agent activity to show: at least one receipt that published a Document.
    public var hasPublished: Bool {
        receipts.contains { $0.outcome == .created || $0.outcome == .reconciled || $0.outcome == .updated }
    }

    /// Reads every receipt. Unreadable, oversized, temporary and undecodable files are skipped, never repaired.
    public static func load(root: URL) -> AgentActivity {
        guard let library = try? AgentCreateFiles.openRoot(root) else { return AgentActivity() }
        defer { close(library) }
        let decoder = JSONDecoder()
        func decoded<T: Decodable>(_ folder: String, as type: T.Type) -> [T] {
            guard let descriptor = try? AgentCreateFiles.metadataFolder(library, folder, create: false) else {
                return []
            }
            defer { close(descriptor) }
            return AgentCreateFiles.names(descriptor).sorted().compactMap { name -> T? in
                guard name.hasSuffix(".json"), !name.hasPrefix("."), !name.contains(".tmp-"),
                    let data = AgentCreateFiles.read(descriptor, name, maxBytes: 65_536)
                else { return nil }
                return try? decoder.decode(T.self, from: data)
            }
        }
        let intents = decoded(AgentCreateService.stagingFolder, as: AgentCreateIntent.self)
        return AgentActivity(
            receipts: decoded(AgentCreateService.eventsFolder, as: AgentReceipt.self),
            pendingDigests: Set(intents.map(\.contentDigest)))
    }

    /// Published receipts matched to Documents that still exist, newest receipt first. A receipt finds its
    /// Document by index identity (which follows renames and moves), else at its destination when the index
    /// never learned that identity. Each Document appears once, with its latest write (create or update).
    public func entries(in snapshot: LibrarySnapshot) -> [AgentActivityEntry] {
        let published = receipts.filter { $0.outcome.isPublished }
        guard !published.isEmpty else { return [] }
        let byID = snapshot.presentation.documentsByID
        let byPath = Dictionary(
            snapshot.documents.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var matched: [UUID: (document: LibraryDocument, receipts: [AgentReceipt])] = [:]
        for receipt in published {
            var document = receipt.documentId.flatMap { byID[$0] }
            if document == nil, receipt.documentId.map({ snapshot.metadata.IDsByPath.values.contains($0) }) != true {
                document = receipt.destination.flatMap { byPath[$0] }
            }
            guard let document else { continue }
            matched[document.id, default: (document, [])].receipts.append(receipt)
        }
        return matched.values.map { document, receipts in
            let ordered = receipts.sorted(by: Self.isEarlier)
            let latest = ordered[ordered.count - 1]
            return AgentActivityEntry(
                document: document, receipt: latest, date: Self.date(latest.createdAt), receipts: ordered)
        }.sorted { Self.isNewer($0, than: $1) }
    }

    /// Agent writes to one document in order: by sequence (create 0, then each update), then date, then
    /// operation ID, so the order never depends on reading order.
    static func isEarlier(_ lhs: AgentReceipt, _ rhs: AgentReceipt) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        let left = date(lhs.createdAt) ?? .distantPast
        let right = date(rhs.createdAt) ?? .distantPast
        if left != right { return left < right }
        if lhs.operation != rhs.operation { return lhs.operation == .create }
        return lhs.operationId < rhs.operationId
    }

    /// Newest first; receipts without a readable date sink to the end, then Library path order.
    static func isNewer(_ lhs: AgentActivityEntry, than rhs: AgentActivityEntry) -> Bool {
        switch (lhs.date, rhs.date) {
        case (let left?, let right?) where left != right: return left > right
        case (.some, nil): return true
        case (nil, .some): return false
        default:
            if lhs.document.relativePath != rhs.document.relativePath {
                return lhs.document.relativePath.localizedStandardCompare(rhs.document.relativePath)
                    == .orderedAscending
            }
            return lhs.receipt.operationId < rhs.receipt.operationId
        }
    }

    /// The claimed agents with their Document counts, naturally sorted (“agent-2” before “agent-10”).
    public static func agents(in entries: [AgentActivityEntry]) -> [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries { counts[entry.agent, default: 0] += 1 }
        return counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map {
            (name: $0.key, count: $0.value)
        }
    }

    /// #229: the grants (receipt `grantId`, the project key) behind the latest writes, with Document counts, in
    /// natural order. Receipts without a grant are left out.
    public static func grants(in entries: [AgentActivityEntry]) -> [(id: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries where !entry.receipt.grantId.isEmpty { counts[entry.receipt.grantId, default: 0] += 1 }
        return counts.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map {
            (id: $0.key, count: $0.value)
        }
    }

    public static func displayName(_ agent: String) -> String {
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown agent" : trimmed
    }

    /// ISO 8601, with or without fractional seconds.
    public static func date(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// What Document Info shows about an agent-created Document (#137, #204). Agent and session are always claims;
/// only the operations and their dates come from Silkweb's receipts.
public struct AgentProvenance: Equatable, Sendable {
    /// Compares the current bytes with the latest agent write's digest (its create, or its newest update).
    /// Only “edited” is provable, never who edited.
    public enum SinceCreation: Equatable, Sendable { case unchanged, edited }

    /// Whether an agent may update the Document directly (#204, owner decision 2026-10-09).
    public enum AgentUpdates: Equatable, Sendable {
        /// The bytes are exactly what an agent last wrote.
        case allowed
        /// Edited since the last agent write: agents can only propose changes (#140).
        case editedInSilkweb
        /// Only the envelope claims an agent; Silkweb holds no receipt.
        case noReceipt

        public var label: String {
            switch self {
            case .allowed: return "Allowed"
            case .editedInSilkweb: return "Proposals only · edited in Silkweb"
            case .noReceipt: return "Proposals only · no Silkweb receipt"
            }
        }
    }

    public var agent: String
    public var session: String?
    public var client: String?
    /// The latest operation; `nil` when only the envelope makes the claim and Silkweb holds no receipt.
    public var operationId: String?
    /// The create receipt's date.
    public var created: Date?
    /// Since the latest agent write.
    public var sinceCreation: SinceCreation?
    /// Agent updates so far (#204), and the newest one's date.
    public var updates = 0
    public var lastUpdate: Date?
    /// Saved earlier versions that still exist under `.silkweb/agent-history/`, and the newest one
    /// (Library-relative) for Show in Finder.
    public var earlierVersions = 0
    public var newestVersion: String?
    public var agentUpdates: AgentUpdates?

    public var hasReceipt: Bool { operationId != nil }
    /// “Agent-created · claude-code”, or “claude-code (claimed)” without a receipt. Text, never colour alone.
    public var agentLabel: String { hasReceipt ? "Agent-created · \(agent)" : "\(agent) (claimed)" }
    public var operationLabel: String { operationId ?? "No Silkweb receipt" }
    /// “Since creation” until an agent updates the Document, then “Since last agent write”.
    public var sinceLabel: String { updates == 0 ? "Since creation" : "Since last agent write" }
    /// “Unchanged”, or “Edited after creation” / “Edited after agent update”, followed by `edited` when known.
    public func sinceValue(edited: String?) -> String? {
        sinceCreation.map {
            $0 == .unchanged
                ? "Unchanged"
                : (updates == 0 ? "Edited after creation" : "Edited after agent update")
                    + (edited.map { " · " + $0 } ?? "")
        }
    }
    /// “2 updates”.
    public var updatesLabel: String { updates == 1 ? "1 update" : "\(updates) updates" }

    public init(
        agent: String, session: String? = nil, client: String? = nil, operationId: String? = nil,
        created: Date? = nil, sinceCreation: SinceCreation? = nil, updates: Int = 0, lastUpdate: Date? = nil,
        earlierVersions: Int = 0, newestVersion: String? = nil, agentUpdates: AgentUpdates? = nil
    ) {
        self.agent = agent
        self.session = session
        self.client = client
        self.operationId = operationId
        self.created = created
        self.sinceCreation = sinceCreation
        self.updates = updates
        self.lastUpdate = lastUpdate
        self.earlierVersions = earlierVersions
        self.newestVersion = newestVersion
        self.agentUpdates = agentUpdates
    }

    /// `nil` for a human-created Document: no receipt and no envelope `agent` claim. `data` is the Document's
    /// current bytes (all of them when the receipt has a digest), or `nil` when it couldn't be read.
    public static func make(receipt: AgentReceipt?, data: Data?) -> AgentProvenance? {
        make(receipts: receipt.map { [$0] } ?? [], data: data)
    }

    /// `receipts` are the Document's published receipts, earliest first (`AgentActivityEntry.receipts`).
    /// `versions` are the saved earlier versions that still exist.
    public static func make(receipts: [AgentReceipt], data: Data?, versions: Set<String> = []) -> AgentProvenance? {
        var envelope: MemoryEnvelope?
        if let data, case .envelope(let parsed, _) = MemoryEnvelope.parse(String(decoding: data, as: UTF8.self)) {
            envelope = parsed
        }
        func claim(_ value: String?) -> String? {
            value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        if let latest = receipts.last {
            var since: SinceCreation?
            if let digest = latest.contentDigest, let data {
                // Another length is an edit without hashing; `load` reads one byte past the published size.
                since =
                    latest.byteCount > 0 && data.count != latest.byteCount
                    ? .edited : AgentCreateService.digest(data) == digest ? .unchanged : .edited
            }
            let creation = receipts.first { $0.operation == .create }
            let creator = creation ?? latest
            let updates = receipts.filter { $0.operation == .update }
            let saved = updates.compactMap(\.previousVersion).filter(versions.contains)
            return AgentProvenance(
                agent: AgentActivity.displayName(creator.agent), session: claim(creator.session),
                client: claim(creator.client), operationId: latest.operationId,
                created: creation.flatMap { AgentActivity.date($0.createdAt) }, sinceCreation: since,
                updates: updates.count, lastUpdate: updates.last.flatMap { AgentActivity.date($0.createdAt) },
                earlierVersions: saved.count, newestVersion: saved.last,
                agentUpdates: since.map { $0 == .unchanged ? .allowed : .editedInSilkweb })
        }
        guard let agent = claim(envelope?.string("agent")) else { return nil }
        return AgentProvenance(agent: agent, session: claim(envelope?.string("session")), agentUpdates: .noReceipt)
    }

    public static func load(relativePath: String, root: URL, receipt: AgentReceipt?) -> AgentProvenance? {
        load(relativePath: relativePath, root: root, receipts: receipt.map { [$0] } ?? [])
    }

    /// Reads the Document below the Library root without following links. Without a receipt digest only
    /// the start is read, enough for the envelope; with one, at most one byte more than was published. Saved
    /// versions are only checked for existence, never read.
    public static func load(relativePath: String, root: URL, receipts: [AgentReceipt]) -> AgentProvenance? {
        let receipt = receipts.last
        var versions: Set<String> = []
        let limit = receipt.flatMap { $0.contentDigest == nil ? nil : max($0.byteCount + 1, 65_536) } ?? 65_536
        var data: Data?
        if let library = try? AgentCreateFiles.openRoot(root) {
            defer { close(library) }
            let parent = (relativePath as NSString).deletingLastPathComponent
            let name = (relativePath as NSString).lastPathComponent
            if parent.isEmpty {
                data = AgentCreateFiles.read(library, name, maxBytes: limit)
            } else if let folder = try? AgentCreateFiles.folder(library, parent, create: false) {
                data = AgentCreateFiles.read(folder.descriptor, name, maxBytes: limit)
                close(folder.descriptor)
            }
            for path in receipts.compactMap(\.previousVersion)
            where path.hasPrefix(".silkweb/" + AgentUpdateService.historyFolder + "/") && !path.contains("..") {
                if AgentCreateFiles.isRegularFile(library, path) { versions.insert(path) }
            }
        }
        return make(receipts: receipts, data: data, versions: versions)
    }
}

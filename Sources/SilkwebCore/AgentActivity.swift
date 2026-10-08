import Darwin
import Foundation

/// One agent-created Document the app shows (#137): a published receipt matched to a scanned Document.
public struct AgentActivityEntry: Equatable, Sendable {
    public let document: LibraryDocument
    public let receipt: AgentReceipt
    /// The receipt's `createdAt`, or `nil` when it can't be read as ISO 8601.
    public let created: Date?

    /// The claimed agent as the app shows it; an empty claim reads “Unknown agent”.
    public var agent: String { AgentActivity.displayName(receipt.agent) }
}

/// The receipts under `.silkweb/agent-events/`, read for display only (#137). Loading never writes, repairs or
/// creates anything, never takes the Library gate and never follows a link, so a receipt arriving can't feed
/// back into the watcher, the index or autosave.
public struct AgentActivity: Equatable, Sendable {
    public var receipts: [AgentReceipt]

    public init(receipts: [AgentReceipt] = []) {
        self.receipts = receipts
    }

    /// The Library has agent activity to show: at least one receipt that published a Document.
    public var hasPublished: Bool { receipts.contains { $0.outcome == .created || $0.outcome == .reconciled } }

    /// Reads every receipt. Unreadable, oversized, temporary and undecodable files are skipped, never repaired.
    public static func load(root: URL) -> AgentActivity {
        guard let library = try? AgentCreateFiles.openRoot(root) else { return AgentActivity() }
        defer { close(library) }
        guard
            let events = try? AgentCreateFiles.metadataFolder(
                library, AgentCreateService.eventsFolder, create: false)
        else { return AgentActivity() }
        defer { close(events) }
        let decoder = JSONDecoder()
        let receipts = AgentCreateFiles.names(events).sorted().compactMap { name -> AgentReceipt? in
            guard name.hasSuffix(".json"), !name.hasPrefix("."), !name.contains(".tmp-"),
                let data = AgentCreateFiles.read(events, name, maxBytes: 65_536)
            else { return nil }
            return try? decoder.decode(AgentReceipt.self, from: data)
        }
        return AgentActivity(receipts: receipts)
    }

    /// Published receipts matched to Documents that still exist, newest receipt first. A receipt finds its
    /// Document by index identity (which follows renames and moves), else at its destination when the index
    /// never learned that identity. Each Document appears once, with its newest receipt.
    public func entries(in snapshot: LibrarySnapshot) -> [AgentActivityEntry] {
        let published = receipts.filter { $0.outcome.isPublished }
        guard !published.isEmpty else { return [] }
        let byID = snapshot.presentation.documentsByID
        let byPath = Dictionary(
            snapshot.documents.map { ($0.relativePath, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [UUID: AgentActivityEntry] = [:]
        for receipt in published {
            var document = receipt.documentId.flatMap { byID[$0] }
            if document == nil, receipt.documentId.map({ snapshot.metadata.IDsByPath.values.contains($0) }) != true {
                document = receipt.destination.flatMap { byPath[$0] }
            }
            guard let document else { continue }
            let entry = AgentActivityEntry(document: document, receipt: receipt, created: Self.date(receipt.createdAt))
            if let existing = entries[document.id], !Self.isNewer(entry, than: existing) { continue }
            entries[document.id] = entry
        }
        return entries.values.sorted { Self.isNewer($0, than: $1) }
    }

    /// Newest first; receipts without a readable date sink to the end, then Library path order.
    static func isNewer(_ lhs: AgentActivityEntry, than rhs: AgentActivityEntry) -> Bool {
        switch (lhs.created, rhs.created) {
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

    static func displayName(_ agent: String) -> String {
        let trimmed = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unknown agent" : trimmed
    }

    /// ISO 8601, with or without fractional seconds.
    public static func date(_ string: String) -> Date? {
        if let date = try? Date(string, strategy: .iso8601) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
    }
}

/// What Document Info shows about an agent-created Document (#137). Agent and session are always claims;
/// only the operation and its creation date come from Silkweb's receipt.
public struct AgentProvenance: Equatable, Sendable {
    /// Compares the current bytes with the receipt's digest. Only “edited” is provable, never who edited.
    public enum SinceCreation: Equatable, Sendable { case unchanged, edited }

    public var agent: String
    public var session: String?
    public var client: String?
    /// `nil` when only the envelope makes the claim and Silkweb holds no receipt.
    public var operationId: String?
    public var created: Date?
    public var sinceCreation: SinceCreation?

    public var hasReceipt: Bool { operationId != nil }
    /// “Agent-created · claude-code”, or “claude-code (claimed)” without a receipt. Text, never colour alone.
    public var agentLabel: String { hasReceipt ? "Agent-created · \(agent)" : "\(agent) (claimed)" }
    public var operationLabel: String { operationId ?? "No Silkweb receipt" }

    public init(
        agent: String, session: String? = nil, client: String? = nil, operationId: String? = nil,
        created: Date? = nil, sinceCreation: SinceCreation? = nil
    ) {
        self.agent = agent
        self.session = session
        self.client = client
        self.operationId = operationId
        self.created = created
        self.sinceCreation = sinceCreation
    }

    /// `nil` for a human-created Document: no receipt and no envelope `agent` claim. `data` is the Document's
    /// current bytes (all of them when the receipt has a digest), or `nil` when it couldn't be read.
    public static func make(receipt: AgentReceipt?, data: Data?) -> AgentProvenance? {
        var envelope: MemoryEnvelope?
        if let data, case .envelope(let parsed, _) = MemoryEnvelope.parse(String(decoding: data, as: UTF8.self)) {
            envelope = parsed
        }
        func claim(_ value: String?) -> String? {
            value.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        }
        if let receipt {
            var since: SinceCreation?
            if let digest = receipt.contentDigest, let data {
                // Another length is an edit without hashing; `load` reads one byte past the published size.
                since =
                    receipt.byteCount > 0 && data.count != receipt.byteCount
                    ? .edited : AgentCreateService.digest(data) == digest ? .unchanged : .edited
            }
            return AgentProvenance(
                agent: AgentActivity.displayName(receipt.agent), session: claim(receipt.session),
                client: claim(receipt.client), operationId: receipt.operationId,
                created: AgentActivity.date(receipt.createdAt), sinceCreation: since)
        }
        guard let agent = claim(envelope?.string("agent")) else { return nil }
        return AgentProvenance(agent: agent, session: claim(envelope?.string("session")))
    }

    /// Reads the Document below the Library root without following links. Without a receipt digest only
    /// the start is read, enough for the envelope; with one, at most one byte more than was published.
    public static func load(relativePath: String, root: URL, receipt: AgentReceipt?) -> AgentProvenance? {
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
        }
        return make(receipt: receipt, data: data)
    }
}

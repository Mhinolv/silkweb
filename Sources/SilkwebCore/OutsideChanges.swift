import Darwin
import Foundation

/// #230: a Library change that came neither through Silkweb nor through the helper, as far as Silkweb can prove.
/// It never says which app made it.
public enum OutsideChangeKind: String, Equatable, Sendable {
    /// A Document under `Memory/` that no receipt published and Silkweb didn't create, move in or save.
    case added
    /// A Document with a `silkweb-memory` envelope whose bytes no receipt, Silkweb save or Keep accounts for.
    case changed

    public var label: String { self == .added ? "Added outside Silkweb" : "Changed outside Silkweb" }
}

/// One flagged Document, for Agent Activity and Document Info. Wording stays neutral: “outside Silkweb”.
public struct OutsideChange: Equatable, Sendable {
    public let document: LibraryDocument
    public let kind: OutsideChangeKind
    /// A published receipt exists for the Document (an agent created it through the helper before the change).
    public let hasReceipt: Bool

    public init(document: LibraryDocument, kind: OutsideChangeKind, hasReceipt: Bool = false) {
        self.document = document
        self.kind = kind
        self.hasReceipt = hasReceipt
    }

    public var label: String { kind.label }
    /// VoiceOver, after the row's other parts: “added outside Silkweb, no Silkweb receipt”.
    public var accessibilityDescription: String {
        (kind == .added ? "added outside Silkweb" : "changed outside Silkweb")
            + (hasReceipt ? "" : ", no Silkweb receipt")
    }
}

/// `.silkweb/outside-changes.json` (#230): the Documents Silkweb accounts for, by index ID, with the digest of the
/// bytes it accounted for. Silkweb adds one when it creates, imports or moves a Document into `Memory/`, saves a
/// Document there (or one an agent created), and when the owner chooses Keep. Only the app writes it.
public struct OutsideChangeLedger: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileName = "outside-changes.json"

    public var version = currentVersion
    /// Document UUID → `sha256:` digest of the accounted bytes; empty when Silkweb accounted for it without them.
    public var documents: [String: String] = [:]

    public init(documents: [String: String] = [:]) {
        self.documents = documents
    }

    private enum CodingKeys: String, CodingKey { case version, documents }

    /// Missing keys decode to defaults; a newer version is refused, so its entries are never dropped by a save.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        guard version <= Self.currentVersion else { throw LibraryError.unsupportedMetadataVersion(version) }
        self.version = Self.currentVersion
        documents = (try? values.decodeIfPresent([String: String].self, forKey: .documents)) ?? [:]
    }

    public func digest(for id: UUID) -> String? { documents[id.uuidString] }

    /// A missing file is an empty ledger. Throws for an unreadable or newer one.
    public static func load(root: URL) throws -> OutsideChangeLedger {
        let file = try url(root: root)
        guard FileManager.default.fileExists(atPath: file.path) else { return OutsideChangeLedger() }
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
    }

    /// Whether `error` from `load` means a newer build wrote the ledger: then it's never overwritten.
    public static func isNewer(_ error: Error) -> Bool {
        if case LibraryError.unsupportedMetadataVersion = error { return true }
        return false
    }

    /// Writes `entries` over the saved ledger (another window may have kept something meanwhile), keeping only
    /// Documents in `existing`. Atomic, sorted keys. An undecodable ledger is replaced; a newer one throws.
    @discardableResult
    public static func merge(_ entries: [String: String], root: URL, existing: Set<UUID>) throws
        -> OutsideChangeLedger
    {
        var ledger = OutsideChangeLedger()
        do { ledger = try load(root: root) } catch  where isNewer(error) { throw error } catch {}
        ledger.documents.merge(entries) { _, new in new }
        let ids = Set(existing.map(\.uuidString))
        ledger.documents = ledger.documents.filter { ids.contains($0.key) }
        let file = try url(root: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(ledger).write(to: file, options: .atomic)
        return ledger
    }

    private static func url(root: URL) throws -> URL {
        try LibraryMetadataStore.rejectLink(root)
        let file = root.appendingPathComponent(".silkweb/" + fileName)
        try LibraryMetadataStore.rejectLink(file.deletingLastPathComponent())
        try LibraryMetadataStore.rejectLink(file)
        return file
    }
}

/// Finds outside changes (#230). Pure apart from reading Documents below the Library root without following links;
/// never writes. A Document is reread only when its modification date changes, so a watcher tick on a large
/// Library reads almost nothing. Run it off the main thread.
///
/// The heuristic, also in `docs/agent-memory.md` › In the app:
/// - **Added outside Silkweb:** a Document under `Memory/` with no published receipt and no ledger entry.
/// - **Changed outside Silkweb:** a Document with a `silkweb-memory` envelope whose bytes match neither its latest
///   receipt's digest nor its ledger digest; or, under `Memory/`, a known envelope Document without a receipt
///   whose bytes changed since Silkweb accounted for them.
/// - Never: Documents outside `Memory/` without a receipt, Documents without an envelope once Silkweb knows them,
///   and anything Silkweb itself saved.
public struct OutsideChangeDetector: Sendable {
    public static let memoryFolder = "Memory"
    /// Agent memory Documents are small; anything larger is compared by its first bytes only and never matches.
    static let maxBytes = 16 << 20

    struct Reading: Equatable, Sendable {
        let path: String
        let modified: Date?
        let digest: String?
        let hasEnvelope: Bool
    }
    private var readings: [UUID: Reading] = [:]
    /// Test seam: Documents read by the last `detect`.
    public private(set) var reads = 0

    public init() {}

    public static func isInMemory(_ path: String) -> Bool {
        path.range(of: memoryFolder + "/", options: [.anchored, .caseInsensitive]) != nil
    }

    /// Flagged Documents in Library order. `pendingDigests` are helper creates that have no receipt yet
    /// (`AgentActivity.pendingDigests`); a Document with those bytes is the helper's, not an outside change.
    public mutating func detect(
        snapshot: LibrarySnapshot, entries: [AgentActivityEntry], ledger: OutsideChangeLedger,
        pendingDigests: Set<String> = []
    ) -> [OutsideChange] {
        reads = 0
        let receipts = Dictionary(entries.map { ($0.document.id, $0.receipt) }, uniquingKeysWith: { first, _ in first })
        var library: Int32?
        defer { if let library { close(library) } }
        func reading(_ document: LibraryDocument) -> Reading? {
            if let cached = readings[document.id], cached.path == document.relativePath,
                cached.modified == document.modified
            {
                return cached
            }
            if library == nil { library = try? AgentCreateFiles.openRoot(snapshot.rootURL) }
            guard let library else { return nil }
            reads += 1
            let data = Self.read(document.relativePath, in: library)
            let result = Reading(
                path: document.relativePath, modified: document.modified,
                digest: data.map(AgentCreateService.digest),
                hasEnvelope: data.map {
                    MemoryEnvelope.parse(String(decoding: $0.prefix(65_536), as: UTF8.self)) != .missing
                } ?? false)
            readings[document.id] = result
            return result
        }

        var found: [OutsideChange] = []
        var seen = Set<UUID>()
        for document in snapshot.documents {
            seen.insert(document.id)
            let accounted = ledger.digest(for: document.id)
            if let receipt = receipts[document.id] {
                // Old receipts without a digest can't be compared.
                guard let published = receipt.contentDigest, let current = reading(document),
                    let digest = current.digest
                else { continue }
                if digest == published || digest == accounted || !current.hasEnvelope { continue }
                found.append(OutsideChange(document: document, kind: .changed, hasReceipt: true))
            } else if Self.isInMemory(document.relativePath) {
                guard let accounted else {
                    if !pendingDigests.isEmpty, let digest = reading(document)?.digest, pendingDigests.contains(digest)
                    {
                        continue
                    }
                    found.append(OutsideChange(document: document, kind: .added))
                    continue
                }
                guard let current = reading(document), let digest = current.digest else { continue }
                if digest == accounted || !current.hasEnvelope || pendingDigests.contains(digest) { continue }
                found.append(OutsideChange(document: document, kind: .changed))
            }
        }
        readings = readings.filter { seen.contains($0.key) }
        return found
    }

    /// The bytes of one Document below the Library, without following links; `nil` when it can't be read.
    static func read(_ relativePath: String, in library: Int32) -> Data? {
        let parent = (relativePath as NSString).deletingLastPathComponent
        let name = (relativePath as NSString).lastPathComponent
        if parent.isEmpty { return AgentCreateFiles.read(library, name, maxBytes: maxBytes) }
        guard let folder = try? AgentCreateFiles.folder(library, parent, create: false) else { return nil }
        defer { close(folder.descriptor) }
        return AgentCreateFiles.read(folder.descriptor, name, maxBytes: maxBytes)
    }

    /// `sha256:` digests of Library-relative Documents, for Keep and for Documents Silkweb just created or moved in.
    /// A Document that can't be read gets an empty digest: accounted for, bytes unknown.
    public static func digests(_ documents: [LibraryDocument], root: URL) -> [String: String] {
        guard !documents.isEmpty, let library = try? AgentCreateFiles.openRoot(root) else { return [:] }
        defer { close(library) }
        var result: [String: String] = [:]
        for document in documents {
            result[document.id.uuidString] =
                read(document.relativePath, in: library).map(AgentCreateService.digest) ?? ""
        }
        return result
    }
}

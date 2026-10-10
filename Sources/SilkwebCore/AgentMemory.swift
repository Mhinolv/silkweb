import Foundation

/// The v2 agent-memory contract (`docs/agent-memory.md`): the grants file, scope rules, filesystem
/// qualification and read-only helper commands. Enforcement per operation lives in `AgentAccess.swift`
/// (#130); creates and receipts in `AgentCreate.swift` (#133).
public enum AgentMemoryContract {
    public static let version = 1
    /// `retrieval_contract_version` in `knowledge-graph-retrieval.md`, reported by capabilities and ranked modes.
    public static let retrievalVersion = 1
    public static let projectsFolder = "Memory/Projects"
    /// Title-case entry folders, in display order. `Proposals` is reserved and never created in MVP.
    public static let entryFolders = ["Memories", "Progress", "Handoffs"]
    public static let reservedFolders: Set<String> = ["proposals"]
    /// Instruction and agent-configuration files are never agent-creatable (compared case-insensitively).
    public static let instructionFiles: Set<String> = [
        "agents.md", "agent.md", "claude.md", "claude.local.md", "gemini.md", ".mcp.json", "mcp.json",
    ]

    public static func projectRoot(_ project: String) -> String { projectsFolder + "/" + project }

    /// #206: agent-level memory shared by every grant with the same `agent_folder`.
    public static let agentsFolder = "Memory/Agents"
    /// The one create folder inside an agent folder.
    public static let agentMemoriesFolder = "Memories"

    public static func agentRoot(_ agentFolder: String) -> String { agentsFolder + "/" + agentFolder }
    public static func agentMemoriesRoot(_ agentFolder: String) -> String {
        agentRoot(agentFolder) + "/" + agentMemoriesFolder
    }

    /// #228: too wide to be a `create_folders` entry (the Library root never normalizes). Compared ignoring case.
    /// `Memory/Projects` is allowed: the owner grants every project with it.
    public static let refusedCreateFolders = ["Memory", agentsFolder]

    /// “Memory › Projects › Silkweb” for anything a human reads; JSON keeps POSIX paths.
    public static func displayPath(_ path: String) -> String {
        path.split(separator: "/").joined(separator: " › ")
    }
}

/// One owner-approved project grant. Stored outside the Library so agents can't edit it.
public struct AgentGrant: Codable, Equatable, Sendable {
    /// The grant's profile. `read-only` is accepted as a spelling of `read`; `read` is what's saved.
    public enum Access: String, Codable, Sendable {
        case read
        case readCreate = "read-create"
        /// #204: also updates documents an agent created, inside the create folders.
        case readCreateUpdate = "read-create-update"

        /// Owner-facing profile names.
        public var displayName: String {
            switch self {
            case .read: return "Read Only"
            case .readCreate: return "Read and Create"
            case .readCreateUpdate: return "Read, Create and Update"
            }
        }

        public var allowsCreate: Bool { self != .read }
        public var allowsUpdate: Bool { self == .readCreateUpdate }

        /// Profiles in order of how much they allow, so `grant init` can tell narrowing from widening.
        public var rank: Int {
            switch self {
            case .read: return 0
            case .readCreate: return 1
            case .readCreateUpdate: return 2
            }
        }

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            switch value {
            case "read", "read-only": self = .read
            case "read-create": self = .readCreate
            case "read-create-update": self = .readCreateUpdate
            default:
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "Unknown access level"))
            }
        }
    }

    public var project: String
    public var library: LibraryLocation
    public var access: Access
    /// Optional extra read-only folders, relative to the Library.
    public var extraReadFolders: [String]
    /// Owner-facing name used in refusals; empty means “<Project> project”.
    public var label: String
    /// #206: the owner-set key of `Memory/Agents/<Key>`, read whole and created in under `Memories`. Never
    /// inferred from the agent's claim. A value that isn't a valid Folder name (or isn't a string) fails the
    /// grant closed.
    public var agentFolder: String?
    /// #228: owner-chosen Library-relative folders agents may create in, recursively. Each is also a read folder.
    /// Empty keeps the default template. An entry that isn't a valid create folder fails the grant closed.
    public var createFolders: [String]
    public var limits: AgentGrantLimits
    public var createdAt: Date?
    /// Set when the owner turns access off. Sessions fail closed on their next operation.
    public var revokedAt: Date?

    public init(
        project: String, library: LibraryLocation, access: Access = .readCreate, extraReadFolders: [String] = [],
        label: String = "", limits: AgentGrantLimits = AgentGrantLimits(), createdAt: Date? = nil,
        revokedAt: Date? = nil, agentFolder: String? = nil, createFolders: [String] = []
    ) {
        self.project = project
        self.library = library
        self.access = access
        self.extraReadFolders = extraReadFolders
        self.label = label
        self.agentFolder = agentFolder
        self.createFolders = createFolders
        self.limits = limits
        self.createdAt = createdAt
        self.revokedAt = revokedAt
    }

    public var displayLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? project + " project" : label
    }

    public var isRevoked: Bool { revokedAt != nil }

    private enum CodingKeys: String, CodingKey {
        case project, library, access, label, limits
        case extraReadFolders = "extra_read_folders"
        case agentFolder = "agent_folder"
        case createFolders = "create_folders"
        case createdAt = "created_at"
        case revokedAt = "revoked_at"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        project = try values.decodeIfPresent(String.self, forKey: .project) ?? ""
        library = try values.decodeIfPresent(LibraryLocation.self, forKey: .library) ?? LibraryLocation()
        // An unknown access level from a newer build falls back to the narrower profile.
        access = (try? values.decodeIfPresent(Access.self, forKey: .access)) ?? .read
        extraReadFolders = try values.decodeIfPresent([String].self, forKey: .extraReadFolders) ?? []
        label = (try? values.decodeIfPresent(String.self, forKey: .label)) ?? ""
        // A non-string value is kept as an invalid key, so the grant fails to load rather than losing its folder.
        if values.contains(.agentFolder), try !values.decodeNil(forKey: .agentFolder) {
            agentFolder = (try? values.decode(String.self, forKey: .agentFolder)) ?? ""
        } else {
            agentFolder = nil
        }
        // Like `agent_folder`: a value that isn't a list of strings fails the grant closed instead of narrowing it.
        if values.contains(.createFolders), try !values.decodeNil(forKey: .createFolders) {
            createFolders = (try? values.decode([String].self, forKey: .createFolders)) ?? [""]
        } else {
            createFolders = []
        }
        limits = (try? values.decodeIfPresent(AgentGrantLimits.self, forKey: .limits)) ?? AgentGrantLimits()
        createdAt = (try? values.decodeIfPresent(String.self, forKey: .createdAt)).flatMap { $0 }.flatMap(Self.date)
        // Any non-null `revoked_at`, even one that can't be parsed, keeps the grant off (fail closed).
        if values.contains(.revokedAt), try !values.decodeNil(forKey: .revokedAt) {
            revokedAt = (try? values.decode(String.self, forKey: .revokedAt)).flatMap(Self.date) ?? .distantPast
        } else {
            revokedAt = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(project, forKey: .project)
        try values.encode(library, forKey: .library)
        try values.encode(access, forKey: .access)
        try values.encode(extraReadFolders, forKey: .extraReadFolders)
        if !label.isEmpty { try values.encode(label, forKey: .label) }
        try values.encodeIfPresent(agentFolder, forKey: .agentFolder)
        if !createFolders.isEmpty { try values.encode(createFolders, forKey: .createFolders) }
        try values.encode(limits, forKey: .limits)
        try values.encodeIfPresent(createdAt.map(Self.string), forKey: .createdAt)
        try values.encodeIfPresent(revokedAt.map(Self.string), forKey: .revokedAt)
    }

    /// ISO 8601 in UTC, whole seconds, so the owner can read and diff the file.
    private static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
    private static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

/// `~/Library/Application Support/Silkweb/agent-grants.json`, versioned and decoded tolerantly.
public struct AgentGrantFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = currentVersion
    public var grants: [AgentGrant]
    /// #205: present once the owner protected their grants (`AgentGrantSigning`). The file stays `version: 1`: older
    /// builds ignore the key.
    public var signature: AgentGrantSignature?

    public init(grants: [AgentGrant] = []) { self.grants = grants }

    private enum CodingKeys: String, CodingKey { case version, grants, signature }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        grants = try values.decodeIfPresent([AgentGrant].self, forKey: .grants) ?? []
        // A `signature` that isn't an object still counts as signed, so it fails verification instead of reading as
        // an unsigned file.
        if values.contains(.signature), try !values.decodeNil(forKey: .signature) {
            signature = (try? values.decode(AgentGrantSignature.self, forKey: .signature)) ?? .unreadable
        } else {
            signature = nil
        }
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Silkweb/agent-grants.json")
    }

    public func grant(for project: String) -> AgentGrant? { grants.first { $0.project == project } }

    /// The grant a caller asked for (#135), by exact project key, then by its label. Without a
    /// request, the only grant is used; with several, the caller has to choose. Revoked grants are
    /// still selected, so the operation reports `grant_revoked` rather than a missing grant.
    public func select(_ requested: String?) throws -> AgentGrant {
        guard let requested else {
            guard grants.count == 1 else {
                throw grants.isEmpty ? AgentAccessError.noGrants : .grantRequired(grants.map(\.displayLabel))
            }
            return grants[0]
        }
        if let grant = grant(for: requested) { return grant }
        let labelled = grants.filter { $0.displayLabel == requested }
        guard labelled.count <= 1 else { throw AgentAccessError.grantRequired(grants.map(\.displayLabel)) }
        guard let grant = labelled.first else { throw AgentAccessError.grantNotFound(requested) }
        return grant
    }

    /// Turns a grant off (keeping the first revocation date) or back on. False if there's no grant.
    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, project: String, at date: Date = Date()) -> Bool {
        guard let index = grants.firstIndex(where: { $0.project == project }) else { return false }
        grants[index].revokedAt = enabled ? nil : (grants[index].revokedAt ?? date)
        return true
    }

    /// Atomic replace with sorted keys, so the owner can diff it and running helpers see one
    /// complete file (a new inode) on their next operation. Writes `signature` as it is: owner paths save through
    /// `AgentGrantSigning.save`, which signs once grants are protected.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum AgentScopeError: Error, Equatable {
    case invalidProject
    case invalidAgentFolder
    /// #228: a `create_folders` entry that's outside the Library or too wide.
    case invalidCreateFolder(String)
    case invalidPath(String)
    case outsideRead(String)
    case outsideCreate(String)
    case excluded(String)

    /// Sentence case, curly quotes, display paths; never echoes document text.
    public var message: String {
        let display = { (path: String) in "“\(AgentMemoryContract.displayPath(path))”" }
        switch self {
        case .invalidProject: return "The project name isn’t a valid folder name."
        case .invalidAgentFolder: return "The agent folder isn’t a valid folder name."
        case .invalidCreateFolder(let path):
            return "\(display(path)) can’t be a create folder: choose a Folder inside the Library, not the Library "
                + "itself, “Memory” or “Memory › Agents”."
        case .invalidPath(let path): return "\(display(path)) isn’t a path inside the Library."
        case .outsideRead(let path): return "\(display(path)) is outside this grant’s read folders."
        case .outsideCreate(let path): return "\(display(path)) is outside this grant’s create folders."
        case .excluded(let path):
            return "Agents can’t create \(display(path)): only Markdown documents that aren’t instruction files."
        }
    }
}

/// Component-aware read/create containment for one grant. Paths are POSIX and Library-relative.
/// Code that touches disk goes through `AgentSecureFiles`, which refuses links on the way.
public struct AgentScope: Equatable, Sendable {
    public let project: String
    /// #206: the grant's agent folder key, if it has one.
    public let agentFolder: String?
    public let readRoots: [String]
    public let createRoots: [String]
    /// Matches the Library's volume. Case-insensitive containment on a case-sensitive volume would let
    /// `memory/…` name a different Folder than `Memory/…`.
    public let caseSensitive: Bool

    /// `createAllowed` is false for read-only grants and for unqualified filesystems.
    public init(grant: AgentGrant, createAllowed: Bool = true, caseSensitive: Bool = false) throws {
        guard (try? LibraryMutations.validateName(grant.project)) == grant.project else {
            throw AgentScopeError.invalidProject
        }
        if let key = grant.agentFolder, (try? LibraryMutations.validateName(key)) != key {
            throw AgentScopeError.invalidAgentFolder
        }
        project = grant.project
        agentFolder = grant.agentFolder
        self.caseSensitive = caseSensitive
        let root = AgentMemoryContract.projectRoot(project)
        var reads = [root]
        // The whole agent folder is readable, so documents the owner placed at its top level are found too.
        if let agentFolder { reads.append(AgentMemoryContract.agentRoot(agentFolder)) }
        let createFolders = try grant.createFolders.map(Self.validateCreateFolder)
        // #228: every create folder is readable too, so an agent finds what it created there.
        for folder in try grant.extraReadFolders.map(Self.normalize) + createFolders {
            if !reads.contains(where: { Self.contains($0, folder, caseSensitive: caseSensitive) }) {
                reads.append(folder)
            }
        }
        readRoots = reads
        var creates: [String] = []
        if createAllowed && grant.access.allowsCreate {
            creates = AgentMemoryContract.entryFolders.map { root + "/" + $0 }
            if let agentFolder { creates.append(AgentMemoryContract.agentMemoriesRoot(agentFolder)) }
            // A create folder that holds a default one replaces it, so each place is listed once.
            for folder in createFolders
            where !creates.contains(where: { Self.contains($0, folder, caseSensitive: caseSensitive) }) {
                creates.removeAll { Self.contains(folder, $0, caseSensitive: caseSensitive) }
                creates.append(folder)
            }
        }
        createRoots = creates
    }

    /// #228: a `create_folders` entry, normalized. The Library root, `Memory`, `Memory/Agents` and paths through
    /// reserved Folders are refused, ignoring case on every volume.
    public static func validateCreateFolder(_ path: String) throws -> String {
        guard let normalized = try? normalize(path) else { throw AgentScopeError.invalidCreateFolder(path) }
        let wide = AgentMemoryContract.refusedCreateFolders.contains {
            $0.compare(normalized, options: [.caseInsensitive]) == .orderedSame
        }
        let reserved = normalized.lowercased().split(separator: "/").contains {
            AgentMemoryContract.reservedFolders.contains(String($0))
        }
        guard !wide, !reserved else { throw AgentScopeError.invalidCreateFolder(normalized) }
        return normalized
    }

    private init(
        project: String, agentFolder: String?, readRoots: [String], createRoots: [String], caseSensitive: Bool
    ) {
        self.project = project
        self.agentFolder = agentFolder
        self.readRoots = readRoots
        self.createRoots = createRoots
        self.caseSensitive = caseSensitive
    }

    /// Intersects the grant with an MCP client's roots: a client root inside a granted folder narrows
    /// it, a granted folder inside a client root stays as is, and anything else is dropped. Invalid
    /// client roots match nothing. The result is never wider than the grant.
    public func narrowed(to clientRoots: [String]) -> AgentScope {
        let clients = clientRoots.compactMap { try? Self.normalize($0) }
        let intersect = { (granted: [String]) -> [String] in
            var result: [String] = []
            for root in granted {
                for client in clients {
                    let inner =
                        contains(root, client) ? client : contains(client, root) ? root : nil
                    if let inner, !result.contains(where: { contains($0, inner) }) {
                        result.removeAll { contains(inner, $0) }
                        result.append(inner)
                    }
                }
            }
            return result
        }
        return AgentScope(
            project: project, agentFolder: agentFolder, readRoots: intersect(readRoots),
            createRoots: intersect(createRoots), caseSensitive: caseSensitive)
    }

    /// #206: whether `path` is in the agent folder rather than the project's. Search ranks these after project
    /// documents, and creates there carry the agent folder key as their envelope `project`.
    public func isAgentLevel(_ path: String) -> Bool {
        guard let agentFolder else { return false }
        return contains(AgentMemoryContract.agentRoot(agentFolder), path)
    }

    /// #228: progress documents go only in a project's `Progress` and handoffs only in its `Handoffs` (the grant's own
    /// project, or another one a create folder such as `Memory/Projects` holds); memories and decisions go in any
    /// create folder.
    public func allows(type: String, at path: String) -> Bool {
        let entry: String
        switch type {
        case "progress": entry = "Progress"
        case "handoff": entry = "Handoffs"
        default: return true
        }
        guard let folder = folderKey(in: AgentMemoryContract.projectsFolder, path) else { return false }
        return contains(AgentMemoryContract.projectRoot(folder) + "/" + entry, path)
    }

    /// The envelope `project` for a document created at `path`: the key of the agent folder it's in
    /// (`Memory/Agents/<Key>/…`, #206 and #228), the other project it's in (`Memory/Projects/<Other>/…`, #228), or nil
    /// for the grant's own project.
    public func envelopeProject(for path: String) -> String? {
        if isAgentLevel(path) { return agentFolder }
        if contains(AgentMemoryContract.projectRoot(project), path) { return nil }
        return folderKey(in: AgentMemoryContract.agentsFolder, path)
            ?? folderKey(in: AgentMemoryContract.projectsFolder, path)
    }

    /// The Folder name right under `parent` (`Memory/Projects` or `Memory/Agents`) for a document inside one of them.
    private func folderKey(in parent: String, _ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count > 3, contains(parent, path) else { return nil }
        return parts[2]
    }

    public func checkRead(_ path: String) throws -> String {
        let normalized = try Self.normalize(path)
        guard readRoots.contains(where: { contains($0, normalized) }) else {
            throw AgentScopeError.outsideRead(normalized)
        }
        return normalized
    }

    /// Keeps only in-scope items. Search, list and activity filter with this **before** ranking,
    /// counting or building snippets, so totals and “N more” never reflect out-of-scope documents.
    public func readable<Item>(_ items: some Sequence<Item>, path: (Item) -> String) -> [Item] {
        items.filter { (try? checkRead(path($0))) != nil }
    }

    /// A new Markdown document inside one of the create folders, never an instruction file.
    public func checkCreate(_ path: String) throws -> String {
        let normalized = try checkInsideCreateRoot(path)
        let name = (normalized as NSString).lastPathComponent.lowercased()
        if AgentMemoryContract.instructionFiles.contains(name) || (name as NSString).pathExtension != "md" {
            throw AgentScopeError.excluded(normalized)
        }
        return normalized
    }

    /// An existing document an update may replace (#204): the same rules as a new one, so updates stay
    /// inside the create folders and never touch instruction files or reserved Folders.
    public func checkUpdate(_ path: String) throws -> String { try checkCreate(path) }

    /// A new Folder inside one of the create folders, named by the rules for new names.
    public func checkCreateFolder(_ path: String) throws -> String {
        let normalized = try checkInsideCreateRoot(path)
        let name = (normalized as NSString).lastPathComponent
        guard (try? LibraryMutations.validateName(name)) == name else { throw AgentScopeError.invalidPath(path) }
        return normalized
    }

    private func checkInsideCreateRoot(_ path: String) throws -> String {
        let normalized = try Self.normalize(path)
        guard
            createRoots.contains(where: {
                contains($0, normalized) && !contains(normalized, $0)
            })
        else { throw AgentScopeError.outsideCreate(normalized) }
        let components = normalized.lowercased().split(separator: "/").map(String.init)
        if components.contains(where: AgentMemoryContract.reservedFolders.contains) {
            throw AgentScopeError.excluded(normalized)
        }
        return normalized
    }

    /// Rejects absolute paths, `.`/`..`, hidden components (`.silkweb`) and control characters.
    static func normalize(_ path: String) throws -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !path.hasPrefix("/"), !parts.isEmpty,
            parts.allSatisfy({ (try? LibraryMutations.validateExistingComponent($0)) != nil }),
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw AgentScopeError.invalidPath(path) }
        return parts.joined(separator: "/")
    }

    private func contains(_ root: String, _ path: String) -> Bool {
        Self.contains(root, path, caseSensitive: caseSensitive)
    }

    /// Whole components only (`Silkweb2` isn't inside `Silkweb`), compared like APFS: Unicode
    /// normalization never matters, and case matters only on a case-sensitive volume.
    static func contains(_ root: String, _ path: String, caseSensitive: Bool) -> Bool {
        let rootParts = root.split(separator: "/")
        let pathParts = path.split(separator: "/")
        guard pathParts.count >= rootParts.count else { return false }
        let options: String.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
        return zip(rootParts, pathParts).allSatisfy { $0.compare($1, options: options) == .orderedSame }
    }
}

/// Only local APFS/HFS+ volumes carry the human-text guarantee. Owner decision 2026-10-07: MVP
/// supports local-disk Libraries only, so creates are disabled elsewhere; reads still work.
public enum AgentFilesystem: String, Codable, Sendable {
    case qualified
    case unqualified

    public static func classify(path: String, isLocal: Bool?, typeName: String?, isUbiquitous: Bool?) -> Self {
        let syncFolders = ["/Library/Mobile Documents/", "/Library/CloudStorage/"]
        guard isLocal == true, isUbiquitous != true, ["apfs", "hfs"].contains(typeName?.lowercased() ?? ""),
            !syncFolders.contains(where: { (path + "/").contains($0) })
        else { return .unqualified }
        return .qualified
    }

    public static func probe(_ url: URL) -> Self {
        let values = try? url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeTypeNameKey, .isUbiquitousItemKey])
        return classify(
            path: url.resolvingSymlinksInPath().path, isLocal: values?.volumeIsLocal,
            typeName: values?.volumeTypeName, isUbiquitous: values?.isUbiquitousItem)
    }
}

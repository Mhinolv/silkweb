import Foundation

/// The v2 agent-memory contract (`docs/agent-memory.md`): the grants file, scope rules, filesystem
/// qualification and read-only helper commands. Enforcement per operation lives in `AgentAccess.swift`
/// (#130); creates and receipts in `AgentCreate.swift` (#133).
public enum AgentMemoryContract {
    public static let version = 1
    public static let projectsFolder = "Memory/Projects"
    /// Title-case entry folders, in display order. `Proposals` is reserved and never created in MVP.
    public static let entryFolders = ["Memories", "Progress", "Handoffs"]
    public static let reservedFolders: Set<String> = ["proposals"]
    /// Instruction and agent-configuration files are never agent-creatable (compared case-insensitively).
    public static let instructionFiles: Set<String> = [
        "agents.md", "agent.md", "claude.md", "claude.local.md", "gemini.md", ".mcp.json", "mcp.json",
    ]

    public static func projectRoot(_ project: String) -> String { projectsFolder + "/" + project }

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

        /// Owner-facing profile names.
        public var displayName: String { self == .read ? "Read Only" : "Read and Create" }

        public init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            switch value {
            case "read", "read-only": self = .read
            case "read-create": self = .readCreate
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
    public var limits: AgentGrantLimits
    public var createdAt: Date?
    /// Set when the owner turns access off. Sessions fail closed on their next operation.
    public var revokedAt: Date?

    public init(
        project: String, library: LibraryLocation, access: Access = .readCreate, extraReadFolders: [String] = [],
        label: String = "", limits: AgentGrantLimits = AgentGrantLimits(), createdAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.project = project
        self.library = library
        self.access = access
        self.extraReadFolders = extraReadFolders
        self.label = label
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

    public init(grants: [AgentGrant] = []) { self.grants = grants }

    private enum CodingKeys: String, CodingKey { case version, grants }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        grants = try values.decodeIfPresent([AgentGrant].self, forKey: .grants) ?? []
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Silkweb/agent-grants.json")
    }

    public func grant(for project: String) -> AgentGrant? { grants.first { $0.project == project } }

    /// Turns a grant off (keeping the first revocation date) or back on. False if there's no grant.
    @discardableResult
    public mutating func setEnabled(_ enabled: Bool, project: String, at date: Date = Date()) -> Bool {
        guard let index = grants.firstIndex(where: { $0.project == project }) else { return false }
        grants[index].revokedAt = enabled ? nil : (grants[index].revokedAt ?? date)
        return true
    }

    /// Atomic replace with sorted keys, so the owner can diff it and running helpers see one
    /// complete file (a new inode) on their next operation.
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

public enum AgentScopeError: Error, Equatable {
    case invalidProject
    case invalidPath(String)
    case outsideRead(String)
    case outsideCreate(String)
    case excluded(String)

    /// Sentence case, curly quotes, display paths; never echoes document text.
    public var message: String {
        let display = { (path: String) in "“\(AgentMemoryContract.displayPath(path))”" }
        switch self {
        case .invalidProject: return "The project name isn’t a valid folder name."
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
        project = grant.project
        self.caseSensitive = caseSensitive
        let root = AgentMemoryContract.projectRoot(project)
        var reads = [root]
        for folder in grant.extraReadFolders {
            let normalized = try Self.normalize(folder)
            if !reads.contains(where: { Self.contains($0, normalized, caseSensitive: caseSensitive) }) {
                reads.append(normalized)
            }
        }
        readRoots = reads
        createRoots =
            createAllowed && grant.access == .readCreate
            ? AgentMemoryContract.entryFolders.map { root + "/" + $0 } : []
    }

    private init(project: String, readRoots: [String], createRoots: [String], caseSensitive: Bool) {
        self.project = project
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
            project: project, readRoots: intersect(readRoots), createRoots: intersect(createRoots),
            caseSensitive: caseSensitive)
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

/// The `silkweb memory …` commands: resolve a grant with Silkweb closed, report scope, list,
/// search and read documents (#134), and create documents and Folders (#133). Only creates write
/// to the Library; nothing writes the grants file. Search keeps its own index cache outside the
/// Library (`AgentMemoryService`).
public enum AgentHelper {
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static let usage = """
        Usage: silkweb memory capabilities --project <Project> [--grants <file>]
               silkweb memory list --project <Project> [--grants <file>]
               silkweb memory search --project <Project> [--query <text>] [--type <t,…>] [--status <s,…>]
                   [--created-after <date>] [--created-before <date>] [--filter-project <Project>]
                   [--limit <n>] [--grants <file>]
               silkweb memory read --project <Project> --path <path> [--cursor <cursor>]
                   [--expected-revision <sha256:…>] [--grants <file>]
               silkweb memory create --project <Project> --key <key> --type <type> --title <title>
                   --agent <agent> --session <session> --body-file <file|-> [--folder <path>]
                   [--status <status>] [--observed-at <time>] [--review-after <time>]
                   [--supersedes <memory_id>]... [--client <name>] [--grants <file>]
               silkweb memory create-folder --project <Project> --path <path> [--grants <file>]
               silkweb version

        """

    /// Options each command accepts. `--supersedes` may repeat; every other option appears once.
    private static let commandOptions: [String: (required: Set<String>, optional: Set<String>)] = [
        "capabilities": (["--project"], ["--grants"]),
        "list": (["--project"], ["--grants"]),
        "search": (
            ["--project"],
            [
                "--grants", "--query", "--type", "--status", "--created-after", "--created-before",
                "--filter-project", "--limit",
            ]
        ),
        "read": (["--project", "--path"], ["--grants", "--cursor", "--expected-revision"]),
        "create": (
            ["--project", "--key", "--type", "--title", "--agent", "--session", "--body-file"],
            [
                "--grants", "--folder", "--status", "--observed-at", "--review-after", "--supersedes", "--client",
            ]
        ),
        "create-folder": (["--project", "--path"], ["--grants"]),
    ]

    public static func run(
        _ arguments: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser,
        standardInput: FileHandle = .standardInput
    ) -> Output {
        if arguments == ["version"] {
            return emit(["contract_version": AgentMemoryContract.version, "helper_version": SilkwebCore.version])
        }
        guard arguments.count >= 2, arguments[0] == "memory", let allowed = commandOptions[arguments[1]],
            let options = options(Array(arguments.dropFirst(2)), allowed: allowed),
            let project = options["--project"]?.first
        else { return Output(status: 64, stdout: "", stderr: usage) }
        let grantsURL =
            options["--grants"]?.first.map { URL(fileURLWithPath: $0) } ?? AgentGrantFile.defaultURL(home: home)
        let session = AgentSession(project: project, store: AgentGrantStore(url: grantsURL))
        do {
            switch arguments[1] {
            case "search", "read":
                let service = AgentMemoryService(
                    session: session, cacheDirectory: AgentMemoryService.defaultCacheDirectory(home: home))
                let json =
                    arguments[1] == "search"
                    ? try service.search(searchRequest(options)).json
                    : try service.read(
                        AgentMemoryReadRequest(
                            path: options["--path"]?.first ?? "", cursor: options["--cursor"]?.first,
                            expectedRevision: options["--expected-revision"]?.first)
                    ).json
                return Output(status: 0, stdout: json.rendered, stderr: "")
            case "create":
                return try create(session.authorize(.create), options: options, standardInput: standardInput)
            case "create-folder":
                let authorization = try session.authorize(.createFolder, path: options["--path"]?.first)
                let folder = try AgentCreateService(authorization: authorization).createFolder(authorization.path ?? "")
                return emit(["path": folder.path, "created": folder.created])
            case "list":
                return try list(session.authorize(.list))
            default:
                return capabilities(try session.authorize(.capabilities))
            }
        } catch let failure as AgentAccessError {
            return refusal(failure)
        } catch let gate as LibraryGateError {
            return refusal(AgentAccessError(gate))
        } catch {
            return Output(status: 1, stdout: "", stderr: "\(error)\n")
        }
    }

    static func refusal(_ failure: AgentAccessError) -> Output {
        var error: [String: Any] = ["code": failure.code, "title": failure.title]
        if let seconds = failure.retryAfter { error["retry_after"] = seconds }
        return Output(status: 1, stdout: json(["error": error]), stderr: failure.title + ": " + failure.message + "\n")
    }

    static func capabilities(_ context: AgentAuthorization) -> Output {
        let root = AgentMemoryContract.projectRoot(context.scope.project)
        let descriptor = try? AgentSecureFiles.openFolder(library: context.library, path: root)
        if let descriptor { close(descriptor) }
        let limits = context.grant.limits
        return emit([
            "contract_version": AgentMemoryContract.version,
            "helper_version": SilkwebCore.version,
            "project": context.scope.project,
            "library": context.library.path,
            "filesystem": context.filesystem.rawValue,
            "access": context.grant.access.rawValue,
            "operations": ["capabilities", "list", "search", "read"]
                + (context.scope.createRoots.isEmpty ? [] : ["create", "create-folder"]),
            "read_roots": context.scope.readRoots,
            "create_roots": context.scope.createRoots,
            "project_folder_exists": descriptor != nil,
            "limits": [
                "max_read_bytes": limits.maxReadBytes, "max_results": limits.maxResults,
                "requests_per_minute": limits.requestsPerMinute, "max_create_bytes": limits.maxCreateBytes,
            ],
        ])
    }

    /// One create (#133). The body comes from `--body-file`, or stdin for `-`, read only up to the
    /// grant's limit. A replay of the same key and payload succeeds with `"replayed": true`.
    static func create(_ context: AgentAuthorization, options: [String: [String]], standardInput: FileHandle) throws
        -> Output
    {
        let value = { (option: String) in options[option]?.first }
        let limit = context.grant.limits.maxCreateBytes
        let source = value("--body-file") ?? "-"
        let handle = source == "-" ? standardInput : FileHandle(forReadingAtPath: source)
        guard let handle, let data = try? handle.read(upToCount: limit + 1) ?? Data() else {
            throw AgentAccessError.invalidRequest("The document text couldn’t be read.")
        }
        guard data.count <= limit else { throw AgentAccessError.createTooLarge(limit: limit) }
        guard let body = String(data: data, encoding: .utf8) else {
            throw AgentAccessError.invalidRequest("The document text must be UTF-8.")
        }
        let request = AgentCreateRequest(
            idempotencyKey: value("--key") ?? "", type: value("--type") ?? "", title: value("--title") ?? "",
            body: body, agent: value("--agent") ?? "", session: value("--session") ?? "",
            client: value("--client") ?? "cli", folder: value("--folder"), status: value("--status"),
            observedAt: value("--observed-at"), reviewAfter: value("--review-after"),
            supersedes: options["--supersedes"])
        let service = AgentCreateService(authorization: context)
        // Interrupted creates from earlier sessions are settled first. Details go to stderr only.
        let settled = (try? service.reconcile()) ?? []
        let result = try service.create(request)
        let receipt = try JSONSerialization.jsonObject(with: AgentReceipt.encoded(result.receipt))
        var output = emit([
            "outcome": result.outcome.rawValue, "replayed": result.replayed, "path": result.path ?? NSNull(),
            "receipt": receipt,
        ])
        if !settled.isEmpty {
            let counts = Dictionary(grouping: settled, by: \.outcome.rawValue).map { "\($0.value.count) \($0.key)" }
            output.stderr = "Recovered interrupted creates: " + counts.sorted().joined(separator: ", ") + ".\n"
        }
        return output
    }

    /// Paths, sizes and dates only — no document bodies. Hidden items, links and special files are
    /// skipped, and a read folder reached through a link is skipped entirely.
    static func list(_ context: AgentAuthorization) throws -> Output {
        let dates = ISO8601DateFormatter()
        var documents: [AgentSecureFiles.Document] = []
        for root in context.scope.readRoots {
            do {
                documents += try AgentSecureFiles.documents(library: context.library, under: root)
            } catch let error as AgentAccessError where error == .invalidPath {
                continue
            }
        }
        let rows = context.scope.readable(documents, path: \.path).sorted { $0.path < $1.path }.map {
            ["path": $0.path, "size": $0.size, "modified": dates.string(from: $0.modified)] as [String: Any]
        }
        return emit(["project": context.scope.project, "documents": rows])
    }

    /// `--type`/`--status` take comma-separated lists; dates are `2026-10-07` or ISO 8601 timestamps.
    static func searchRequest(_ options: [String: [String]]) throws -> AgentMemorySearchRequest {
        let value = { (option: String) in options[option]?.first }
        let list = { (key: String) -> [String] in
            (value(key) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        let date = { (key: String) throws -> Date? in
            guard let text = value(key) else { return nil }
            guard let date = AgentMemorySearchRequest.date(text) else {
                throw AgentAccessError.invalidArgument(String(key.dropFirst(2)))
            }
            return date
        }
        var limit = AgentMemorySearchRequest.defaultLimit
        if let text = value("--limit") {
            guard let parsed = Int(text) else { throw AgentAccessError.invalidArgument("limit") }
            limit = parsed
        }
        return AgentMemorySearchRequest(
            query: value("--query") ?? "", project: value("--filter-project"), types: list("--type"),
            statuses: list("--status"), createdAfter: try date("--created-after"),
            createdBefore: try date("--created-before"), limit: limit)
    }

    private static func options(_ arguments: [String], allowed: (required: Set<String>, optional: Set<String>))
        -> [String: [String]]?
    {
        guard arguments.count.isMultiple(of: 2) else { return nil }
        var result: [String: [String]] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let option = arguments[index]
            guard allowed.required.contains(option) || allowed.optional.contains(option),
                result[option] == nil || option == "--supersedes"
            else { return nil }
            result[option, default: []].append(arguments[index + 1])
        }
        return allowed.required.isSubset(of: result.keys) ? result : nil
    }

    private static func emit(_ object: [String: Any]) -> Output {
        Output(status: 0, stdout: json(object), stderr: "")
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return (data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}") + "\n"
    }
}

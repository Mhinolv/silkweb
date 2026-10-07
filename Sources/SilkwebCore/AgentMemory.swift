import Foundation

/// The v2 agent-memory contract (`docs/agent-memory.md`). This spike covers the grants file, scope
/// rules, filesystem qualification and read-only helper commands; creates arrive with #135/#136.
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
    public enum Access: String, Codable, Sendable {
        case read
        case readCreate = "read-create"
    }

    public var project: String
    public var library: LibraryLocation
    public var access: Access
    /// Optional extra read-only folders, relative to the Library.
    public var extraReadFolders: [String]

    public init(
        project: String, library: LibraryLocation, access: Access = .readCreate, extraReadFolders: [String] = []
    ) {
        self.project = project
        self.library = library
        self.access = access
        self.extraReadFolders = extraReadFolders
    }

    private enum CodingKeys: String, CodingKey {
        case project, library, access
        case extraReadFolders = "extra_read_folders"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        project = try values.decodeIfPresent(String.self, forKey: .project) ?? ""
        library = try values.decodeIfPresent(LibraryLocation.self, forKey: .library) ?? LibraryLocation()
        // An unknown access level from a newer build falls back to the narrower profile.
        access = (try? values.decodeIfPresent(Access.self, forKey: .access)) ?? .read
        extraReadFolders = try values.decodeIfPresent([String].self, forKey: .extraReadFolders) ?? []
    }
}

/// `~/Library/Application Support/Silkweb/agent-grants.json`, versioned and decoded tolerantly.
public struct AgentGrantFile: Codable, Equatable, Sendable {
    public var version = 1
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
/// Callers that touch disk must still reject symbolic links on the way (see #131).
public struct AgentScope: Equatable, Sendable {
    public let project: String
    public let readRoots: [String]
    public let createRoots: [String]

    /// `createAllowed` is false for read-only grants and for unqualified filesystems.
    public init(grant: AgentGrant, createAllowed: Bool = true) throws {
        guard (try? LibraryMutations.validateName(grant.project)) == grant.project else {
            throw AgentScopeError.invalidProject
        }
        project = grant.project
        let root = AgentMemoryContract.projectRoot(project)
        var reads = [root]
        for folder in grant.extraReadFolders {
            let normalized = try Self.normalize(folder)
            if !reads.contains(where: { Self.contains($0, normalized) }) { reads.append(normalized) }
        }
        readRoots = reads
        createRoots =
            createAllowed && grant.access == .readCreate
            ? AgentMemoryContract.entryFolders.map { root + "/" + $0 } : []
    }

    public func checkRead(_ path: String) throws -> String {
        let normalized = try Self.normalize(path)
        guard readRoots.contains(where: { Self.contains($0, normalized) }) else {
            throw AgentScopeError.outsideRead(normalized)
        }
        return normalized
    }

    /// A new Markdown document inside one of the create folders, never an instruction file.
    public func checkCreate(_ path: String) throws -> String {
        let normalized = try Self.normalize(path)
        guard
            createRoots.contains(where: { $0.lowercased() != normalized.lowercased() && Self.contains($0, normalized) })
        else { throw AgentScopeError.outsideCreate(normalized) }
        let name = (normalized as NSString).lastPathComponent.lowercased()
        let components = normalized.lowercased().split(separator: "/").map(String.init)
        if AgentMemoryContract.instructionFiles.contains(name) || (name as NSString).pathExtension != "md"
            || components.contains(where: AgentMemoryContract.reservedFolders.contains)
        {
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

    /// Case-insensitive like the default APFS volume, so `memory/projects` can't sidestep a root.
    static func contains(_ root: String, _ path: String) -> Bool {
        let root = root.lowercased()
        let path = path.lowercased()
        return path == root || path.hasPrefix(root + "/")
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

/// The spike's `silkweb memory …` commands: resolve a grant with Silkweb closed and report scope
/// or list documents. Read-only: it never writes to the Library or the grants file.
public enum AgentHelper {
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static let usage = """
        Usage: silkweb memory capabilities --project <Project> [--grants <file>]
               silkweb memory list --project <Project> [--grants <file>]
               silkweb version

        """

    public static func run(_ arguments: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> Output
    {
        if arguments == ["version"] {
            return emit(["contract_version": AgentMemoryContract.version, "helper_version": SilkwebCore.version])
        }
        guard arguments.count >= 2, arguments[0] == "memory", ["capabilities", "list"].contains(arguments[1]),
            let options = options(Array(arguments.dropFirst(2))), let project = options["--project"]
        else { return Output(status: 64, stdout: "", stderr: usage) }
        let grantsURL = options["--grants"].map { URL(fileURLWithPath: $0) } ?? AgentGrantFile.defaultURL(home: home)
        do {
            let context = try resolve(project: project, grantsURL: grantsURL)
            return arguments[1] == "list" ? list(context) : capabilities(context)
        } catch let failure as Failure {
            return Output(
                status: 1, stdout: json(["error": ["code": failure.code, "title": failure.title]]),
                stderr: failure.title + ": " + failure.message + "\n")
        } catch {
            return Output(status: 1, stdout: "", stderr: "\(error)\n")
        }
    }

    struct Failure: Error {
        let code: String
        let title: String
        let message: String
    }

    struct Context {
        let library: URL
        let filesystem: AgentFilesystem
        let grant: AgentGrant
        let scope: AgentScope
    }

    static func resolve(project: String, grantsURL: URL) throws -> Context {
        let file: AgentGrantFile
        do {
            file = try JSONDecoder().decode(AgentGrantFile.self, from: Data(contentsOf: grantsURL))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
        {
            throw Failure(
                code: "no_grants_file", title: "No Agent Access",
                message: "There’s no grants file at “\(grantsURL.path)”.")
        } catch {
            throw Failure(
                code: "invalid_grants_file", title: "No Agent Access",
                message: "The grants file at “\(grantsURL.path)” can’t be read.")
        }
        guard file.version <= 1 else {
            throw Failure(
                code: "unsupported_grants_version", title: "No Agent Access",
                message: "The grants file was saved by a newer version of Silkweb.")
        }
        guard let grant = file.grant(for: project) else {
            throw Failure(
                code: "no_grant", title: "No Agent Access", message: "There’s no grant for the project “\(project)”.")
        }
        let library: URL
        do {
            // Same restore path the app uses; the refreshed location is ignored (the helper is read-only).
            guard let resolved = try LibraryLocationRestore.restore(grant.library) else {
                throw LibraryLocationError.notFound
            }
            library = resolved.url
        } catch let error as LibraryLocationError {
            let name = grant.library.path.map { ($0 as NSString).lastPathComponent } ?? "Library"
            throw Failure(
                code: error == .notFound ? "library_not_found" : "library_unreadable", title: error.title,
                message: error == .notFound
                    ? "The Library “\(name)” can’t be found." : "The Library “\(name)” can’t be read.")
        }
        let filesystem = AgentFilesystem.probe(library)
        do {
            let scope = try AgentScope(grant: grant, createAllowed: filesystem == .qualified)
            return Context(library: library, filesystem: filesystem, grant: grant, scope: scope)
        } catch let error as AgentScopeError {
            throw Failure(code: "invalid_grant", title: "No Agent Access", message: error.message)
        }
    }

    static func capabilities(_ context: Context) -> Output {
        let root = AgentMemoryContract.projectRoot(context.scope.project)
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: context.library.appendingPathComponent(root).path, isDirectory: &isFolder)
        return emit([
            "contract_version": AgentMemoryContract.version,
            "helper_version": SilkwebCore.version,
            "project": context.scope.project,
            "library": context.library.path,
            "filesystem": context.filesystem.rawValue,
            "access": context.grant.access.rawValue,
            "operations": ["capabilities", "list"],
            "read_roots": context.scope.readRoots,
            "create_roots": context.scope.createRoots,
            "project_folder_exists": exists && isFolder.boolValue,
        ])
    }

    /// Paths, sizes and dates only — no document bodies. Hidden items and symbolic links are skipped.
    static func list(_ context: Context) -> Output {
        var documents: [[String: Any]] = []
        let dates = ISO8601DateFormatter()
        for root in context.scope.readRoots {
            let base = context.library.appendingPathComponent(root)
            guard (try? base.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                let walker = FileManager.default.enumerator(atPath: base.path)
            else { continue }
            while let relative = walker.nextObject() as? String {
                let type = walker.fileAttributes?[.type] as? FileAttributeType
                let path = root + "/" + relative
                if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) || type == .typeSymbolicLink {
                    if type == .typeDirectory { walker.skipDescendants() }
                    continue
                }
                guard type == .typeRegular, (relative as NSString).pathExtension.lowercased() == "md",
                    (try? context.scope.checkRead(path)) != nil
                else { continue }
                let modified = walker.fileAttributes?[.modificationDate] as? Date
                documents.append([
                    "path": path,
                    "size": (walker.fileAttributes?[.size] as? NSNumber)?.intValue ?? 0,
                    "modified": modified.map(dates.string(from:)) ?? "",
                ])
            }
        }
        documents.sort { ($0["path"] as? String ?? "") < ($1["path"] as? String ?? "") }
        return emit(["project": context.scope.project, "documents": documents])
    }

    private static func options(_ arguments: [String]) -> [String: String]? {
        guard arguments.count.isMultiple(of: 2) else { return nil }
        var result: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            guard ["--project", "--grants"].contains(arguments[index]), result[arguments[index]] == nil else {
                return nil
            }
            result[arguments[index]] = arguments[index + 1]
        }
        return result
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

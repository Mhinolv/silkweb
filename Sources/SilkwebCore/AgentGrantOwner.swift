import Foundation

/// #229: the owner's changes to `agent-grants.json` from the app's Agent Access window. Unlike `grant init` and
/// approval (#186, #203), this path may widen a grant, so every widening needs `authenticated` (Touch ID or the account
/// password, checked by the app first). Narrowing, pausing, label edits and removal don't. Only the app calls this:
/// the helper CLI and MCP never do, so agents still can't widen their own access.
///
/// Every change rereads the file, refuses when the grant it started from changed on disk meanwhile, and replaces the
/// file atomically (`AgentGrantFile.write`), so running helpers see one whole file on their next operation.
public enum AgentGrantOwner {
    /// One way a change gives agents more than before. Any of these needs owner authentication.
    public enum Widening: Equatable, Sendable {
        case newGrant
        case access(from: AgentGrant.Access, to: AgentGrant.Access)
        case readFolders([String])
        case agentFolder(String)
        case createFolders([String])
        case library
        case limits
        case resume
    }

    /// Why a change couldn't be saved. `title` and `message` are owner-facing copy.
    public struct Failure: Error, Equatable, Sendable {
        public var code: String
        public var title: String
        public var message: String

        static let saveTitle = "Can’t Save This Grant"

        static func invalid(_ message: String) -> Failure {
            Failure(code: "invalid_grant", title: saveTitle, message: message)
        }

        public static let needsAuthentication = Failure(
            code: "needs_authentication", title: saveTitle,
            message: "This change gives agents more access, so it needs your Touch ID or password. Nothing was saved.")

        static func changedOutside(_ project: String) -> Failure {
            Failure(
                code: "grant_changed", title: saveTitle,
                message: "The grant “\(project)” was changed outside Silkweb. Reload it, then make your change again.")
        }

        static func notFound(_ project: String) -> Failure {
            Failure(code: "grant_not_found", title: saveTitle, message: "The grant “\(project)” no longer exists.")
        }

        static func exists(_ project: String) -> Failure {
            Failure(code: "grant_exists", title: saveTitle, message: existsMessage(project))
        }

        static let writeFailed = Failure(
            code: "write_failed", title: saveTitle,
            message: "Silkweb couldn’t save “agent-grants.json”. Nothing was saved.")
    }

    /// “A grant for “Silkweb” already exists.”
    public static func existsMessage(_ project: String) -> String { "A grant for “\(project)” already exists." }

    public static let invalidProjectMessage = AgentGrantInit.invalidProjectMessage
    public static let invalidAgentFolderMessage = AgentGrantInit.invalidAgentFolderMessage
    public static let notLocalWarning = AgentGrantInit.notLocalWarning

    /// A project key as `grant init` accepts it (one Folder name, NFC), or nil.
    public static func validProject(_ text: String) -> String? { AgentGrantInit.validProject(text) }

    // MARK: Reading

    /// The grants file, or an empty one when there's none yet. A broken or newer file throws `AgentAccessError`.
    public static func load(_ url: URL) throws -> AgentGrantFile {
        do {
            return try AgentGrantStore(url: url).load()
        } catch let error as AgentAccessError where error.code == "no_grants_file" {
            return AgentGrantFile()
        }
    }

    // MARK: Classifying

    /// What `edited` gives agents beyond `original` (nil for a new grant). Empty means the change only narrows, pauses
    /// or relabels, and saves without authentication.
    public static func widenings(from original: AgentGrant?, to edited: AgentGrant) -> [Widening] {
        guard let original else { return [.newGrant] }
        var found: [Widening] = []
        if !sameLibrary(original.library, edited.library) { found.append(.library) }
        if edited.access.rank > original.access.rank { found.append(.access(from: original.access, to: edited.access)) }
        var readable =
            [AgentMemoryContract.projectRoot(original.project)] + original.extraReadFolders
            + original.createFolders
        if let key = original.agentFolder { readable.append(AgentMemoryContract.agentRoot(key)) }
        let addedReads = edited.extraReadFolders.filter { folder in
            !readable.contains { AgentScope.contains($0, folder, caseSensitive: true) }
        }
        if !addedReads.isEmpty { found.append(.readFolders(addedReads)) }
        if let key = edited.agentFolder, key != original.agentFolder { found.append(.agentFolder(key)) }
        let addedCreates = edited.createFolders.filter { folder in
            !original.createFolders.contains { AgentScope.contains($0, folder, caseSensitive: true) }
        }
        if !addedCreates.isEmpty { found.append(.createFolders(addedCreates)) }
        if edited.limits != original.limits { found.append(.limits) }
        if original.isRevoked && !edited.isRevoked { found.append(.resume) }
        return found
    }

    private static func sameLibrary(_ lhs: LibraryLocation, _ rhs: LibraryLocation) -> Bool {
        if lhs == rhs { return true }
        guard let path = rhs.path, !path.isEmpty else { return false }
        return AgentGrantInit.sameLibrary(lhs, URL(fileURLWithPath: path))
    }

    // MARK: Validating

    /// A new grant from the New Grant sheet, checked like `grant init`: the Library must be a readable folder (links
    /// resolved), the project key a valid Folder name and the agent folder, when given, too. The filesystem tells the
    /// caller whether to warn that creating stays off.
    public static func newGrant(
        library path: String, project: String, label: String = "", access: AgentGrant.Access,
        agentFolder: String? = nil, now: Date = Date()
    ) throws -> (grant: AgentGrant, filesystem: AgentFilesystem) {
        let library: AgentGrantInit.Library
        do {
            library = try AgentGrantInit.resolveLibrary(path, from: "/")
        } catch let failure as AgentGrantInit.Failure {
            throw Failure.invalid(failure.message)
        }
        guard let key = validProject(project) else { throw Failure.invalid(invalidProjectMessage) }
        let created = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        let grant = AgentGrant(
            project: key, library: LibraryLocation(path: library.url.path), access: access,
            label: AgentAccessRequests.oneLine(label), createdAt: created,
            agentFolder: try validAgentFolder(agentFolder))
        return (grant, library.filesystem)
    }

    /// Nil for no agent folder (nil or blank), else the valid key.
    public static func validAgentFolder(_ text: String?) throws -> String? {
        guard let text, !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        guard let key = validProject(text.trimmingCharacters(in: .whitespaces)) else {
            throw Failure.invalid(invalidAgentFolderMessage)
        }
        return key
    }

    /// The Library-relative read folder for `folder`, chosen in an open panel: inside `library`, never the Library
    /// itself, and valid as a grant path. Throws `AgentScopeError.invalidPath` with `grant init`'s copy otherwise.
    public static func readFolder(_ folder: URL, library: URL) throws -> String {
        let canonical = { (url: URL) in url.standardizedFileURL.resolvingSymlinksInPath().path }
        let root = canonical(library)
        let path = canonical(folder)
        guard path.hasPrefix(root + "/") else { throw AgentScopeError.invalidPath(folder.path) }
        return try AgentScope.normalize(AgentHelper.nfc(String(path.dropFirst(root.count + 1))))
    }

    /// Read folders as the grant stores them: the project's own Folder and folders inside another count once.
    public static func addingReadFolder(_ folder: String, to grant: AgentGrant) -> [String] {
        let inside = { (root: String) in AgentScope.contains(root, folder, caseSensitive: true) }
        if inside(AgentMemoryContract.projectRoot(grant.project)) || grant.extraReadFolders.contains(where: inside) {
            return grant.extraReadFolders
        }
        return grant.extraReadFolders.filter { !AgentScope.contains(folder, $0, caseSensitive: true) } + [folder]
    }

    /// The edited grant normalized for saving, or why it can't be saved.
    static func validated(_ grant: AgentGrant) throws -> AgentGrant {
        var grant = grant
        guard validProject(grant.project) == grant.project else { throw Failure.invalid(invalidProjectMessage) }
        grant.agentFolder = try validAgentFolder(grant.agentFolder)
        grant.label = AgentAccessRequests.oneLine(grant.label)
        do {
            grant.extraReadFolders = try grant.extraReadFolders.map { try AgentScope.normalize(AgentHelper.nfc($0)) }
        } catch let error as AgentScopeError {
            throw Failure.invalid(error.message)
        }
        grant.createFolders = try AgentGrantInit.validCreateFolders(grant.createFolders) { Failure.invalid($0) }
        if !grant.createFolders.isEmpty, !grant.access.allowsCreate {
            throw Failure.invalid("Create folders need Read and Create or Read, Create and Update access.")
        }
        return grant
    }

    // MARK: Saving

    /// Saves `grant` over `original` (the grant as the editor loaded it), or adds it when `original` is nil. Refuses a
    /// widening without `authenticated`, a grant changed or removed on disk since `original`, and a new grant whose
    /// key exists. Other grants are kept as they are. Returns the saved grant.
    @discardableResult
    public static func save(
        _ grant: AgentGrant, replacing original: AgentGrant?, in url: URL, authenticated: Bool
    ) throws -> AgentGrant {
        let grant = try validated(grant)
        if !widenings(from: original, to: grant).isEmpty, !authenticated { throw Failure.needsAuthentication }
        var file = try load(url)
        let index = file.grants.firstIndex { $0.project == grant.project }
        if let original {
            guard original.project == grant.project else { throw Failure.invalid(invalidProjectMessage) }
            guard let index else { throw Failure.notFound(grant.project) }
            guard file.grants[index] == original else { throw Failure.changedOutside(grant.project) }
            file.grants[index] = grant
        } else {
            guard index == nil else { throw Failure.exists(grant.project) }
            file.grants.append(grant)
        }
        try write(file, to: url)
        return grant
    }

    /// Pause (`revoked_at`, keeping the first date) or Resume. Resuming widens, so it needs `authenticated`.
    @discardableResult
    public static func setPaused(_ paused: Bool, project: String, in url: URL, authenticated: Bool, now: Date = Date())
        throws -> AgentGrant
    {
        var file = try load(url)
        guard let index = file.grants.firstIndex(where: { $0.project == project }) else {
            throw Failure.notFound(project)
        }
        if !paused, file.grants[index].isRevoked, !authenticated { throw Failure.needsAuthentication }
        let before = file.grants[index]
        // Whole seconds, as the file stores them.
        file.setEnabled(
            !paused, project: project, at: Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down)))
        if file.grants[index] != before { try write(file, to: url) }
        return file.grants[index]
    }

    /// Remove Grant…: deletes the row. Agents using it stop at their next operation; no Document changes.
    public static func remove(project: String, in url: URL) throws {
        var file = try load(url)
        guard file.grants.contains(where: { $0.project == project }) else { throw Failure.notFound(project) }
        file.grants.removeAll { $0.project == project }
        try write(file, to: url)
    }

    private static func write(_ file: AgentGrantFile, to url: URL) throws {
        var file = file
        file.version = AgentGrantFile.currentVersion
        do {
            try file.write(to: url)
        } catch {
            throw Failure.writeFailed
        }
    }

    // MARK: Presentation

    /// The folders agents may create in, as the helper computes them (the entry folders, the agent folder's
    /// `Memories` and #228 create folders). Empty for Read Only.
    public static func createFolders(_ grant: AgentGrant) -> [String] {
        (try? AgentScope(grant: grant))?.createRoots ?? []
    }

    /// The `grant init` install lines and write-protect rules for one grant, for Client setup.
    public static func installBlock(project: String, library: String?, helper: String?) -> String {
        AgentGrantInit.installBlock(helper: helper, project: project, library: library)
    }

    /// `~/.local/bin/silkweb` when it's installed, else nil (the install lines then say to replace the placeholder).
    public static func installedHelper(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let path = home.appendingPathComponent(".local/bin/silkweb").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
}

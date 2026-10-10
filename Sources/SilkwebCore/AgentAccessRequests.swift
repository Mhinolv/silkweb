import Darwin
import Foundation

/// One agent's request for access (#203, `docs/agent-memory.md` › Access requests). Requests and their
/// history live in one file outside every Library; only the owner turns one into a grant.
public struct AgentAccessRequest: Codable, Equatable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case pending, approved, denied, expired
    }

    /// Where the owner decided.
    public enum Via: String, Codable, Sendable {
        case app, terminal

        /// “in Silkweb” / “in Terminal”.
        public var displayName: String { self == .app ? "Silkweb" : "Terminal" }
    }

    public var requestId: String
    /// The Library folder, resolved as `grant init` stores it.
    public var libraryRoot: String
    public var project: String
    public var profile: AgentGrant.Access
    /// Extra read folders, Library-relative POSIX paths.
    public var readFolders: [String]
    /// #228: create folders (`create_folders`), Library-relative POSIX paths. Only with a create profile.
    public var createFolders: [String]
    /// One line from the agent, at most 280 characters. Shown to the owner as the agent's words.
    public var message: String
    /// Claims, not verified.
    public var agent: String
    public var session: String
    public var client: String
    public var requestedAt: Date
    public var expiresAt: Date
    /// As saved. A pending request past `expiresAt` reads as expired; see `status(at:)`.
    public var status: Status
    public var decidedAt: Date?
    public var decidedVia: Via?
    public var ownerNote: String

    public var id: String { requestId }

    public init(
        requestId: String, libraryRoot: String, project: String, profile: AgentGrant.Access,
        readFolders: [String] = [], message: String = "", agent: String = "", session: String = "",
        client: String = "", requestedAt: Date, expiresAt: Date, status: Status = .pending, decidedAt: Date? = nil,
        decidedVia: Via? = nil, ownerNote: String = "", createFolders: [String] = []
    ) {
        self.requestId = requestId
        self.libraryRoot = libraryRoot
        self.project = project
        self.profile = profile
        self.readFolders = readFolders
        self.createFolders = createFolders
        self.message = message
        self.agent = agent
        self.session = session
        self.client = client
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.status = status
        self.decidedAt = decidedAt
        self.decidedVia = decidedVia
        self.ownerNote = ownerNote
    }

    /// Expiry is computed on read: a pending request past its date is expired and can't be approved.
    public func status(at now: Date) -> Status { status == .pending && expiresAt <= now ? .expired : status }

    public func isPending(at now: Date) -> Bool { status(at: now) == .pending }

    /// When it was decided, or for an expired request, when it expired. History sorts by this.
    public func closedAt(_ now: Date) -> Date? {
        switch status(at: now) {
        case .pending: return nil
        case .expired: return decidedAt ?? expiresAt
        default: return decidedAt
        }
    }

    // MARK: Presentation

    /// The claimed agent, or “Unknown agent”.
    public var agentName: String { AgentActivity.displayName(agent) }

    /// “Memory › Projects › Silkweb + 2 read folders: Notes › Swift, Specs · Create in: Memory › Projects › Silkweb”.
    public var folderSummary: String {
        var summary = AgentMemoryContract.displayPath(AgentMemoryContract.projectRoot(project))
        if !readFolders.isEmpty {
            let count = readFolders.count == 1 ? "1 read folder" : "\(readFolders.count) read folders"
            summary += " + \(count): " + readFolders.map(AgentMemoryContract.displayPath).joined(separator: ", ")
        }
        if !createFolders.isEmpty { summary += " · " + createSummary }
        return summary
    }

    /// #228: “Create in: Memory › Projects › Silkweb, Notes › Swift”.
    public var createSummary: String {
        "Create in: " + createFolders.map(AgentMemoryContract.displayPath).joined(separator: ", ")
    }

    /// “claude-code wants Read and Create for “Silkweb””.
    public var headline: String { "\(agentName) wants \(profile.displayName) for “\(project)”" }

    /// “expires in 30 days”, “expires tomorrow”, “expires today”.
    public func expiryLabel(_ now: Date) -> String {
        let days = Int((expiresAt.timeIntervalSince(now) / 86_400).rounded(.down))
        switch days {
        case ..<1: return "expires today"
        case 1: return "expires tomorrow"
        default: return "expires in \(days) days"
        }
    }

    /// “Approved · Oct 9 · in Silkweb”, “Denied · Oct 9 · in Terminal — note”, “Expired · Sep 8”.
    public func historyLabel(_ now: Date) -> String {
        let status = status(at: now)
        let date = closedAt(now).map { " · " + AgentAccessRequests.shortDate($0) } ?? ""
        switch status {
        case .pending: return "Waiting"
        case .expired: return "Expired" + date
        case .approved, .denied:
            var label = (status == .approved ? "Approved" : "Denied") + date
            if let via = decidedVia { label += " · in " + via.displayName }
            if !ownerNote.isEmpty { label += " — " + ownerNote }
            return label
        }
    }

    /// One VoiceOver element per row: “claude-code wants Read and Create for Silkweb, 3 folders, expires in 30 days”.
    public func accessibilityLabel(_ now: Date) -> String {
        let folders = readFolders.count + 1
        var summary =
            "\(agentName) wants \(profile.displayName) for \(project), \(folders) \(folders == 1 ? "folder" : "folders")"
        if !createFolders.isEmpty {
            summary += ", \(createFolders.count) create \(createFolders.count == 1 ? "folder" : "folders")"
        }
        return summary + ", " + (isPending(at: now) ? expiryLabel(now) : historyLabel(now))
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case requestId, libraryRoot, project, profile, readFolders, createFolders, message, agent, session, client
        case requestedAt, expiresAt, status, decidedAt, decidedVia, ownerNote
    }

    /// Tolerant: missing keys get defaults, an unknown status or profile from a newer build reads as the safer one
    /// (expired, Read Only), so nothing unknown is ever approvable or wider than asked.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let text = { (key: CodingKeys) in (try? values.decodeIfPresent(String.self, forKey: key)).flatMap { $0 } }
        let date = { (key: CodingKeys) in text(key).flatMap(AgentAccessRequests.date) }
        requestId = text(.requestId) ?? ""
        libraryRoot = text(.libraryRoot) ?? ""
        project = text(.project) ?? ""
        profile = (try? values.decodeIfPresent(AgentGrant.Access.self, forKey: .profile)).flatMap { $0 } ?? .read
        readFolders = (try? values.decodeIfPresent([String].self, forKey: .readFolders)).flatMap { $0 } ?? []
        createFolders = (try? values.decodeIfPresent([String].self, forKey: .createFolders)).flatMap { $0 } ?? []
        message = text(.message) ?? ""
        agent = text(.agent) ?? ""
        session = text(.session) ?? ""
        client = text(.client) ?? ""
        requestedAt = date(.requestedAt) ?? .distantPast
        expiresAt = date(.expiresAt) ?? requestedAt.addingTimeInterval(AgentAccessRequests.timeToLive)
        status = text(.status).map { Status(rawValue: $0) ?? .expired } ?? .pending
        decidedAt = date(.decidedAt)
        decidedVia = text(.decidedVia).flatMap(Via.init(rawValue:))
        ownerNote = text(.ownerNote) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestId, forKey: .requestId)
        try values.encode(libraryRoot, forKey: .libraryRoot)
        try values.encode(project, forKey: .project)
        try values.encode(profile, forKey: .profile)
        try values.encode(readFolders, forKey: .readFolders)
        if !createFolders.isEmpty { try values.encode(createFolders, forKey: .createFolders) }
        try values.encode(message, forKey: .message)
        try values.encode(agent, forKey: .agent)
        try values.encode(session, forKey: .session)
        try values.encode(client, forKey: .client)
        try values.encode(AgentAccessRequests.string(requestedAt), forKey: .requestedAt)
        try values.encode(AgentAccessRequests.string(expiresAt), forKey: .expiresAt)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(decidedAt.map(AgentAccessRequests.string), forKey: .decidedAt)
        try values.encodeIfPresent(decidedVia, forKey: .decidedVia)
        try values.encode(ownerNote, forKey: .ownerNote)
    }
}

/// `~/Library/Application Support/Silkweb/agent-access-requests.json`: pending requests and their history in one
/// versioned file. There is no second log.
public struct AgentAccessRequestFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = currentVersion
    public var requests: [AgentAccessRequest]

    public init(requests: [AgentAccessRequest] = []) { self.requests = requests }

    private enum CodingKeys: String, CodingKey { case version, requests }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? values.decodeIfPresent(Int.self, forKey: .version)).flatMap { $0 } ?? 1
        requests = try values.decodeIfPresent([AgentAccessRequest].self, forKey: .requests) ?? []
    }

    /// Pending first (oldest first), then history (newest first, at most `limit`). Only `libraryRoot`'s when given.
    public func review(library libraryRoot: String? = nil, now: Date, historyLimit: Int = .max) -> (
        waiting: [AgentAccessRequest], history: [AgentAccessRequest]
    ) {
        let mine = requests.filter { libraryRoot == nil || $0.libraryRoot == libraryRoot }
        let waiting = mine.filter { $0.isPending(at: now) }.sorted { $0.requestedAt < $1.requestedAt }
        let history = mine.filter { !$0.isPending(at: now) }.sorted {
            ($0.closedAt(now) ?? .distantPast) > ($1.closedAt(now) ?? .distantPast)
        }
        return (waiting, Array(history.prefix(historyLimit)))
    }
}

/// What an agent asks for, validated. Built by `AgentAccessRequests.draft`, shared by the CLI and MCP.
public struct AgentAccessRequestDraft: Equatable, Sendable {
    public var libraryRoot: String
    public var project: String
    public var profile: AgentGrant.Access
    public var readFolders: [String]
    /// #228: create folders, validated like `grant init --create-folder`.
    public var createFolders: [String] = []
    public var message: String
    public var agent: String
    public var session: String
    public var client: String

    /// The same request: Library, project, profile and folder sets. Message and claims don't count.
    func matches(_ request: AgentAccessRequest) -> Bool {
        request.libraryRoot == libraryRoot && request.project == project && request.profile == profile
            && Set(request.readFolders) == Set(readFolders) && Set(request.createFolders) == Set(createFolders)
    }
}

/// What an approval did, for the Terminal summary and the app.
public struct AgentAccessDecision: Sendable {
    public let request: AgentAccessRequest
    /// The saved grant and what happened to it; nil for a denial.
    public let grant: AgentGrant?
    public let outcome: AgentGrantInit.Outcome?
    public let filesystem: AgentFilesystem?
}

/// The request store and the rules both sides share (#203).
public enum AgentAccessRequests {
    /// 30 days (owner-confirmable TTL, PM Q3).
    public static let timeToLive: TimeInterval = 30 * 86_400
    public static let maxPendingPerLibrary = 5
    /// Across every Library, so a stream of made-up Library folders can't grow the file without bound.
    public static let maxPendingTotal = 50
    public static let maxReadFolders = 10
    public static let maxMessageLength = 280
    static let maxClaimLength = 100
    /// Decided and expired records kept; the oldest are dropped on the next write.
    public static let maxHistory = 200

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Silkweb/agent-access-requests.json")
    }

    /// `silkweb: Access request req_… is waiting for the owner. …`; never mentions approving.
    public static func waitingNote(_ requestId: String) -> String {
        "Access request \(requestId) is waiting for the owner. They can review it in Silkweb "
            + "(Agent Activity ▸ Access Requests) or Terminal."
    }

    // MARK: Validation

    /// Checks everything an agent sent. `library` is resolved like `grant init` (links, `~`, relative paths) and must
    /// be a readable folder. Folders are Library-relative and validated like grant paths; the message and claims are
    /// kept on one line with control characters removed.
    public static func draft(
        library: String, project: String, access: String, readFolders: [String], createFolders: [String] = [],
        message: String?, agent: String?, session: String?, client: String?,
        currentDirectory: String = FileManager.default.currentDirectoryPath
    ) throws -> AgentAccessRequestDraft {
        let resolved: AgentGrantInit.Library
        do {
            resolved = try AgentGrantInit.resolveLibrary(library, from: currentDirectory)
        } catch let failure as AgentGrantInit.Failure {
            throw failure == .folderMissing
                ? AgentAccessError(code: "library_not_found", title: "Library Not Found", message: failure.message)
                : AgentAccessError(code: "library_unreadable", title: "Can’t Read Library", message: failure.message)
        }
        guard let key = AgentGrantInit.validProject(project) else {
            throw AgentAccessError.invalidRequest(AgentGrantInit.invalidProjectMessage)
        }
        let profile: AgentGrant.Access
        switch access {
        case "read", "read-only": profile = .read
        case "read-create": profile = .readCreate
        default: throw AgentAccessError.invalidRequest("The access must be read or read-create.")
        }
        var folders: [String] = []
        for folder in readFolders {
            guard let normalized = try? AgentScope.normalize(AgentHelper.nfc(folder)) else {
                throw AgentAccessError.invalidRequest(
                    "Read folders must be Library-relative folders without “..”, hidden names or control characters.")
            }
            // The project's own Folder is always readable; repeats and folders inside another count once.
            let inside = { (root: String) in AgentScope.contains(root, normalized, caseSensitive: true) }
            if inside(AgentMemoryContract.projectRoot(key)) || folders.contains(where: inside) { continue }
            folders.removeAll { AgentScope.contains(normalized, $0, caseSensitive: true) }
            folders.append(normalized)
        }
        guard folders.count <= maxReadFolders else {
            throw AgentAccessError.invalidRequest("Ask for at most \(maxReadFolders) read folders.")
        }
        // #228: create folders follow `grant init --create-folder`'s rules and need a create profile.
        let creates = try AgentGrantInit.validCreateFolders(createFolders) { AgentAccessError.invalidRequest($0) }
        if !creates.isEmpty, !profile.allowsCreate {
            throw AgentAccessError.invalidRequest("Create folders need read-create access.")
        }
        let line = oneLine(message ?? "")
        guard line.count <= maxMessageLength else {
            throw AgentAccessError.invalidRequest("The message can be at most \(maxMessageLength) characters.")
        }
        let claim = { (text: String?) in String(oneLine(text ?? "").prefix(maxClaimLength)) }
        return AgentAccessRequestDraft(
            libraryRoot: resolved.url.path, project: key, profile: profile, readFolders: folders,
            createFolders: creates, message: line, agent: claim(agent), session: claim(session), client: claim(client))
    }

    /// Control characters (line breaks, tabs, bidi overrides) become spaces; runs of spaces collapse.
    public static func oneLine(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : $0 }
        return String(String.UnicodeScalarView(scalars)).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // MARK: Errors

    public static func tooManyRequests(total: Bool) -> AgentAccessError {
        AgentAccessError(
            code: "too_many_requests", title: "Too Many Requests",
            message: total
                ? "There are already \(maxPendingTotal) access requests waiting. Ask the owner to review them."
                : "There are already \(maxPendingPerLibrary) access requests waiting for this Library. "
                    + "Ask the owner to review them.")
    }

    static func notFound(_ id: String) -> AgentAccessError {
        AgentAccessError(
            code: "request_not_found", title: "Request Not Found", message: "There’s no access request “\(id)”.")
    }

    /// “This request was already approved in Terminal.” / “This request expired on Sep 8.”
    public static func alreadyDecided(_ request: AgentAccessRequest, now: Date) -> AgentAccessError {
        let status = request.status(at: now)
        let message: String
        if status == .expired {
            message = "This request expired on \(shortDate(request.closedAt(now) ?? request.expiresAt))."
        } else {
            message =
                "This request was already \(status.rawValue)"
                + (request.decidedVia.map { " in " + $0.displayName } ?? "") + "."
        }
        return AgentAccessError(code: "request_decided", title: "Request Already Decided", message: message)
    }

    static let ownerOnlyMessage = "Only the owner can approve or deny access. Run this in Terminal."
}

/// Reads and changes `agent-access-requests.json`. Every change holds an exclusive `flock` on a lock file beside it
/// (the kernel drops it if the holder dies), rereads the file, and replaces it atomically, so helpers and the app
/// never lose each other's records. A broken or newer file is reported and never overwritten.
public struct AgentAccessRequestStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var standard: AgentAccessRequestStore {
        AgentAccessRequestStore(url: AgentAccessRequests.defaultURL())
    }

    /// A missing file is an empty one.
    public func load() throws -> AgentAccessRequestFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code)
        {
            return AgentAccessRequestFile()
        } catch {
            throw invalid
        }
        let file: AgentAccessRequestFile
        do {
            file = try JSONDecoder().decode(AgentAccessRequestFile.self, from: data)
        } catch {
            throw invalid
        }
        guard file.version <= AgentAccessRequestFile.currentVersion else {
            throw AgentAccessError(
                code: "unsupported_requests_version", title: "Can’t Read Access Requests",
                message: "The access requests file was saved by a newer version of Silkweb.")
        }
        return file
    }

    private var invalid: AgentAccessError {
        AgentAccessError(
            code: "invalid_requests_file", title: "Can’t Read Access Requests",
            message: "The access requests file at “\(url.path)” can’t be read.")
    }

    /// Runs `body` on the current file under the lock and saves it if it changed.
    func update<Result>(_ body: (inout AgentAccessRequestFile) throws -> Result) throws -> Result {
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw AgentAccessError.requestsWriteFailed
        }
        let descriptor = open(url.path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AgentAccessError.requestsWriteFailed }
        defer { close(descriptor) }
        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else { throw AgentAccessError.requestsWriteFailed }
        }
        defer { flock(descriptor, LOCK_UN) }
        let before = try load()
        var file = before
        let result = try body(&file)
        if file != before {
            file.version = AgentAccessRequestFile.currentVersion
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            do {
                try encoder.encode(file).write(to: url, options: .atomic)
            } catch {
                throw AgentAccessError.requestsWriteFailed
            }
        }
        return result
    }

    // MARK: Agent side

    /// Adds a pending request, or returns the matching pending one with `duplicate: true`. Never touches
    /// `agent-grants.json`.
    public func submit(_ draft: AgentAccessRequestDraft, now: Date = Date()) throws -> (
        request: AgentAccessRequest, duplicate: Bool
    ) {
        try update { file in
            let pending = file.requests.filter { $0.isPending(at: now) }
            if let existing = pending.first(where: draft.matches) { return (existing, true) }
            guard
                pending.filter({ $0.libraryRoot == draft.libraryRoot }).count < AgentAccessRequests.maxPendingPerLibrary
            else { throw AgentAccessRequests.tooManyRequests(total: false) }
            guard pending.count < AgentAccessRequests.maxPendingTotal else {
                throw AgentAccessRequests.tooManyRequests(total: true)
            }
            // Whole seconds, as the file stores them, so the reply matches what's saved.
            let start = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            var id: String
            repeat {
                id = "req_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
            } while file.requests.contains { $0.requestId == id }
            let request = AgentAccessRequest(
                requestId: id, libraryRoot: draft.libraryRoot, project: draft.project, profile: draft.profile,
                readFolders: draft.readFolders, message: draft.message, agent: draft.agent, session: draft.session,
                client: draft.client, requestedAt: start,
                expiresAt: start.addingTimeInterval(AgentAccessRequests.timeToLive), createFolders: draft.createFolders)
            file.requests.append(request)
            prune(&file, now: now)
            return (request, false)
        }
    }

    /// Keeps every pending request and the newest `maxHistory` others.
    private func prune(_ file: inout AgentAccessRequestFile, now: Date) {
        let closed = file.requests.filter { !$0.isPending(at: now) }
        guard closed.count > AgentAccessRequests.maxHistory else { return }
        let dropped = Set(
            closed.sorted { ($0.closedAt(now) ?? .distantPast) > ($1.closedAt(now) ?? .distantPast) }
                .dropFirst(AgentAccessRequests.maxHistory).map(\.requestId))
        file.requests.removeAll { dropped.contains($0.requestId) }
    }

    // MARK: Owner side

    /// The pending request `id`, or why it can't be decided.
    public func pending(_ id: String, now: Date = Date()) throws -> AgentAccessRequest {
        guard let request = try load().requests.first(where: { $0.requestId == id }) else {
            throw AgentAccessRequests.notFound(id)
        }
        guard request.isPending(at: now) else { throw AgentAccessRequests.alreadyDecided(request, now: now) }
        return request
    }

    /// What approving would save, without saving anything: refuses exactly as the approval would (#186 rules).
    public func previewApproval(
        _ id: String, grantsURL: URL, now: Date = Date(), keys: (any AgentGrantVerifier)? = nil
    ) throws -> AgentAccessDecision {
        let request = try pending(id, now: now)
        let plan = try Self.approval(request, grantsURL: grantsURL, now: now, keys: keys)
        return AgentAccessDecision(
            request: request, grant: plan.merged.grant, outcome: plan.merged.outcome, filesystem: plan.filesystem)
    }

    /// Approves or denies one pending request. Approval merges into `grantsURL` with `grant init`'s rules: a new
    /// grant is added with the requested read and create folders; an identical one is left as it is; create folders
    /// (#228) are added to an existing grant, which the owner's Approve confirms; anything else that would widen a
    /// grant is refused and the request stays pending. Callers are the owner's: the Terminal command after its
    /// terminal check, or the app after owner authentication. Agents have no path here.
    ///
    /// #205: protected grants are re-signed with `signer` (the Terminal command passes one only with a terminal on
    /// stdin, the app after authentication); without one, approving into protected grants is refused. Unprotected
    /// grants stay unsigned: approval never protects them on its own.
    public func decide(
        _ id: String, approve: Bool, note: String = "", via: AgentAccessRequest.Via, grantsURL: URL, now: Date = Date(),
        signer: (any AgentGrantSigner)? = nil, keys: (any AgentGrantVerifier)? = nil
    ) throws -> AgentAccessDecision {
        try update { file in
            guard let index = file.requests.firstIndex(where: { $0.requestId == id }) else {
                throw AgentAccessRequests.notFound(id)
            }
            var request = file.requests[index]
            guard request.isPending(at: now) else { throw AgentAccessRequests.alreadyDecided(request, now: now) }
            var decision = AgentAccessDecision(request: request, grant: nil, outcome: nil, filesystem: nil)
            if approve {
                let plan = try Self.approval(request, grantsURL: grantsURL, now: now, keys: keys ?? signer)
                if plan.merged.outcome != .unchanged {
                    do {
                        try AgentGrantSigning.save(
                            plan.merged.file, to: grantsURL, current: plan.current, signer: signer, authenticated: true)
                    } catch let error as AgentAccessError {
                        throw error
                    } catch {
                        throw AgentAccessError(
                            code: "write_failed", title: "Can’t Approve This Request",
                            message: "Silkweb couldn’t save “agent-grants.json”. Nothing was saved.")
                    }
                }
                decision = AgentAccessDecision(
                    request: request, grant: plan.merged.grant, outcome: plan.merged.outcome,
                    filesystem: plan.filesystem)
            } else {
                request.ownerNote = String(
                    AgentAccessRequests.oneLine(note).prefix(AgentAccessRequests.maxMessageLength))
            }
            request.status = approve ? .approved : .denied
            request.decidedAt = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            request.decidedVia = via
            file.requests[index] = request
            return AgentAccessDecision(
                request: request, grant: decision.grant, outcome: decision.outcome, filesystem: decision.filesystem)
        }
    }

    /// `keys` verifies the grants (the process's verifier when nil); grants that need review refuse the approval.
    private static func approval(
        _ request: AgentAccessRequest, grantsURL: URL, now: Date, keys: (any AgentGrantVerifier)?
    ) throws -> (
        merged: (file: AgentGrantFile, grant: AgentGrant, outcome: AgentGrantInit.Outcome),
        filesystem: AgentFilesystem, current: AgentGrantInspection
    ) {
        let refused = { (message: String) in
            AgentAccessError(code: "approve_would_widen", title: "Can’t Approve This Request", message: message)
        }
        do {
            let library = try AgentGrantInit.resolveLibrary(request.libraryRoot, from: "/")
            let current = try AgentGrantSigning.inspect(grantsURL, keys: keys ?? AgentGrantKeys.verifier)
            switch current.protection {
            case .changedOutside: throw AgentAccessError.grantsChangedOutside
            case .keyMissing: throw AgentAccessError.grantsKeyMissing
            case .keyUnreadable: throw AgentAccessError.grantsKeyUnreadable
            case .protected, .unprotected: break
            }
            let merged = try AgentGrantInit.merge(
                current.file, project: request.project, library: library.url, access: request.profile,
                readFolders: request.readFolders, createFolders: request.createFolders, now: now, approving: true)
            return (merged, library.filesystem, current)
        } catch let failure as AgentGrantInit.Failure {
            if failure == .folderMissing || failure == .folderUnreadable {
                throw refused("The Library “\(request.libraryRoot)” can’t be found or read.")
            }
            throw refused(failure.message)
        }
    }
}

extension AgentAccessRequests {
    /// ISO 8601 in UTC, whole seconds, as the grants file stores dates.
    static func date(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
    static func string(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    /// “Nov 8”, in the current time zone.
    public static func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }
}

extension AgentAccessError {
    static let requestsWriteFailed = AgentAccessError(
        code: "write_failed", title: "Can’t Save Access Request",
        message: "Silkweb couldn’t save the access request. Nothing was changed. Try again.")
}

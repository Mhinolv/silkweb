import Foundation

/// `silkweb grant request | requests | approve | deny` (#203, `docs/agent-memory.md` › Access requests).
///
/// `request` is the agent's: it needs no grant and no terminal, never touches `agent-grants.json`, and prints one
/// JSON object on stdout like `silkweb memory`. The rest are the owner's and print plain text; `approve` and `deny`
/// refuse without a terminal, so an agent's shell can't decide its own request.
enum AgentGrantRequests {
    static let flags: Set<String> = ["all", "pretty"]
    private static let requestOptions: Set<String> = [
        "library", "project", "access", "folder", "create-folder", "message", "agent", "session", "client",
        "requests",
    ]

    // MARK: Agent

    /// `grant request …`. The summary line goes to stderr; stdout is `{"ok":true,"result":{…},"version":1}`.
    static func request(_ arguments: [String], home: URL, currentDirectory: String, now: Date) -> AgentHelper.Output {
        var pretty = arguments.contains("--pretty")
        do {
            let invocation = try AgentHelper.parse(arguments, flags: ["pretty", "help"])
            pretty = invocation.flags.contains("pretty")
            if invocation.flags.contains("help") {
                return AgentHelper.Output(status: 0, stdout: AgentGrantInit.help, stderr: "")
            }
            guard invocation.words.count == 2 else { throw usage("“grant request” takes no other arguments.") }
            for (option, values) in invocation.options.sorted(by: { $0.key < $1.key }) {
                guard requestOptions.contains(option) else {
                    throw usage("The option “--\(option)” isn’t valid for “grant request”.")
                }
                guard values.count == 1 || option == "folder" || option == "create-folder" else {
                    throw usage("The option “--\(option)” can only be given once.")
                }
            }
            if let missing = ["library", "project", "access"].first(where: { invocation.value($0) == nil }) {
                throw usage("“grant request” needs --\(missing).")
            }
            let draft = try AgentAccessRequests.draft(
                library: invocation.value("library") ?? "", project: invocation.value("project") ?? "",
                access: invocation.value("access") ?? "", readFolders: invocation.options["folder"] ?? [],
                createFolders: invocation.options["create-folder"] ?? [], message: invocation.value("message"),
                agent: invocation.value("agent"),
                session: invocation.value("session"), client: invocation.value("client") ?? "cli",
                currentDirectory: currentDirectory)
            let store = requestStore(invocation, home: home, currentDirectory: currentDirectory)
            let submitted = try store.submit(draft, now: now)
            let json = AgentJSON.object([
                ("ok", .bool(true)), ("result", result(submitted.request, duplicate: submitted.duplicate)),
                ("version", .int(AgentHelper.outputVersion)),
            ])
            return AgentHelper.Output(
                status: 0, stdout: json.rendered(pretty: pretty),
                stderr: "silkweb: " + AgentAccessRequests.waitingNote(submitted.request.requestId) + "\n")
        } catch let failure as AgentAccessError {
            return AgentHelper.refusal(failure, pretty: pretty)
        } catch {
            return AgentHelper.refusal(.internalError, pretty: pretty)
        }
    }

    /// `{"duplicate","expiresAt","requestId","status"}`, shared with MCP `grant_request`.
    static func result(_ request: AgentAccessRequest, duplicate: Bool) -> AgentJSON {
        .object([
            ("duplicate", .bool(duplicate)), ("expiresAt", .string(AgentAccessRequests.string(request.expiresAt))),
            ("requestId", .string(request.requestId)), ("status", .string(request.status.rawValue)),
        ])
    }

    private static func usage(_ message: String) -> AgentAccessError {
        .invalidRequest(message + " Run “silkweb grant --help” for usage.")
    }

    private static func requestStore(_ invocation: AgentHelper.Invocation, home: URL, currentDirectory: String)
        -> AgentAccessRequestStore
    {
        AgentAccessRequestStore(
            url: invocation.value("requests").map { AgentGrantInit.absoluteURL($0, from: currentDirectory) }
                ?? AgentAccessRequests.defaultURL(home: home))
    }

    // MARK: Owner

    /// `grant requests [--all]`, `grant approve <ID>`, `grant deny <ID> [--note …]`.
    static func owner(
        _ invocation: AgentHelper.Invocation, console: AgentGrantInit.Console, home: URL,
        environment: [String: String], executable: String?, currentDirectory: String, now: Date
    ) throws -> AgentHelper.Output {
        let command = invocation.words[1]
        let usage = { (message: String) in
            AgentGrantInit.Failure(status: 64, message: message + " Run “silkweb grant --help” for usage.")
        }
        var allowed: Set<String> = ["requests"]
        if command != "requests" { allowed.insert("grants") }
        if command == "deny" { allowed.insert("note") }
        for (option, values) in invocation.options.sorted(by: { $0.key < $1.key }) {
            guard allowed.contains(option) else {
                throw usage("The option “--\(option)” isn’t valid for “grant \(command)”.")
            }
            guard values.count == 1 else { throw usage("The option “--\(option)” can only be given once.") }
        }
        let validFlags: Set<String> = command == "requests" ? ["all"] : []
        if let flag = invocation.flags.subtracting(validFlags).sorted().first {
            throw usage("The option “--\(flag)” isn’t valid for “grant \(command)”.")
        }
        let store = requestStore(invocation, home: home, currentDirectory: currentDirectory)
        if command == "requests" {
            guard invocation.words.count == 2 else { throw usage("“grant requests” takes no other arguments.") }
            return AgentHelper.Output(
                status: 0, stdout: list(try store.load(), all: invocation.flags.contains("all"), home: home, now: now),
                stderr: "")
        }
        guard invocation.words.count == 3 else { throw usage("“grant \(command)” needs one request ID.") }
        let id = invocation.words[2]
        let realGrants = AgentGrantFile.defaultURL(home: home)
        let grantsURL =
            invocation.value("grants").map { AgentGrantInit.absoluteURL($0, from: currentDirectory) } ?? realGrants
        // An agent's shell has no terminal: it can't decide a request in the real files, even its own.
        if !console.isTerminal,
            AgentGrantInit.isSameFile(store.url, AgentAccessRequests.defaultURL(home: home))
                || AgentGrantInit.isSameFile(grantsURL, realGrants)
        {
            throw AgentGrantInit.Failure(status: 77, message: AgentAccessRequests.ownerOnlyMessage)
        }
        let approve = command == "approve"
        // Refusals (unknown, decided, would widen) come before the question, so the owner isn't asked in vain.
        let request = try store.pending(id, now: now)
        if approve { _ = try store.previewApproval(id, grantsURL: grantsURL, now: now) }
        if console.isTerminal {
            console.write(describe(request, home: home, now: now))
            console.write(approve ? "Approve this request? [y/N] " : "Deny this request? [y/N] ")
            guard let answer = console.readLine() else {
                console.write("\n")
                throw AgentGrantInit.Failure.cancelled
            }
            let word = answer.trimmingCharacters(in: .whitespaces).lowercased()
            guard word == "y" || word == "yes" else {
                return AgentHelper.Output(status: 0, stdout: "Nothing was saved.\n", stderr: "")
            }
        }
        let decision = try store.decide(
            id, approve: approve, note: invocation.value("note") ?? "", via: .terminal, grantsURL: grantsURL, now: now)
        guard approve, let grant = decision.grant, let outcome = decision.outcome else {
            return AgentHelper.Output(
                status: 0, stdout: "Denied the request from “\(request.agentName)” for “\(request.project)”.\n",
                stderr: "")
        }
        let helper = AgentGrantInit.helperPath(executable, environment: environment, currentDirectory: currentDirectory)
        let stdout =
            AgentGrantInit.summary(
                grant, outcome: outcome, filesystem: decision.filesystem ?? .unqualified,
                fileName: AgentGrantInit.displayPath(grantsURL, home: home)) + "\n"
            + AgentGrantInit.installBlock(helper: helper, project: grant.project)
        return AgentHelper.Output(status: 0, stdout: stdout, stderr: "")
    }

    /// What the owner is asked about, on stderr before the question.
    static func describe(_ request: AgentAccessRequest, home: URL, now: Date) -> String {
        var lines = [
            request.headline,
            "  Library  " + AgentGrantInit.displayPath(URL(fileURLWithPath: request.libraryRoot), home: home),
            "  Folders  "
                + ([AgentMemoryContract.projectRoot(request.project)] + request.readFolders)
                .map(AgentMemoryContract.displayPath).joined(separator: ", "),
        ]
        if !request.createFolders.isEmpty {
            lines.append(
                "  Create   " + request.createFolders.map(AgentMemoryContract.displayPath).joined(separator: ", "))
        }
        if !request.message.isEmpty { lines.append("  Message  “\(request.message)”") }
        lines.append(
            "  Asked    \(AgentAccessRequests.shortDate(request.requestedAt)) · \(request.expiryLabel(now))")
        lines.append("Agent and session are claimed, not verified.")
        return lines.joined(separator: "\n") + "\n"
    }

    /// `req_…  pending  claude-code  Silkweb  Read and Create  ~/Writing  expires Nov 8`, waiting first.
    static func list(_ file: AgentAccessRequestFile, all: Bool, home: URL, now: Date) -> String {
        let review = file.review(now: now)
        let rows = review.waiting + (all ? review.history : [])
        guard !rows.isEmpty else { return all ? "No access requests yet.\n" : "No access requests are waiting.\n" }
        return rows.map { request in
            let status = request.status(at: now)
            var columns = [
                request.requestId, status.rawValue, request.agentName, request.project, request.profile.displayName,
                AgentGrantInit.displayPath(URL(fileURLWithPath: request.libraryRoot), home: home)
                    + (request.readFolders.isEmpty
                        ? ""
                        : " + \(request.readFolders.count) read folder\(request.readFolders.count == 1 ? "" : "s")")
                    + (request.createFolders.isEmpty
                        ? ""
                        : " + \(request.createFolders.count) create folder\(request.createFolders.count == 1 ? "" : "s")"),
            ]
            switch status {
            case .pending: columns.append("expires " + AgentAccessRequests.shortDate(request.expiresAt))
            case .expired:
                columns.append("expired " + AgentAccessRequests.shortDate(request.closedAt(now) ?? request.expiresAt))
            case .approved, .denied:
                var text = (request.decidedAt.map { AgentAccessRequests.shortDate($0) } ?? "")
                if let via = request.decidedVia { text += " in " + via.displayName }
                if !request.ownerNote.isEmpty { text += " — " + request.ownerNote }
                columns.append(text.trimmingCharacters(in: .whitespaces))
            }
            return columns.joined(separator: "  ")
        }.joined(separator: "\n") + "\n"
    }
}

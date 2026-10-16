import Foundation

/// The `silkweb memory …` command line (#135, `docs/agent-memory.md` › Command line): a thin layer
/// over the same services MCP uses (#136). It resolves a grant with Silkweb closed, then reports
/// scope, lists, searches and reads documents (#134), creates documents and Folders (#133) and lists
/// this grant's receipts, and updates documents an agent created (#204). Only creates and updates write to
/// the Library; only `grant init` (#186,
/// `AgentGrantInit.swift`) writes the grants file.
///
/// stdout always carries exactly one JSON object, `{"ok":true,"result":…,"version":1}` or
/// `{"error":{…},"ok":false,"version":1}`, so scripts can parse it whatever happened. stderr carries
/// only `silkweb: <message>` lines, never document text.
public enum AgentHelper {
    public struct Output: Equatable, Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    /// Version of the stdout envelope.
    public static let outputVersion = 1

    public static let help = """
        USAGE
          silkweb memory <command> [arguments] [options]
          silkweb mcp [--grant G] [--agent A] [--session S] [--client C]
                                        Stdio MCP server for agents (stdout is MCP only)
          silkweb grant init [...]      Set up agent access for one project (owner only)
          silkweb grant request [...]   Ask the owner for access; see “silkweb grant --help”

        COMMANDS
          capabilities                  This grant’s scope, limits and commands
          search [QUERY]                Search the read folders
              [--project P] [--type T]... [--status S]... [--created-after D]
              [--created-before D] [--limit N] [--ranked] [--include-archived]
              [--recent-days N] [--cursor C]
              Progress and handoffs older than 30 days are left out unless a
              project has none newer; --recent-days 0 turns this off
              --ranked orders by relevance and reads "phrases", tag:, type:,
              status:, project:, after: and before: in QUERY
              --limit is at most the grant's max_results; pass nextCursor
              as --cursor, with the same QUERY and filters, for the next page
          read <PATH> | --id ID | --memory-id M
                                        Read one page of a document
              [--cursor C] [--expected-revision R]
          create                        Create one document; never replaces anything
              --folder memories|progress|handoffs|agent-memories|<PATH> --title T --body-file <FILE|->
              --agent A --session S [--type T] [--idempotency-key K] [--status S]
              [--observed-at D] [--review-after D] [--supersedes MEMORY_ID]...
          create-folder <PATH>          Create a Folder inside a create folder
          update <PATH> | --id ID       Replace the body of a document an agent created
              --expected-revision R --body-file <FILE|-> --agent A --session S
              [--idempotency-key K]
          propose-change <PATH> | --id ID
                                        Propose a new body for any readable document;
                                        the owner reviews it in Silkweb
              --expected-revision R --body-file <FILE|-> --reason TEXT --agent A
              --session S [--idempotency-key K]
          propose-organization --kind move|rename|merge
                                        Propose a move, rename or merge for the owner
              move:   <PATH> | --id ID --destination FOLDER
              rename: <PATH> | --id ID --title T
              merge:  --source PATH... --title T --destination FOLDER --body-file <FILE|->
              --reason TEXT --agent A --session S [--expected-revision R]
              [--idempotency-key K]
          activity [--limit N] [--since D]
                                        This grant’s receipts, newest first
          list                          Document paths, sizes and dates, no text

        OPTIONS
          --grant <GRANT>     Project key or label of the grant to use (or SILKWEB_GRANT).
                              Needed only when there's more than one grant.
          --agent <NAME>      Agent recorded in created documents (a claim, not authentication)
          --session <ID>      Session recorded in created documents
          --client <NAME>     Client recorded in receipts (default “cli”)
          --grants <FILE>     Read grants from another file, for testing
          --pretty            Indent the JSON output
          --help              Show this help
          --version           Show the helper and contract versions

        Paths are relative to the Library, for example "Memory/Projects/Silkweb/Memories/Note.md".
        Document text comes only from --body-file, or stdin with "-".
        stdout is one JSON object; messages go to stderr.
        Exit status: 0 ok, 64 usage, 65 bad input, 69 busy (try again), 70 internal, 74 I/O, 77 access.

        """

    /// Arguments and options one command accepts, beyond the global ones.
    private struct Command {
        var arguments: ClosedRange<Int> = 0...0
        var options: Set<String> = []
        var repeatable: Set<String> = []
        var required: [String] = []
    }

    private static let globalOptions: Set<String> = ["grant", "agent", "session", "client", "grants"]
    private static let flags: Set<String> = ["pretty", "help", "version", "ranked", "include-archived"]

    private static let commands: [String: Command] = [
        "capabilities": Command(),
        "list": Command(),
        "search": Command(
            arguments: 0...Int.max,
            options: [
                "project", "type", "status", "created-after", "created-before", "limit", "recent-days", "cursor",
            ],
            repeatable: ["type", "status"]),
        "read": Command(arguments: 0...1, options: ["id", "memory-id", "cursor", "expected-revision"]),
        "create": Command(
            options: [
                "folder", "type", "title", "body-file", "idempotency-key", "status", "observed-at", "review-after",
                "supersedes",
            ],
            repeatable: ["supersedes"], required: ["title", "body-file", "agent", "session"]),
        "create-folder": Command(arguments: 1...1),
        "update": Command(
            arguments: 0...1, options: ["id", "expected-revision", "body-file", "idempotency-key"],
            required: ["expected-revision", "body-file", "agent", "session"]),
        "propose-change": Command(
            arguments: 0...1, options: ["id", "expected-revision", "body-file", "idempotency-key", "reason"],
            required: ["expected-revision", "body-file", "reason", "agent", "session"]),
        "propose-organization": Command(
            arguments: 0...1,
            options: [
                "kind", "id", "expected-revision", "destination", "title", "source", "body-file", "idempotency-key",
                "reason",
            ],
            repeatable: ["source"], required: ["kind", "reason", "agent", "session"]),
        "activity": Command(options: ["limit", "since"]),
    ]

    /// `--folder` keywords for the three entry folders, and the type each one creates by default.
    private static let folderKeywords = ["memories": "memory", "progress": "progress", "handoffs": "handoff"]
    /// #206: the agent folder's `Memories`, for memory and decision documents only.
    static let agentMemoriesKeyword = "agent-memories"

    static let defaultActivityLimit = 20

    /// Parsed command line: words (command and arguments), options by name without `--`, and flags.
    struct Invocation {
        var words: [String] = []
        var options: [String: [String]] = [:]
        var flags: Set<String> = []

        func value(_ name: String) -> String? { options[name]?.first }
    }

    public static func run(
        _ arguments: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardInput: FileHandle = .standardInput
    ) -> Output {
        var pretty = arguments.contains("--pretty")
        do {
            let invocation = try parse(arguments)
            pretty = invocation.flags.contains("pretty")
            if invocation.flags.contains("help") { return Output(status: 0, stdout: help, stderr: "") }
            if invocation.flags.contains("version") || invocation.words == ["version"] {
                let version: [String: Any] = [
                    "contract_version": AgentMemoryContract.version, "helper_version": SilkwebCore.version,
                ]
                return success(AgentJSON(sortingKeysOf: version), pretty: pretty)
            }
            let (result, note) = try execute(
                invocation, home: home, environment: environment, standardInput: standardInput)
            var output = success(result, pretty: pretty)
            output.stderr = note.map { "silkweb: " + $0 + "\n" } ?? ""
            return output
        } catch let failure as AgentAccessError {
            return refusal(failure, pretty: pretty)
        } catch let gate as LibraryGateError {
            return refusal(AgentAccessError(gate), pretty: pretty)
        } catch {
            return refusal(.internalError, pretty: pretty)
        }
    }

    /// The failure envelope on stdout, the message on stderr, and the code's exit status.
    static func refusal(_ failure: AgentAccessError, pretty: Bool = false) -> Output {
        let json = AgentJSON.object([
            ("error", AgentJSON(sortingKeysOf: failure.fields)), ("ok", .bool(false)), ("version", .int(outputVersion)),
        ])
        return Output(
            status: exitStatus(for: failure.code), stdout: json.rendered(pretty: pretty),
            stderr: "silkweb: " + failure.message + "\n")
    }

    /// sysexits(3): 64 usage, 65 bad input, 69 busy or rate limited (try again), 70 internal,
    /// 74 Library I/O, 77 access. Unknown codes are internal.
    public static func exitStatus(for code: String) -> Int32 {
        switch code {
        case "invalid_argument":
            return 64
        case "envelope_malformed", "envelope_schema_newer", "envelope_invalid_field", "too_large",
            "idempotency_conflict", "not_found", "revision_changed", "request_not_found", "request_decided",
            "invalid_agent_folder", "invalid_create_folder":
            return 65
        case "library_busy", "stale_snapshot", "rate_limited", "document_has_unsaved_changes", "too_many_requests",
            "too_many_proposals":
            return 69
        case "library_not_found", "library_unreadable", "unreadable", "write_failed", "disk_full", "permission_denied",
            "grants_signing_failed":
            return 74
        case "grant_required", "grant_not_found", "grant_revoked", "no_grant", "no_grants_file",
            "invalid_grants_file", "unsupported_grants_version", "invalid_grant", "out_of_scope",
            "create_not_allowed", "invalid_path", "excluded_name", "update_not_allowed", "update_requires_proposal",
            "propose_not_allowed",
            "invalid_requests_file", "unsupported_requests_version", "approve_would_widen", "invalid_grants_signature",
            "grants_key_missing", "grants_key_unreadable", "grants_signing_required", "needs_authentication":
            return 77
        default:
            return 70
        }
    }

    private static func success(_ result: AgentJSON, pretty: Bool) -> Output {
        let json = AgentJSON.object([("ok", .bool(true)), ("result", result), ("version", .int(outputVersion))])
        return Output(status: 0, stdout: json.rendered(pretty: pretty), stderr: "")
    }

    // MARK: Parsing

    /// `--name value` and `--name=value`; `--` ends the options, so a query may start with “-”.
    /// `flags` are the options that take no value.
    static func parse(_ arguments: [String], flags: Set<String> = flags) throws -> Invocation {
        var invocation = Invocation()
        var index = 0
        var literal = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if literal || !argument.hasPrefix("-") || argument == "-" {
                invocation.words.append(argument)
                continue
            }
            if argument == "--" {
                literal = true
                continue
            }
            if argument == "-h" {
                invocation.flags.insert("help")
                continue
            }
            let body = argument.dropFirst(2)
            let name = String(body.prefix { $0 != "=" })
            guard argument.hasPrefix("--"), !name.isEmpty else { throw usage("That option isn’t valid.") }
            let inline = body.contains("=") ? String(body.drop { $0 != "=" }.dropFirst()) : nil
            if flags.contains(name) {
                guard inline == nil else { throw usage("The option “--\(name)” doesn’t take a value.") }
                invocation.flags.insert(name)
                continue
            }
            guard let value = inline ?? (index < arguments.count ? arguments[index] : nil) else {
                throw usage("The option “--\(name)” needs a value.")
            }
            if inline == nil { index += 1 }
            invocation.options[name, default: []].append(value)
        }
        return invocation
    }

    /// The command name and its arguments, after checking its options.
    private static func command(_ invocation: Invocation) throws -> (name: String, arguments: [String]) {
        let words = invocation.words
        guard words.first == "memory" else {
            throw usage(words.isEmpty ? "Choose a command." : "That isn’t a silkweb command.")
        }
        let names =
            "capabilities, search, read, create, create-folder, update, propose-change, propose-organization, "
            + "activity or list"
        guard words.count >= 2 else { throw usage("Choose a memory command: \(names).") }
        guard let command = commands[words[1]] else { throw usage("That isn’t a memory command. Use \(names).") }
        let name = words[1]
        let arguments = Array(words.dropFirst(2))
        guard command.arguments.contains(arguments.count) else {
            throw usage(
                arguments.count < command.arguments.lowerBound
                    ? "“memory \(name)” needs a path." : "“memory \(name)” takes no other arguments.")
        }
        for (option, values) in invocation.options.sorted(by: { $0.key < $1.key }) {
            guard globalOptions.contains(option) || command.options.contains(option) else {
                throw usage("The option “--\(option)” isn’t valid for “memory \(name)”.")
            }
            guard values.count == 1 || command.repeatable.contains(option) else {
                throw usage("The option “--\(option)” can only be given once.")
            }
        }
        if let missing = command.required.first(where: { invocation.options[$0] == nil }) {
            throw usage("“memory \(name)” needs --\(missing).")
        }
        for flag in ["ranked", "include-archived"] where invocation.flags.contains(flag) && name != "search" {
            throw usage("The option “--\(flag)” isn’t valid for “memory \(name)”.")
        }
        if name == "read" {
            let given = [!arguments.isEmpty, invocation.value("id") != nil, invocation.value("memory-id") != nil]
            guard given.filter({ $0 }).count == 1 else {
                throw usage("“memory read” needs one of a path, --id or --memory-id.")
            }
        } else if name == "update" || name == "propose-change", arguments.isEmpty == (invocation.value("id") == nil) {
            throw usage("“memory \(name)” needs a path or --id, not both.")
        }
        if name == "propose-organization" {
            guard let kind = invocation.value("kind").flatMap(AgentProposal.Kind.init(rawValue:)), kind != .edit else {
                throw usage("The option “--kind” must be move, rename or merge.")
            }
            let named = !arguments.isEmpty || invocation.value("id") != nil
            switch kind {
            case .merge:
                guard !named else { throw usage("A merge names its documents with --source, not a path or --id.") }
                for option in ["title", "destination", "body-file"] where invocation.value(option) == nil {
                    throw usage("A merge needs --\(option).")
                }
            default:
                guard arguments.isEmpty != (invocation.value("id") == nil) else {
                    throw usage("“memory \(name)” needs a path or --id, not both.")
                }
                guard invocation.options["source"] == nil, invocation.value("body-file") == nil else {
                    throw usage("Only a merge takes --source and --body-file.")
                }
                let needed = kind == .move ? "destination" : "title"
                guard invocation.value(needed) != nil else { throw usage("A \(kind.rawValue) needs --\(needed).") }
            }
        }
        return (name, arguments)
    }

    private static func usage(_ message: String) -> AgentAccessError {
        .invalidRequest(message + " Run “silkweb --help” for usage.")
    }

    /// Library-relative paths and titles are compared and stored in NFC.
    static func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    // MARK: Commands

    /// The command's result and an optional note for stderr.
    private static func execute(
        _ invocation: Invocation, home: URL, environment: [String: String], standardInput: FileHandle
    ) throws -> (AgentJSON, String?) {
        let (name, arguments) = try command(invocation)
        let store = AgentGrantStore(
            url: invocation.value("grants").map { URL(fileURLWithPath: $0) } ?? AgentGrantFile.defaultURL(home: home))
        // The flag wins over the environment; an empty variable counts as unset.
        let requested = invocation.value("grant") ?? environment["SILKWEB_GRANT"].flatMap { $0.isEmpty ? nil : $0 }
        let grant: AgentGrant
        do {
            grant = try store.load().select(requested)
        } catch let error as AgentAccessError where ["grant_not_found", "no_grants_file"].contains(error.code) {
            // A removed grant's search cache goes with it, as when a running session sees it disappear.
            if let requested {
                try? FileManager.default.removeItem(
                    at: AgentMemoryService.defaultCacheDirectory(home: home)
                        .appendingPathComponent(AgentMemoryService.grantID(project: requested) + ".json"))
            }
            throw error
        }
        let session = AgentSession(project: grant.project, store: store)
        switch name {
        case "search", "read":
            let service = AgentMemoryService(
                session: session, cacheDirectory: AgentMemoryService.defaultCacheDirectory(home: home))
            if name == "search" {
                return (try service.search(searchRequest(invocation, query: arguments)).json, nil)
            }
            let id = try invocation.value("id").map { text -> UUID in
                if AgentAccessError.isMemoryID(text) {
                    throw AgentAccessError.memoryIDGiven("--id", use: "--memory-id")
                }
                guard let id = UUID(uuidString: text) else { throw AgentAccessError.invalidArgument("id") }
                return id
            }
            let request = AgentMemoryReadRequest(
                path: nfc(arguments.first ?? ""), documentID: id, memoryID: try memoryID(invocation.value("memory-id")),
                cursor: invocation.value("cursor"), expectedRevision: invocation.value("expected-revision"))
            return (try service.read(request).json, nil)
        case "create":
            return try create(session.authorize(.create), invocation: invocation, standardInput: standardInput)
        case "update":
            let path = arguments.first.map(nfc)
            let context = try session.authorize(.update, path: path)
            let body = try body(
                invocation, limit: context.grant.limits.maxCreateBytes, tooLarge: AgentAccessError.updateTooLarge,
                standardInput: standardInput)
            return (try update(context, invocation: invocation, path: path, body: body, keyPrefix: "cli-").json, nil)
        case "propose-change", "propose-organization":
            let path = arguments.first.map(nfc)
            let context = try session.authorize(.propose, path: path)
            let kind =
                name == "propose-change"
                ? AgentProposal.Kind.edit : AgentProposal.Kind(rawValue: invocation.value("kind") ?? "") ?? .move
            let body =
                invocation.value("body-file") == nil
                ? nil
                : try self.body(
                    invocation, limit: context.grant.limits.maxCreateBytes, tooLarge: AgentProposeService.tooLarge,
                    standardInput: standardInput)
            return (
                try propose(context, kind: kind, invocation: invocation, path: path, body: body, keyPrefix: "cli-")
                    .json, nil
            )
        case "create-folder":
            let authorization = try session.authorize(.createFolder, path: nfc(arguments[0]))
            let folder = try AgentCreateService(authorization: authorization).createFolder(authorization.path ?? "")
            let fields: [String: Any] = ["path": folder.path, "created": folder.created]
            return (AgentJSON(sortingKeysOf: fields), nil)
        case "activity":
            return (try activity(session.authorize(.activity), invocation: invocation), nil)
        case "list":
            return (try list(session.authorize(.list)), nil)
        default:
            return (capabilities(try session.authorize(.capabilities)), nil)
        }
    }

    /// #263: the readable documents directly in the project folder, for agents to read first each session. The title
    /// is the file name, as `memory_read` reports it, also when the envelope is bad or missing. `revision` is `null`
    /// when the document can't be read (larger than `max_read_bytes`, or replaced by a link since the listing).
    static func projectDocuments(_ context: AgentAuthorization) -> [[String: Any]] {
        let root = AgentMemoryContract.projectRoot(context.scope.project)
        let documents = (try? AgentSecureFiles.documents(library: context.library, in: root)) ?? []
        let dates = ISO8601DateFormatter()
        return context.scope.readable(documents, path: \.path).map { document in
            let data = try? AgentSecureFiles.readDocument(
                library: context.library, path: document.path, maxBytes: context.grant.limits.maxReadBytes)
            return [
                "path": document.path,
                "title": ((document.path as NSString).lastPathComponent as NSString).deletingPathExtension,
                "revision": data.map(AgentMemoryIndex.revision) ?? NSNull(),
                "modified": dates.string(from: document.modified),
            ]
        }
    }

    /// Scope, profile, limits, commands and the project documents to read first.
    static func capabilities(_ context: AgentAuthorization, projectDocuments: [[String: Any]]? = nil) -> AgentJSON {
        let root = AgentMemoryContract.projectRoot(context.scope.project)
        let descriptor = try? AgentSecureFiles.openFolder(library: context.library, path: root)
        if let descriptor { close(descriptor) }
        let limits = context.grant.limits
        let scope = context.scope
        // #206: `null` without an agent folder, or when MCP roots narrowed it away.
        let agentReadRoot = scope.readRoots.first(where: scope.isAgentLevel)
        let agentCreateRoot = scope.createRoots.first(where: scope.isAgentLevel)
        let fields: [String: Any] = [
            "agent_folder": scope.agentFolder ?? NSNull(),
            "agent_read_root": agentReadRoot ?? NSNull(),
            "agent_create_root": agentCreateRoot ?? NSNull(),
            "contract_version": AgentMemoryContract.version,
            "helper_version": SilkwebCore.version,
            "schema": MemoryEnvelope.schemaV1,
            "project": context.scope.project,
            "label": context.grant.displayLabel,
            "library": context.library.path,
            "filesystem": context.filesystem.rawValue,
            "access": context.grant.access.rawValue,
            "profile": context.grant.access.displayName,
            "operations": ["capabilities", "list", "search", "read", "activity"]
                + (context.scope.createRoots.isEmpty ? [] : ["create", "create-folder"])
                + (context.scope.createRoots.isEmpty || !context.grant.access.allowsUpdate ? [] : ["update"])
                // #140: proposals are saved under `.silkweb/`, so they need a qualified disk, not a create folder.
                + (context.filesystem == .qualified && context.grant.access.allowsPropose
                    ? ["propose-change", "propose-organization"] : []),
            "read_roots": context.scope.readRoots,
            "retrieval_contract_version": AgentMemoryContract.retrievalVersion,
            "retrieval_modes": AgentMemorySearchRequest.Mode.allCases.map(\.rawValue),
            "create_roots": context.scope.createRoots,
            "project_folder_exists": descriptor != nil,
            "project_documents": projectDocuments ?? Self.projectDocuments(context),
            "limits": [
                "max_read_bytes": limits.maxReadBytes, "max_results": limits.maxResults,
                "requests_per_minute": limits.requestsPerMinute, "max_create_bytes": limits.maxCreateBytes,
            ],
        ]
        return AgentJSON(sortingKeysOf: fields)
    }

    /// One create (#133). The body comes from `--body-file`, or stdin for `-`, read only up to the
    /// grant's limit, so an oversized input is refused without reading all of it. A replay of the
    /// same key and payload succeeds with `"replayed": true`.
    static func create(_ context: AgentAuthorization, invocation: Invocation, standardInput: FileHandle) throws
        -> (AgentJSON, String?)
    {
        let (type, folder) = try destination(invocation, scope: context.scope)
        let body = try body(
            invocation, limit: context.grant.limits.maxCreateBytes, tooLarge: AgentAccessError.createTooLarge,
            standardInput: standardInput)
        let created = try publish(
            context, invocation: invocation, type: type, folder: folder, body: body, keyPrefix: "cli-")
        return (created.json, created.note)
    }

    /// The text from `--body-file`, or stdin for `-`, read only up to `limit`.
    private static func body(
        _ invocation: Invocation, limit: Int, tooLarge: (Int) -> AgentAccessError,
        standardInput: FileHandle = .standardInput
    ) throws -> String {
        let source = invocation.value("body-file") ?? "-"
        let handle = source == "-" ? standardInput : FileHandle(forReadingAtPath: source)
        guard let handle, let data = try? handle.read(upToCount: limit + 1) ?? Data() else {
            throw AgentAccessError.invalidRequest("The document text couldn’t be read.")
        }
        guard data.count <= limit else { throw tooLarge(limit) }
        guard let body = String(data: data, encoding: .utf8) else {
            throw AgentAccessError.invalidRequest("The document text must be UTF-8.")
        }
        return body
    }

    /// One update (#204), shared with `memory_update`. A replay of the same key and payload succeeds with
    /// `"replayed": true`; the result carries the document's new `revision` for the next update.
    static func update(
        _ context: AgentAuthorization, invocation: Invocation, path: String?, body: String, keyPrefix: String
    ) throws -> (json: AgentJSON, result: AgentUpdateResult) {
        let value = invocation.value
        let id = try value("id").map { text -> UUID in
            guard let id = UUID(uuidString: text) else { throw AgentAccessError.invalidArgument("id") }
            return id
        }
        let request = AgentUpdateRequest(
            // Without a key a retry can't be recognized; the revision check still stops a second write.
            idempotencyKey: value("idempotency-key") ?? keyPrefix + UUID().uuidString, path: path, documentID: id,
            expectedRevision: value("expected-revision") ?? "", body: body, agent: value("agent") ?? "",
            session: value("session") ?? "", client: value("client") ?? "cli")
        let result = try AgentUpdateService(authorization: context).update(request)
        let receipt = try JSONSerialization.jsonObject(with: AgentReceipt.encoded(result.receipt))
        let fields: [String: Any] = [
            "outcome": result.outcome.rawValue, "replayed": result.replayed, "path": result.path ?? NSNull(),
            "revision": result.revision ?? NSNull(), "receipt": receipt,
        ]
        return (AgentJSON(sortingKeysOf: fields), result)
    }

    /// One Proposal (#140), shared with `memory_propose_change` and `memory_propose_organization`. A replay of the
    /// same key and payload succeeds with `"replayed": true`.
    static func propose(
        _ context: AgentAuthorization, kind: AgentProposal.Kind, invocation: Invocation, path: String?, body: String?,
        keyPrefix: String
    ) throws -> AgentProposeResult {
        let value = invocation.value
        let id = try value("id").map { text -> UUID in
            guard let id = UUID(uuidString: text) else { throw AgentAccessError.invalidArgument("id") }
            return id
        }
        let request = AgentProposeRequest(
            // Without a key a retry can't be recognized, so each run saves another proposal.
            kind: kind, idempotencyKey: value("idempotency-key") ?? keyPrefix + UUID().uuidString,
            path: context.path ?? path, documentID: id, sources: invocation.options["source"] ?? [],
            expectedRevision: value("expected-revision"), body: body, destination: value("destination"),
            title: value("title"), reason: value("reason") ?? "", agent: value("agent") ?? "",
            session: value("session") ?? "", client: value("client") ?? "cli")
        return try AgentProposeService(authorization: context).propose(request)
    }

    /// The envelope type and the Library-relative Folder (`nil` for the type's entry folder) from
    /// `--folder` and `--type`. `agent-memories` (#206) is the grant's `Memory/Agents/<Key>/Memories`.
    static func destination(_ invocation: Invocation, scope: AgentScope) throws -> (type: String, folder: String?) {
        var type = invocation.value("type")
        var folder: String?
        if let given = invocation.value("folder").map(nfc) {
            if given.lowercased() == agentMemoriesKeyword {
                guard let agentFolder = scope.agentFolder else { throw AgentAccessError.noAgentFolder }
                if let type, AgentCreateService.entryFolder(for: type) != AgentMemoryContract.agentMemoriesFolder {
                    throw AgentAccessError.invalidRequest(
                        "The type “\(type)” can’t go in “\(given)”: only memory and decision can.")
                }
                type = type ?? "memory"
                folder = AgentMemoryContract.agentMemoriesRoot(agentFolder)
            } else if let keywordType = folderKeywords[given.lowercased()] {
                if let type, let entry = AgentCreateService.entryFolder(for: type),
                    entry.lowercased() != given.lowercased()
                {
                    throw AgentAccessError.invalidRequest("The type “\(type)” goes in “\(entry)”, not “\(given)”.")
                }
                type = type ?? keywordType
            } else {
                folder = given
            }
        }
        guard let type else { throw usage("“memory create” needs --folder or --type.") }
        return (type, folder)
    }

    /// The create itself, shared with `memory_create` (#136): the same request, recovery and result.
    /// `note` is the stderr line about recovered creates, if any.
    static func publish(
        _ context: AgentAuthorization, invocation: Invocation, type: String, folder: String?, body: String,
        keyPrefix: String
    ) throws -> (json: AgentJSON, note: String?, result: AgentCreateResult) {
        let value = invocation.value
        let request = AgentCreateRequest(
            // Without a key a retry can't be recognized, so each run creates a new document.
            idempotencyKey: value("idempotency-key") ?? keyPrefix + UUID().uuidString, type: type,
            title: nfc(value("title") ?? ""), body: body, agent: value("agent") ?? "", session: value("session") ?? "",
            client: value("client") ?? "cli", folder: folder, status: value("status"),
            observedAt: value("observed-at"), reviewAfter: value("review-after"),
            supersedes: invocation.options["supersedes"])
        let service = AgentCreateService(authorization: context)
        // Interrupted creates from earlier sessions are settled first. Details go to stderr only.
        let settled = (try? service.reconcile()) ?? []
        let result = try service.create(request)
        let receipt = try JSONSerialization.jsonObject(with: AgentReceipt.encoded(result.receipt))
        let fields: [String: Any] = [
            "outcome": result.outcome.rawValue, "replayed": result.replayed, "path": result.path ?? NSNull(),
            "receipt": receipt,
        ]
        let json = AgentJSON(sortingKeysOf: fields)
        guard !settled.isEmpty else { return (json, nil, result) }
        let counts = Dictionary(grouping: settled, by: \.outcome.rawValue).map { "\($0.value.count) \($0.key)" }
        return (json, "Recovered interrupted creates: " + counts.sorted().joined(separator: ", ") + ".", result)
    }

    /// This grant's receipts within its read folders, newest first. Never document text.
    static func activity(_ context: AgentAuthorization, invocation: Invocation) throws -> AgentJSON {
        var limit = defaultActivityLimit
        if let text = invocation.value("limit") {
            guard let parsed = Int(text), parsed >= 1 else { throw AgentAccessError.invalidArgument("limit") }
            limit = parsed
        }
        let since = try invocation.value("since").map { text -> Date in
            guard let date = AgentMemorySearchRequest.date(text) else {
                throw AgentAccessError.invalidArgument("since")
            }
            return date
        }
        let page = AgentCreateService(authorization: context).activity(
            since: since, limit: min(limit, context.grant.limits.maxResults))
        let receipts = try page.receipts.map {
            AgentJSON(sortingKeysOf: try JSONSerialization.jsonObject(with: AgentReceipt.encoded($0)))
        }
        return .object([("receipts", .array(receipts)), ("total", .int(page.total))])
    }

    /// Paths, sizes and dates only — no document bodies. Hidden items, links and special files are
    /// skipped, and a read folder reached through a link is skipped entirely. Read folders can overlap (#228), so
    /// each path is listed once (#264).
    static func list(_ context: AgentAuthorization) throws -> AgentJSON {
        let dates = ISO8601DateFormatter()
        var documents: [AgentSecureFiles.Document] = []
        var seen: Set<String> = []
        for root in context.scope.readRoots {
            do {
                documents += try AgentSecureFiles.documents(library: context.library, under: root).filter {
                    seen.insert(nfc($0.path)).inserted
                }
            } catch let error as AgentAccessError where error == .invalidPath {
                continue
            }
        }
        let rows = context.scope.readable(documents, path: \.path).sorted { $0.path < $1.path }.map {
            ["path": $0.path, "size": $0.size, "modified": dates.string(from: $0.modified)] as [String: Any]
        }
        let fields: [String: Any] = ["project": context.scope.project, "documents": rows]
        return AgentJSON(sortingKeysOf: fields)
    }

    /// #282: a `--memory-id` value, shared with `memory_read`'s `memoryId`. Any non-empty text without white space
    /// or control characters, because `memory_id` has no fixed format.
    static func memoryID(_ text: String?) throws -> String? {
        guard let text else { return nil }
        guard !text.isEmpty,
            !text.unicodeScalars.contains(where: {
                CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
            })
        else { throw AgentAccessError.invalidArgument("memory-id") }
        return text
    }

    /// `--type`/`--status` repeat or take comma-separated lists; dates are `2026-10-07` or ISO 8601
    /// timestamps. The query is the command's words, joined by spaces.
    static func searchRequest(_ invocation: Invocation, query: [String]) throws -> AgentMemorySearchRequest {
        let value = invocation.value
        let list = { (key: String) -> [String] in
            (invocation.options[key] ?? []).flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let date = { (key: String) throws -> Date? in
            guard let text = value(key) else { return nil }
            guard let date = AgentMemorySearchRequest.date(text) else { throw AgentAccessError.invalidArgument(key) }
            return date
        }
        var limit = AgentMemorySearchRequest.defaultLimit
        if let text = value("limit") {
            guard let parsed = Int(text) else { throw AgentAccessError.invalidArgument("limit") }
            limit = parsed
        }
        var recentDays = AgentMemorySearchRequest.defaultRecentDays
        if let text = value("recent-days") {
            guard let parsed = Int(text), (0...AgentMemorySearchRequest.maxRecentDays).contains(parsed) else {
                throw AgentAccessError.invalidArgument("recent-days")
            }
            recentDays = parsed
        }
        return AgentMemorySearchRequest(
            query: query.joined(separator: " "), project: value("project").map(nfc), types: list("type"),
            statuses: list("status"), createdAfter: try date("created-after"),
            createdBefore: try date("created-before"), limit: limit,
            mode: invocation.flags.contains("ranked") ? .ranked : .default,
            includeArchived: invocation.flags.contains("include-archived"), recentDays: recentDays,
            cursor: value("cursor"))
    }
}

extension AgentAccessError {
    /// Anything the helper didn't expect. Never carries the underlying error's text.
    static let internalError = Self(
        code: "internal_error", title: "Can’t Complete Request",
        message: "Silkweb’s helper ran into an unexpected problem. Try again.")
}

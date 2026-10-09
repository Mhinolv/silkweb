import Darwin
import Foundation

/// `silkweb grant init` (#186, `docs/agent-memory.md` › Setting up a grant): the owner's way to add
/// one project grant to `agent-grants.json` without editing JSON. It asks for whatever the flags
/// leave out, merges into the existing file (other grants keep their meaning), never widens an
/// existing grant, and prints the MCP install lines for each client. It reads the Library's volume
/// details but never writes inside the Library.
///
/// Unlike `silkweb memory`, stdout is plain text for a person: the summary and install lines.
/// Prompts and `silkweb: …` messages go to stderr.
public enum AgentGrantInit {
    /// Where prompts are shown and answers read. `write` goes to stderr straight away, so a prompt
    /// appears before the helper waits for its answer.
    public struct Console {
        public var isTerminal: Bool
        public var readLine: () -> String?
        public var write: (String) -> Void

        public init(isTerminal: Bool, readLine: @escaping () -> String?, write: @escaping (String) -> Void) {
            self.isTerminal = isTerminal
            self.readLine = readLine
            self.write = write
        }

        /// The process's own stdin and stderr.
        public static var standard: Console {
            Console(
                isTerminal: isatty(STDIN_FILENO) == 1, readLine: { Swift.readLine(strippingNewline: true) },
                write: { FileHandle.standardError.write(Data($0.utf8)) })
        }
    }

    /// What a run did to the stored grant.
    public enum Outcome: Equatable, Sendable {
        case added
        case unchanged
        case narrowed(from: AgentGrant.Access)
    }

    public static let help = """
        USAGE
          silkweb grant init [--library <PATH>] [--project <KEY>] [--access read|read-create]
                             [--dry-run] [--grants <FILE>]

        Sets up agent access for one project in agent-grants.json. Asks for anything the options
        leave out. Never widens an existing grant and never writes inside the Library.

        OPTIONS
          --library <PATH>    The Library folder agents may use (~ is expanded)
          --project <KEY>     Project key, the Folder name under Memory/Projects
          --access <LEVEL>    read (Read Only) or read-create (Read and Create)
          --dry-run           Show the grant and install commands without saving anything
          --grants <FILE>     Write another grants file, for testing
          --help              Show this help

        Saving to the real grants file needs a terminal, so an agent can't grant itself access.
        Exit status: 0 ok, 1 cancelled, 64 usage, 74 I/O, 77 access.

        """

    static let placeholderHelper = "<SILKWEB_HELPER>"
    static let notLocalWarning =
        "Agents can read; creating stays off until the Library is on a local APFS or HFS+ disk."

    private static let options: Set<String> = ["library", "project", "access", "grants"]
    private static let flags: Set<String> = ["dry-run", "help"]

    /// A failure with its exit status and the one line shown on stderr.
    struct Failure: Error, Equatable {
        var status: Int32
        var message: String

        static func usage(_ message: String) -> Failure {
            Failure(status: 64, message: message + " Run “silkweb grant init --help” for usage.")
        }

        static let cancelled = Failure(status: 1, message: "Nothing was saved.")
        static let ownerOnly = Failure(
            status: 77, message: "Only the owner can save agent access. Run this in Terminal.")
        static let folderMissing = Failure(status: 74, message: "That folder doesn’t exist.")
        static let folderUnreadable = Failure(status: 74, message: "Silkweb can’t read that folder.")
    }

    /// The Library as the grant will store it, and how its volume qualifies.
    struct Library: Equatable {
        var url: URL
        var filesystem: AgentFilesystem
    }

    // MARK: Running

    /// `arguments` starts with `grant`. `executable` is the helper's `argv[0]`, used for the install
    /// lines; `currentDirectory` resolves relative paths.
    public static func run(
        _ arguments: [String], console: Console, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment, executable: String?,
        currentDirectory: String = FileManager.default.currentDirectoryPath, now: Date = Date()
    ) -> AgentHelper.Output {
        do {
            let invocation = try AgentHelper.parse(arguments, flags: flags)
            if invocation.flags.contains("help") { return AgentHelper.Output(status: 0, stdout: help, stderr: "") }
            guard invocation.words.count >= 2 else { throw Failure.usage("Choose a grant command: init.") }
            guard invocation.words[1] == "init" else { throw Failure.usage("That isn’t a grant command. Use init.") }
            guard invocation.words.count == 2 else { throw Failure.usage("“grant init” takes no other arguments.") }
            for (option, values) in invocation.options.sorted(by: { $0.key < $1.key }) {
                guard options.contains(option) else {
                    throw Failure.usage("The option “--\(option)” isn’t valid for “grant init”.")
                }
                guard values.count == 1 else { throw Failure.usage("The option “--\(option)” can only be given once.") }
            }
            let stdout = try initialize(
                invocation, console: console, home: home, environment: environment, executable: executable,
                currentDirectory: currentDirectory, now: now)
            return AgentHelper.Output(status: 0, stdout: stdout, stderr: "")
        } catch let failure as Failure {
            return AgentHelper.Output(status: failure.status, stdout: "", stderr: "silkweb: " + failure.message + "\n")
        } catch let failure as AgentAccessError {
            return AgentHelper.Output(
                status: AgentHelper.exitStatus(for: failure.code), stdout: "",
                stderr: "silkweb: " + failure.message + "\n")
        } catch {
            return AgentHelper.Output(
                status: 70, stdout: "", stderr: "silkweb: " + AgentAccessError.internalError.message + "\n")
        }
    }

    private static func initialize(
        _ invocation: AgentHelper.Invocation, console: Console, home: URL, environment: [String: String],
        executable: String?, currentDirectory: String, now: Date
    ) throws -> String {
        let dryRun = invocation.flags.contains("dry-run")
        var access = try invocation.value("access").map { text -> AgentGrant.Access in
            switch text {
            case "read", "read-only": return .read
            case "read-create": return .readCreate
            default: throw Failure.usage("The option “--access” must be read or read-create.")
            }
        }
        let missing = ["library", "project", "access"].filter { invocation.value($0) == nil }
        let interactive = !missing.isEmpty
        // Never wait for answers that can't come.
        if let first = missing.first, !console.isTerminal { throw Failure.usage("“grant init” needs --\(first).") }

        let realURL = AgentGrantFile.defaultURL(home: home)
        let grantsURL = invocation.value("grants").map { absoluteURL($0, from: currentDirectory) } ?? realURL
        // An agent's shell has no terminal, so it can't save access for itself, even with every flag.
        if !dryRun, !console.isTerminal, isSameFile(grantsURL, realURL) { throw Failure.ownerOnly }

        // Read the file first, so a broken or newer one is reported before any questions.
        let store = AgentGrantStore(url: grantsURL)
        var file: AgentGrantFile
        do {
            file = try store.load()
        } catch let error as AgentAccessError where error.code == "no_grants_file" {
            file = AgentGrantFile()
        }

        let ask = { (prompt: String) throws -> String in
            console.write(prompt)
            guard let answer = console.readLine() else {
                console.write("\n")
                throw Failure.cancelled
            }
            return answer.trimmingCharacters(in: .whitespaces)
        }

        let library: Library
        if let path = invocation.value("library") {
            library = try resolveLibrary(path, from: currentDirectory)
        } else {
            var resolved: Library?
            while resolved == nil {
                let answer = try ask("Library folder: ")
                do {
                    resolved = try resolveLibrary(answer, from: currentDirectory)
                } catch let failure as Failure {
                    console.write("  " + failure.message + "\n")
                }
            }
            library = resolved!
        }
        if interactive {
            console.write(
                library.filesystem == .qualified
                    ? "  ✓ \(library.url.path) — local disk. Agents can read and create.\n"
                    : "  ! \(library.url.path) — not a local disk. \(notLocalWarning)\n")
        }

        let project: String
        if let given = invocation.value("project") {
            guard let valid = validProject(given) else { throw Failure(status: 64, message: invalidProjectMessage) }
            project = valid
        } else {
            var valid: String?
            while valid == nil {
                valid = validProject(try ask("Project key: "))
                if valid == nil { console.write("  " + invalidProjectMessage + "\n") }
            }
            project = valid!
            console.write("  Agents use \(AgentMemoryContract.projectRoot(project)). Nothing is created now.\n")
        }

        if access == nil {
            let preferred = library.filesystem == .qualified ? 2 : 1
            console.write(
                """
                Access:
                  1  Read Only        Agents search and read.
                  2  Read and Create  Agents can also add documents. They never edit or delete.

                """)
            while access == nil {
                switch try ask("Choose 1 or 2 [\(preferred)]: ") {
                case "1": access = .read
                case "2": access = .readCreate
                case "": access = preferred == 1 ? .read : .readCreate
                default: console.write("  Choose 1 or 2.\n")
                }
            }
        }
        guard let access else { throw Failure.cancelled }

        let merged = try merge(file, project: project, library: library.url, access: access, now: now)
        let helper = helperPath(executable, environment: environment, currentDirectory: currentDirectory)
        let install = installBlock(helper: helper, project: project)
        if dryRun {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let json = String(decoding: try encoder.encode(merged.grant), as: UTF8.self)
            return "Dry run. Nothing was saved.\n" + json + "\n\n" + install
        }
        let fileName = displayPath(grantsURL, home: home)
        if interactive, merged.outcome != .unchanged {
            let answer = try ask("Save to \(fileName)? [y/N] ").lowercased()
            guard answer == "y" || answer == "yes" else { return "Nothing was saved.\n" }
        }
        if merged.outcome != .unchanged {
            do {
                try merged.file.write(to: grantsURL)
            } catch {
                throw Failure(status: 74, message: "Silkweb couldn’t save “\(fileName)”. Nothing was saved.")
            }
        }
        return summary(
            merged.grant, outcome: merged.outcome, filesystem: library.filesystem, fileName: fileName) + "\n"
            + install
    }

    // MARK: Merging

    /// Adds `project`'s grant, or keeps or narrows the existing one. Anything that would widen it — more
    /// access, another Library, or turning a revoked grant back on — is refused, and the caller
    /// saves nothing. Labels, limits and extra read folders are never changed (the command has no
    /// way to set them), so they can't be widened either. Other grants are kept as they are.
    static func merge(
        _ file: AgentGrantFile, project: String, library: URL, access: AgentGrant.Access, now: Date
    ) throws -> (file: AgentGrantFile, grant: AgentGrant, outcome: Outcome) {
        var file = file
        file.version = AgentGrantFile.currentVersion
        guard let index = file.grants.firstIndex(where: { $0.project == project }) else {
            // Whole seconds, as the file stores them, so a dry run shows exactly what is saved.
            let created = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
            let grant = AgentGrant(
                project: project, library: LibraryLocation(path: library.path), access: access, createdAt: created)
            file.grants.append(grant)
            return (file, grant, .added)
        }
        var grant = file.grants[index]
        let refuse = { (reason: String) in
            Failure(
                status: 77,
                message: "The grant “\(project)” \(reason). grant init never widens access; edit agent-grants.json "
                    + "to change it. Nothing was saved.")
        }
        if grant.isRevoked { throw refuse("is turned off") }
        if !sameLibrary(grant.library, library) {
            throw refuse("already uses another Library (\(grant.library.path ?? "a saved location"))")
        }
        if grant.access == .read, access == .readCreate {
            throw refuse("already exists with \(grant.access.displayName) access")
        }
        guard grant.access != access else { return (file, grant, .unchanged) }
        let previous = grant.access
        grant.access = access
        file.grants[index] = grant
        return (file, grant, .narrowed(from: previous))
    }

    /// The stored location names `library`: by its path, or by where its bookmark or path resolves.
    static func sameLibrary(_ location: LibraryLocation, _ library: URL) -> Bool {
        let target = canonical(library)
        if let path = location.path, !path.isEmpty, canonical(URL(fileURLWithPath: path)) == target { return true }
        let restored = try? LibraryLocationRestore.restore(location, save: { LibraryLocation(path: $0.path) })
        return restored.map { canonical($0.url) == target } ?? false
    }

    private static func canonical(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    // MARK: Inputs

    /// `~` expanded, relative paths taken from the current directory, links resolved (as the app
    /// saves Library locations), and checked to be a readable folder.
    static func resolveLibrary(_ path: String, from currentDirectory: String) throws -> Library {
        guard !path.isEmpty else { throw Failure.folderMissing }
        let url = URL(fileURLWithPath: canonical(absoluteURL(path, from: currentDirectory)))
        do {
            try LibraryLocationRestore.validateDirectory(url, scoped: false)
        } catch let error as LibraryLocationError {
            throw error == .notFound ? Failure.folderMissing : Failure.folderUnreadable
        }
        return Library(url: url, filesystem: AgentFilesystem.probe(url))
    }

    static let invalidProjectMessage = AgentScopeError.invalidProject.message

    /// A project key is one valid Folder name, compared in NFC like Library paths.
    static func validProject(_ text: String) -> String? {
        let key = AgentHelper.nfc(text)
        return (try? LibraryMutations.validateName(key)) == key ? key : nil
    }

    static func absoluteURL(_ path: String, from currentDirectory: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath
        let absolute =
            expanded.hasPrefix("/") ? expanded : (currentDirectory as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute).standardizedFileURL
    }

    /// Whether `url` is the real grants file however it's spelled: the same file or the same name
    /// in the same folder (case-insensitive, as on the default volume), or the same resolved path.
    static func isSameFile(_ url: URL, _ real: URL) -> Bool {
        if canonical(url).compare(canonical(real), options: [.caseInsensitive]) == .orderedSame { return true }
        let identity = { (path: String) -> [Int]? in
            var info = stat()
            return stat(path, &info) == 0 ? [Int(info.st_dev), Int(info.st_ino)] : nil
        }
        if let file = identity(url.path), file == identity(real.path) { return true }
        if let folder = identity(url.deletingLastPathComponent().path),
            folder == identity(real.deletingLastPathComponent().path)
        {
            return url.lastPathComponent.compare(real.lastPathComponent, options: [.caseInsensitive]) == .orderedSame
        }
        return false
    }

    /// `argv[0]` made absolute, looked up on `PATH` when it has no slash. Links aren't resolved, so
    /// the stable `~/.local/bin/silkweb` stays in the install lines. Nil when it can't be found.
    static func helperPath(_ executable: String?, environment: [String: String], currentDirectory: String) -> String? {
        guard let executable, !executable.isEmpty else { return nil }
        if executable.contains("/") {
            let url = absoluteURL(executable, from: currentDirectory)
            return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
        }
        for folder in (environment["PATH"] ?? "").split(separator: ":") where folder.hasPrefix("/") {
            let candidate = URL(fileURLWithPath: String(folder)).appendingPathComponent(executable).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    // MARK: Output

    static func displayPath(_ url: URL, home: URL) -> String {
        let homePath = home.standardizedFileURL.path
        return url.path.hasPrefix(homePath + "/") ? "~" + url.path.dropFirst(homePath.count) : url.path
    }

    static func summary(_ grant: AgentGrant, outcome: Outcome, filesystem: AgentFilesystem, fileName: String)
        -> String
    {
        var lines: [String]
        switch outcome {
        case .unchanged: lines = ["Agent access for “\(grant.project)” is already set up."]
        case .added: lines = ["Saved agent access for “\(grant.project)” (\(grant.access.displayName))."]
        case .narrowed(let previous):
            lines = [
                "Saved agent access for “\(grant.project)” (\(grant.access.displayName)).",
                "Changed access: \(previous.displayName) → \(grant.access.displayName).",
            ]
        }
        let disk = filesystem == .qualified ? "local disk" : "not a local disk"
        lines.append("  Library  \(grant.library.path ?? "") — \(disk)")
        if filesystem == .unqualified, grant.access == .readCreate { lines.append("  ! " + notLocalWarning) }
        lines.append("  Folder   " + AgentMemoryContract.projectRoot(grant.project))
        lines.append("  File     " + fileName)
        return lines.joined(separator: "\n") + "\n"
    }

    /// The `agent-packages/README.md` › Install commands, byte for byte, with the helper path and
    /// project key filled in.
    static func installBlock(helper: String?, project: String) -> String {
        let shownHelper = helper ?? placeholderHelper
        let helperWord = helper.map(shellQuoted) ?? placeholderHelper
        let grant = shellQuoted(project)
        let substitutions =
            "-e 's|<SILKWEB_HELPER>|\(sedReplacement(shownHelper))|' -e 's|<GRANT_ID>|\(sedReplacement(project))|'"
        var lines = [
            "Add the MCP server (user scope):",
            "  Claude Code",
            "    claude mcp add --scope user silkweb -- \(helperWord) mcp --grant \(grant)",
            "  Codex CLI",
            "    codex mcp add silkweb -- \(helperWord) mcp --grant \(grant)",
            "  Gemini CLI",
            "    cp -R agent-packages/gemini/silkweb-memory/ \"$TMPDIR/silkweb-memory\"",
            "    sed -i '' \(substitutions) \"$TMPDIR/silkweb-memory/gemini-extension.json\" \"$TMPDIR/silkweb-memory/GEMINI.md\"",
            "    gemini extensions install \"$TMPDIR/silkweb-memory\"",
            "",
            "Then install the skills: agent-packages/README.md › Install.",
            "Check: \(helperWord) memory capabilities --grant \(grant) --pretty",
        ]
        if helper == nil { lines.append("Replace \(placeholderHelper) with the helper’s absolute path.") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// One shell word: as is when it's plain, otherwise in single quotes.
    static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A `sed` replacement for `s|…|…|` inside a single-quoted shell argument. `"` and `\` are
    /// escaped for JSON first, because the value lands in a string in `gemini-extension.json`.
    static func sedReplacement(_ text: String) -> String {
        var escaped = ""
        let json = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        for character in json {
            switch character {
            case "\\", "&", "|": escaped += "\\" + String(character)
            case "'": escaped += "'\\''"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}

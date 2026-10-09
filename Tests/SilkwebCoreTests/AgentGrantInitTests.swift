import Foundation
import XCTest

@testable import SilkwebCore

/// `silkweb grant init` (#186): interactive and flag modes, merging into an existing grants file,
/// idempotency, widen refusal, dry runs, unqualified Libraries, the terminal rule and `--grants`
/// isolation, plus the install lines it prints.
final class AgentGrantInitTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private var root: URL!
    private var home: URL!
    private var library: URL!
    private var grantsURL: URL!
    private var realURL: URL { AgentGrantFile.defaultURL(home: home) }
    private let now = Date(timeIntervalSince1970: 1_791_450_000.75)
    /// The helper as `argv[0]` names it: a bare `silkweb` found on `PATH`.
    private var helper: String { root.appendingPathComponent("bin/silkweb").path }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentGrantInit-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        home = root.appendingPathComponent("home")
        library = root.appendingPathComponent("Writing Library 日本語")
        grantsURL = root.appendingPathComponent("grants.json")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("# Diary\n".utf8).write(to: library.appendingPathComponent("Notes/Diary.md"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: helper))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs `grant init …`. `answers` are the lines typed at the prompts (nil at the end is EOF);
    /// `grants: nil` targets the real file under the temporary home.
    private func run(
        _ arguments: [String], answers: [String] = [], terminal: Bool = false, grants: URL? = nil,
        defaultGrants: Bool = true, executable: String? = "silkweb"
    ) -> (output: AgentHelper.Output, prompts: String) {
        var remaining = answers
        var prompts = ""
        let console = AgentGrantInit.Console(
            isTerminal: terminal, readLine: { remaining.isEmpty ? nil : remaining.removeFirst() },
            write: { prompts += $0 })
        let target = defaultGrants ? ["--grants", (grants ?? grantsURL).path] : []
        let output = AgentGrantInit.run(
            ["grant", "init"] + arguments + target, console: console, home: home,
            environment: ["PATH": "/usr/bin:" + root.appendingPathComponent("bin").path],
            executable: executable, currentDirectory: root.path, now: now)
        return (output, prompts)
    }

    private func flags(_ project: String = "Silkweb", access: String = "read-create", library: URL? = nil) -> [String] {
        ["--library", (library ?? self.library).path, "--project", project, "--access", access]
    }

    private func load(_ url: URL? = nil) throws -> AgentGrantFile {
        try JSONDecoder().decode(AgentGrantFile.self, from: Data(contentsOf: url ?? grantsURL))
    }

    /// Every item below the Library with its size and modification date, to prove nothing was written there.
    private func librarySnapshot() throws -> [String] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let items = try XCTUnwrap(FileManager.default.enumerator(at: library, includingPropertiesForKeys: keys))
        return try items.compactMap { $0 as? URL }.map {
            let values = try $0.resourceValues(forKeys: Set(keys))
            return "\($0.path) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.sorted() + [
            "\(try library.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!)"
        ]
    }

    private func installBlock(_ project: String = "Silkweb") -> String {
        """
        Add the MCP server (user scope):
          Claude Code
            claude mcp add --scope user silkweb -- \(helper) mcp --grant \(project)
          Codex CLI
            codex mcp add silkweb -- \(helper) mcp --grant \(project)
          Gemini CLI
            cp -R agent-packages/gemini/silkweb-memory/ "$TMPDIR/silkweb-memory"
            sed -i '' -e 's|<SILKWEB_HELPER>|\(helper)|' -e 's|<GRANT_ID>|\(project)|' "$TMPDIR/silkweb-memory/gemini-extension.json" "$TMPDIR/silkweb-memory/GEMINI.md"
            gemini extensions install "$TMPDIR/silkweb-memory"

        Then install the skills: agent-packages/README.md › Install.
        Check: \(helper) memory capabilities --grant \(project) --pretty

        """
    }

    // MARK: Modes

    func testFlagModeAddsADefaultGrantAndPrintsTheInstallBlock() throws {
        let before = try librarySnapshot()
        let (output, prompts) = run(flags())
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertEqual(output.stderr, "")
        XCTAssertEqual(prompts, "", "flag mode asks nothing")
        XCTAssertEqual(
            output.stdout,
            """
            Saved agent access for “Silkweb” (Read and Create).
              Library  \(library.path) — local disk
              Folder   Memory/Projects/Silkweb
              File     \(grantsURL.path)

            """ + "\n" + installBlock())

        let file = try load()
        XCTAssertEqual(file.version, 1)
        XCTAssertEqual(
            file.grants,
            [
                AgentGrant(
                    project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreate,
                    createdAt: Date(timeIntervalSince1970: 1_791_450_000))
            ])
        let raw = try XCTUnwrap(String(data: Data(contentsOf: grantsURL), encoding: .utf8))
        XCTAssertFalse(raw.contains("bookmark"), "library.path only")
        XCTAssertFalse(raw.contains("label"), "default label")
        XCTAssertEqual(try librarySnapshot(), before, "nothing is written inside the Library")
        XCTAssertFalse(FileManager.default.fileExists(atPath: realURL.path), "--grants never touches the real file")
        // The saved grant works with the memory commands straight away.
        let capabilities = AgentHelper.run(["memory", "capabilities", "--grants", grantsURL.path], home: home)
        XCTAssertEqual(capabilities.status, 0, capabilities.stdout)
        XCTAssertEqual(try librarySnapshot(), before)
    }

    func testInteractiveModeAsksForWhatsMissingAndSavesTheSameRecord() throws {
        let flagGrants = root.appendingPathComponent("flag.json")
        XCTAssertEqual(run(flags(), grants: flagGrants).output.status, 0)

        // A relative path is taken from the current directory.
        let (output, prompts) = run([], answers: ["Writing Library 日本語", "Silkweb", "", "y"], terminal: true)
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertEqual(output.stderr, "")
        XCTAssertEqual(try Data(contentsOf: grantsURL), try Data(contentsOf: flagGrants))
        XCTAssertEqual(
            prompts,
            """
            Library folder:   ✓ \(library.path) — local disk. Agents can read and create.
            Project key:   Agents use Memory/Projects/Silkweb. Nothing is created now.
            Access:
              1  Read Only        Agents search and read.
              2  Read and Create  Agents can also add documents. They never edit or delete.

            """ + "Choose 1 or 2 [2]: Save to \(grantsURL.path)? [y/N] ")
        XCTAssertTrue(output.stdout.hasPrefix("Saved agent access for “Silkweb” (Read and Create).\n"))
        XCTAssertTrue(output.stdout.hasSuffix(installBlock()))
    }

    func testInteractiveModeRepromptsAfterInvalidAnswersAndOnlyAsksForMissingFlags() throws {
        let (output, prompts) = run(
            ["--library", library.path], answers: ["a/b", ".hidden", "Notes", "3", "1", "yes"], terminal: true)
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertFalse(prompts.contains("Library folder:"), "--library was given")
        XCTAssertEqual(prompts.components(separatedBy: "The project name isn’t a valid folder name.").count, 3)
        XCTAssertTrue(prompts.contains("  Choose 1 or 2.\n"))
        XCTAssertEqual(try load().grants.map(\.access), [.read])

        let missing = run(
            ["--project", "Other", "--access", "read"],
            answers: [root.appendingPathComponent("nope").path, grantsURL.path, library.path, "y"], terminal: true)
        XCTAssertEqual(missing.output.status, 0, missing.output.stderr)
        XCTAssertEqual(missing.prompts.components(separatedBy: "  That folder doesn’t exist.\n").count, 3)
        XCTAssertFalse(missing.prompts.contains("Project key:"))
        XCTAssertFalse(missing.prompts.contains("Choose 1 or 2"))
        XCTAssertEqual(try load().grants.map(\.project), ["Notes", "Other"])
    }

    func testAnsweringNoOrEndOfInputSavesNothing() throws {
        let declined = run([], answers: [library.path, "Silkweb", "2", "n"], terminal: true)
        XCTAssertEqual(declined.output.status, 0)
        XCTAssertEqual(declined.output.stdout, "Nothing was saved.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))

        let defaulted = run([], answers: [library.path, "Silkweb", "2", ""], terminal: true)
        XCTAssertEqual(defaulted.output.stdout, "Nothing was saved.\n", "the default answer is No")

        for answers in [[], [library.path], [library.path, "Silkweb"], [library.path, "Silkweb", "2"]] {
            let ended = run([], answers: answers, terminal: true)
            XCTAssertEqual(ended.output.status, 1, "\(answers)")
            XCTAssertEqual(ended.output.stdout, "")
            XCTAssertEqual(ended.output.stderr, "silkweb: Nothing was saved.\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))
        }
    }

    // MARK: Merging

    func testMergeAppendsKeepsOtherGrantsAndReRunsAreByteIdentical() throws {
        let other = AgentGrant(
            project: "Notes", library: LibraryLocation(bookmark: Data([1, 2, 3]), path: "/Volumes/NAS/Notes"),
            access: .read, extraReadFolders: ["Reference"], label: "Team notes",
            limits: AgentGrantLimits(maxReadBytes: 10, maxResults: 5, requestsPerMinute: 3, maxCreateBytes: 7),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), revokedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
        try AgentGrantFile(grants: [other]).write(to: grantsURL)

        XCTAssertEqual(run(flags()).output.status, 0)
        let merged = try load()
        XCTAssertEqual(merged.grants.map(\.project), ["Notes", "Silkweb"])
        XCTAssertEqual(merged.grants[0], other, "unrelated grants keep every field")

        let saved = try Data(contentsOf: grantsURL)
        let modified = try FileManager.default.attributesOfItem(atPath: grantsURL.path)[.modificationDate] as? Date
        for arguments in [
            flags(),
            flags(access: "read-create", library: library.appendingPathComponent("../\(library.lastPathComponent)")),
        ] {
            let (output, _) = run(arguments)
            XCTAssertEqual(output.status, 0, output.stderr)
            XCTAssertTrue(output.stdout.hasPrefix("Agent access for “Silkweb” is already set up.\n"), output.stdout)
            XCTAssertTrue(output.stdout.hasSuffix(installBlock()))
        }
        // Interactive re-runs don't ask to save when nothing would change.
        let interactive = run([], answers: [library.path, "Silkweb", ""], terminal: true)
        XCTAssertEqual(interactive.output.status, 0, interactive.output.stderr)
        XCTAssertFalse(interactive.prompts.contains("Save to"))
        XCTAssertEqual(try Data(contentsOf: grantsURL), saved)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: grantsURL.path)[.modificationDate] as? Date, modified)
    }

    func testWideningIsRefusedAndLeavesTheFileUnchanged() throws {
        let otherLibrary = root.appendingPathComponent("Other Library")
        try FileManager.default.createDirectory(at: otherLibrary, withIntermediateDirectories: true)
        let cases: [(AgentGrant, [String], String)] = [
            (
                AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path), access: .read),
                flags(), "The grant “Silkweb” already exists with Read Only access."
            ),
            (
                AgentGrant(project: "Silkweb", library: LibraryLocation(path: otherLibrary.path), access: .read),
                flags(access: "read"), "The grant “Silkweb” already uses another Library (\(otherLibrary.path))."
            ),
            (
                AgentGrant(
                    project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreate,
                    revokedAt: Date()), flags(), "The grant “Silkweb” is turned off."
            ),
            (
                AgentGrant(
                    project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreate,
                    revokedAt: Date()), flags(access: "read"), "The grant “Silkweb” is turned off."
            ),
        ]
        for (existing, arguments, start) in cases {
            try AgentGrantFile(grants: [existing]).write(to: grantsURL)
            let before = try Data(contentsOf: grantsURL)
            for extra in [[], ["--dry-run"]] {
                let (output, _) = run(arguments + extra)
                XCTAssertEqual(output.status, 77, "\(arguments + extra)")
                XCTAssertEqual(output.stdout, "")
                XCTAssertEqual(
                    output.stderr,
                    "silkweb: " + start.dropLast()
                        + ". grant init never widens access; edit agent-grants.json to change it. Nothing was saved.\n")
                XCTAssertEqual(try Data(contentsOf: grantsURL), before)
            }
        }
    }

    func testNarrowingIsAllowedAndKeepsLimitsFoldersAndLabel() throws {
        let existing = AgentGrant(
            project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreate,
            extraReadFolders: ["Notes"], label: "Mine", limits: AgentGrantLimits(maxResults: 3),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000))
        try AgentGrantFile(grants: [existing]).write(to: grantsURL)
        let (output, _) = run(flags(access: "read-only"))
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(
            output.stdout.hasPrefix(
                "Saved agent access for “Silkweb” (Read Only).\nChanged access: Read and Create → Read Only.\n"),
            output.stdout)
        var narrowed = existing
        narrowed.access = .read
        XCTAssertEqual(try load().grants, [narrowed])
        // Read Only → Read and Create is now a widening.
        XCTAssertEqual(run(flags()).output.status, 77)
    }

    func testDefaultLimitsNeverReplaceCustomOnes() throws {
        let existing = AgentGrant(
            project: "Silkweb", library: LibraryLocation(path: library.path), access: .readCreate,
            limits: AgentGrantLimits(maxReadBytes: 1))
        try AgentGrantFile(grants: [existing]).write(to: grantsURL)
        XCTAssertEqual(run(flags()).output.status, 0)
        XCTAssertEqual(try load().grants, [existing])
    }

    func testABrokenOrNewerGrantsFileIsNeverOverwritten() throws {
        for content in ["{not json", #"{"version":2,"grants":[]}"#] {
            try Data(content.utf8).write(to: grantsURL)
            let (output, _) = run(flags())
            XCTAssertEqual(output.status, 77, content)
            XCTAssertEqual(try String(contentsOf: grantsURL, encoding: .utf8), content)
        }
    }

    /// A grants file saved by the #129 spike (no version, `read-only`, minimal keys) still loads and merges.
    func testFilesFromEarlierBuildsStillLoadAndMerge() throws {
        try Data(
            #"{"grants":[{"project":"Silkweb","library":{"path":"\#(library.path)"},"access":"read-only"}]}"#.utf8
        ).write(to: grantsURL)
        let (output, _) = run(flags(access: "read"))
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(output.stdout.hasPrefix("Agent access for “Silkweb” is already set up.\n"))
        XCTAssertEqual(run(flags("Next", access: "read")).output.status, 0)
        XCTAssertEqual(try load().grants.map(\.project), ["Silkweb", "Next"])
    }

    // MARK: Dry run

    func testDryRunPrintsTheGrantAndInstallLinesWithoutWritingAnything() throws {
        let nested = root.appendingPathComponent("not/yet/grants.json")
        let (output, _) = run(flags() + ["--dry-run"], grants: nested)
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("not").path))
        let parts = output.stdout.components(separatedBy: "\n\nAdd the MCP server")
        XCTAssertTrue(parts[0].hasPrefix("Dry run. Nothing was saved.\n{\n"), output.stdout)
        let json = String(parts[0].dropFirst("Dry run. Nothing was saved.\n".count))
        let grant = try JSONDecoder().decode(AgentGrant.self, from: Data(json.utf8))
        XCTAssertTrue(output.stdout.hasSuffix("\n\n" + installBlock()))

        XCTAssertEqual(run(flags()).output.status, 0)
        XCTAssertEqual(try load().grants, [grant], "a dry run shows exactly what is saved")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        XCTAssertEqual(json, String(decoding: try encoder.encode(grant), as: UTF8.self))

        // A dry run needs no terminal, even for the real file, and still writes nothing.
        let real = run(flags() + ["--dry-run"], defaultGrants: false)
        XCTAssertEqual(real.output.status, 0, real.output.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: realURL.deletingLastPathComponent().path))
    }

    // MARK: Qualification

    func testReadCreateOnAnUnqualifiedLibraryIsSavedWithAWarning() throws {
        // Sync folders are unqualified whatever the volume (AgentFilesystem.classify).
        let synced = root.appendingPathComponent("Library/Mobile Documents/Writing")
        try FileManager.default.createDirectory(at: synced, withIntermediateDirectories: true)
        XCTAssertEqual(AgentFilesystem.probe(synced), .unqualified)

        let (output, _) = run(flags(library: synced))
        XCTAssertEqual(output.status, 0, output.stderr)
        XCTAssertTrue(
            output.stdout.hasPrefix(
                """
                Saved agent access for “Silkweb” (Read and Create).
                  Library  \(synced.path) — not a local disk
                  ! Agents can read; creating stays off until the Library is on a local APFS or HFS+ disk.

                """), output.stdout)
        XCTAssertEqual(try load().grants.map(\.access), [.readCreate])

        let readOnly = run(flags("Plain", access: "read", library: synced))
        XCTAssertFalse(readOnly.output.stdout.contains("! "), "no warning for Read Only")

        // Interactively the check line warns and the default becomes Read Only.
        let interactive = run([], answers: [synced.path, "Asked", "", "y"], terminal: true)
        XCTAssertEqual(interactive.output.status, 0, interactive.output.stderr)
        XCTAssertTrue(
            interactive.prompts.contains(
                "  ! \(synced.path) — not a local disk. Agents can read; creating stays off until the Library is on a local APFS or HFS+ disk.\n"
            ), interactive.prompts)
        XCTAssertTrue(interactive.prompts.contains("Choose 1 or 2 [1]: "))
        XCTAssertEqual(try load().grant(for: "Asked")?.access, .read)
        let chosen = run([], answers: [synced.path, "Chosen", "2", "y"], terminal: true)
        XCTAssertTrue(chosen.output.stdout.contains("  ! Agents can read;"))
        XCTAssertEqual(try load().grant(for: "Chosen")?.access, .readCreate)
    }

    // MARK: Terminal rule and --grants isolation

    func testSavingTheRealGrantsFileNeedsATerminal() throws {
        let refused = run(flags(), defaultGrants: false)
        XCTAssertEqual(refused.output.status, 77)
        XCTAssertEqual(
            refused.output.stderr, "silkweb: Only the owner can save agent access. Run this in Terminal.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: realURL.path))

        // Other spellings of the real file are refused too.
        try FileManager.default.createDirectory(
            at: realURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: realURL.deletingLastPathComponent())
        for spelling in [
            realURL.path, home.path + "/Library/../Library/Application Support/Silkweb/agent-grants.json",
            home.path + "/library/application support/silkweb/Agent-Grants.json", link.path + "/agent-grants.json",
        ] {
            let (output, _) = run(flags(), grants: URL(fileURLWithPath: spelling))
            XCTAssertEqual(output.status, 77, spelling)
            XCTAssertFalse(FileManager.default.fileExists(atPath: realURL.path), spelling)
        }
        try AgentGrantFile().write(to: realURL)
        let hardLink = root.appendingPathComponent("hard.json")
        try FileManager.default.linkItem(at: realURL, to: hardLink)
        XCTAssertEqual(run(flags(), grants: hardLink).output.status, 77)
        XCTAssertEqual(try load(realURL).grants, [])

        // Another file needs no terminal; a terminal may save the real one.
        XCTAssertEqual(run(flags()).output.status, 0)
        XCTAssertEqual(try load(realURL).grants, [])
        let owner = run(flags(), terminal: true, defaultGrants: false)
        XCTAssertEqual(owner.output.status, 0, owner.output.stderr)
        XCTAssertTrue(
            owner.output.stdout.contains("  File     ~/Library/Application Support/Silkweb/agent-grants.json\n"))
        XCTAssertEqual(try load(realURL).grants.map(\.project), ["Silkweb"])
    }

    // MARK: Usage

    func testUsageErrorsHelpAndRouting() throws {
        let missing = run(["--project", "Silkweb"])
        XCTAssertEqual(missing.output.status, 64)
        XCTAssertEqual(
            missing.output.stderr, "silkweb: “grant init” needs --library. Run “silkweb grant init --help” for usage.\n"
        )
        XCTAssertEqual(missing.prompts, "", "never waits for input without a terminal")
        XCTAssertEqual(run(["--library", library.path]).output.stderr.contains("needs --project."), true)
        XCTAssertEqual(
            run(["--library", library.path, "--project", "P"]).output.stderr.contains("needs --access."), true)

        for arguments in [
            flags(access: "write"), flags() + ["--pretty"], flags() + ["--grant", "X"], flags() + ["--project", "Y"],
            flags() + ["extra"], flags("a/b"), flags(".hidden"), flags(""),
        ] {
            let (output, _) = run(arguments)
            XCTAssertEqual(output.status, 64, "\(arguments)")
            XCTAssertTrue(output.stderr.hasPrefix("silkweb: "), output.stderr)
            XCTAssertFalse(FileManager.default.fileExists(atPath: grantsURL.path))
        }
        XCTAssertEqual(run(flags("a/b")).output.stderr, "silkweb: The project name isn’t a valid folder name.\n")
        let noFolder = run(flags(library: root.appendingPathComponent("missing")))
        XCTAssertEqual(noFolder.output.status, 74)
        XCTAssertEqual(noFolder.output.stderr, "silkweb: That folder doesn’t exist.\n")
        let document = run(flags(library: library.appendingPathComponent("Notes/Diary.md")))
        XCTAssertEqual(document.output.stderr, "silkweb: That folder doesn’t exist.\n", "a file isn't a Library")

        let console = AgentGrantInit.Console(isTerminal: false, readLine: { nil }, write: { _ in })
        for arguments in [["grant"], ["grant", "revoke"]] {
            let output = AgentGrantInit.run(arguments, console: console, home: home, executable: nil)
            XCTAssertEqual(output.status, 64, "\(arguments)")
        }
        for arguments in [["grant", "--help"], ["grant", "init", "--help"], ["grant", "init", "-h"]] {
            let output = AgentGrantInit.run(arguments, console: console, home: home, executable: nil)
            XCTAssertEqual(output.status, 0)
            XCTAssertEqual(output.stdout, AgentGrantInit.help)
        }
        XCTAssertTrue(
            AgentHelper.help.contains(
                "  silkweb grant init [...]      Set up agent access for one project (owner only)\n"))
        // `memory` keeps its JSON contract; `grant` is not a memory command.
        let memory = AgentHelper.run(["memory", "grant"], home: home)
        XCTAssertEqual(memory.status, 64)
        XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(memory.stdout.utf8)))
    }

    // MARK: Install lines

    func testInstallLinesMatchTheReadme() throws {
        let readme = try String(
            contentsOf: Self.repository.appendingPathComponent("agent-packages/README.md"), encoding: .utf8)
        let commands = AgentGrantInit.installBlock(helper: "/Users/me/.local/bin/silkweb", project: "Silkweb")
            .components(separatedBy: "\n").filter { $0.hasPrefix("    ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(commands.count, 5)
        for command in commands {
            XCTAssertTrue(readme.contains("```sh\n\(command)\n```"), "README lacks “\(command)”")
        }
        XCTAssertTrue(readme.contains("/Users/me/.local/bin/silkweb memory capabilities --grant Silkweb --pretty"))
    }

    func testHelperPathIsAbsoluteKeepsLinksAndFallsBackToThePlaceholder() throws {
        let bin = root.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("silkweb-real")
        try Data("#!/bin/sh\n".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(
            at: bin.appendingPathComponent("silkweb"), withDestinationURL: target)
        let path = bin.appendingPathComponent("silkweb").path

        let environment = ["PATH": "relative:/nowhere:" + bin.path]
        XCTAssertEqual(AgentGrantInit.helperPath(path, environment: [:], currentDirectory: "/"), path)
        XCTAssertEqual(
            AgentGrantInit.helperPath("links/./silkweb", environment: [:], currentDirectory: root.path), path)
        XCTAssertEqual(AgentGrantInit.helperPath("silkweb", environment: environment, currentDirectory: "/"), path)
        XCTAssertNil(AgentGrantInit.helperPath("silkweb", environment: ["PATH": "/nowhere"], currentDirectory: "/"))
        XCTAssertNil(AgentGrantInit.helperPath(nil, environment: environment, currentDirectory: "/"))
        XCTAssertNil(AgentGrantInit.helperPath("missing/silkweb", environment: [:], currentDirectory: root.path))

        let (output, _) = run(flags(), executable: nil)
        XCTAssertEqual(output.status, 0)
        XCTAssertTrue(output.stdout.contains("-- <SILKWEB_HELPER> mcp --grant Silkweb\n"))
        XCTAssertTrue(output.stdout.contains("'s|<SILKWEB_HELPER>|<SILKWEB_HELPER>|'"))
        XCTAssertTrue(output.stdout.hasSuffix("Replace <SILKWEB_HELPER> with the helper’s absolute path.\n"))
    }

    /// Values with spaces and shell or `sed` metacharacters still make working commands: the shell
    /// sees the exact words, and the Gemini manifest gets the exact values.
    func testInstallLinesQuoteValuesForTheShellSedAndJSON() throws {
        let helper = "/Users/me/My Tools/silkweb"
        let project = #"Bob's & "Co" | $x \ 1"#
        let lines = AgentGrantInit.installBlock(helper: helper, project: project).components(separatedBy: "\n")
        XCTAssertEqual(AgentGrantInit.shellQuoted("Silkweb"), "Silkweb")
        XCTAssertEqual(AgentGrantInit.shellQuoted("a b"), "'a b'")
        XCTAssertEqual(AgentGrantInit.shellQuoted("it's"), #"'it'\''s'"#)

        let claude = try XCTUnwrap(lines.first { $0.hasPrefix("    claude mcp add") })
        let words = try shell("printf '%s\\n' " + claude.dropFirst("    claude ".count), directory: root)
        XCTAssertEqual(
            words,
            ["mcp", "add", "--scope", "user", "silkweb", "--", helper, "mcp", "--grant", project].joined(
                separator: "\n") + "\n")

        let gemini = lines.filter { $0.hasPrefix("    cp -R") || $0.hasPrefix("    sed -i") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(gemini.count, 2)
        let temporary = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        _ = try shell(
            "TMPDIR='\(temporary.path)'; " + gemini.joined(separator: " && "), directory: Self.repository)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: temporary.appendingPathComponent("silkweb-memory/gemini-extension.json")))
                as? [String: Any])
        let server = try XCTUnwrap((manifest["mcpServers"] as? [String: Any])?["silkweb"] as? [String: Any])
        XCTAssertEqual(server["command"] as? String, helper)
        XCTAssertEqual(server["args"] as? [String], ["mcp", "--grant", project])
    }

    private func shell(_ script: String, directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, script)
        return String(decoding: data, as: UTF8.self)
    }
}

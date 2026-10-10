import XCTest

@testable import SilkwebCore

/// #230: which Library changes count as made outside Silkweb, the versioned ledger of what Silkweb accounts for, and
/// that detection rereads only Documents whose dates changed.
final class OutsideChangesTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private let project = "Memory/Projects/Silkweb"
    /// 2026-10-07 09:30:00 UTC.
    private let fixedDate = Date(timeIntervalSince1970: 1_791_365_400)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("OutsideChanges-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent(project), withIntermediateDirectories: true)
        library = library.resolvingSymlinksInPath()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func create(_ title: String) throws -> AgentCreateResult {
        let grant = AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path))
        var service = AgentCreateService(
            library: library, grantId: "Silkweb", scope: try AgentScope(grant: grant),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        service.now = { self.fixedDate }
        service.timeZone = TimeZone(identifier: "UTC")!
        return try service.create(
            AgentCreateRequest(
                idempotencyKey: title, type: "progress", title: title, body: "Objective: \(title).",
                agent: "claude-code", session: "s-1"))
    }

    /// Writes as another app would, with a modification date `seconds` after the fixed date so rereads are seen.
    private func write(_ text: String, to path: String, seconds: TimeInterval = 0) throws {
        let url = library.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedDate.addingTimeInterval(seconds)], ofItemAtPath: url.path)
    }

    private static let envelope =
        "---\nschema: \"silkweb-memory/v1\"\nmemory_id: \"mem_1\"\ntype: \"memory\"\nproject: \"Silkweb\"\n"
        + "agent: \"claude-code\"\nsession: \"s\"\ncreated_at: \"2026-10-07T09:30:00Z\"\n---\n\n"

    private var detector = OutsideChangeDetector()
    private var found: [OutsideChange] = []

    /// Scans, loads the receipts and runs `detector`; the result by path.
    private func detect(ledger: OutsideChangeLedger = OutsideChangeLedger()) async throws -> [String: OutsideChangeKind]
    {
        let snapshot = try await LibraryScanner.scan(root: library)
        let activity = AgentActivity.load(root: library)
        found = detector.detect(
            snapshot: snapshot, entries: activity.entries(in: snapshot), ledger: ledger,
            pendingDigests: activity.pendingDigests)
        return Dictionary(uniqueKeysWithValues: found.map { ($0.document.relativePath, $0.kind) })
    }

    private func id(_ path: String) async throws -> UUID {
        let snapshot = try await LibraryScanner.scan(root: library)
        return try XCTUnwrap(snapshot.metadata.IDsByPath[path])
    }

    // MARK: Heuristic

    /// The #230 repro: a plain Markdown file written straight into the project Folder, outside every create folder.
    func testADirectWriteUnderMemoryWithoutAReceiptIsAddedOutsideSilkweb() async throws {
        let created = try create("Helper spike")
        let overview = project + "/Silkweb Overview.md"
        try write("# Silkweb overview\n\nWritten without the helper.\n", to: overview)
        try write("# Diary\n", to: "Notes/Diary.md")
        let found = try await detect()
        XCTAssertEqual(found, [overview: .added], "the helper's own create and Documents outside Memory aren't flagged")
        XCTAssertNotNil(created.path)
        let change = OutsideChange(
            document: LibraryDocument(
                id: UUID(), folderID: UUID(), relativePath: overview, name: "Silkweb Overview.md"),
            kind: .added)
        XCTAssertEqual(change.label, "Added outside Silkweb")
        XCTAssertEqual(change.accessibilityDescription, "added outside Silkweb, no Silkweb receipt")
        // Case is ignored, as on the default volume; a Folder merely named like it isn't Memory.
        XCTAssertTrue(OutsideChangeDetector.isInMemory("memory/Projects/A.md"))
        XCTAssertFalse(OutsideChangeDetector.isInMemory("Memory.md"))
        XCTAssertFalse(OutsideChangeDetector.isInMemory("Notes/Memory/A.md"))
    }

    func testEnvelopeOnlyClaimsUnderMemoryAreFlaggedAndElsewhereAreNot() async throws {
        let claimed = project + "/Memories/Claimed.md"
        try write(Self.envelope + "# Claimed\n", to: claimed)
        try write(Self.envelope + "# Copied\n", to: "Notes/Copied.md")
        var result = try await detect()
        XCTAssertEqual(result, [claimed: .added])
        // Once kept, a later change to the envelope Document is “changed”; the same bytes again are not.
        let claimedID = try await id(claimed)
        let ledger = OutsideChangeLedger(documents: [
            claimedID.uuidString: AgentCreateService.digest(Data((Self.envelope + "# Claimed\n").utf8))
        ])
        result = try await detect(ledger: ledger)
        XCTAssertEqual(result, [:])
        try write(Self.envelope + "# Claimed\n\nEdited by an agent.\n", to: claimed, seconds: 60)
        result = try await detect(ledger: ledger)
        XCTAssertEqual(result, [claimed: .changed])
        XCTAssertEqual(found.first?.hasReceipt, false)
    }

    /// The owner's own edits in another app to a Document Silkweb knows, without an envelope, never flag it.
    func testExternalEditsToKnownDocumentsWithoutAnEnvelopeAreNeverFlagged() async throws {
        let mine = project + "/Owner overview.md"
        try write("# Owner overview\n", to: mine)
        let mineID = try await id(mine)
        let ledger = OutsideChangeLedger(documents: [mineID.uuidString: ""])
        var result = try await detect(ledger: ledger)
        XCTAssertEqual(result, [:])
        try write("# Owner overview\n\nEdited in VS Code.\n", to: mine, seconds: 60)
        result = try await detect(ledger: ledger)
        XCTAssertEqual(result, [:])
    }

    func testAReceiptDocumentChangedOutsideSilkwebIsFlaggedUnlessSilkwebSavedThoseBytes() async throws {
        let created = try create("Next session")
        let path = try XCTUnwrap(created.path)
        var result = try await detect()
        XCTAssertEqual(result, [:], "unchanged since the receipt")
        let edited = try String(contentsOf: library.appendingPathComponent(path), encoding: .utf8) + "\nMore.\n"
        try write(edited, to: path, seconds: 60)
        result = try await detect()
        XCTAssertEqual(result, [path: .changed])
        XCTAssertEqual(found.first?.hasReceipt, true)
        XCTAssertEqual(found.first?.accessibilityDescription, "changed outside Silkweb")
        // Silkweb saved exactly these bytes (or the owner kept them): not outside.
        let pathID = try await id(path)
        let ledger = OutsideChangeLedger(documents: [pathID.uuidString: AgentCreateService.digest(Data(edited.utf8))])
        result = try await detect(ledger: ledger)
        XCTAssertEqual(result, [:])
        // Removing the envelope makes it an ordinary Document: never flagged.
        let body = edited.components(separatedBy: "---\n\n").dropFirst().joined(separator: "---\n\n")
        try write(body, to: path, seconds: 120)
        result = try await detect()
        XCTAssertEqual(result, [:])
    }

    /// A helper create that crashed after publishing has no receipt until the helper reconciles it; its staged
    /// intent says the bytes are the helper's.
    func testAnInterruptedHelperCreateIsNotOutsideSilkweb() async throws {
        let grant = AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path))
        var service = AgentCreateService(
            library: library, grantId: "Silkweb", scope: try AgentScope(grant: grant),
            maxBytes: AgentGrantLimits.defaultMaxCreateBytes)
        struct Crash: Error {}
        service.fault = { if $0 == .published { throw Crash() } }
        XCTAssertThrowsError(
            try service.create(
                AgentCreateRequest(
                    idempotencyKey: "k", type: "handoff", title: "Published", body: "Body.", agent: "codex",
                    session: "s")))
        XCTAssertEqual(AgentActivity.load(root: library).receipts, [])
        XCTAssertEqual(AgentActivity.load(root: library).pendingDigests.count, 1)
        let result = try await detect()
        XCTAssertEqual(result, [:])
        XCTAssertEqual(detector.reads, 1, "only to compare with the staged intent")
    }

    func testDocumentsAreRereadOnlyWhenTheirDateChanges() async throws {
        let created = try create("Helper spike")
        let path = try XCTUnwrap(created.path)
        let known = project + "/Known.md"
        try write(Self.envelope + "# Known\n", to: known)
        let knownID = try await id(known)
        let ledger = OutsideChangeLedger(documents: [knownID.uuidString: "sha256:other"])
        var result = try await detect(ledger: ledger)
        XCTAssertEqual(result, [known: .changed])
        XCTAssertEqual(detector.reads, 2, "the receipt Document and the known one")
        result = try await detect(ledger: ledger)
        XCTAssertEqual(result, [known: .changed])
        XCTAssertEqual(detector.reads, 0, "nothing changed, nothing reread")
        let text = try String(contentsOf: library.appendingPathComponent(path), encoding: .utf8)
        try write(text, to: path, seconds: 300)
        _ = try await detect(ledger: ledger)
        XCTAssertEqual(detector.reads, 1)
    }

    // MARK: Ledger

    func testLedgerDecodesTolerantlyRefusesNewerVersionsAndMergesAtomically() throws {
        XCTAssertEqual(try OutsideChangeLedger.load(root: library), OutsideChangeLedger(), "missing file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.appendingPathComponent(".silkweb").path))
        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(OutsideChangeLedger.self, from: Data("{}".utf8)), OutsideChangeLedger())
        XCTAssertEqual(
            try decoder.decode(OutsideChangeLedger.self, from: Data(#"{"version":1,"documents":7}"#.utf8)),
            OutsideChangeLedger())
        XCTAssertThrowsError(try decoder.decode(OutsideChangeLedger.self, from: Data(#"{"version":2}"#.utf8)))

        let kept = UUID()
        let gone = UUID()
        let other = UUID()
        let file = library.appendingPathComponent(".silkweb/outside-changes.json")
        try OutsideChangeLedger.merge(
            [kept.uuidString: "sha256:a", gone.uuidString: "sha256:b"], root: library, existing: [kept, gone, other])
        // Another window kept a Document meanwhile: a merge keeps it, and drops Documents that no longer exist.
        try OutsideChangeLedger.merge([other.uuidString: "sha256:c"], root: library, existing: [kept, other])
        XCTAssertEqual(
            try OutsideChangeLedger.load(root: library).documents,
            [kept.uuidString: "sha256:a", other.uuidString: "sha256:c"])
        let raw = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(raw.hasPrefix(#"{"documents":{"#) && raw.hasSuffix(#""version":1}"#), raw)
        // A newer file is refused, so the app never overwrites it; an undecodable one is replaced.
        let newer = Data(#"{"version":9,"documents":{}}"#.utf8)
        try newer.write(to: file)
        XCTAssertThrowsError(try OutsideChangeLedger.load(root: library)) {
            XCTAssertTrue(OutsideChangeLedger.isNewer($0))
        }
        XCTAssertThrowsError(try OutsideChangeLedger.merge([kept.uuidString: "x"], root: library, existing: [kept]))
        XCTAssertEqual(try Data(contentsOf: file), newer)
        try Data("{".utf8).write(to: file)
        XCTAssertThrowsError(try OutsideChangeLedger.load(root: library)) {
            XCTAssertFalse(OutsideChangeLedger.isNewer($0))
        }
        try OutsideChangeLedger.merge([kept.uuidString: "sha256:a"], root: library, existing: [kept])
        XCTAssertEqual(try OutsideChangeLedger.load(root: library).documents, [kept.uuidString: "sha256:a"])
    }
}

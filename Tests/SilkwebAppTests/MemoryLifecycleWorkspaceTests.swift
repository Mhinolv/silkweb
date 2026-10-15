import AppKit
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #141: the owner's lifecycle actions in a real workspace. Each one saves `.silkweb/memory-state.json`, never changes
/// Document text, and has one named Undo. Archive moves into the project's Archive Folder and keeps identity.
final class MemoryLifecycleWorkspaceTests: XCTestCase {
    static let memories = "Memory/Projects/Silkweb/Memories"
    static let predecessor = memories + "/Use flock.md"
    static let successor = memories + "/Use flock with a timeout.md"

    private static func memory(_ id: String, supersedes: String? = nil, body: String) -> String {
        "---\nschema: \"silkweb-memory/v1\"\nmemory_id: \"\(id)\"\ntype: \"decision\"\nproject: \"Silkweb\"\n"
            + "agent: \"claude-code\"\nsession: \"s-1\"\ncreated_at: \"2026-10-06T15:00:00Z\"\n"
            + (supersedes.map { "supersedes: [\"\($0)\"]\n" } ?? "") + "---\n\n" + body
    }

    @MainActor
    func testLifecycleActionsSaveStateWithNamedUndoAndNeverChangeText() async throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebLifecycle-" + UUID().uuidString)
        let unresolved = container.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: unresolved.appendingPathComponent(Self.memories), withIntermediateDirectories: true)
        let root = unresolved.resolvingSymlinksInPath()
        try Data(Self.memory("m_old", body: "# Use flock\n\nOld rule.\n").utf8)
            .write(to: root.appendingPathComponent(Self.predecessor))
        try Data(Self.memory("m_new", supersedes: "m_old", body: "# Use flock with a timeout\n\nNew rule.\n").utf8)
            .write(to: root.appendingPathComponent(Self.successor))
        let suite = "Silkweb.Lifecycle." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: container)
        }
        try await openLibrary(root, in: workspace)
        try await waitUntil("the memory links load", timeout: .seconds(10)) {
            workspace.memoryLinks.links.count == 2
        }
        XCTAssertEqual(workspace.memoryLinks.claimants["m_old"], [Self.successor])
        let oldText = try Data(contentsOf: root.appendingPathComponent(Self.predecessor))
        let oldID = try XCTUnwrap(workspace.snapshot?.metadata.IDsByPath[Self.predecessor])
        let revision = MemoryStateStore.revision(oldText)
        func idle() async throws { try await waitUntil("idle", timeout: .seconds(10)) { !workspace.mutating } }
        func saved() throws -> MemoryLifecycleEntry { try MemoryStateStore.load(root: root)[oldID] }
        func undo(_ title: String) async throws {
            XCTAssertEqual(workspace.libraryUndo.last?.title, title)
            workspace.undoLibrary()
            try await idle()
        }

        // Pin, with “Undo Pin”.
        workspace.setPinned([Self.predecessor], pinned: true)
        try await idle()
        XCTAssertTrue(try saved().pinned)
        XCTAssertTrue(workspace.memoryEntry(try XCTUnwrap(workspace.selectedDocumentFor(Self.predecessor))).pinned)
        try await undo("Undo Pin")
        XCTAssertFalse(try saved().pinned)

        // Mark as Reviewed binds the saved revision.
        workspace.markReviewed([Self.predecessor])
        try await idle()
        XCTAssertEqual(try saved().reviewed?.revision, revision)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Mark as Reviewed")

        // Review date: the owner's date, then Clear.
        let document = try XCTUnwrap(workspace.selectedDocumentFor(Self.predecessor))
        let date = try XCTUnwrap(AgentMemorySearchRequest.date("2027-01-06"))
        workspace.setReviewDate(document, to: date)
        try await idle()
        XCTAssertEqual(try saved().reviewAfter, date)
        workspace.setReviewDate(document, to: nil)
        try await idle()
        XCTAssertNil(try saved().reviewAfter)
        XCTAssertTrue(try saved().reviewAfterCleared)

        // Accept is revision-bound and separate from reviewing.
        workspace.decideSupersession(target: Self.predecessor, successor: Self.successor, .accepted)
        try await idle()
        let newRevision = MemoryStateStore.revision(try Data(contentsOf: root.appendingPathComponent(Self.successor)))
        XCTAssertEqual(
            try saved().claimState(by: "m_new", revision: revision, successorRevision: newRevision), .accepted)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Accept Replacement")
        try await undo("Undo Accept Replacement")
        XCTAssertEqual(
            try saved().claimState(by: "m_new", revision: revision, successorRevision: newRevision), .claimed)
        XCTAssertEqual(try saved().reviewed?.revision, revision, "Undo restores only that action's change")

        // Archive moves into the project's Archive Folder, keeps the ID, and records where it came from.
        XCTAssertTrue(workspace.canArchive(Self.predecessor))
        workspace.archiveDocuments([Self.predecessor])
        try await idle()
        let archived = "Memory/Projects/Silkweb/Archive/Use flock.md"
        XCTAssertEqual(workspace.snapshot?.metadata.IDsByPath[archived], oldID)
        XCTAssertEqual(try saved().archived?.fromPath, Self.memories)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(archived)), oldText, "never rewritten")
        XCTAssertFalse(workspace.canArchive(archived))
        try await undo("Undo Archive")
        XCTAssertEqual(workspace.snapshot?.metadata.IDsByPath[Self.predecessor], oldID)
        XCTAssertNil(try saved().archived)

        // Restore moves it back.
        workspace.archiveDocuments([Self.predecessor])
        try await idle()
        workspace.restoreDocument(try XCTUnwrap(workspace.selectedDocumentFor(archived)))
        try await idle()
        XCTAssertEqual(workspace.snapshot?.metadata.IDsByPath[Self.predecessor], oldID)
        XCTAssertNil(try saved().archived)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Restore")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(Self.predecessor)), oldText)

        // A newer state file locks the controls and is never overwritten.
        try Data(#"{"version": 9}"#.utf8).write(to: MemoryStateStore.url(root: root))
        await workspace.reloadMemoryState()
        XCTAssertTrue(workspace.memoryStateLocked)
        XCTAssertFalse(workspace.canChangeMemoryState)
        workspace.setPinned([Self.predecessor], pinned: true)
        try await idle()
        XCTAssertEqual(try String(contentsOf: MemoryStateStore.url(root: root), encoding: .utf8), #"{"version": 9}"#)
    }

    func testConsolidationListsSourcesAndNamesTheirMemoryIDs() throws {
        let text = MemoryConsolidation.document(
            body: "# Summary\n\nBoth.\n",
            sources: [
                .init(title: "Plan", path: "Memory/Projects/Silkweb/Notes/Plan.md", memoryID: "m_a"),
                .init(title: "Spike", path: "Memory/Projects/Silkweb/Progress/Spike.md", memoryID: nil),
            ],
            folder: "Memory/Projects/Silkweb/Memories", project: "Silkweb", agent: "claude-code", session: "s-1",
            createdAt: Date(timeIntervalSince1970: 0), memoryID: "m_sum")
        guard case .envelope(let envelope, let body) = MemoryEnvelope.parse(text) else {
            return XCTFail("no envelope: \(text)")
        }
        XCTAssertEqual(envelope.memoryID, "m_sum")
        XCTAssertEqual(envelope["consolidates"], .list(["m_a"]))
        XCTAssertEqual(
            String(text[body]),
            "# Summary\n\nBoth.\n\n## Sources\n\n- [Plan](<../Notes/Plan.md>)\n- [Spike](<../Progress/Spike.md>)\n")
        // Without memory IDs, no envelope: only the Sources list.
        let plain = MemoryConsolidation.document(
            body: "Text", sources: [.init(title: "A", path: "A.md", memoryID: nil)], folder: "", project: "P",
            agent: "a", session: "s", createdAt: Date())
        XCTAssertEqual(plain, "Text\n\n## Sources\n\n- [A](<A.md>)\n")
        XCTAssertEqual(MemoryConsolidation.relativeLink(from: "a/b", to: "a/b/c.md"), "c.md")
        XCTAssertEqual(MemoryConsolidation.relativeLink(from: "a/b", to: "x/c.md"), "../../x/c.md")
    }
}

extension LibraryWorkspace {
    fileprivate func selectedDocumentFor(_ path: String) -> LibraryDocument? {
        snapshot?.documents.first { $0.relativePath == path }
    }
}

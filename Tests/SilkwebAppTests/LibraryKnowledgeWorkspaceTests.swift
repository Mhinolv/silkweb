import AppKit
import SilkwebCore
import XCTest

@testable import Silkweb

/// #177: the window feeds its knowledge index from installed snapshots (saves, scans), never from typing.
final class LibraryKnowledgeWorkspaceTests: XCTestCase {
    @MainActor
    func testSavesFeedTheKnowledgeIndexButKeystrokesDoNot() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[b](B.md)".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        try "bee".write(to: root.appendingPathComponent("B.md"), atomically: true, encoding: .utf8)
        let snapshot = try await LibraryScanner.scan(root: root)
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(snapshot)
        await workspace.editor.configure(root: root)
        await workspace.knowledge.waitForIndex()
        let index = try XCTUnwrap(workspace.knowledge.index)
        var links = await index.links(from: "A.md")
        XCTAssertEqual(links.value?.map(\.target), ["B.md"])

        let document = try XCTUnwrap(snapshot.documents.first { $0.relativePath == "A.md" })
        let opened = await workspace.openTab(document)
        XCTAssertTrue(opened)
        let fed = workspace.knowledge.reconcileCount
        for character in " typing [c](C.md)" { workspace.editor.edit(workspace.editor.text + String(character)) }
        XCTAssertEqual(workspace.knowledge.reconcileCount, fed, "no indexing per keystroke")
        links = await index.links(from: "A.md")
        XCTAssertEqual(links.value?.map(\.target), ["B.md"], "unsaved text is never indexed")

        workspace.editor.edit("[c](C.md) only")
        let saved = await workspace.editor.save()
        XCTAssertTrue(saved)
        await workspace.refreshSavedDocumentDates()
        XCTAssertEqual(workspace.knowledge.reconcileCount, fed + 1)
        await workspace.knowledge.waitForIndex()
        links = await index.links(from: "A.md")
        XCTAssertEqual(links.value, [])
        let posting = await index.postings(for: "only")
        XCTAssertEqual(posting.value?.keys.sorted(), ["A.md"])

        // Closing the Library drops the index; nothing is written into the Library for it.
        workspace.knowledge.reset()
        XCTAssertNil(workspace.knowledge.index)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".silkweb").path)
                .contains { $0.localizedCaseInsensitiveContains("knowledge") })
    }
}

import SilkwebCore
import XCTest

@testable import Silkweb

/// #102: a refused library switch or a failed New Library leaves the current library untouched.
final class LibrarySwitchTests: XCTestCase {
    @MainActor private func fixture() async throws -> LibraryWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for name in ["A", "B"] { try Data(name.utf8).write(to: root.appendingPathComponent(name + ".md")) }
        let workspace = LibraryWorkspace(defaults: disposableDefaults("LibrarySwitch"))
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        return workspace
    }

    @MainActor func testRefusedSwitchKeepsTagsUndoRenameAndDragIdentity() async throws {
        let workspace = try await fixture()
        let root = try XCTUnwrap(workspace.root)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        workspace.navigate(folder: "", documents: ["A.md"], pinned: true)
        await workspace.waitForNavigation()
        // An external-edit conflict makes `flushEditors()` refuse, with no OS permission assumptions.
        workspace.editor.edit("mine")
        try Data("external".utf8).write(to: root.appendingPathComponent("A.md"), options: .atomic)
        await workspace.editor.reconcileExternalChange()
        XCTAssertTrue(workspace.editor.externalConflict)
        let tag = LibraryTag(name: "Draft")
        workspace.tags = [tag]
        workspace.tagCounts = [tag.id: 1]
        workspace.tagFilters = [tag.id]
        workspace.libraryUndo = [.newFolder("Chapter")]
        workspace.rename = LibraryRename(path: "B.md", isFolder: false)
        let drag = workspace.dragIdentity
        let snapshot = workspace.snapshot

        workspace.open(other)
        await workspace.waitForLoad()

        XCTAssertEqual(workspace.root, root, "the refused switch must not change library")
        XCTAssertEqual(workspace.snapshot?.rootURL, snapshot?.rootURL)
        XCTAssertEqual(workspace.tags, [tag])
        XCTAssertEqual(workspace.tagCounts, [tag.id: 1])
        XCTAssertEqual(workspace.tagFilters, [tag.id])
        XCTAssertEqual(workspace.libraryUndo.map(\.title), [LibraryUndo.newFolder("Chapter").title])
        XCTAssertEqual(workspace.rename, LibraryRename(path: "B.md", isFolder: false))
        XCTAssertEqual(workspace.dragIdentity, drag)
        XCTAssertEqual(workspace.editor.text, "mine")
        XCTAssertNil(workspace.error)
    }

    @MainActor func testAcceptedSwitchResetsLibraryState() async throws {
        let workspace = try await fixture()
        let root = try XCTUnwrap(workspace.root)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try Data("C".utf8).write(to: other.appendingPathComponent("C.md"))
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let tag = LibraryTag(name: "Draft")
        workspace.tags = [tag]
        workspace.tagCounts = [tag.id: 1]
        workspace.tagFilters = [tag.id]
        workspace.libraryUndo = [.newFolder("Chapter")]
        workspace.rename = LibraryRename(path: "B.md", isFolder: false)
        let drag = workspace.dragIdentity

        workspace.open(other)
        await workspace.waitForLoad()

        XCTAssertEqual(workspace.root, other.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertEqual(workspace.snapshot?.documents.map(\.relativePath), ["C.md"])
        XCTAssertTrue(workspace.tags.isEmpty)
        XCTAssertTrue(workspace.tagCounts.isEmpty)
        XCTAssertTrue(workspace.tagFilters.isEmpty)
        XCTAssertTrue(workspace.libraryUndo.isEmpty)
        XCTAssertNil(workspace.rename)
        XCTAssertNotEqual(workspace.dragIdentity, drag)
    }

    @MainActor func testFailedNewLibraryShowsMutationAlertAndKeepsLibrary() async throws {
        let workspace = try await fixture()
        let root = try XCTUnwrap(workspace.root)
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("Existing")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let snapshot = workspace.snapshot

        workspace.createLibrary(at: existing)
        await workspace.waitForLoad()

        XCTAssertNil(workspace.error, "a failed create must not replace the window with Can’t Open Library")
        XCTAssertEqual(workspace.mutationErrorTitle, "“Existing” couldn’t be created.")
        XCTAssertNotNil(workspace.mutationError)
        XCTAssertEqual(workspace.root, root)
        XCTAssertEqual(workspace.snapshot?.rootURL, snapshot?.rootURL)
    }
}

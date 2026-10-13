import SilkwebCore
import XCTest

@testable import Silkweb

final class LibraryLocationWorkspaceTests: XCTestCase {
    @MainActor
    private func waitForOpen(_ workspace: LibraryWorkspace, _ root: URL, defaults: UserDefaults) async throws {
        // #213: the shared bounded wait for the requested root, then for the persisted location.
        try await waitForLibrary(root, in: workspace)
        XCTAssertNil(workspace.error, "Library did not open")
        try await waitUntil("the library location persists", timeout: .seconds(10)) {
            defaults.data(forKey: "libraryLocation") != nil
        }
    }

    @MainActor
    func testFolderChoicePersistenceRelaunchAndLegacyMigration() async throws {
        let defaults = disposableDefaults("LocationTests")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Test\n".utf8).write(to: root.appendingPathComponent("Note.md"))
        let expectedPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let chosen = LibraryWorkspace(defaults: defaults)
        // Same entry point used by the folder panel, without presenting a GUI.
        chosen.open(root)
        try await waitForOpen(chosen, root, defaults: defaults)
        let saved = try JSONDecoder().decode(
            LibraryLocation.self, from: XCTUnwrap(defaults.data(forKey: "libraryLocation")))
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.path, expectedPath)
        XCTAssertNotNil(saved.bookmark)
        XCTAssertNil(defaults.data(forKey: "libraryBookmark"))
        let relaunched = LibraryWorkspace(defaults: defaults)
        relaunched.restore()
        try await waitForOpen(relaunched, root, defaults: defaults)
        XCTAssertEqual(relaunched.root?.path, expectedPath)
        XCTAssertEqual(relaunched.snapshot?.documents.count, 1)
        defaults.removeObject(forKey: "libraryLocation")
        // Old key migration uses a real resolvable bookmark; scoped retry is covered in core.
        defaults.set(saved.bookmark, forKey: "libraryBookmark")
        let migrated = LibraryWorkspace(defaults: defaults)
        migrated.restore()
        try await waitForOpen(migrated, root, defaults: defaults)
        XCTAssertEqual(migrated.root?.path, expectedPath)
        XCTAssertNil(defaults.data(forKey: "libraryBookmark"))
    }
}

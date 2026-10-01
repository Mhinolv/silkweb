import XCTest
import SilkwebCore
@testable import Silkweb

final class LibraryLocationWorkspaceTests: XCTestCase {
    @MainActor
    private func waitForOpen(_ workspace: LibraryWorkspace, defaults: UserDefaults) async throws {
        for _ in 0..<500 {
            if workspace.error != nil { break }
            if workspace.snapshot != nil, !workspace.loading, defaults.data(forKey: "libraryLocation") != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Library did not open: \(workspace.error ?? "timed out")")
    }

    @MainActor
    func testFolderChoicePersistenceRelaunchAndLegacyMigration() async throws {
        let suite = "SilkwebLocationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Test\n".utf8).write(to: root.appendingPathComponent("Note.md"))
        let expectedPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let chosen = LibraryWorkspace(defaults: defaults)
        // Same entry point used by the folder panel, without presenting a GUI.
        chosen.open(root)
        try await waitForOpen(chosen, defaults: defaults)
        let saved = try JSONDecoder().decode(LibraryLocation.self, from: XCTUnwrap(defaults.data(forKey: "libraryLocation")))
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.path, expectedPath)
        XCTAssertNotNil(saved.bookmark)
        XCTAssertNil(defaults.data(forKey: "libraryBookmark"))
        let relaunched = LibraryWorkspace(defaults: defaults)
        relaunched.restore()
        try await waitForOpen(relaunched, defaults: defaults)
        XCTAssertEqual(relaunched.root?.path, expectedPath)
        XCTAssertEqual(relaunched.snapshot?.documents.count, 1)
        defaults.removeObject(forKey: "libraryLocation")
        // Old key migration uses a real resolvable bookmark; scoped retry is covered in core.
        defaults.set(saved.bookmark, forKey: "libraryBookmark")
        let migrated = LibraryWorkspace(defaults: defaults)
        migrated.restore()
        try await waitForOpen(migrated, defaults: defaults)
        XCTAssertEqual(migrated.root?.path, expectedPath)
        XCTAssertNil(defaults.data(forKey: "libraryBookmark"))
    }
}

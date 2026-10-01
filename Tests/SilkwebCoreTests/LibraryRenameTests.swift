import XCTest
@testable import SilkwebCore

final class LibraryRenameTests: XCTestCase {
    func testPreflightNeverWritesAndRemapsDescendants() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createFolder(named: "Parent")
        _ = try await engine.createFolder(named: "Child", in: "Parent")
        _ = try await engine.createDocument(named: "Note.md", in: "Parent/Child", text: "Original")
        _ = try await engine.createDocument(named: "Other.md", in: "Parent/Child")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Parent/Child").path).sorted()
        for name in ["", ".reserved.md", "../Escape.md", "Other.md"] {
            do {
                try await engine.validateRename("Parent/Child/Note.md", to: name)
                XCTFail("Expected invalid name")
            } catch { XCTAssertNotNil(error as? LibraryMutationError) }
        }
        for name in ["Note.md", "NOTE.md", "New.md", String(repeating: "a", count: 252) + ".md"] {
            try await engine.validateRename("Parent/Child/Note.md", to: name)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Parent/Child").path).sorted(), before)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Parent/Child/Note.md"), encoding: .utf8), "Original")
        var session = LibrarySession()
        session.selectedFolder = "Parent/Child"
        session.selectedDocuments = ["Parent/Child/Note.md"]
        session.expandedFolders = ["", "Parent", "Parent/Child", "Parenthetical"]
        let changes = try await engine.rename("Parent", to: "Renamed")
        let updated = session.applying(changes)
        XCTAssertEqual(updated.selectedFolder, "Renamed/Child")
        XCTAssertEqual(updated.selectedDocuments, ["Renamed/Child/Note.md"])
        XCTAssertEqual(updated.expandedFolders, ["", "Renamed", "Renamed/Child", "Parenthetical"])
        do { try await engine.removeEmptyFolder("Renamed"); XCTFail("Must refuse nonempty folder") } catch { }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Renamed/Child/Note.md").path))
    }
}

import XCTest
@testable import SilkwebCore

final class LibraryScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, text: String = "# Café 日本語\n") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testNestedEmptyFoldersExtensionsAndUTF8() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
        for name in ["Top.md", "Nested/Note.markdown", "Nested/UPPER.MD", "ignored.txt", ".hidden.md",
                     ".hidden/ignored.md", ".silkweb/ignored.md", "Nested/Empty/fake.md/ignored.txt"] {
            try write(name)
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(Set(snapshot.folders.map(\.relativePath)), ["", "Nested", "Nested/Empty", "Nested/Empty/fake.md"])
        XCTAssertEqual(Set(snapshot.documents.map(\.relativePath)), ["Top.md", "Nested/Note.markdown", "Nested/UPPER.MD"])
        for document in snapshot.documents {
            XCTAssertTrue(snapshot.folders.contains { $0.id == document.folderID })
            let text = try await LibraryScanner.readDocument(document, root: root)
            XCTAssertEqual(text, "# Café 日本語\n")
        }
        let again = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(snapshot.metadata, again.metadata)
        XCTAssertNil(again.recoveredMetadataURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Top.md"))
        let afterDelete = try await LibraryScanner.scan(root: root)
        XCTAssertNil(afterDelete.metadata.IDsByPath["Top.md"])
    }

    func testEmptyLibraryAndOldMetadata() async throws {
        try write(".silkweb/index.json", text: "{}")
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(snapshot.folders.count, 1)
        XCTAssertTrue(snapshot.documents.isEmpty)
        XCTAssertEqual(snapshot.metadata.formatVersion, 1)
        XCTAssertNil(snapshot.recoveredMetadataURL)
    }

    func testMalformedMetadataIsPreservedAndRebuilt() async throws {
        for malformed in ["not JSON", "{\"IDsByPath\":{\"Note.md\":\"invalid UUID\"}}"] {
            try write("Note.md")
            try write(".silkweb/index.json", text: malformed)
            let snapshot = try await LibraryScanner.scan(root: root)
            let recovered = try XCTUnwrap(snapshot.recoveredMetadataURL)
            XCTAssertEqual(try String(contentsOf: recovered, encoding: .utf8), malformed)
            XCTAssertEqual(snapshot.documents.count, 1)
            let saved = try JSONDecoder().decode(LibraryMetadata.self, from: Data(contentsOf: root.appendingPathComponent(".silkweb/index.json")))
            XCTAssertEqual(saved, snapshot.metadata)
        }
    }

    func testNewerFormatIsNotOverwritten() async throws {
        let json = "{\"formatVersion\":999}"
        try write(".silkweb/index.json", text: json)
        do {
            _ = try await LibraryScanner.scan(root: root)
            XCTFail("Expected unsupported version")
        } catch {
            XCTAssertEqual(error as? LibraryError, .unsupportedMetadataVersion(999))
        }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent(".silkweb/index.json"), encoding: .utf8), json)
    }

    func testSymlinkCycleFilesAndDanglingLinksAreSkipped() async throws {
        try write("Folder/real.md")
        for (path, destination) in [("Folder/cycle", root.path), ("linked.md", root.appendingPathComponent("Folder/real.md").path),
                                    ("dangling.md", root.appendingPathComponent("missing").path)] {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(path).path, withDestinationPath: destination)
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(snapshot.folders.count, 2)
        XCTAssertEqual(snapshot.documents.map(\.relativePath), ["Folder/real.md"])
        // A file swapped for a symlink after scanning must not be read.
        let url = root.appendingPathComponent("Folder/real.md")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: root.appendingPathComponent("missing").path)
        do {
            _ = try await LibraryScanner.readDocument(snapshot.documents[0], root: root)
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? LibraryError, .symbolicLink(url))
        }
    }

    func testMetadataSymlinksAreRejected() async throws {
        for path in [".silkweb", ".silkweb/index.json"] {
            if path.contains("/") {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(".silkweb"), withIntermediateDirectories: false)
            }
            let url = root.appendingPathComponent(path)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: root.appendingPathComponent("missing").path)
            do {
                _ = try await LibraryScanner.scan(root: root)
                XCTFail("Expected symlink rejection")
            } catch {
                guard case let LibraryError.symbolicLink(rejected) = error else {
                    return XCTFail("Expected symlink rejection, got \(error)")
                }
                XCTAssertEqual(rejected.path, url.path)
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent(".silkweb"))
        }
    }

    func testDuplicateMetadataIDsAreRepaired() async throws {
        try write("Note.md")
        let id = UUID()
        try LibraryMetadataStore.save(LibraryMetadata(IDsByPath: ["": id, "Note.md": id]), root: root)
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertNotEqual(snapshot.folders[0].id, snapshot.documents[0].id)
    }

    @MainActor
    func testLargeLibraryOffMainThreadWithinBudget() async throws {
        for folder in 0..<1_000 {
            let directory = root.appendingPathComponent("Folder-\(folder)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for document in 0..<10 {
                try Data("# Note\n".utf8).write(to: directory.appendingPathComponent("Note-\(document).md"))
            }
        }
        // Called from the main actor; the scanner asserts its worker is not on the main thread.
        let start = Date()
        let snapshot = try await LibraryScanner.scan(root: root)
        let elapsed = Date().timeIntervalSince(start)
        print("Library scan: 10,000 documents / 1,000 folders in \(elapsed)s (budget: 10s)")
        XCTAssertEqual(snapshot.documents.count, 10_000)
        XCTAssertEqual(snapshot.folders.count, 1_001)
        XCTAssertLessThan(elapsed, 10)
    }
}

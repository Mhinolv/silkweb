import XCTest
@testable import SilkwebCore

final class WindowSessionMetadataTests: XCTestCase {
    func testDefaultsAndPositionModeSweep() throws {
        XCTAssertEqual(try JSONDecoder().decode(WindowSessionMetadata.self, from: Data("{}".utf8)), WindowSessionMetadata())
        let id = UUID()
        let partial = try JSONDecoder().decode(DocumentTabMetadata.self, from: Data("{\"documentID\":\"\(id)\"}".utf8))
        XCTAssertFalse(partial.isPreview)
        XCTAssertEqual(partial.selectionLocation, 0)
        for count in [0, 1, 2, 1000] {
            for mode in ["editor", "split", "preview"] {
                for preview in [false, true] {
                    for location in [0, 1, Int.max] {
                        var value = WindowSessionMetadata()
                        value.viewMode = mode
                        value.selectedFolder = nil
                        value.tabs = (0..<count).map { index in
                            var tab = DocumentTabMetadata(documentID: UUID(), relativePath: "Folder/\(index).md", isPreview: preview && index == 0)
                            tab.selectionLocation = location; tab.selectionLength = location
                            tab.scrollY = 1_000_000
                            return tab
                        }
                        value.activeDocumentID = value.tabs.last?.documentID
                        XCTAssertEqual(try JSONDecoder().decode(WindowSessionMetadata.self, from: JSONEncoder().encode(value)), value)
                    }
                }
            }
        }
        let negative = try JSONDecoder().decode(DocumentTabMetadata.self, from: Data("{\"documentID\":\"\(id)\",\"selectionLocation\":-5,\"selectionLength\":-1,\"scrollY\":-10}".utf8))
        XCTAssertEqual(negative.selectionLocation, 0)
        XCTAssertEqual(negative.selectionLength, 0)
        XCTAssertEqual(negative.scrollY, 0)
        XCTAssertThrowsError(try JSONDecoder().decode(WindowSessionMetadata.self, from: Data("{\"formatVersion\":999}".utf8)))
    }

    func testDiskRoundTripMissingDocumentsStableIDRebindAndOldSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appendingPathComponent("A.md"))
        try Data("b".utf8).write(to: root.appendingPathComponent("B.md"))
        let first = try await LibraryScanner.scan(root: root)
        let a = try XCTUnwrap(first.documents.first { $0.relativePath == "A.md" })
        let b = try XCTUnwrap(first.documents.first { $0.relativePath == "B.md" })
        let initial = try await WindowSessionMetadata.load(root: root)
        XCTAssertNil(initial)
        var value = WindowSessionMetadata()
        value.tabs = [DocumentTabMetadata(documentID: a.id, relativePath: a.relativePath, isPreview: false),
                      DocumentTabMetadata(documentID: b.id, relativePath: b.relativePath, isPreview: true)]
        value.activeDocumentID = b.id
        value.selectedFolderID = first.folders[0].id
        try await value.save(root: root)
        let saved = try await WindowSessionMetadata.load(root: root)
        XCTAssertEqual(saved, value)
        let engine = try LibraryMutations(root: root)
        _ = try await engine.rename("A.md", to: "Moved.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent("B.md"))
        let changed = try await LibraryScanner.scan(root: root)
        let rebound = value.resolving(in: changed)
        XCTAssertEqual(rebound.tabs.map(\.relativePath), ["Moved.md"])
        XCTAssertEqual(rebound.activeDocumentID, a.id)
        // A new document occupying a stale path must never receive the old buffer.
        try Data("replacement".utf8).write(to: root.appendingPathComponent("B.md"))
        let replaced = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(value.resolving(in: replaced).tabs.map(\.documentID), [a.id])
        var duplicate = value
        duplicate.tabs = [value.tabs[0], value.tabs[0]]
        XCTAssertEqual(duplicate.resolving(in: replaced).tabs.count, 1)
        // Pre-tab navigation JSON remains readable and its schema remains unchanged.
        let old = try JSONDecoder().decode(LibrarySession.self, from: Data("{\"formatVersion\":1,\"selectedDocuments\":[\"Moved.md\"]}".utf8))
        XCTAssertEqual(old.selectedDocuments, ["Moved.md"])
        try await old.save(root: root)
        let oldReloaded = try await LibrarySession.load(root: root)
        XCTAssertEqual(oldReloaded, old)
    }
}

import XCTest

@testable import SilkwebCore

final class LibrarySessionTests: XCTestCase {
    func testTolerantDefaultsAndEverySelectionMode() throws {
        let defaults = try JSONDecoder().decode(LibrarySession.self, from: Data("{}".utf8))
        XCTAssertEqual(defaults, LibrarySession())
        for folder in [nil, "", "Writing/Drafts"] as [String?] {
            for count in [0, 1, 3, 10_000] {
                for expanded in [Set<String>(), ["", "Writing", "Writing/Drafts"]] {
                    var session = LibrarySession()
                    session.selectedFolder = folder
                    session.selectedDocuments = Set((0..<count).map { "Writing/\($0).md" })
                    session.expandedFolders = expanded
                    XCTAssertEqual(
                        try JSONDecoder().decode(LibrarySession.self, from: JSONEncoder().encode(session)), session)
                }
            }
        }
    }

    func testSessionDiskRoundTripAndSummaryBounds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let initial = try await LibrarySession.load(root: root)
        XCTAssertEqual(initial, LibrarySession())
        var session = LibrarySession()
        session.selectedFolder = nil
        session.selectedDocuments = ["日本語.md"]
        try await session.save(root: root)
        let restored = try await LibrarySession.load(root: root)
        XCTAssertEqual(restored, session)
        for text in ["", "Hello\nWorld", "日本語\nNext", String(repeating: "a", count: 100_000)] {
            try Data(text.utf8).write(to: root.appendingPathComponent("日本語.md"))
            let snapshot = try await LibraryScanner.scan(root: root)
            let summary = await DocumentSummary.load(document: snapshot.documents[0], root: root)
            XCTAssertLessThanOrEqual(summary.firstLine.utf8.count, 514)
            XCTAssertNotNil(summary.modified)
            if text == "Hello\nWorld" { XCTAssertEqual(summary.firstLine, "Hello") }
        }
    }
}

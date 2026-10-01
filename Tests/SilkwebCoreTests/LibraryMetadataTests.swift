import XCTest
@testable import SilkwebCore

final class LibraryMetadataTests: XCTestCase {
    func testOlderMetadataDefaultsAndVersionedRoundTrip() throws {
        for json in ["{}", "{\"formatVersion\":1}", "{\"IDsByPath\":{}}"] {
            let metadata = try JSONDecoder().decode(LibraryMetadata.self, from: Data(json.utf8))
            XCTAssertEqual(metadata, LibraryMetadata())
        }
        let metadata = LibraryMetadata(IDsByPath: ["": UUID(), "日本語/Note.md": UUID()])
        let data = try JSONEncoder().encode(metadata)
        XCTAssertEqual(try JSONDecoder().decode(LibraryMetadata.self, from: data), metadata)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 1)
        XCTAssertNil(json["body"])
    }

    func testMissingMetadataLoadsDefaults() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let (metadata, recovered) = try LibraryMetadataStore.load(root: root)
        XCTAssertEqual(metadata, LibraryMetadata())
        XCTAssertNil(recovered)
    }
}

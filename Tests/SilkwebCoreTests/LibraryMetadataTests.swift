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
        XCTAssertEqual(json["formatVersion"] as? Int, LibraryMetadata.currentVersion)
        XCTAssertNil(json["body"])
    }

    /// #107: healthy indexes from every earlier build keep their tags and IDs under the tolerant decoder.
    func testHealthyEarlierFormatsKeepTagsAndIDs() throws {
        let id = UUID()
        let tag = UUID()
        let ids = "\"IDsByPath\":{\"\":\"\(UUID().uuidString)\",\"Note.md\":\"\(id.uuidString)\"}"
        let tags =
            "\"tags\":[{\"id\":\"\(tag.uuidString)\",\"name\":\"Travel\"}],\"tagsByDocument\":{\"\(id.uuidString)\":[\"\(tag.uuidString)\"]}"
        let v1 = try JSONDecoder().decode(LibraryMetadata.self, from: Data("{\(ids)}".utf8))
        XCTAssertEqual(v1.IDsByPath["Note.md"], id)
        for version in 2...3 {
            let json = "{\"formatVersion\":\(version),\(ids),\(tags),\"tagRecency\":[\"\(tag.uuidString)\"]}"
            let metadata = try JSONDecoder().decode(LibraryMetadata.self, from: Data(json.utf8))
            XCTAssertEqual(metadata.formatVersion, LibraryMetadata.currentVersion)
            XCTAssertEqual(metadata.IDsByPath.count, 2)
            XCTAssertEqual(metadata.IDsByPath["Note.md"], id)
            XCTAssertEqual(metadata.tags, [LibraryTag(id: tag, name: "Travel")])
            XCTAssertEqual(metadata.tagsByDocument, [id.uuidString: [tag]])
            XCTAssertEqual(metadata.tagRecency, [tag])
            let encoded = try JSONEncoder().encode(metadata)
            XCTAssertEqual(try JSONDecoder().decode(LibraryMetadata.self, from: encoded), metadata)
        }
    }

    /// #107: Can’t Open Library shows these instead of Cocoa's generic text.
    func testLibraryErrorsHavePlainDescriptions() {
        let link = URL(fileURLWithPath: "/tmp/Notes Link")
        XCTAssertEqual(
            LibraryError.unsupportedMetadataVersion(999).localizedDescription,
            "This library was last used with a newer version of Silkweb. Update Silkweb to open it. Nothing in the library was changed."
        )
        XCTAssertEqual(LibraryError.invalidRoot.localizedDescription, "This folder can’t be used as a library.")
        XCTAssertEqual(
            LibraryError.symbolicLink(link).localizedDescription,
            "“Notes Link” is a symbolic link. Silkweb doesn’t open libraries through links.")
        XCTAssertEqual(LibraryError.invalidRelativePath.localizedDescription, "That location is outside the library.")
        XCTAssertFalse(LibraryError.unsupportedMetadataVersion(999).localizedDescription.contains("999"))
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

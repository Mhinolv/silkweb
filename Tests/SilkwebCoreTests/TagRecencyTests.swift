import XCTest
@testable import SilkwebCore

final class TagRecencyTests: XCTestCase {
    func testApplyingRecordsVersionedRecencyAndOldFilesDecodeTolerantly() throws {
        let a = UUID(), b = UUID()
        var metadata = LibraryMetadata(IDsByPath: ["a.md": a, "b.md": b])
        metadata = TagEditor.edit(["coffee"], documents: [a], metadata: metadata)
        let coffee = try XCTUnwrap(metadata.tags.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as? [String: Any])
        XCTAssertEqual(json["formatVersion"] as? Int, 3, "Recency requires a versioned index")
        let history = json["tagRecency"] as? [String]
        XCTAssertEqual(history, [coffee.id.uuidString], "Applying a tag must record recency")
        for version in [1, 2, 3] {
            for history: Any in [NSNull(), "malformed", [], [coffee.id.uuidString]] {
                var old = json; old["formatVersion"] = version; old["tagRecency"] = history
                let loaded = try JSONDecoder().decode(LibraryMetadata.self, from: JSONSerialization.data(withJSONObject: old))
                XCTAssertEqual(loaded.tags, metadata.tags)
                XCTAssertEqual(loaded.tagsByDocument, metadata.tagsByDocument)
                let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(loaded)) as! [String: Any]
                XCTAssertEqual(encoded["tagRecency"] as? [String], history as? [String] ?? [])
            }
        }
        metadata = TagEditor.edit(["coffee"], documents: [b], metadata: metadata)
        XCTAssertEqual(metadata.tags.count, 1)
    }
    func testRecentSetOrderingFallbackAndPruningSweep() throws {
        let ids = (0..<8).map { _ in UUID() }
        var metadata = LibraryMetadata(IDsByPath: Dictionary(uniqueKeysWithValues: ids.enumerated().map { ("\($0.offset).md", $0.element) }))
        let names = ["topic 10", "topic 2", "coffee", "draft", "research", "travel", "writing", "archive"]
        for count in 1...8 {
            metadata = TagEditor.edit([names[count - 1]], documents: Set(ids.prefix(count)), metadata: metadata)
        }
        // Build explicit usage counts without common-token replacement.
        metadata.tags = names.map { LibraryTag(name: $0) }
        metadata.tagsByDocument = Dictionary(uniqueKeysWithValues: ids.enumerated().map { index, id in
            (id.uuidString, Set(metadata.tags.prefix(index + 1).map(\.id)))
        })
        metadata.tagRecency = []
        for limit in [0, 1, 6, 8, 100] {
            let recent = TagEditor.recentTags(metadata: metadata, limit: limit)
            XCTAssertEqual(Set(recent.map(\.id)), Set(metadata.tags.prefix(min(limit, 8)).map(\.id)))
            XCTAssertEqual(recent.map(\.name), recent.map(\.name).sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        }
        let last = metadata.tags.last!
        metadata.tagRecency = [UUID(), last.id, last.id]
        XCTAssertEqual(TagEditor.recentTags(metadata: metadata, limit: 1), [last])
        XCTAssertEqual(TagEditor.recentTags(metadata: metadata).count, 6)
        metadata = TagEditor.edit([last.name], documents: [ids[0]], metadata: metadata)
        XCTAssertEqual(metadata.tagRecency.first, last.id)
        let encoded = try JSONEncoder().encode(metadata)
        XCTAssertEqual(try JSONDecoder().decode(LibraryMetadata.self, from: encoded), metadata)
        metadata = TagEditor.delete(last.id, metadata: metadata)
        XCTAssertFalse(metadata.tagRecency.contains(last.id))
        // Equal usage: natural name order is the fallback tie breaker.
        metadata.tagsByDocument = [ids[0].uuidString: Set(metadata.tags.map(\.id))]
        metadata.tagRecency = []
        XCTAssertEqual(TagEditor.recentTags(metadata: metadata, limit: 2).map(\.name), ["coffee", "draft"])
        XCTAssertTrue(TagEditor.recentTags(metadata: LibraryMetadata()).isEmpty)
    }

    func testRecencySurvivesRestartRenameMoveAndMerge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data("# Unchanged\n".utf8)
        try body.write(to: root.appendingPathComponent("A.md"))
        let initial = try await LibraryScanner.scan(root: root)
        let id = try XCTUnwrap(initial.metadata.IDsByPath["A.md"])
        let edited = try await TagStore.update(root: root) { TagEditor.edit(["coffee", "draft"], documents: [id], metadata: $0) }
        let coffee = try XCTUnwrap(TagEditor.existing("coffee", in: edited.tags))
        let draft = try XCTUnwrap(TagEditor.existing("draft", in: edited.tags))
        XCTAssertEqual(edited.tagRecency, [coffee.id, draft.id])
        _ = try await TagStore.update(root: root) { TagEditor.rename(coffee.id, to: "Coffee notes", metadata: $0) }
        let mutations = try LibraryMutations(root: root)
        _ = try await mutations.rename("A.md", to: "B.md")
        let plan = try await mutations.planMove(["B.md"], toFolder: "Folder")
        _ = try await mutations.executeMove(plan)
        let restarted = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(restarted.metadata.tagRecency, [coffee.id, draft.id])
        XCTAssertEqual(TagEditor.recentTags(metadata: restarted.metadata).map(\.name), ["Coffee notes", "draft"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Folder/B.md")), body)
        let merged = TagEditor.rename(coffee.id, to: "draft", metadata: restarted.metadata)
        XCTAssertEqual(merged.tagRecency, [draft.id])
    }

}

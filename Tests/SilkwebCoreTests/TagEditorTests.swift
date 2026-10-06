import XCTest
@testable import SilkwebCore

final class TagEditorTests: XCTestCase {
    func testNormalizationAndMultiSelection() throws {
        XCTAssertNil(TagEditor.normalize(" \n\t"))
        XCTAssertNil(TagEditor.normalize("a,b"))
        XCTAssertEqual(TagEditor.normalize("  Research\n notes  "), "Research notes")
        XCTAssertNotNil(TagEditor.normalize(String(repeating: "界", count: 64)))
        XCTAssertNil(TagEditor.normalize(String(repeating: "界", count: 65)))
        let a = UUID(), b = UUID()
        var metadata = LibraryMetadata(IDsByPath: ["a.md": a, "b.md": b])
        metadata = TagEditor.edit(["research", "private"], documents: [a], metadata: metadata)
        metadata = TagEditor.edit(["Research"], documents: [b], metadata: metadata)
        XCTAssertEqual(metadata.tags.count, 2)
        XCTAssertEqual(TagEditor.commonTags(documents: [a, b], metadata: metadata).count, 1)
        metadata = TagEditor.edit(["draft"], documents: [a, b], metadata: metadata)
        XCTAssertEqual(Set(metadata.tags.map(\.name)), ["private", "draft"])
        let privateID = try XCTUnwrap(metadata.tags.first { $0.name == "private" }?.id)
        XCTAssertTrue(metadata.tagsByDocument[a.uuidString]!.contains(privateID))
        XCTAssertFalse(metadata.tagsByDocument[b.uuidString]!.contains(privateID))
        metadata = TagEditor.rename(privateID, to: "DRAFT", metadata: metadata)
        XCTAssertEqual(metadata.tags.count, 1)
        metadata = TagEditor.delete(metadata.tags[0].id, metadata: metadata)
        XCTAssertTrue(metadata.tags.isEmpty)
        XCTAssertTrue(metadata.tagsByDocument.isEmpty)
    }

    /// #72 chips: applied/mixed coverage, add keeps queued edits, remove clears partial tags too.
    func testAppliedTagsAddAndRemoveAcrossSelections() throws {
        let a = UUID(), b = UUID(), c = UUID()
        var metadata = LibraryMetadata(IDsByPath: ["a.md": a, "b.md": b, "c.md": c])
        XCTAssertTrue(TagEditor.appliedTags(documents: [], metadata: metadata).isEmpty)
        XCTAssertTrue(TagEditor.appliedTags(documents: [a, b], metadata: metadata).isEmpty)
        metadata = TagEditor.edit(["camping", "coffee"], documents: [a], metadata: metadata)
        metadata = TagEditor.edit(["camping"], documents: [b], metadata: metadata)
        let camping = try XCTUnwrap(metadata.tags.first { $0.name == "camping" }?.id)
        let coffee = try XCTUnwrap(metadata.tags.first { $0.name == "coffee" }?.id)
        XCTAssertEqual(TagEditor.appliedTags(documents: [a], metadata: metadata), [camping: true, coffee: true])
        XCTAssertEqual(TagEditor.appliedTags(documents: [a, b], metadata: metadata), [camping: true, coffee: false])
        XCTAssertEqual(TagEditor.appliedTags(documents: [a, b, c], metadata: metadata), [camping: false, coffee: false])
        XCTAssertEqual(TagEditor.appliedTags(documents: [c], metadata: metadata), [:])

        // Adding never removes a common tag, even when the caller's view of it is stale.
        var added = TagEditor.add(["  Vanlife ", "COFFEE", "a,b", ""], documents: [a, b], metadata: metadata)
        XCTAssertEqual(TagEditor.appliedTags(documents: [a, b], metadata: added).filter(\.value).count, 3)
        XCTAssertEqual(Set(added.tags.map(\.name)), ["camping", "coffee", "Vanlife"], "Existing spelling is reused")
        XCTAssertEqual(added.tagRecency.first.flatMap { id in added.tags.first { $0.id == id }?.name }, "Vanlife")
        added = TagEditor.add(["vanlife"], documents: [a, b], metadata: added)
        XCTAssertEqual(added.tags.count, 3)
        XCTAssertEqual(TagEditor.add([], documents: [a], metadata: metadata).tagsByDocument, metadata.tagsByDocument)
        XCTAssertEqual(TagEditor.add(["x"], documents: [], metadata: metadata), metadata)

        // Removing a mixed tag clears it from every selected document only.
        var removed = TagEditor.remove(coffee, documents: [a, b], metadata: metadata)
        XCTAssertEqual(TagEditor.appliedTags(documents: [a, b], metadata: removed), [camping: true])
        XCTAssertFalse(removed.tags.contains { $0.id == coffee }, "An unused tag is pruned")
        removed = TagEditor.remove(camping, documents: [a], metadata: metadata)
        XCTAssertEqual(TagEditor.appliedTags(documents: [b], metadata: removed), [camping: true])
        XCTAssertEqual(TagEditor.remove(UUID(), documents: [a], metadata: metadata).tagsByDocument, metadata.tagsByDocument)
        XCTAssertEqual(TagEditor.remove(camping, documents: [c], metadata: metadata).tagsByDocument, metadata.tagsByDocument)
    }

    func testFolderTagSearchPredicateSweep() {
        let folder = LibraryFolder(id: UUID(), parentID: nil, relativePath: "Folder", name: "Folder")
        let nested = UUID(), tag = UUID(), other = UUID()
        let documents = [
            LibraryDocument(id: UUID(), folderID: folder.id, relativePath: "Folder/A.md", name: "A.md"),
            LibraryDocument(id: UUID(), folderID: nested, relativePath: "Folder/Nested/B.md", name: "B.md"),
            LibraryDocument(id: UUID(), folderID: UUID(), relativePath: "Elsewhere/C.md", name: "C.md")
        ]
        var metadata = LibraryMetadata()
        metadata.tagsByDocument = [documents[0].id.uuidString: [tag, other], documents[1].id.uuidString: [tag]]
        for scoped in [false, true] {
            for recursive in [false, true] {
                for filters: Set<UUID> in [[], [tag], [tag, other], [UUID()]] {
                    for search: Set<UUID>? in [nil, [], Set(documents.map(\.id)), [documents[1].id]] {
                        for (index, document) in documents.enumerated() {
                            let expectedFolder = !scoped || index == 0 || (recursive && index == 1)
                            let expectedTags = filters.isSubset(of: index == 0 ? [tag, other] : index == 1 ? [tag] : [])
                            XCTAssertEqual(TagEditor.matches(document, folder: scoped ? folder : nil, includeSubfolders: recursive,
                                tags: filters, metadata: metadata, searchIDs: search),
                                expectedFolder && expectedTags && (search?.contains(document.id) ?? true))
                        }
                    }
                }
            }
        }
    }

    func testLegacyRestartMoveAndPrunedPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data("# Original\n#hashtag\n".utf8)
        try body.write(to: root.appendingPathComponent("A.md"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Destination"), withIntermediateDirectories: false)
        var snapshot = try await LibraryScanner.scan(root: root)
        let document = try XCTUnwrap(snapshot.documents.first)
        let legacy = LibraryMetadata(IDsByPath: snapshot.metadata.IDsByPath)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json["formatVersion"] = 1; json.removeValue(forKey: "tags"); json.removeValue(forKey: "tagsByDocument")
        try JSONSerialization.data(withJSONObject: json).write(to: root.appendingPathComponent(".silkweb/index.json"))
        snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertTrue(snapshot.metadata.tags.isEmpty)
        _ = try await TagStore.update(root: root) { TagEditor.edit(["research"], documents: [document.id], metadata: $0) }
        snapshot = try await LibraryScanner.scan(root: root)
        let tagID = try XCTUnwrap(snapshot.metadata.tags.first?.id)
        let engine = try LibraryMutations(root: root)
        _ = try await engine.rename("A.md", to: "Renamed.md")
        let plan = try await engine.planMove(["Renamed.md"], toFolder: "Destination")
        _ = try await engine.executeMove(plan)
        let restarted = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(restarted.documents.first?.id, document.id)
        XCTAssertEqual(restarted.metadata.tagsByDocument[document.id.uuidString], [tagID])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Destination/Renamed.md")), body)
        var session = LibrarySession()
        session.selectedTagID = tagID
        session.listPreferences = ["all": .init(), "tag:" + tagID.uuidString: .init(), "folder:" + UUID().uuidString: .init(), "tag:" + UUID().uuidString: .init()]
        session = session.pruningPreferences(folderIDs: [], tagIDs: [tagID])
        XCTAssertEqual(session.listPreferences.count, 2)
        try await session.save(root: root)
        let loaded = try await LibrarySession.load(root: root)
        XCTAssertEqual(loaded, session)
    }
}

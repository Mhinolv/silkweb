import Foundation
import XCTest

@testable import SilkwebCore

final class TrashServiceTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    private func write(_ path: String, root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("text".utf8).write(to: url)
    }
    private func service(root: URL, trash: URL, fail: String? = nil) throws -> TrashService {
        try TrashService(root: root) { url in
            if url.lastPathComponent == fail { throw CocoaError(.fileWriteNoPermission) }
            let target = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: target)
            return target
        }
    }
    func testCountsHiddenAttachmentsSymlinksAndNestedSelection() async throws {
        let root = try fixture()
        let outside = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        for path in ["Folder/One.md", "Folder/Child/Two.MARKDOWN", "Folder/image.png", "Folder/.hidden"] {
            try write(path, root: root)
        }
        try write("private.md", root: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("Folder/link"), withDestinationURL: outside)
        let service = try TrashService(root: root)
        let plan = try await service.plan(["Folder", "Folder/One.md", "Folder"])
        XCTAssertEqual(plan.paths, ["Folder"])
        XCTAssertTrue(plan.needsConfirmation)
        XCTAssertEqual(plan.counts.documents, 2)
        XCTAssertEqual(plan.counts.folders, 1)
        XCTAssertEqual(plan.counts.otherFiles, 3)
        XCTAssertTrue(plan.contains("Folder/Child/Two.MARKDOWN"))
        XCTAssertFalse(plan.contains("Folder2/One.md"))
        XCTAssertEqual(plan.counts.summary, "2 documents, 1 folder, 3 other files")
        for paths in [
            [], [""], ["../private.md"], ["/Folder"], ["Folder//One.md"], ["Folder", "Folder/link/private.md"],
            [".silkweb"],
        ] {
            do { _ = try await service.plan(paths); XCTFail("Accepted unsafe selection: \(paths)") } catch {}
        }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("private.md"), encoding: .utf8), "text")
    }
    func testEmptyDocumentsAndStaleConfirmation() async throws {
        let root = try fixture()
        let trash = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Empty"), withIntermediateDirectories: false)
        try write("One.md", root: root)
        let service = try service(root: root, trash: trash)
        for paths in [["Empty"], ["One.md"], ["Empty", "One.md"]] {
            let plan = try await service.plan(paths)
            XCTAssertFalse(plan.needsConfirmation)
            XCTAssertEqual(plan.counts.summary, "")
        }
        let plan = try await service.plan(["Empty", "One.md"])
        try write("Empty/new.png", root: root)
        do { _ = try await service.execute(plan); XCTFail("Accepted changed descendants") } catch {
            XCTAssertTrue(error is TrashError)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("One.md").path))
    }
    func testPartialFailureRestoreConflictAndStableIdentity() async throws {
        let root = try fixture()
        let trash = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        for path in ["A.md", "B.md", "Folder/C.md"] { try write(path, root: root) }
        let before = try await LibraryScanner.scan(root: root)
        let service = try service(root: root, trash: trash, fail: "B.md")
        let plan = try await service.plan(["A.md", "B.md", "Folder"])
        let result = try await service.execute(plan)
        XCTAssertEqual(result.items.map(\.originalPath), ["A.md", "Folder"])
        XCTAssertEqual(result.failures.map(\.path), ["B.md"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("B.md").path))
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("A.md"), encoding: .utf8), "text")
        _ = try await LibraryScanner.scan(root: root)
        try write("A.md", root: root)
        let restored = await service.restore(result.items)
        XCTAssertEqual(restored.items.map(\.originalPath), ["Folder"])
        XCTAssertEqual(restored.failures.map(\.path), ["A.md"])
        XCTAssertTrue(restored.failures[0].reason.contains("now exists"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("A.md").path))
        let after = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(after.metadata.IDsByPath["Folder/C.md"], before.metadata.IDsByPath["Folder/C.md"])
    }
    func testSelectionSweepAndLargeInventory() async throws {
        for size in 0...20 {
            let rows = (0..<size).map(String.init)
            for start in 0..<max(1, size) {
                for end in start..<max(1, size) {
                    let removed = Set(rows.dropFirst(start).prefix(end - start + 1))
                    let next = DeletionSelection.successor(in: rows, removing: removed)
                    let expected =
                        removed.isEmpty
                        ? nil : (end + 1 < size ? String(end + 1) : (start > 0 ? String(start - 1) : nil))
                    XCTAssertEqual(next, expected)
                }
            }
        }
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for i in 0..<1000 { try write("Folder/Sub\(i)/Note.md", root: root) }
        let plan = try await TrashService(root: root).plan(["Folder"])
        XCTAssertEqual(plan.counts.documents, 1000)
        XCTAssertEqual(plan.counts.folders, 1000)
    }
    private func tag(_ names: [String], _ path: String, root: URL) async throws {
        _ = try await TagStore.update(root: root) { metadata in
            TagEditor.edit(names, documents: [metadata.IDsByPath[path]!], metadata: metadata)
        }
    }
    /// silkweb-1.71: undo restores tag assignments, definitions and recency the post-trash scan pruned.
    func testRestoreBringsBackTagsOfDocumentsAndDescendants() async throws {
        let root = try fixture()
        let trash = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        for path in ["Note.md", "Folder/A.md", "Folder/Sub/B.md", "Other.md"] { try write(path, root: root) }
        _ = try await LibraryScanner.scan(root: root)
        try await tag(["Shared", "Mid"], "Other.md", root: root)
        try await tag(["Deep"], "Folder/Sub/B.md", root: root)
        try await tag(["Folder Only", "Shared"], "Folder/A.md", root: root)
        try await tag(["Unique", "Shared"], "Note.md", root: root)
        let before = try await LibraryScanner.scan(root: root).metadata
        XCTAssertEqual(before.tags.count, 5)
        let service = try service(root: root, trash: trash)
        let result = try await service.execute(try await service.plan(["Note.md", "Folder"]))
        XCTAssertEqual(result.failures.map(\.path), [])
        let pruned = try await LibraryScanner.scan(root: root).metadata
        XCTAssertEqual(Set(pruned.tags.map(\.name)), ["Shared", "Mid"])
        // Unrelated edits while the items are in Trash survive the restore.
        try await tag(["Shared", "Mid", "Later"], "Other.md", root: root)
        let restored = await service.restore(result.items)
        XCTAssertEqual(restored.failures.map(\.path), [])
        let after = try await LibraryScanner.scan(root: root).metadata
        XCTAssertEqual(after.IDsByPath, before.IDsByPath)
        for path in ["Note.md", "Folder/A.md", "Folder/Sub/B.md"] {
            let id = before.IDsByPath[path]!.uuidString
            XCTAssertEqual(after.tagsByDocument[id], before.tagsByDocument[id], path)
        }
        let other = before.IDsByPath["Other.md"]!.uuidString
        XCTAssertEqual(Set(after.tags.map(\.name)), Set(before.tags.map(\.name)).union(["Later"]))
        XCTAssertEqual(after.tagsByDocument[other]?.count, 3)
        for tag in before.tags { XCTAssertEqual(after.tags.first { $0.id == tag.id }?.name, tag.name) }
        let later = after.tags.first { $0.name == "Later" }!.id
        XCTAssertEqual(after.tagRecency, [later] + before.tagRecency)
    }
    func testRestoreMergesIntoRecreatedTagNameAndPartialRecency() throws {
        let note = UUID(), shared = LibraryTag(name: "Shared"), unique = LibraryTag(name: "Unique"),
            other = LibraryTag(name: "Other")
        let tags = TrashedTags(
            tags: [shared, unique], tagsByDocument: [note.uuidString: [shared.id, unique.id]],
            tagRecency: [unique.id, other.id, shared.id])
        // After trash the user re-created "unique" (different ID) and kept using "Other".
        let recreated = LibraryTag(name: "UNIQUE")
        var current = LibraryMetadata(IDsByPath: ["Note.md": note, "X.md": UUID()])
        current.tags = [other, recreated]
        current.tagsByDocument = [current.IDsByPath["X.md"]!.uuidString: [other.id, recreated.id]]
        current.tagRecency = [recreated.id, other.id]
        let merged = TagEditor.pruning(tags.merged(into: current))
        XCTAssertEqual(Set(merged.tagsByDocument[note.uuidString] ?? []), [shared.id, recreated.id])
        XCTAssertEqual(merged.tags.map(\.name).sorted(), ["Other", "Shared", "UNIQUE"])
        XCTAssertEqual(merged.tagRecency, [recreated.id, other.id, shared.id])
        // Missing first anchor goes to the front; an empty payload is a no-op.
        current.tagRecency = [other.id]
        XCTAssertEqual(
            TrashedTags(
                tags: [shared], tagsByDocument: [note.uuidString: [shared.id]], tagRecency: [shared.id, other.id]
            )
            .merged(into: current).tagRecency, [shared.id, other.id])
        XCTAssertEqual(TrashedTags().merged(into: current), current)
    }
    func testTrashedItemWithoutTagPayloadDecodes() throws {
        let id = UUID()
        let legacy = Data(
            #"{"originalPath":"A.md","trashURL":"file:///tmp/A.md","identities":{"A.md":"\#(id.uuidString)"}}"#.utf8)
        let item = try JSONDecoder().decode(TrashedItem.self, from: legacy)
        XCTAssertEqual(item.identities, ["A.md": id])
        XCTAssertEqual(item.tags, TrashedTags())
        let round = try JSONDecoder().decode(TrashedItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(round.originalPath, "A.md")
        XCTAssertEqual(round.tags, item.tags)
    }
    /// silkweb-1.73: on-disk names that predate the new-name rules can still be trashed and put back.
    func testLegacyColonNamesTrashAndRestore() async throws {
        let root = try fixture()
        let trash = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        for path in ["Meeting 10:04.md", "Notes 9:30/Inner 1:2.md", "Other.md"] { try write(path, root: root) }
        let before = try await LibraryScanner.scan(root: root)
        let service = try service(root: root, trash: trash)
        let plan = try await service.plan(["Meeting 10:04.md", "Notes 9:30"])
        XCTAssertEqual(plan.paths, ["Meeting 10:04.md", "Notes 9:30"])
        let result = try await service.execute(plan)
        XCTAssertEqual(result.failures.map(\.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting 10:04.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Notes 9:30").path))
        _ = try await LibraryScanner.scan(root: root)
        let restored = await service.restore(result.items)
        XCTAssertEqual(restored.failures.map(\.path), [])
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Notes 9:30/Inner 1:2.md"), encoding: .utf8), "text")
        let after = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(after.metadata.IDsByPath, before.metadata.IDsByPath)
        // Structural checks still refuse paths that escape or reach hidden entries.
        for paths in [["Meeting 10:04.md/.."], [".silkweb"], ["./Other.md"], ["Notes 9:30//Inner 1:2.md"]] {
            do { _ = try await service.plan(paths); XCTFail("Accepted unsafe selection: \(paths)") } catch {}
        }
    }
}

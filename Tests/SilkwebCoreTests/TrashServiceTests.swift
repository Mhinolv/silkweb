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
        for path in ["Folder/One.md", "Folder/Child/Two.MARKDOWN", "Folder/image.png", "Folder/.hidden"] { try write(path, root: root) }
        try write("private.md", root: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Folder/link"), withDestinationURL: outside)
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
        for paths in [[], [""], ["../private.md"], ["/Folder"], ["Folder//One.md"], ["Folder", "Folder/link/private.md"], [".silkweb"]] {
            do { _ = try await service.plan(paths); XCTFail("Accepted unsafe selection: \(paths)") } catch { }
        }
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("private.md"), encoding: .utf8), "text")
    }
    func testEmptyDocumentsAndStaleConfirmation() async throws {
        let root = try fixture()
        let trash = try fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: false)
        try write("One.md", root: root)
        let service = try service(root: root, trash: trash)
        for paths in [["Empty"], ["One.md"], ["Empty", "One.md"]] {
            let plan = try await service.plan(paths)
            XCTAssertFalse(plan.needsConfirmation)
            XCTAssertEqual(plan.counts.summary, "")
        }
        let plan = try await service.plan(["Empty", "One.md"])
        try write("Empty/new.png", root: root)
        do { _ = try await service.execute(plan); XCTFail("Accepted changed descendants") } catch { XCTAssertTrue(error is TrashError) }
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
                    let expected = removed.isEmpty ? nil : (end + 1 < size ? String(end + 1) : (start > 0 ? String(start - 1) : nil))
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
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes 9:30/Inner 1:2.md"), encoding: .utf8), "text")
        let after = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(after.metadata.IDsByPath, before.metadata.IDsByPath)
        // Structural checks still refuse paths that escape or reach hidden entries.
        for paths in [["Meeting 10:04.md/.."], [".silkweb"], ["./Other.md"], ["Notes 9:30//Inner 1:2.md"]] {
            do { _ = try await service.plan(paths); XCTFail("Accepted unsafe selection: \(paths)") } catch { }
        }
    }
}

import Foundation
import XCTest

@testable import SilkwebCore

final class AssetMigrationTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    func testConflictAdoptionAndMarkedScanExclusion() async throws {
        for conflict in [false, true] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            try write("image", "media/nested/image.png", in: root)
            if conflict { try write("user note", "media/nested/user.MD", in: root) }
            try write("note", "note.md", in: root)
            let batch = await AssetStore().add(
                [.init(name: "asset.md", isImage: false, data: Data("hidden asset".utf8))], root: root,
                document: root.appendingPathComponent("note.md"), id: UUID())
            let name = conflict ? "Media Assets" : "media"
            XCTAssertTrue(MediaDirectory.isMarked(root.appendingPathComponent(name)))
            XCTAssertEqual(batch.assets.count, 1)
            XCTAssertTrue(batch.assets[0].url.path.hasPrefix(root.appendingPathComponent(name).path + "/"))
            let snapshot = try await LibraryScanner.scan(root: root)
            XCTAssertFalse(snapshot.folders.contains { $0.relativePath == name })
            XCTAssertFalse(snapshot.documents.contains { $0.relativePath.hasPrefix(name + "/") })
            XCTAssertEqual(snapshot.documents.count, conflict ? 2 : 1)
            XCTAssertEqual(snapshot.presentation.counts[snapshot.folders[0].id]?.recursive, conflict ? 2 : 1)
            let search = SearchIndex(root: root)
            try await search.reconcile(snapshot)
            let hiddenHits = try await search.query(SearchQuery("hidden asset"))
            XCTAssertTrue(hiddenHits.isEmpty)
            let quickHits = try await search.query(SearchQuery("asset", mode: .quickOpen))
            XCTAssertTrue(quickHits.isEmpty)
            let trash = try TrashService(
                root: root,
                trash: { url in
                    let destination = root.appendingPathComponent(".trashed-note.md")
                    try FileManager.default.moveItem(at: url, to: destination)
                    return destination
                })
            let deletion = try await trash.plan(["note.md"])
            let trashed = try await trash.execute(deletion)
            XCTAssertTrue(trashed.failures.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: batch.assets[0].url.path))
        }
    }

    func testMigrationCollisionResumeAndMove() async throws {
        for limit in [0, 1, 2, 10] {
            let root = try root()
            defer { try? FileManager.default.removeItem(at: root) }
            try write("one", ".silkweb-assets/id/a b.png", in: root)
            try write("two", ".silkweb-assets/id/other.png", in: root)
            try write("existing", "media/id/a b.png", in: root)
            try write(
                "![one](../.silkweb-assets/id/a%20b.png)\n[other]: ../.silkweb-assets/id/other.png\n![two][other]",
                "Notes/note.md", in: root)
            try write("![one](.silkweb-assets/id/a%20b.png)", "root.md", in: root)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Destination"), withIntermediateDirectories: true)
            let store = AssetStore()
            let first = await store.migrate(root: root, documents: ["Notes/note.md", "root.md"], fileLimit: limit)
            XCTAssertTrue(first.failures.isEmpty, "\(first.failures)")
            if limit < 2 {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(".silkweb-assets/id/a b.png").path))
                XCTAssertTrue(
                    try String(contentsOf: root.appendingPathComponent("Notes/note.md"), encoding: .utf8).contains(
                        ".silkweb-assets"))
            }
            let resumed = await store.migrate(root: root, documents: ["Notes/note.md", "root.md"])
            XCTAssertTrue(resumed.failures.isEmpty, "\(resumed.failures)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".silkweb-assets").path))
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent("media/id/a b.png"), encoding: .utf8), "existing")
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent("media/id/a b 2.png"), encoding: .utf8), "one")
            let text = try String(contentsOf: root.appendingPathComponent("Notes/note.md"), encoding: .utf8)
            XCTAssertFalse(text.contains(".silkweb-assets"))
            XCTAssertTrue(text.contains("../media/id/a%20b%202.png"))
            for offline in [false, true] {
                let html = HTMLRenderer.render(
                    text,
                    options: .init(
                        libraryRoot: root, documentURL: root.appendingPathComponent("Notes/note.md"),
                        offlinePreview: offline))
                XCTAssertTrue(html.contains("<img"))
                XCTAssertTrue(html.contains("media/id/a%20b%202.png"), html)
            }
            let asset = root.appendingPathComponent("media/id/a b 2.png")
            let resource = try XCTUnwrap(PreviewResource.assetURL(for: asset, root: root))
            XCTAssertEqual(PreviewResource.fileURL(for: resource, root: root), asset)
            _ = await store.migrate(root: root, documents: ["Notes/note.md", "root.md"])
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Notes/note.md"), encoding: .utf8), text)
            _ = try await LibraryScanner.scan(root: root)
            let engine = try LibraryMutations(root: root)
            let plan = try await engine.planMove(["Notes/note.md"], toFolder: "Destination")
            _ = try await engine.executeMove(plan)
            let moved = try String(contentsOf: root.appendingPathComponent("Destination/note.md"), encoding: .utf8)
            var paths: [String] = []
            _ = MarkdownDestinations.rewrite(
                moved, source: "Destination/note.md", changes: .init(changes: []), visit: { paths.append($0) })
            XCTAssertFalse(paths.isEmpty)
            for path in paths {
                let url = root.appendingPathComponent("Destination").appendingPathComponent(
                    try XCTUnwrap(path.removingPercentEncoding)
                ).standardizedFileURL
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), path)
            }
            let journal =
                try JSONSerialization.jsonObject(
                    with: Data(contentsOf: root.appendingPathComponent(".silkweb/media-migration.json")))
                as! [String: Any]
            XCTAssertEqual(journal["formatVersion"] as? Int, 1)
            XCTAssertEqual(journal["completed"] as? Bool, true)
        }
    }

    func testReadOnlyLegacyAndInterruptedRewrite() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("image", ".silkweb-assets/id/image.png", in: root)
        try write("![x](.silkweb-assets/id/image.png)", "note.md", in: root)
        let store = AssetStore()
        _ = await store.migrate(root: root, documents: ["note.md"], readOnly: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("media").path))
        let legacy = root.appendingPathComponent(".silkweb-assets/id/image.png")
        XCTAssertEqual(
            PreviewResource.fileURL(for: try XCTUnwrap(PreviewResource.assetURL(for: legacy, root: root)), root: root),
            legacy)
        XCTAssertTrue(
            HTMLRenderer.render(
                "![x](.silkweb-assets/id/image.png)",
                options: .init(
                    libraryRoot: root, documentURL: root.appendingPathComponent("note.md"), offlinePreview: true)
            ).contains("<img"))
        let blocked = await store.migrate(root: root, documents: ["note.md"], beforeRewrite: { false })
        XCTAssertFalse(blocked.failures.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".silkweb-assets/id/image.png").path))
        let resumed = await store.migrate(root: root, documents: ["note.md"])
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8), "![x](media/id/image.png)")
    }

    func testSharedResolverPreservesUnicodeAndExistingPercentEscapes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for folder in ["media", "Media Assets", ".silkweb-assets"] {
            let path = folder + "/id/日本語(#?%).png"
            try write("image", path, in: root)
            let encoded = AssetStore.encodePath(path)
            let document = root.appendingPathComponent("note.md")
            XCTAssertEqual(
                PreviewResource.resolve(encoded, relativeTo: document)?.path, root.appendingPathComponent(path).path)
            let html = HTMLRenderer.render(
                "![x](\(encoded))", options: .init(libraryRoot: root, documentURL: document, offlinePreview: true))
            XCTAssertTrue(html.contains("<img"), html)
            XCTAssertFalse(html.contains("sw-missing-image"))
        }
    }

    func testPartialDocumentRewriteRetainsLegacyThenResumes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("image", ".silkweb-assets/id/image.png", in: root)
        try write("![x](.silkweb-assets/id/image.png)", "A.md", in: root)
        try Data([0xff, 0xfe]).write(to: root.appendingPathComponent("B.md"))
        let store = AssetStore()
        let partial = await store.migrate(root: root, documents: ["A.md", "B.md"])
        XCTAssertFalse(partial.failures.isEmpty)
        XCTAssertTrue(
            try String(contentsOf: root.appendingPathComponent("A.md"), encoding: .utf8).contains("media/id/image.png"))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".silkweb-assets/id/image.png").path))
        try write("![x](.silkweb-assets/id/image.png)", "B.md", in: root)
        let resumed = await store.migrate(root: root, documents: ["A.md", "B.md"])
        XCTAssertTrue(resumed.completed)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("media/id").path),
            ["image.png"])
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("B.md"), encoding: .utf8), "![x](media/id/image.png)")
    }

    func testMigrationUsesFallbackAndPreservesUserNotes() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("user", "media/nested/user.md", in: root)
        try write("image", ".silkweb-assets/id/image.png", in: root)
        try write("![x](.silkweb-assets/id/image.png)", "note.md", in: root)
        let result = await AssetStore().migrate(root: root, documents: ["note.md", "media/nested/user.md"])
        XCTAssertTrue(result.completed)
        XCTAssertEqual(result.directoryName, "Media Assets")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("note.md"), encoding: .utf8),
            "![x](Media%20Assets/id/image.png)")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("media/nested/user.md"), encoding: .utf8), "user")
        let scan = try await LibraryScanner.scan(root: root)
        XCTAssertTrue(scan.folders.contains { $0.relativePath == "media/nested" })
        XCTAssertFalse(scan.folders.contains { $0.relativePath == "Media Assets" })
    }

    func testImportRetainsMarkerAndLinkedMediaWithoutImportingAssetDocuments() async throws {
        let source = try root(), destination = try root()
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: destination) }
        try write("![x](media/id/image.png)", "note.md", in: source)
        try write("image", "media/id/image.png", in: source)
        try write("asset, not a note", "media/id/attachment.md", in: source)
        try write("marker", "media/.silkweb-media", in: source)
        let direct = try FolderImporter.plan(
            source: source.appendingPathComponent("media"), library: destination, destination: "")
        XCTAssertEqual(direct.documentCount, 0)
        let plan = try FolderImporter.plan(source: source, library: destination, destination: "")
        XCTAssertEqual(plan.documentCount, 1)
        let path = try FolderImporter.copy(plan)
        XCTAssertTrue(MediaDirectory.isMarked(destination.appendingPathComponent(path + "/media")))
        let snapshot = try await LibraryScanner.scan(root: destination)
        XCTAssertEqual(snapshot.documents.count, 1)
        XCTAssertFalse(snapshot.folders.contains { $0.relativePath.contains("media") })
    }
}

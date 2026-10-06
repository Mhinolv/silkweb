import Foundation
import XCTest

@testable import SilkwebCore

final class AssetStoreTests: XCTestCase {
    func testBatchCollisionsEncodingFailuresAndExistingDocuments() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("A/B"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("A/B/old.md")
        try "old text".write(to: document, atomically: true, encoding: .utf8)
        let id = UUID()
        let store = AssetStore()
        let name = "Ünïcode photo(#?%).png"
        let inputs =
            (0..<3).map { AssetInput(name: name, isImage: true, data: Data([$0])) }
            + [
                AssetInput(name: "report.pdf", isImage: false, data: Data([9])),
                AssetInput(name: "missing.png", isImage: true, file: root.appendingPathComponent("missing.png")),
            ]
        let batch = await store.add(inputs, root: root, document: document, id: id)
        XCTAssertEqual(batch.assets.count, 4, "\(batch.failures)")
        guard batch.assets.count == 4 else { return }
        XCTAssertEqual(batch.failures.count, 1)
        XCTAssertEqual(
            batch.assets.map { $0.url.lastPathComponent },
            [name, "Ünïcode photo(#?%) 2.png", "Ünïcode photo(#?%) 3.png", "report.pdf"])
        XCTAssertEqual(batch.assets[0].path, "../../media/\(id.uuidString)/Ünïcode%20photo%28%23%3F%25%29.png")
        XCTAssertTrue(batch.assets[3].markdown.hasPrefix("[report.pdf]"))
        for (index, asset) in batch.assets.enumerated() {
            XCTAssertEqual(try Data(contentsOf: asset.url), Data([index == 3 ? 9 : UInt8(index)]))
            XCTAssertEqual(
                document.deletingLastPathComponent().appendingPathComponent(
                    try XCTUnwrap(asset.path.removingPercentEncoding)
                ).standardizedFileURL, asset.url)
        }
        let scanned = try await LibraryScanner.scan(root: root)
        XCTAssertTrue(MediaDirectory.isMarked(root.appendingPathComponent("media")))
        XCTAssertEqual(scanned.documents.count, 1)
        XCTAssertFalse(scanned.folders.contains { $0.relativePath.contains("media") })
        XCTAssertEqual(try String(contentsOf: document, encoding: .utf8), "old text")
        let changed = LibraryChangeSet(changes: [
            .init(id: id, oldPath: "A/B/old.md", newPath: "moved.md", isFolder: false)
        ])
        let rewritten = MarkdownDestinations.rewrite(batch.assets[0].markdown, source: "A/B/old.md", changes: changed)
        var paths: [String] = []
        _ = MarkdownDestinations.rewrite(
            rewritten.text, source: "moved.md", changes: .init(changes: []), visit: { paths.append($0) })
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(
            root.appendingPathComponent(try XCTUnwrap(paths.first?.removingPercentEncoding)).standardizedFileURL,
            batch.assets[0].url)
        let brackets = await store.add(
            [.init(name: "a[b]\\c.png", isImage: true, data: Data())], root: root, document: document, id: id)
        let bracketAsset = try XCTUnwrap(brackets.assets.first)
        let bracketMove = MarkdownDestinations.rewrite(bracketAsset.markdown, source: "A/B/old.md", changes: changed)
        XCTAssertTrue(bracketMove.unsupported.isEmpty)
        paths = []
        _ = MarkdownDestinations.rewrite(
            bracketMove.text, source: "moved.md", changes: .init(changes: []), visit: { paths.append($0) })
        XCTAssertEqual(paths.count, 1)
        XCTAssertEqual(
            root.appendingPathComponent(try XCTUnwrap(paths.first?.removingPercentEncoding)).standardizedFileURL,
            bracketAsset.url)
    }

    func testEmptyBoundaryNamesAndSymlinkDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore()
        let document = root.appendingPathComponent("doc.md")
        let names = [
            "", ".hidden", "a/b", "a:b", "a\nb", String(repeating: "x", count: 256), "x",
            String(repeating: "x", count: 255),
        ]
        let result = await store.add(
            names.map { .init(name: $0, isImage: false, data: Data()) }, root: root, document: document, id: UUID())
        XCTAssertEqual(result.failures.count, 6)
        XCTAssertEqual(result.assets.count, 2)
        let empty = await store.add([], root: root, document: document, id: UUID())
        XCTAssertTrue(empty.assets.isEmpty)
        let outside = await store.add(
            [.init(name: "x", isImage: true, data: Data())], root: root,
            document: root.deletingLastPathComponent().appendingPathComponent("outside.md"), id: UUID())
        XCTAssertEqual(outside.failures.count, 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("media"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("media"), withDestinationURL: root)
        let link = await store.add(
            [.init(name: "x", isImage: true, data: Data())], root: root, document: document, id: UUID())
        XCTAssertEqual(link.failures.count, 1)
    }

    func testInsertionSweep() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AssetStore()
        let batch = await store.add(
            [
                .init(name: "日本語.png", isImage: true, data: Data()), .init(name: "x.pdf", isImage: false, data: Data()),
                .init(name: "last.png", isImage: true, data: Data()),
            ], root: root, document: root.appendingPathComponent("doc.md"), id: UUID())
        XCTAssertEqual(batch.assets.count, 3, "\(batch.failures)")
        guard batch.assets.count == 3 else { return }
        for text in ["", "a", "a\nb", "👩🏽‍💻", String(repeating: "line\n", count: 10000)] {
            for images in [
                Array(batch.assets.prefix(1)), Array(batch.assets.prefix(2)), batch.assets, Array(batch.assets[1...1]),
            ] {
                for location in [0, text.utf16.count / 2, text.utf16.count] {
                    for length in [0, text.utf16.count - location] {
                        let edit = try XCTUnwrap(
                            AssetStore.insertion(
                                images, text: text, selection: NSRange(location: location, length: length)))
                        let result = edit.applying(to: text) as NSString
                        XCTAssertLessThanOrEqual(NSMaxRange(edit.selection), result.length)
                        if images.contains(where: \.isImage) {
                            XCTAssertEqual(result.substring(with: edit.selection), images.last(where: \.isImage)?.alt)
                        }
                        XCTAssertTrue(edit.replacement.contains(images[0].markdown))
                    }
                }
            }
        }
        XCTAssertNil(AssetStore.insertion([], text: "", selection: NSRange(location: 0, length: 0)))
    }
}

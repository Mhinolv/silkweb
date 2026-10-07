import XCTest

@testable import SilkwebCore

final class InlineImagesTests: XCTestCase {
    func testParagraphDetection() {
        let references = InlineImages.paragraph(
            "Text ![a [nested] label](one.png) and ![two](two%20words.png \"title\")\n")
        XCTAssertEqual(references.map(\.alt), ["a [nested] label", "two"])
        XCTAssertEqual(references.map(\.destination), ["one.png", "two%20words.png"])
        for source in [
            "`![x](a.png)`", "`` ![x](a.png) ``", #"\![x](a.png)"#, "```\n![x](a.png)\n```", "~~~\n![x](a.png)\n~~~",
        ] {
            XCTAssertTrue(InlineImages.paragraph(source).isEmpty, source)
        }
        // silkweb-1.72: the parser has no indented code, so indented (nested list) lines show their images.
        for source in ["    ![x](a.png)", "\t![x](a.png)", "    - ![x](a.png)", "\t\t![x](a.png)"] {
            XCTAssertEqual(InlineImages.paragraph(source).map(\.destination), ["a.png"], source)
        }
        XCTAssertEqual(InlineImages.paragraph("![escaped \\[alt\\]](a.png)").count, 1)
    }

    func testResolutionAndContainment() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("test.md")
        func resolve(_ path: String) -> InlineImages.Resource {
            InlineImages.resource(InlineImages.paragraph("![x](\(path))")[0], document: document, root: root)
        }
        XCTAssertEqual(resolve("two%20words.png"), .local(root.appendingPathComponent("two words.png")))
        XCTAssertEqual(resolve("https://example.invalid/a.png"), .remote)
        XCTAssertEqual(resolve("http://example.invalid/a.png"), .remote)
        XCTAssertEqual(resolve("../outside.png"), .outsideLibrary)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertEqual(resolve("escape/missing.png"), .outsideLibrary)
        XCTAssertEqual(resolve("%5Cevil.png"), .unreadable)
    }

    func testFitSweep() {
        for width in [1.0, 40, 400, 100_000] {
            for height in [1.0, 20, 240, 100_000] {
                for column in [1.0, 100, 720] {
                    for viewport in [1.0, 560, 1200] {
                        let size = InlineImages.fittedSize(
                            width: width, height: height, column: column, viewport: viewport)
                        XCTAssertLessThanOrEqual(size.width, min(width, column) + 0.001)
                        XCTAssertLessThanOrEqual(size.height, min(height, viewport * 0.7) + 0.001)
                        XCTAssertEqual(size.width / size.height, width / height, accuracy: 0.001)
                    }
                }
            }
        }
        XCTAssertEqual(InlineImages.fittedSize(width: 0, height: 20, column: 720, viewport: 560).width, 0)
    }

    /// #154: macOS screenshot names put U+202F (narrow no-break space) before AM/PM. A pasted screenshot,
    /// and the same reference written by hand or by earlier builds, resolves to the file on disk.
    func testScreenshotNameWithNarrowNoBreakSpaceResolves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("Notes/Day.md")
        try "".write(to: document, atomically: true, encoding: .utf8)
        let name = "Screenshot 2026-10-07 at 9.41.00\u{202F}AM.png"
        let id = UUID()
        let batch = await AssetStore().add(
            [AssetInput(name: name, isImage: true, data: Data([1]))], root: root, document: document, id: id)
        let asset = try XCTUnwrap(batch.assets.first, "\(batch.failures)")
        XCTAssertEqual(asset.url.lastPathComponent, name)
        let folder = "../media/" + id.uuidString + "/"
        let encoded = folder + "Screenshot%202026-10-07%20at%209.41.00%E2%80%AFAM.png"
        XCTAssertEqual(asset.path, encoded, "the Markdown text stays percent-encoded")
        for markdown in [
            asset.markdown, "![s](" + encoded + ")", "![s](<" + folder + name + ">)",
            "![s](" + folder + "Screenshot%202026-10-07%20at%209.41.00\u{202F}AM.png)",
        ] {
            let reference = try XCTUnwrap(InlineImages.paragraph(markdown).first, markdown)
            guard case .local(let url) = InlineImages.resource(reference, document: document, root: root) else {
                return XCTFail("not local: \(markdown)")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "\(markdown) → \(url.path)")
            // The preview serves the same file.
            let html = HTMLRenderer.render(
                markdown, options: .init(libraryRoot: root, documentURL: document, offlinePreview: true))
            let src = try XCTUnwrap(
                html.range(of: "src=\"silkweb-preview://asset/[^\"]*", options: .regularExpression), html)
            let asset = try XCTUnwrap(URL(string: String(html[src].dropFirst("src=\"".count))))
            let served = try XCTUnwrap(PreviewResource.fileURL(for: asset, root: root), asset.absoluteString)
            XCTAssertTrue(FileManager.default.fileExists(atPath: served.path), "\(markdown) → \(served.path)")
        }
    }
}

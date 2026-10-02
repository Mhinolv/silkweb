import XCTest
@testable import SilkwebCore

final class InlineImagesTests: XCTestCase {
    func testParagraphDetection() {
        let references = InlineImages.paragraph("Text ![a [nested] label](one.png) and ![two](two%20words.png \"title\")\n")
        XCTAssertEqual(references.map(\.alt), ["a [nested] label", "two"])
        XCTAssertEqual(references.map(\.destination), ["one.png", "two%20words.png"])
        for source in ["`![x](a.png)`", "`` ![x](a.png) ``", #"\![x](a.png)"#, "    ![x](a.png)", "\t![x](a.png)", "```\n![x](a.png)\n```", "~~~\n![x](a.png)\n~~~"] {
            XCTAssertTrue(InlineImages.paragraph(source).isEmpty, source)
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
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        XCTAssertEqual(resolve("escape/missing.png"), .outsideLibrary)
        XCTAssertEqual(resolve("%5Cevil.png"), .unreadable)
    }

    func testFitSweep() {
        for width in [1.0, 40, 400, 100_000] {
            for height in [1.0, 20, 240, 100_000] {
                for column in [1.0, 100, 720] {
                    for viewport in [1.0, 560, 1200] {
                        let size = InlineImages.fittedSize(width: width, height: height, column: column, viewport: viewport)
                        XCTAssertLessThanOrEqual(size.width, min(width, column) + 0.001)
                        XCTAssertLessThanOrEqual(size.height, min(height, viewport * 0.7) + 0.001)
                        XCTAssertEqual(size.width / size.height, width / height, accuracy: 0.001)
                    }
                }
            }
        }
        XCTAssertEqual(InlineImages.fittedSize(width: 0, height: 20, column: 720, viewport: 560).width, 0)
    }
}

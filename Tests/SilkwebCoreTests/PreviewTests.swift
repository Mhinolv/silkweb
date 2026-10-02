import XCTest
@testable import SilkwebCore

final class PreviewTests: XCTestCase {
    func testOfflineAssetAndLinkSweep() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        let document = root.appendingPathComponent("notes/a.md")
        for breaks in HTMLRenderer.LineBreaks.allCases {
            let options = HTMLRenderer.Options(lineBreaks: breaks, libraryRoot: root, documentURL: document, offlinePreview: true)
            for path in ["picture.png", "../picture.png", "a%20b.png"] {
                let html = HTMLRenderer.render("![alt](\(path))", options: options)
                XCTAssertTrue(html.contains("src=\"file:"), html)
                XCTAssertFalse(html.contains("src=\"\(path)"))
            }
            for path in ["https://example.com/a.png", "http://example.com/a.png", "data:image/png;base64,AA==", "../../outside.png", "../escape/test.png", "javascript:alert(1)", "//example.com/a.png"] {
                let html = HTMLRenderer.render("![alt](\(path))", options: options)
                XCTAssertFalse(html.contains("<img"), html)
            }
            for source in ["", "x", "# 日本語\n## 日本語", String(repeating: "# Heading\n\ntext\n", count: 1000)] {
                let parsed = MarkdownParser.parse(source)
                let html = HTMLRenderer.render(parsed, options: options)
                XCTAssertTrue(html.contains("sw-doc"))
                XCTAssertEqual(Set(parsed.headings.map(\.id)).count, parsed.headings.count)
            }
        }
    }

    func testNavigationPolicy() {
        let root = URL(fileURLWithPath: "/silkweb-preview-test")
        let document = root.appendingPathComponent("notes/a.md")
        let page = URL(fileURLWithPath: "/tmp/preview.html")
        func action(_ value: String) -> PreviewNavigation.Action {
            PreviewNavigation.action(for: URL(string: value, relativeTo: page)!.absoluteURL, document: document, root: root, page: page)
        }
        XCTAssertEqual(action("#heading"), .anchor("heading"))
        XCTAssertEqual(action("file:///silkweb-preview-test/notes/a.md#heading"), .anchor("heading"))
        XCTAssertEqual(action("file:///silkweb-preview-test/b.md"), .document(root.appendingPathComponent("b.md")))
        XCTAssertEqual(action("https://example.com"), .browser(URL(string: "https://example.com")!))
        for value in ["file:///silkweb-preview-test-other/a.md", "file:///tmp/a.md", "file:///silkweb-preview-test/../a.md", "file:///silkweb-preview-test/image.png", "mailto:a@example.com", "javascript:alert(1)", "data:text/html,test"] {
            XCTAssertEqual(action(value), .blocked, value)
        }
    }
}

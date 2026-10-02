import Foundation
import XCTest
@testable import SilkwebCore

final class PrintRenderingTests: XCTestCase {
    func testPrintVariantsAndCodeBoundaries() {
        let root = URL(fileURLWithPath: "/nonexistent-print-fixture")
        for lines in [0, 1, 13, 14, 15, 16, 1000] {
            for lineBreaks in HTMLRenderer.LineBreaks.allCases {
                for printing in [false, true] {
                    let code = Array(repeating: "<code> & " + String(repeating: "x", count: 300), count: lines).joined(separator: "\n")
                    let markdown = "# Title & <raw>\n\n- [ ] Pending\n- [x] Done\n\n```swift\n\(code)\n```\n\n| Wide | Table |\n| --- | --- |\n| \(String(repeating: "long", count: 300)) | wrap |\n\n![remote](https://example.invalid/never.png)\n![missing](absent.png)"
                    let result = HTMLExport.prepare(markdown: markdown, title: "Title", documentURL: root.appendingPathComponent("note.md"), libraryRoot: root, stylesheet: "PRINT-CSS", lineBreaks: lineBreaks, printOutput: printing)
                    XCTAssertTrue(result.html.contains("Title &amp;"))
                    XCTAssertTrue(result.html.contains("&lt;raw&gt;"))
                    XCTAssertEqual(result.html.contains("☐ Pending"), printing)
                    XCTAssertEqual(result.html.contains("☑ Done"), printing)
                    XCTAssertEqual(result.html.contains("<input"), !printing)
                    XCTAssertEqual(result.html.contains("sw-short-code"), printing && lines < 15)
                    XCTAssertEqual(result.html.contains("prefers-color-scheme: dark"), !printing)
                    XCTAssertTrue(result.html.contains("<thead>"))
                    XCTAssertFalse(result.html.contains("src=\"https:"))
                    XCTAssertEqual(result.missingAssets, ["absent.png"])
                }
            }
        }
    }

    func testPrintEmbedsLocalImageAndUsesSameContentRenderer() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZJkAAAAASUVORK5CYII=")!
        try data.write(to: root.appendingPathComponent("local.png"))
        let markdown = "[TOC]\n# Title\n\n**Body** & <script>bad</script>\n\n![Local](local.png)"
        let printed = HTMLExport.prepare(markdown: markdown, title: "Title", documentURL: root.appendingPathComponent("note.md"), libraryRoot: root, stylesheet: "", printOutput: true)
        let exported = HTMLExport.prepare(markdown: markdown, title: "Title", documentURL: root.appendingPathComponent("note.md"), libraryRoot: root, stylesheet: "")
        func body(_ html: String) -> String { html.components(separatedBy: "<body>")[1] }
        XCTAssertEqual(body(printed.html), body(exported.html))
        XCTAssertTrue(printed.html.contains("data:image/png;base64," + data.base64EncodedString()))
        XCTAssertFalse(printed.html.contains("<script>"))
        XCTAssertTrue(printed.missingAssets.isEmpty)
        XCTAssertTrue(HTMLExport.prepare(markdown: "", title: "", documentURL: root.appendingPathComponent("note.md"), libraryRoot: root, stylesheet: "", printOutput: true).html.contains("sw-empty"))
    }
}

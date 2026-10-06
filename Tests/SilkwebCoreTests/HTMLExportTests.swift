import Foundation
import XCTest

@testable import SilkwebCore

final class HTMLExportTests: XCTestCase {
    func testOfflineImagesBoundariesAndDeterminism() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data(
            base64Encoded:
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZJkAAAAASUVORK5CYII=")!
        try bytes.write(to: root.appendingPathComponent("日本 image.png"))
        try Data("<svg><script>alert(1)</script></svg>".utf8).write(to: root.appendingPathComponent("active.svg"))
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
        try bytes.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape.png"), withDestinationURL: outside)
        let markdown = """
            [TOC]
            # <Title> & 日本
            ![local](../日本%20image.png)
            ![duplicate](../日本%20image.png)
            ![missing & <alt>](missing.png)
            ![outside](../escape.png)
            ![svg](../active.svg)
            ![remote](https://example.invalid/image.png)
            [Next](next.md) [Anchor](#title)
            <script>alert("bad")</script>
            """
        for mode in HTMLRenderer.LineBreaks.allCases {
            let result = HTMLExport.prepare(
                markdown: markdown, title: "<Title> & 日本", documentURL: root.appendingPathComponent("nested/Doc.md"),
                libraryRoot: root, stylesheet: "", language: "en\" onload=\"bad", lineBreaks: mode)
            XCTAssertEqual(result.missingAssets, ["missing.png", "../escape.png", "../active.svg"])
            XCTAssertTrue(result.html.contains("data:image/png;base64," + bytes.base64EncodedString()))
            XCTAssertTrue(result.html.contains("Image not included: missing &amp; &lt;alt&gt;"))
            XCTAssertTrue(result.html.contains("href=\"https://example.invalid/image.png\""))
            XCTAssertFalse(result.html.contains("src=\"https:"))
            XCTAssertTrue(result.html.contains("href=\"next.md\""))
            XCTAssertTrue(result.html.contains("aria-label=\"Table of contents\""))
            XCTAssertTrue(result.html.contains("<title>&lt;Title&gt; &amp; 日本</title>"))
            XCTAssertFalse(result.html.contains("<script>"))
            XCTAssertTrue(result.html.contains("lang=\"en&quot; onload=&quot;bad\""))
            let destination = root.appendingPathComponent("output.html")
            try result.write(to: destination)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), result.html)
            XCTAssertEqual(
                result.html,
                HTMLExport.prepare(
                    markdown: markdown, title: "<Title> & 日本",
                    documentURL: root.appendingPathComponent("nested/Doc.md"), libraryRoot: root, stylesheet: "",
                    language: "en\" onload=\"bad", lineBreaks: mode
                ).html)
        }
    }

    func testWarningCountsEmptyAndNestedImages() {
        let root = URL(fileURLWithPath: "/nonexistent-export-fixture")
        for count in [0, 1, 5, 6, 1000] {
            let markdown = (0..<count).map { "> **![alt](image-\($0).png)**" }.joined(separator: "\n\n")
            let result = HTMLExport.prepare(
                markdown: markdown, title: "", documentURL: root.appendingPathComponent("doc.md"), libraryRoot: root,
                stylesheet: "")
            XCTAssertEqual(result.missingAssets.count, count)
            XCTAssertEqual(result.warningDetail.contains("and \(max(0, count - 5)) more"), count > 5)
            XCTAssertTrue(result.html.hasPrefix("<!doctype html>"))
        }
        let result = HTMLExport.prepare(
            markdown: "| Image |\n| --- |\n| ![table](table.png) |\n\nFoot[^a]\n\n[^a]: ![footnote](foot.png)",
            title: "Test", documentURL: root.appendingPathComponent("doc.md"), libraryRoot: root, stylesheet: "")
        XCTAssertEqual(result.missingAssets, ["table.png", "foot.png"])
    }

    /// #101: the [TOC] option reaches the renderer; it defaults to on, as in Preview.
    func testTableOfContentsOption() {
        let root = URL(fileURLWithPath: "/nonexistent-export-fixture")
        for printOutput in [false, true] {
            for shows: Bool? in [nil, false, true] {
                let markdown = "[TOC]\n\n[TOC]\n\n# One\n\n## Two"
                let document = root.appendingPathComponent("doc.md")
                let html =
                    shows.map {
                        HTMLExport.prepare(
                            markdown: markdown, title: "", documentURL: document, libraryRoot: root, stylesheet: "",
                            showsTableOfContents: $0, printOutput: printOutput)
                    }
                    ?? HTMLExport.prepare(
                        markdown: markdown, title: "", documentURL: document, libraryRoot: root, stylesheet: "",
                        printOutput: printOutput)
                let body = html.html.components(separatedBy: "<body>")[1]
                let navs = body.components(separatedBy: "<nav class=\"sw-toc\"").count - 1
                XCTAssertEqual(navs, shows == false ? 0 : 2, "\(String(describing: shows)) \(printOutput)")
                XCTAssertEqual(body.components(separatedBy: "<p>[TOC]</p>").count - 1, shows == false ? 2 : 0)
            }
        }
        let empty = HTMLExport.prepare(
            markdown: "[TOC]", title: "", documentURL: root.appendingPathComponent("doc.md"), libraryRoot: root,
            stylesheet: "", showsTableOfContents: false)
        XCTAssertTrue(empty.html.contains("<p>[TOC]</p>"))
    }

    func testPortableCSSAndInlineData() {
        let root = URL(fileURLWithPath: "/tmp")
        for source in [
            "data:image/png;base64,YQ==", "data:image/svg+xml;base64,YQ==", "javascript:alert(1)",
            "//example.invalid/a.png",
        ] {
            let result = HTMLExport.prepare(
                markdown: "![alt](\(source))", title: "", documentURL: root.appendingPathComponent("doc.md"),
                libraryRoot: root,
                stylesheet: "body { color: -apple-system-label; background: -apple-system-text-background; }")
            XCTAssertEqual(result.missingAssets.isEmpty, source == "data:image/png;base64,YQ==")
            XCTAssertFalse(result.html.contains("-apple-system-label"))
            XCTAssertTrue(result.html.contains("prefers-color-scheme: dark"))
            XCTAssertTrue(result.html.contains("@media print"))
        }
    }
}

import XCTest
@testable import SilkwebCore

final class MarkdownParserTests: XCTestCase {
    private func article(_ body: String) -> String { "<article class=\"sw-doc\">\n" + body + "</article>" }

    func testSupportedFixtures() {
        let fixtures: [(String, String)] = [
            ("", "<article class=\"sw-doc sw-empty\"></article>"),
            (" \n\t\r\n", "<article class=\"sw-doc sw-empty\"></article>"),
            ("A paragraph\ncontinued.\n\nAnother.", article("<p>A paragraph\ncontinued.</p>\n<p>Another.</p>\n")),
            ("# One\n## Two ##\n### Three\n#### Four\n##### Five\n###### Six", article("<h1>One</h1>\n<h2>Two</h2>\n<h3>Three</h3>\n<h4>Four</h4>\n<h5>Five</h5>\n<h6>Six</h6>\n")),
            ("**Bold** and *italic* and __strong__ and _emphasis_", article("<p><strong>Bold</strong> and <em>italic</em> and <strong>strong</strong> and <em>emphasis</em></p>\n")),
            ("***both*** and ___both___", article("<p><strong><em>both</em></strong> and <strong><em>both</em></strong></p>\n")),
            ("**bold *italic* end**", article("<p><strong>bold <em>italic</em> end</strong></p>\n")),
            ("`<a>&` and ``inline ` code``", article("<p><code>&lt;a&gt;&amp;</code> and <code>inline ` code</code></p>\n")),
            ("\\*literal\\* & 2*3*4 snake_case", article("<p>*literal* &amp; 2*3*4 snake_case</p>\n")),
            ("[link **text**](https://example.com/path_(part) \"Title\")", article("<p><a href=\"https://example.com/path_(part)\" title=\"Title\">link <strong>text</strong></a></p>\n")),
            ("![local](assets/a.png 'Caption')", article("<p><img src=\"assets/a.png\" alt=\"local\" title=\"Caption\"></p>\n")),
            ("> Quote\n>\n> > Nested", article("<blockquote>\n<p>Quote</p>\n<blockquote>\n<p>Nested</p>\n</blockquote>\n</blockquote>\n")),
            ("- One\n  - Nested\n- Two", article("<ul>\n<li>\n<p>One</p>\n<ul>\n<li>\n<p>Nested</p>\n</li>\n</ul>\n</li>\n<li>\n<p>Two</p>\n</li>\n</ul>\n")),
            ("3. Three\n4. Four", article("<ol start=\"3\">\n<li>\n<p>Three</p>\n</li>\n<li>\n<p>Four</p>\n</li>\n</ol>\n")),
            ("---\n* * *\n___", article("<hr>\n<hr>\n<hr>\n")),
            ("```swift\nlet x = a < b && c\n```", article("<pre><code class=\"language-swift\">let x = a &lt; b &amp;&amp; c\n</code></pre>\n")),
            ("~~~~c++ extra\n<tag>\n~~~~~", article("<pre><code class=\"language-c++\">&lt;tag&gt;\n</code></pre>\n"))
        ]
        for (source, expected) in fixtures { XCTAssertEqual(HTMLRenderer.render(source), expected, source) }
    }

    func testASTAndBlockEdges() {
        XCTAssertEqual(MarkdownParser.parse("# **Title**").blocks,
                       [.heading(level: 1, content: [.strong([.text("Title")])])])
        for start in [0, 1, 999_999_999] {
            let html = HTMLRenderer.render("\(start). Item")
            XCTAssertTrue(html.contains(start == 1 ? "<ol>" : "<ol start=\"\(start)\">"))
        }
        XCTAssertTrue(HTMLRenderer.render("1000000000. Text").contains("<p>1000000000. Text</p>"))
        XCTAssertEqual(HTMLRenderer.render("```\na\n\n```"), article("<pre><code>a\n\n</code></pre>\n"))
        XCTAssertEqual(HTMLRenderer.render("```\n```"), article("<pre><code></code></pre>\n"))
        XCTAssertEqual(HTMLRenderer.render("````\na\n```\nb\n````"), article("<pre><code>a\n```\nb\n</code></pre>\n"))
        XCTAssertEqual(HTMLRenderer.render("` **literal** `"), article("<p><code>**literal**</code></p>\n"))
        XCTAssertEqual(HTMLRenderer.render("   # Indented"), article("<h1>Indented</h1>\n"))
        XCTAssertTrue(HTMLRenderer.render("    # Literal").contains("<p># Literal</p>"))
    }

    func testLineBreakModesAndNewlines() {
        for mode in HTMLRenderer.LineBreaks.allCases {
            let soft = mode == .standard ? "\n" : "<br>\n"
            for newline in ["\n", "\r\n", "\r"] {
                XCTAssertEqual(HTMLRenderer.render("one\(newline)two  \(newline)three\\\(newline)four", options: .init(lineBreaks: mode)),
                               article("<p>one\(soft)two<br>\nthree<br>\nfour</p>\n"))
            }
        }
    }

    func testRawHTMLAttributesAndRemoteImages() {
        XCTAssertEqual(HTMLRenderer.render("<script>alert('x')</script>"), article("<p><span class=\"sw-raw-html\">&lt;script&gt;</span>alert(&#39;x&#39;)<span class=\"sw-raw-html\">&lt;/script&gt;</span></p>\n"))
        let source = "![\\\" onerror=\\\"evil](https://example.com/a.png \"\\\" onclick=\\\"evil\")"
        let html = HTMLRenderer.render(source)
        XCTAssertTrue(html.contains("class=\"sw-remote-image\""))
        XCTAssertTrue(html.contains("alt=\"&quot; onerror=&quot;evil\""))
        XCTAssertTrue(html.contains("title=\"&quot; onclick=&quot;evil\""))
        XCTAssertFalse(html.contains(" onerror=\""))
        XCTAssertFalse(html.contains(" onclick=\""))
        let code = HTMLRenderer.render("```\"onclick=evil<svg>\n<script>\n```")
        XCTAssertTrue(code.contains("class=\"language-onclickevilsvg\""))
        XCTAssertFalse(code.contains("<script>"))
    }

    func testURLPolicySweep() {
        let blocked = ["javascript:alert(1)", "JaVaScRiPt:evil", "vbscript:evil", "data:text/html,evil",
                       "data:image/svg+xml,evil", "custom:value", "file:///etc/passwd", "//example.com/x",
                       "../secret.md", "%2e%2e/secret.md", "/etc/passwd", "https://", "java%73cript:evil",
                       "javascript&colon;evil", "a%00b", "a%0Ab", "a%5Cb", "a%zz", "mailto:a@example.com"]
        for destination in blocked {
            let html = HTMLRenderer.render("![alt](<\(destination)>)")
            XCTAssertFalse(html.contains("<img"), destination)
            XCTAssertTrue(html.contains("sw-blocked-link"), destination)
            if !destination.hasPrefix("mailto:") {
                let link = HTMLRenderer.render("[label](<\(destination)>)")
                XCTAssertFalse(link.contains("<a "), destination)
                XCTAssertTrue(link.contains("sw-blocked-link"), destination)
            }
        }
        for destination in ["https://example.com", "http://example.com/a?b=1&c=2", "assets/a.png", "#section", ""] {
            XCTAssertTrue(HTMLRenderer.render("[text](<\(destination)>)").contains("<a "), destination)
        }
        XCTAssertTrue(HTMLRenderer.render("[mail](mailto:a@example.com)").contains("<a "))
        // Direct AST callers get the same filtering, including controls and backslashes.
        for destination in ["java\nscript:evil", " https://example.com", "\\\\example.com", "a\0b"] {
            let document = MarkdownDocument(blocks: [.paragraph([.link(label: [.text("x")], destination: destination, title: nil)])])
            XCTAssertFalse(HTMLRenderer.render(document).contains("<a "), destination)
        }
    }

    func testRasterDataImagesOnly() {
        for type in ["png", "jpeg", "gif", "webp"] {
            let destination = "data:image/\(type);base64,AA=="
            XCTAssertTrue(HTMLRenderer.render("![alt](\(destination))").contains("<img src="))
            XCTAssertFalse(HTMLRenderer.render("[label](\(destination))").contains("<a "))
        }
        for destination in ["data:image/svg+xml;base64,AA==", "data:text/html;base64,AA==",
                            "data:image/png;base64,", "data:image/png;base64,invalid!",
                            "data:image/png,raw", "data:image/png;base64," + String(repeating: "A", count: 4 * 1024 * 1024 + 4)] {
            XCTAssertFalse(HTMLRenderer.render(MarkdownDocument(blocks: [.paragraph([.image(alt: "x", destination: destination, title: nil)])])).contains("<img "))
        }
    }

    func testLibraryFileContainmentAndSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        let options = HTMLRenderer.Options(libraryRoot: root, documentURL: root.appendingPathComponent("folder/note.md"))
        for destination in ["../image.png", root.appendingPathComponent("image.png").absoluteString, "#anchor"] {
            XCTAssertTrue(HTMLRenderer.render("[x](<\(destination)>)", options: options).contains("<a "), destination)
        }
        for hasRoot in [false, true] {
            for hasDocument in [false, true] {
                let context = HTMLRenderer.Options(libraryRoot: hasRoot ? root : nil,
                                                   documentURL: hasDocument ? options.documentURL : nil)
                XCTAssertEqual(HTMLRenderer.render("[x](../image.png)", options: context).contains("<a "), hasRoot && hasDocument)
                XCTAssertEqual(HTMLRenderer.render("[x](<\(root.appendingPathComponent("image.png").absoluteString)>)", options: context).contains("<a "), hasRoot)
            }
        }
        for destination in ["../../outside.md", "../escape/outside.md", "file:///etc/passwd",
                            root.appendingPathComponent("escape/outside.md").absoluteString,
                            root.absoluteString.dropLast() + "-sibling/file.md"] {
            XCTAssertFalse(HTMLRenderer.render("[x](<\(destination)>)", options: options).contains("<a "), destination)
        }
    }

    func testUnsupportedAndUnclosedSyntaxStaysVisible() {
        for source in ["| A | B |", "| --- | --- |", "- [x] **Task**", "[^note]: Footnote",
                       "[ref]: https://example.com", "~~deleted~~", "####### Not heading", "[unclosed](", "*unclosed", "`unclosed"] {
            let html = HTMLRenderer.render(source)
            XCTAssertTrue(html.contains(source), source)
        }
        XCTAssertEqual(HTMLRenderer.render("```\n<unclosed>"), article("<pre><code>&lt;unclosed&gt;\n</code></pre>\n"))
    }

    func testBoundedAdversarialAndUnicodeSweep() {
        for count in [0, 1, 31, 32, 33, 128, 10_000] {
            for token in ["[", "*a ", "`", "<", "> ", "👩🏽‍💻", "日", "a_"] {
                let source = String(repeating: token, count: count)
                for mode in HTMLRenderer.LineBreaks.allCases {
                    let html = HTMLRenderer.render(source, options: .init(lineBreaks: mode))
                    XCTAssertTrue(html.hasPrefix("<article class=\"sw-doc"))
                    XCTAssertTrue(html.hasSuffix("</article>"))
                }
            }
        }
    }
}

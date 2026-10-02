import XCTest
@testable import SilkwebCore

final class MarkdownExtensionsTests: XCTestCase {
    func testTableAlignmentAndEscapedPipes() {
        let html = HTMLRenderer.render(#"""
        | **Left** | Center | Right | None |
        | :--- | :---: | ---: | --- |
        | a\|b | `c\|d` | ~~gone~~ | [link](a?b=1&c=2) |
        | short |
        | a | b | c | d | ignored |
        """#)
        XCTAssertTrue(html.contains("<div class=\"sw-table-wrap\"><table>"))
        XCTAssertTrue(html.contains("<thead>\n<tr><th class=\"sw-align-left\"><strong>Left</strong></th>"))
        XCTAssertTrue(html.contains("<td class=\"sw-align-left\">a|b</td>"))
        // GFM escaped pipes are unescaped even inside table code spans.
        XCTAssertTrue(html.contains("<td class=\"sw-align-center\"><code>c|d</code></td>"))
        XCTAssertTrue(html.contains("<td class=\"sw-align-right\"><del>gone</del></td>"))
        XCTAssertTrue(html.contains("href=\"a?b=1&amp;c=2\""))
        XCTAssertTrue(html.contains("<td class=\"sw-align-center\"></td>"))
        XCTAssertFalse(html.contains("ignored"))
        XCTAssertFalse(html.contains("style="))
    }

    func testTableShapesAndMalformedDelimiters() {
        for pipes in [false, true] {
            for columns in [1, 2, 32, 256] {
                let header = Array(repeating: "Title", count: columns).joined(separator: " | ")
                let delimiter = Array(repeating: "---", count: columns).joined(separator: " | ")
                let wrap: (String) -> String = { pipes ? "| " + $0 + " |" : $0 }
                let html = HTMLRenderer.render(wrap(header) + "\n" + wrap(delimiter))
                XCTAssertEqual(html.contains("<table>"), pipes || columns > 1)
            }
        }
        for delimiter in ["| | --- |", "| --- |", "| :-x | --- |", "| : | --- |", "| :: | --- |"] {
            XCTAssertFalse(HTMLRenderer.render("| A | B |\n" + delimiter).contains("<table>"))
        }
        XCTAssertTrue(HTMLRenderer.render("Before\nA | B\n--- | ---\nx | y").contains("<p>Before</p>\n<div"))
        XCTAssertTrue(HTMLRenderer.render("```\n| A |\n| --- |\n``` ").contains("<pre><code>"))
        XCTAssertFalse(HTMLRenderer.render("```\n| A |\n| --- |\n```").contains("<table>"))
    }

    func testShortTableDelimiters() {
        for delimiter in ["|:-:|-:|", "|:--|--:|", "|--|--|", "-|-"] {
            let html = HTMLRenderer.render("a|b\n\(delimiter)\n1|2")
            XCTAssertTrue(html.contains("<div class=\"sw-table-wrap\"><table>"), delimiter)
            XCTAssertTrue(html.contains("<tbody>"), delimiter)
        }
        for dashCount in [1, 2, 3, 256] {
            let dashes = String(repeating: "-", count: dashCount)
            for (delimiter, alignment) in [(dashes, nil), (":" + dashes, "left"),
                                          (dashes + ":", "right"), (":" + dashes + ":", "center")] {
                let html = HTMLRenderer.render("| A | B |\n|\(delimiter)|\(delimiter)|\n| a\\|b | `x\\|y` |")
                let attribute = alignment.map { " class=\"sw-align-\($0)\"" } ?? ""
                XCTAssertTrue(html.contains("<th\(attribute)>A</th>"), delimiter)
                XCTAssertTrue(html.contains("<td\(attribute)>a|b</td>"), delimiter)
                XCTAssertTrue(html.contains("<td\(attribute)><code>x|y</code></td>"), delimiter)
            }
        }
    }

    func testTaskStatesMixedAndNestedLists() {
        for marker in ["-", "+", "*", "3."] {
            for state in [" ", "x", "X"] {
                let html = HTMLRenderer.render("\(marker) [\(state)] **Task**\n   continued")
                XCTAssertTrue(html.contains("class=\"sw-task-list\""))
                XCTAssertTrue(html.contains("<li class=\"sw-task\"><input type=\"checkbox\" disabled" + (state == " " ? ">" : " checked>")))
                XCTAssertTrue(html.contains("<strong>Task</strong>"))
            }
        }
        let html = HTMLRenderer.render("- plain\n- [x] done\n  - [ ] child\n- [ ]")
        XCTAssertTrue(html.contains("<li>\n<p>plain</p>"))
        XCTAssertEqual(html.components(separatedBy: "class=\"sw-task\"").count - 1, 3)
        XCTAssertFalse(HTMLRenderer.render("- [x]word").contains("checkbox"))
        XCTAssertFalse(HTMLRenderer.render("[x] paragraph").contains("checkbox"))
    }

    func testSlugIDsAndOriginalSourceRanges() {
        for newline in ["\n", "\r", "\r\n"] {
            let lines = ["👩🏽‍💻 intro", "# **Café** & 世界!", "> ## Café & 世界!", "- ### Café & 世界!", "# !!!", "#", "# section", "# café-世界-1"]
            let source = lines.joined(separator: newline)
            let document = MarkdownParser.parse(source)
            XCTAssertEqual(document.headings.map(\.id), ["café-世界", "café-世界-1", "café-世界-2", "section", "section-1", "section-2", "café-世界-1-1"])
            XCTAssertEqual(document.headings.map(\.level), [1, 2, 3, 1, 1, 1, 1])
            XCTAssertEqual(document.headings.map { (source as NSString).substring(with: $0.sourceRange) }, Array(lines.dropFirst()))
            let html = HTMLRenderer.render(document)
            for heading in document.headings { XCTAssertTrue(html.contains("id=\"\(heading.id)\"")) }
            XCTAssertEqual(document.headings, MarkdownParser.parse(source).headings)
        }
        for (text, slug) in [("", "section"), ("!!!", "section"), (" A  B ", "a-b"), ("日本語 ١٢٣", "日本語-١٢٣"), ("ÉCOLE", "école")] {
            XCTAssertEqual(MarkdownExtensions.slug(text), slug)
        }
        let direct = MarkdownDocument(blocks: [.heading(level: 1, content: [.text("Title")])])
        XCTAssertEqual(direct.headings.first?.sourceRange.location, NSNotFound)
        XCTAssertTrue(HTMLRenderer.render(direct).contains("id=\"title\""))
    }

    func testTOCNestingEmptyAndCodeLiterals() {
        let html = HTMLRenderer.render("[TOC]\n# A\n### B\n## C\n# A")
        XCTAssertTrue(html.contains("<nav class=\"sw-toc\" aria-label=\"Table of contents\"><ul><li><a href=\"#a\">A</a><ul><li><a href=\"#b\">B</a></li><li><a href=\"#c\">C</a></li></ul></li><li><a href=\"#a-1\">A</a></li></ul></nav>"))
        XCTAssertFalse(HTMLRenderer.render("[TOC]").contains("<nav"))
        XCTAssertFalse(HTMLRenderer.render("```\n[TOC]\n# literal\n```").contains("<nav"))
        XCTAssertTrue(HTMLRenderer.render("`[TOC]`").contains("<code>[TOC]</code>"))
        XCTAssertTrue(HTMLRenderer.render("text [TOC]").contains("text [TOC]"))
        let descending = HTMLRenderer.render("[TOC]\n### First\n# Second")
        XCTAssertTrue(descending.contains("<ul><li><a href=\"#first\">First</a></li><li><a href=\"#second\">Second</a></li></ul>"))
    }

    func testFootnoteOrderingMissingUnusedAndRepeatedReferences() {
        let html = HTMLRenderer.render("B[^b] A[^a] B[^b] missing[^missing]\n\n[^a]: *Alpha*\n[^b]: Beta\n    continued\n[^unused]: omitted")
        XCTAssertTrue(html.contains("B<sup class=\"sw-fn-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>"))
        XCTAssertTrue(html.contains("id=\"fnref-1-2\">1</a>"))
        XCTAssertTrue(html.contains("<li id=\"fn-1\"><p>Beta\ncontinued"))
        XCTAssertTrue(html.contains("<li id=\"fn-2\"><p><em>Alpha</em>"))
        XCTAssertTrue(html.contains("href=\"#fnref-1-2\" class=\"sw-fn-back\""))
        XCTAssertTrue(html.contains("aria-label=\"Back to reference 1\""))
        XCTAssertTrue(html.contains("missing[^missing]"))
        XCTAssertFalse(html.contains("omitted"))
        XCTAssertFalse(HTMLRenderer.render("[^missing]").contains("sw-footnotes"))
        XCTAssertFalse(HTMLRenderer.render("[^unused]: omitted").contains("omitted"))
        XCTAssertTrue(HTMLRenderer.render("[^a]\n[^a]: first\n[^a]: second").contains("first"))
        XCTAssertFalse(HTMLRenderer.render("[^a]\n[^a]: first\n[^a]: second").contains("second"))
        XCTAssertTrue(HTMLRenderer.render("`[^a]`\n[^a]: unused").contains("<code>[^a]</code>"))
        let cycle = HTMLRenderer.render("[^a]\n[^a]: A[^b]\n[^b]: B[^a]")
        XCTAssertEqual(cycle.components(separatedBy: "<li id=\"fn-").count - 1, 2)
    }

    func testStrikeAndAutolinksWithSafetyAndCode() {
        let html = HTMLRenderer.render("~~**gone**~~ <https://example.com/a?b=1&c=2> https://example.com/a_(b). www.example.com!")
        XCTAssertTrue(html.contains("<del><strong>gone</strong></del>"))
        XCTAssertTrue(html.contains("href=\"https://example.com/a?b=1&amp;c=2\""))
        XCTAssertTrue(html.contains("href=\"https://example.com/a_(b)\""))
        XCTAssertTrue(html.contains("href=\"https://www.example.com\""))
        XCTAssertTrue(HTMLRenderer.render("*https://example.com*").contains("<em><a href="))
        XCTAssertFalse(HTMLRenderer.render("`https://example.com ~~x~~`").contains("<a "))
        XCTAssertFalse(HTMLRenderer.render("<javascript:alert(1)>").contains("<a "))
        XCTAssertFalse(HTMLRenderer.render("<https://example.com/%00>").contains("<a "))
        XCTAssertFalse(HTMLRenderer.render("~~unclosed").contains("<del>"))
        XCTAssertTrue(HTMLRenderer.render("a~~gone~~b").contains("a<del>gone</del>b"))
        let linkLabel = HTMLRenderer.render("[<https://example.com>](https://example.org)")
        XCTAssertEqual(linkLabel.components(separatedBy: "<a ").count - 1, 1)
    }

    func testRawHTMLShapeRegression() {
        XCTAssertTrue(HTMLRenderer.render("1 < 2 and 3 > 2").contains("<p>1 &lt; 2 and 3 &gt; 2</p>"))
        for raw in ["<tag>", "</tag>", "<tag a='b'>", "<tag/>", "<!-- comment -->", "<!-- a > b -->", "<?pi?>", "<?a > b?>", "<!DOCTYPE html>"] {
            XCTAssertTrue(HTMLRenderer.render(raw).contains("sw-raw-html"), raw)
        }
        for text in ["< 2 >", "<> ", "<123>", "<tag!>"] {
            XCTAssertFalse(HTMLRenderer.render(text).contains("sw-raw-html"), text)
        }
    }

    func testRelativeQueryAmpersandRegression() {
        for destination in ["a?b=1&c=2", "a?b=1%26c=2", "#part&two"] {
            XCTAssertTrue(HTMLRenderer.render("[x](\(destination))").contains("<a "), destination)
        }
        for destination in ["javascript&colon;evil", "../a?b=1&c=2", "%2e%2e/a?b=1&c=2", "//example.com?a=1&b=2"] {
            XCTAssertTrue(HTMLRenderer.render("[x](\(destination))").contains("sw-blocked-link"), destination)
        }
    }

    func testExtensionAdversarialSweep() {
        for count in [0, 1, 31, 32, 33, 1_000, 10_000] {
            for token in ["~~x ", "[^", "\\|", "<https://", "www."] {
                for mode in HTMLRenderer.LineBreaks.allCases {
                    let html = HTMLRenderer.render(String(repeating: token, count: count), options: .init(lineBreaks: mode))
                    XCTAssertTrue(html.hasPrefix("<article"))
                    XCTAssertTrue(html.hasSuffix("</article>"))
                }
            }
        }
        let source = "[TOC]\n" + Array(repeating: "# Same", count: 10_000).joined(separator: "\n")
        let document = MarkdownParser.parse(source)
        XCTAssertEqual(Set(document.headings.map(\.id)).count, 10_000)
        XCTAssertTrue(HTMLRenderer.render(document).contains("href=\"#same-9999\""))
    }
}

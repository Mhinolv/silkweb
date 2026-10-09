import Foundation
import XCTest

@testable import SilkwebCore

/// #176: one link grammar and one resolver for the preview, the link index and the rename rewrite.
final class MarkdownLinksTests: XCTestCase {
    private func destinations(_ text: String) -> [String] { MarkdownLinks.scan(text).links.map(\.destination) }

    // MARK: Grammar and source ranges

    func testRangesHoldWhatTheParserReadInEveryBlock() {
        let text = [
            "# Title [h](<A/My Note.md#Part 1> \"T\") ##",
            "Para [a](A/One.md) and ![i](A/pic%20one.png 'x') 📝 [u](A/Café.md#Été)",
            "> quoted [q](A/a(b).md)",
            "- item [l](A/One.md)",
            "\t- nested\t[t](<A/x y.md>)",
            "    four spaces [s](A/s.md)",
            "",
            "| 🧭 | b |",
            "| --- | --- |",
            "| x \\| [c1](A/c1.md) | `code` [c2](A/c2.md) |",
            "",
            "See[^n].",
            "",
            "[ref]: <A/ref one.md> \"Title\"",
            "end \\![e](A/e.md) [esc\\)](A/e\\(1\\).md)",
            "",
            // Footnotes render last, so define them last to keep document and render order alike.
            "[^n]: Note [f](A/f.md)",
            "    more [g](A/g.md)",
        ].joined(separator: "\r\n")
        let source = text as NSString
        let scan = MarkdownLinks.scan(text)
        XCTAssertEqual(scan.unsupported, [])
        XCTAssertEqual(
            scan.links.map(\.destination),
            [
                "A/My Note.md#Part 1", "A/One.md", "A/pic%20one.png", "A/Café.md#Été", "A/a(b).md", "A/One.md",
                "A/x y.md", "A/s.md", "A/c1.md", "A/c2.md", "A/ref one.md", "A/e.md", "A/e(1).md", "A/f.md", "A/g.md",
            ])
        XCTAssertEqual(scan.links.map(\.kind).filter { $0 == .image }.count, 1)
        XCTAssertEqual(scan.links.last(where: { $0.kind == .referenceDefinition })?.title, "Title")
        XCTAssertEqual(scan.links.first?.title, "T")
        for link in scan.links {
            XCTAssertEqual(source.substring(with: link.destinationRange), link.written, link.destination)
            let syntax = source.substring(with: link.range)
            if link.kind == .referenceDefinition {
                XCTAssertTrue(syntax.hasPrefix("[ref]: "), syntax)
            } else {
                XCTAssertTrue(syntax.hasPrefix(link.kind == .image ? "![" : "["), syntax)
                XCTAssertTrue(syntax.hasSuffix(")"), syntax)
            }
            XCTAssertEqual(
                link.isAngleBracketed,
                source.substring(with: NSRange(location: link.destinationRange.location - 1, length: 1)) == "<")
        }
        // The renderer reads the same destinations, in the same order.
        let document = MarkdownParser.parse(text)
        var rendered: [String] = []
        func walk(_ inlines: [MarkdownInline]) {
            for inline in inlines {
                switch inline {
                case .link(let label, let destination, _): rendered.append(destination); walk(label)
                case .image(_, let destination, _): rendered.append(destination)
                case .emphasis(let c), .strong(let c), .strikethrough(let c): walk(c)
                default: break
                }
            }
        }
        func walk(_ blocks: [MarkdownBlock]) {
            for block in blocks {
                switch block {
                case .paragraph(let c), .heading(_, let c): walk(c)
                case .quote(let c), .taskItem(_, let c): walk(c)
                case .list(_, let items): items.forEach(walk)
                case .table(let header, _, let rows): header.forEach(walk); rows.forEach { $0.forEach(walk) }
                default: break
                }
            }
        }
        walk(document.blocks)
        for label in document.footnotes.keys.sorted() { walk(document.footnotes[label]!) }
        XCTAssertEqual(rendered, scan.links.filter { $0.kind != .referenceDefinition }.map(\.destination))
    }

    func testCodeAndEscapedSyntaxNeverProduceLinks() {
        let library = MarkdownLinkResolver(items: ["A/One.md": .document], caseSensitive: false)
        for text in [
            "`[a](A/One.md)`", "`` [a](A/One.md) ``", "```\n[a](A/One.md)\n```", "~~~md\n[a](A/One.md)\n",
            "- x\n  ```\n  [a](A/One.md)\n  ```", "> ```\n> [a](A/One.md)\n> ```", "\\[a](A/One.md)", "[a\\](A/One.md)",
            "\\![a\\](A/One.md)", "| `[a](A/One.md)` | b |\n| - | - |", "[[A/One.md]]", "<a href=\"A/One.md\">x</a>",
            "[a]: A/One.md trailing", "[x](A/One.md",
        ] {
            let scan = MarkdownLinks.scan(text)
            XCTAssertEqual(scan.links, [], text)
            XCTAssertEqual(library.linksTo(scan, from: "Two.md"), [], text)
        }
        // Code and escapes aren't reported as unsupported either; unparsed link syntax is.
        for text in ["`[[A/One.md]]`", "```\n<img src=\"a.png\"> ](\n```", "\\[[A/One.md]]", "x \\](y"] {
            XCTAssertEqual(MarkdownLinks.scan(text).unsupported, [], text)
        }
        for text in ["[[A/One.md]]", "<img src=\"a.png\">", "[x](A/One.md", "[x](a b.md)", "a ](b)"] {
            XCTAssertEqual(MarkdownLinks.scan(text).unsupported.count, 1, text)
        }
    }

    // MARK: Resolution

    func testResolutionStatusesAreDeterministic() {
        let items: [String: MarkdownLinkResolver.Item] = [
            "Index.md": .document, "Notes/Plan.md": .document, "Notes/PLAN.md": .document,
            "Notes/Daily.md": .document, "Notes/Café.md": .document, "Notes/report.pdf": .file, "Notes": .folder,
            "Linked": .symbolicLink, "Alias.md": .symbolicLink,
        ]
        typealias Expectation = (String, MarkdownLinkStatus, String?)
        let common: [Expectation] = [
            ("Notes/Plan.md", .resolved, "Notes/Plan.md"),
            ("Notes/PLAN.md#Top", .resolved, "Notes/PLAN.md"),
            ("./Notes/../Notes/Daily.md?x=1#Part", .resolved, "Notes/Daily.md"),
            ("Notes/Caf%C3%A9.md", .resolved, "Notes/Café.md"),
            ("Notes/Cafe%CC%81.md", .resolved, "Notes/Café.md"),
            ("Notes/Cafe\u{301}.md", .resolved, "Notes/Café.md"),
            ("Notes%2FDaily.md", .resolved, "Notes/Daily.md"),
            ("Notes/report.pdf", .resolved, "Notes/report.pdf"),
            ("Notes/plan.md", .ambiguous, "Notes/plan.md"),
            ("Notes/Missing.md", .missing, "Notes/Missing.md"),
            ("#Heading", .anchor, nil), ("", .anchor, nil), ("?q", .anchor, nil),
            ("../Outside.md", .outsideLibrary, nil), ("Notes/../../x.md", .outsideLibrary, nil),
            ("Linked/Note.md", .outsideLibrary, nil), ("Alias.md", .outsideLibrary, nil),
            ("https://example.com/a.md", .external, nil), ("mailto:a@example.com", .external, nil),
            ("Notes", .unsupported, "Notes"), ("Notes/", .unsupported, "Notes"), ("/abs.md", .unsupported, nil),
            ("file:///tmp/x.md", .unsupported, nil), ("javascript:alert(1)", .unsupported, nil),
            ("a%ZZ.md", .unsupported, nil), ("//host/x.md", .unsupported, nil), ("R&D.md", .unsupported, nil),
        ]
        let byVolume: [Bool: [Expectation]] = [
            false: [("notes/daily.MD", .resolved, "Notes/Daily.md"), ("index.md", .resolved, "Index.md")],
            true: [("notes/daily.MD", .missing, "notes/daily.MD"), ("index.md", .missing, "index.md")],
        ]
        for caseSensitive in [false, true] {
            let resolver = MarkdownLinkResolver(items: items, caseSensitive: caseSensitive)
            for (destination, status, path) in common + byVolume[caseSensitive]! {
                let resolution = resolver.resolve(destination, from: "Index.md")
                XCTAssertEqual(resolution.status, status, "\(destination) caseSensitive: \(caseSensitive)")
                XCTAssertEqual(resolution.path, path, destination)
            }
            XCTAssertEqual(
                resolver.resolve("Notes/plan.md", from: "Index.md").candidates, ["Notes/PLAN.md", "Notes/Plan.md"])
            XCTAssertEqual(resolver.resolve("Notes/PLAN.md#Top", from: "Index.md").fragment, "Top")
            XCTAssertEqual(resolver.resolve("Daily.md#Été%202", from: "Notes/Plan.md").fragment, "Été 2")
            XCTAssertEqual(resolver.resolve("../Index.md", from: "Notes/Plan.md").path, "Index.md")
        }
        // Reference definitions are text in the preview, so they never resolve.
        let definition = MarkdownLinks.scan("[r]: Index.md").links[0]
        XCTAssertEqual(
            MarkdownLinkResolver(items: items, caseSensitive: false).resolve(definition, from: "x.md").status,
            .unsupported)
        XCTAssertEqual(
            MarkdownLinkStatus.allCases.map(\.rawValue),
            ["resolved", "anchor", "missing", "ambiguous", "outsideLibrary", "external", "unsupported"])
    }

    func testOnlyResolvedDocumentLinksAreEdges() {
        let resolver = MarkdownLinkResolver(
            items: ["Index.md": .document, "A.md": .document, "B.md": .document, "pic.png": .file],
            caseSensitive: false)
        let text = """
            [a](A.md) [again](A.md) [part](A.md#Part) [b](<B.md>) ![img](A.md) [pic](pic.png) [self](Index.md)
            [missing](C.md) [web](https://example.com) [anchor](#x) `[code](B.md)` \\[esc](B.md)
            [ref]: B.md
            """
        XCTAssertEqual(
            resolver.linksTo(MarkdownLinks.scan(text), from: "Index.md"),
            [
                .init(target: "A.md", section: nil), .init(target: "A.md", section: "Part"),
                .init(target: "B.md", section: nil),
            ])
    }

    // MARK: Preview, index and rewrite agree

    /// The same fixtures resolve to the same document when clicked in the preview, when indexed, and after the
    /// target folder moves (the rewritten link still resolves, in the author's form).
    func testPreviewIndexAndRewriteAgree() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createFolder(named: "Notes")
        _ = try await engine.createFolder(named: "Archive")
        for name in ["Plan (Final).md", "Space Name.md", "Café.md", "Shot 9.41\u{202F}AM.md"] {
            _ = try await engine.createDocument(named: name, in: "Notes", text: "# Part 2\n")
        }
        let insensitive =
            try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
            == false
        // (Markdown, the document it names, its section, the destination after Notes moves into Archive)
        var fixtures: [(String, String, String?, String)] = [
            ("[a](Notes/Plan%20(Final).md)", "Notes/Plan (Final).md", nil, "Archive/Notes/Plan%20(Final).md"),
            ("[b](<Notes/Space Name.md>)", "Notes/Space Name.md", nil, "<Archive/Notes/Space Name.md>"),
            ("[c](Notes/Caf%C3%A9.md#Part-2)", "Notes/Café.md", "Part-2", "Archive/Notes/Caf%C3%A9.md#Part-2"),
            ("[d](Notes/Café.md \"T\")", "Notes/Café.md", nil, "Archive/Notes/Café.md \"T\""),
            (
                "[e](./Notes/../Notes/Space%20Name.md?x=1#part-2)", "Notes/Space Name.md", "part-2",
                "Archive/Notes/Space%20Name.md?x=1#part-2"
            ),
            (
                "[f](<Notes/Shot 9.41\u{202F}AM.md>)", "Notes/Shot 9.41\u{202F}AM.md", nil,
                "<Archive/Notes/Shot 9.41\u{202F}AM.md>"
            ),
        ]
        if insensitive {
            fixtures.append(("[g](<notes/SPACE NAME.md>)", "Notes/Space Name.md", nil, "<Archive/Notes/Space Name.md>"))
        }
        let text = fixtures.map(\.0).joined(separator: "\n") + "\n"
        _ = try await engine.createDocument(named: "Index.md", text: text)
        let snapshot = try await LibraryScanner.scan(root: root)
        let resolver = MarkdownLinkResolver(snapshot: snapshot)
        let scan = MarkdownLinks.scan(text)
        XCTAssertEqual(scan.links.count, fixtures.count)

        // Preview: render, click the href, and open what the workspace would open.
        let document = root.appendingPathComponent("Index.md")
        let options = HTMLRenderer.Options(libraryRoot: root, documentURL: document, offlinePreview: true)
        let html = HTMLRenderer.render(text, options: options)
        let hrefs = try NSRegularExpression(pattern: #"<a href="([^"]*)""#).matches(
            in: html, range: NSRange(html.startIndex..., in: html)
        ).map { (html as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(hrefs.count, fixtures.count, html)
        let page = URL(string: "silkweb-preview://page/agree")!
        for ((markdown, target, section, _), (href, link)) in zip(fixtures, zip(hrefs, scan.links)) {
            let url = try XCTUnwrap(URL(string: href), href)
            guard
                case .document(let opened) = PreviewNavigation.action(
                    for: url, document: document, root: root, page: page)
            else { XCTFail("not a document: \(markdown)"); continue }
            let path = String(opened.path.dropFirst(root.path.count + 1))
            XCTAssertEqual(snapshot.document(linkedAt: path)?.relativePath, target, markdown)
            XCTAssertEqual(url.fragment, section.map { $0 }, markdown)
            // Index: the same document and section.
            let resolution = resolver.resolve(link, from: "Index.md")
            XCTAssertEqual(resolution.status, .resolved, markdown)
            XCTAssertEqual(resolution.path, target, markdown)
            XCTAssertEqual(resolution.fragment, section, markdown)
        }
        XCTAssertEqual(
            Set(resolver.linksTo(scan, from: "Index.md").map(\.target)), Set(fixtures.map(\.1)))

        // Rewrite: move the folder; every link still resolves to the moved document, in the author's form.
        let plan = try await engine.planMove(["Notes"], toFolder: "Archive")
        XCTAssertEqual(plan.unsupportedLinks, [])
        _ = try await engine.executeMove(plan)
        let moved = try String(contentsOf: document, encoding: .utf8)
        XCTAssertEqual(
            moved,
            fixtures.map { fixture in
                let open = fixture.0.firstIndex(of: "(")!
                return fixture.0[...open] + fixture.3 + ")"
            }.joined(separator: "\n") + "\n")
        let after = MarkdownLinkResolver(snapshot: try await LibraryScanner.scan(root: root))
        XCTAssertEqual(
            after.linksTo(MarkdownLinks.scan(moved), from: "Index.md").map(\.target).sorted(),
            resolver.linksTo(scan, from: "Index.md").map { "Archive/" + $0.target }.sorted())
    }

    /// Scanning stays cheap enough for incremental, off-main indexing.
    func testScanScalesLinearly() {
        let line = "Text [a](Folder/Doc%20one.md#x) `code [b](c.md)` ![i](<img one.png>) | more | [[wiki]]\n"
        let text = String(repeating: line, count: 5_000)
        let start = Date()
        let scan = MarkdownLinks.scan(text)
        let elapsed = Date().timeIntervalSince(start)
        print("MarkdownLinks.scan: 5,000 lines in \(elapsed)s")
        XCTAssertEqual(scan.links.count, 10_000)
        XCTAssertEqual(scan.unsupported.count, 5_000)
        XCTAssertLessThan(elapsed, 5)
    }
}

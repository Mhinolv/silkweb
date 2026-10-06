import XCTest

@testable import SilkwebCore

final class PreviewTests: XCTestCase {
    func testEveryHeadingLevelKeepsSemanticTagAndAnchor() {
        let source = (1...6).map { String(repeating: "#", count: $0) + " Level \($0)" }.joined(separator: "\n")
        for breaks in HTMLRenderer.LineBreaks.allCases {
            for offline in [false, true] {
                let html = HTMLRenderer.render(source, options: .init(lineBreaks: breaks, offlinePreview: offline))
                XCTAssertTrue(html.contains("<article class=\"sw-doc\">"))
                for level in 1...6 {
                    XCTAssertTrue(html.contains("<h\(level) id=\"level-\(level)\">Level \(level)</h\(level)>"), html)
                }
            }
        }
    }

    func testOfflineAssetAndLinkSweep() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/tmp"))
        let document = root.appendingPathComponent("notes/a.md")
        for breaks in HTMLRenderer.LineBreaks.allCases {
            let options = HTMLRenderer.Options(
                lineBreaks: breaks, libraryRoot: root, documentURL: document, offlinePreview: true)
            for path in ["picture.png", "../picture.png", "a%20b.png"] {
                let file = URL(string: path, relativeTo: document)!.absoluteURL
                try Data([0]).write(to: file)
                let html = HTMLRenderer.render("![alt](\(path))", options: options)
                XCTAssertTrue(html.contains("src=\"silkweb-preview://asset/"), html)
                XCTAssertFalse(html.contains("src=\"\(path)"))
            }
            for path in [
                "https://example.com/a.png", "http://example.com/a.png", "data:image/png;base64,AA==",
                "../../outside.png", "../escape/test.png", "javascript:alert(1)", "//example.com/a.png",
            ] {
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

    func testAssetContainmentRoundTripAndMissingImages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        for name in ["x.png", "space and #hash.png", "日本語.png", "percent%25.png"] {
            let file = root.appendingPathComponent(name)
            try Data([0]).write(to: file)
            let asset = try XCTUnwrap(PreviewResource.assetURL(for: file, root: root))
            XCTAssertEqual(PreviewResource.fileURL(for: asset, root: root), file.standardizedFileURL)
            XCTAssertEqual(PreviewResource.mimeType(for: file), "image/png")
        }
        for path in ["../outside.png", "%2e%2e/outside.png", "escape/missing.png", "%5cfoo.png", "%00.png"] {
            XCTAssertNil(
                PreviewResource.fileURL(for: URL(string: "silkweb-preview://asset/" + path)!, root: root), path)
        }
        for value in [
            "https://asset/x.png", "silkweb-preview://page/x.png", "silkweb-preview://user@asset/x.png",
            "silkweb-preview://asset/x.png?x=1",
        ] {
            XCTAssertNil(PreviewResource.fileURL(for: URL(string: value)!, root: root))
        }
        let options = HTMLRenderer.Options(
            libraryRoot: root, documentURL: root.appendingPathComponent("note.md"), offlinePreview: true)
        XCTAssertTrue(HTMLRenderer.render("![x](missing.png)", options: options).contains("Missing image: missing.png"))
        XCTAssertTrue(
            HTMLRenderer.render("![outside](escape/missing.png)", options: options).contains(
                "Image outside library: outside"))
        let page = URL(string: "silkweb-preview://page/id")!
        XCTAssertEqual(
            PreviewNavigation.action(
                for: URL(string: "#heading", relativeTo: page)!.absoluteURL,
                document: root.appendingPathComponent("note.md"), root: root, page: page), .anchor("heading"))
    }

    func testNavigationPolicy() {
        let root = URL(fileURLWithPath: "/silkweb-preview-test")
        let document = root.appendingPathComponent("notes/a.md")
        let page = URL(fileURLWithPath: "/tmp/preview.html")
        func action(_ value: String) -> PreviewNavigation.Action {
            PreviewNavigation.action(
                for: URL(string: value, relativeTo: page)!.absoluteURL, document: document, root: root, page: page)
        }
        XCTAssertEqual(action("#heading"), .anchor("heading"))
        XCTAssertEqual(action("file:///silkweb-preview-test/notes/a.md#heading"), .anchor("heading"))
        XCTAssertEqual(action("file:///silkweb-preview-test/b.md"), .document(root.appendingPathComponent("b.md")))
        XCTAssertEqual(action("https://example.com"), .browser(URL(string: "https://example.com")!))
        for value in [
            "file:///silkweb-preview-test-other/a.md", "file:///tmp/a.md", "file:///silkweb-preview-test/../a.md",
            "file:///silkweb-preview-test/image.png", "mailto:", "javascript:alert(1)", "data:text/html,test",
            "ftp://example.com/a.pdf", "file://server/silkweb-preview-test/a.pdf",
        ] {
            XCTAssertEqual(action(value), .blocked, value)
        }
    }

    /// #109: a pasted attachment and a `mailto:` link in the preview open instead of beeping.
    func testNavigationOpensAttachmentsAndMailto() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appendingPathComponent("media/note-id")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let document = root.appendingPathComponent("note.md")
        let pdf = media.appendingPathComponent("Report 2026.pdf")
        try Data("%PDF-1.4".utf8).write(to: pdf)
        let page = URL(string: "silkweb-preview://page/id")!
        func action(_ url: URL) -> PreviewNavigation.Action {
            PreviewNavigation.action(for: url, document: document, root: root, page: page)
        }
        // The href exactly as the offline preview renders the pasted Markdown link.
        let options = HTMLRenderer.Options(libraryRoot: root, documentURL: document, offlinePreview: true)
        let html = HTMLRenderer.render("[Report](media/note-id/Report%202026.pdf)", options: options)
        let href = try XCTUnwrap(
            html.components(separatedBy: "href=\"").dropFirst().first?.split(separator: "\"").first)
        let link = try XCTUnwrap(URL(string: String(href)))
        let opened = action(link)
        XCTAssertNotEqual(opened, .blocked, "a library attachment must open, not beep")
        XCTAssertNotEqual(opened, .document(link.standardizedFileURL), "an attachment is not a Silkweb document")
        let mail = URL(string: "mailto:user@example.com")!
        XCTAssertEqual(action(mail), .browser(mail))
    }

    /// silkweb-1.72: `.markdown` documents are library documents, so preview links open them like `.md`.
    func testNavigationOpensMarkdownExtensionDocuments() {
        let root = URL(fileURLWithPath: "/silkweb-preview-test")
        let document = root.appendingPathComponent("notes/a.md")
        let page = URL(fileURLWithPath: "/tmp/preview.html")
        for name in ["note.markdown", "Note.MARKDOWN", "note.md", "Note.MD"] {
            let url = URL(string: name, relativeTo: document)!.absoluteURL
            XCTAssertEqual(
                PreviewNavigation.action(for: url, document: document, root: root, page: page),
                .document(root.appendingPathComponent("notes/" + name)), name)
        }
        for name in ["note.markdownx", "note.mdown", "note.txt"] {
            let url = root.appendingPathComponent("notes/" + name)
            XCTAssertEqual(
                PreviewNavigation.action(for: url, document: document, root: root, page: page), .blocked, name)
        }
    }
}

import Foundation
import XCTest

@testable import SilkwebCore

/// #109: which preview links open, reveal or beep, and the shared missing-image label.
final class PreviewAttachmentTests: XCTestCase {
    private var root: URL!
    private var document: URL!
    private let page = URL(string: "silkweb-preview://page/id")!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("media/note-id"), withIntermediateDirectories: true)
        document = root.appendingPathComponent("notes/note.md")
        try FileManager.default.createDirectory(
            at: document.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# Note".utf8).write(to: document)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func action(_ url: URL, revealing: Bool = false) -> PreviewNavigation.Action {
        PreviewNavigation.action(for: url, document: document, root: root, page: page, revealing: revealing)
    }

    private func file(_ path: String, _ contents: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url.resolvingSymlinksInPath()
    }

    func testAttachmentsOpenAndCommandClickReveals() throws {
        for path in ["media/note-id/Report 2026.pdf", "media/note-id/photo.PNG", "notes/data.csv", "notes/readme.txt"] {
            let url = try file(path)
            XCTAssertEqual(action(url), .attachment(url), path)
            XCTAssertEqual(action(url, revealing: true), .reveal(url), path)
            // As rendered: relative to the note, percent-encoded, with a fragment.
            let encoded = try XCTUnwrap(URL(string: url.absoluteString + "#page=2"))
            XCTAssertEqual(action(encoded), .attachment(url), path)
        }
    }

    func testCodeIsRevealedNeverOpened() throws {
        var scripts = try ["run.sh", "build.command", "tool.zsh"].map { try file("media/note-id/" + $0) }
        let binary = try file("media/note-id/binary")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        scripts.append(binary)
        let app = root.appendingPathComponent("media/note-id/Tool.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        scripts.append(app.deletingLastPathComponent().resolvingSymlinksInPath())
        for url in scripts {
            XCTAssertEqual(action(url), .reveal(url), url.lastPathComponent)
            XCTAssertEqual(action(url, revealing: true), .reveal(url), url.lastPathComponent)
        }
    }

    func testMissingFoldersOutsidePathsAndEscapesStayBlocked() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("x".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("media/escape.pdf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let folderLink = root.appendingPathComponent("media/outside-folder")
        try FileManager.default.createSymbolicLink(
            at: folderLink, withDestinationURL: outside.deletingLastPathComponent())
        for url in [
            root.appendingPathComponent("media/note-id/missing.pdf"), root.appendingPathComponent("media/note-id"),
            root.appendingPathComponent("media/../../outside.pdf"), outside, link,
            folderLink.appendingPathComponent(outside.lastPathComponent),
            URL(string: "file://server" + root.appendingPathComponent("notes/data.csv").path)!,
            URL(string: "javascript:alert(1)")!, URL(string: "data:application/pdf;base64,AAAA")!,
            URL(string: "mailto:")!, URL(string: "ftp://example.com/a.pdf")!,
            URL(string: "silkweb-preview://asset/a.pdf")!,
        ] {
            XCTAssertEqual(action(url), .blocked, url.absoluteString)
            XCTAssertEqual(action(url, revealing: true), .blocked, url.absoluteString)
        }
    }

    func testMailtoAndMarkdownLinksAreUnchangedByCommandClick() throws {
        for value in ["mailto:user@example.com", "mailto:a@example.com?subject=Hello%20there", "MAILTO:a@example.com"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(action(url), .browser(url), value)
            XCTAssertEqual(action(url, revealing: true), .browser(url), value)
        }
        let other = try file("notes/other.markdown", "# Other")
        XCTAssertEqual(action(other, revealing: true), .document(other.standardizedFileURL))
        let web = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertEqual(action(web, revealing: true), .browser(web))
    }

    func testMissingImagePlaceholderShowsDestinationAsWritten() {
        XCTAssertEqual(ImagePlaceholder.missing("media/photo.png"), "Missing image: media/photo.png")
        XCTAssertEqual(ImagePlaceholder.missing("media/my%20photo.png"), "Missing image: media/my photo.png")
        XCTAssertEqual(ImagePlaceholder.missing("<media/my photo.png>"), "Missing image: media/my photo.png")
        XCTAssertEqual(ImagePlaceholder.missing("../%E6%97%85/a.png"), "Missing image: ../旅/a.png")
        // A malformed escape stays as written rather than disappearing.
        XCTAssertEqual(ImagePlaceholder.missing("a%zz.png"), "Missing image: a%zz.png")
        let options = HTMLRenderer.Options(libraryRoot: root, documentURL: document, offlinePreview: true)
        XCTAssertTrue(
            HTMLRenderer.render("![x](media/a%20%3Cb%3E.png)", options: options).contains(
                ">Missing image: media/a &lt;b&gt;.png<"))
    }

    func testPreviewLinksCarryTheirDestinationAsWritten() {
        let options = HTMLRenderer.Options(libraryRoot: root, documentURL: document, offlinePreview: true)
        let html = HTMLRenderer.render("[Report](../media/note-id/Report%202026.pdf)", options: options)
        XCTAssertTrue(html.contains("data-sw-destination=\"../media/note-id/Report%202026.pdf\""), html)
        // Export and absolute links are untouched.
        XCTAssertFalse(HTMLRenderer.render("[Report](media/a.pdf)").contains("data-sw-destination"))
        XCTAssertFalse(HTMLRenderer.render("[Web](https://example.com)", options: options).contains("data-sw"))
    }
}

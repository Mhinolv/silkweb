import AppKit
import SilkwebCore
import XCTest

@testable import Silkweb

/// #109: preview attachment links and the shared missing-image label.
@MainActor final class PreviewLinkTests: XCTestCase {
    /// Editor chip, Outline row and preview name a broken reference the same way: the path as written.
    func testMissingImageLabelMatchesOnEverySurface() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let document = root.appendingPathComponent("note.md")
        let expected = "Missing image: media/trip photos/photo.png"
        for markdown in ["![photo](media/trip%20photos/photo.png)", "![photo](<media/trip photos/photo.png>)"] {
            try Data(markdown.utf8).write(to: document)
            let paragraphs = await InlineImageLoader().load(
                text: markdown, document: document, root: root, column: 600, viewport: 800, scale: 2)
            XCTAssertEqual(paragraphs.first?.contents.first?.message, expected, markdown)
            let reference = try XCTUnwrap(InlineImages.paragraph(markdown).first)
            let outline = await OutlineImageRow.load(reference, document: document, root: root, pixels: 32)
            XCTAssertEqual(outline.message, expected, markdown)
            let html = HTMLRenderer.render(
                markdown, options: .init(libraryRoot: root, documentURL: document, offlinePreview: true))
            XCTAssertTrue(html.contains(">" + expected + "<"), html)
        }
    }

    /// The real preview web view replaces WebKit's link items for attachments only (GUI regression rule).
    func testAttachmentLinkMenuTitlesAndOrder() throws {
        let web = PreviewView.makeWebView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
            defer: true)
        window.contentView = web
        let pdf = URL(fileURLWithPath: "/library/media/Report.pdf")
        let script = URL(fileURLWithPath: "/library/media/run.sh")
        web.linkAction = { url in
            switch url {
            case pdf: .attachment(pdf)
            case script: .reveal(script)
            case URL(string: "https://example.com")!: .browser(url)
            default: .blocked
            }
        }
        func menu(_ link: URL?, destination: String = "", extra: Bool = false) -> [String] {
            web.contextLink = link.map { PreviewWebView.ContextLink(url: $0, destination: destination) }
            let menu = NSMenu()
            for identifier in PreviewWebView.webKitLinkItems.sorted() {
                let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
                item.identifier = NSUserInterfaceItemIdentifier(identifier)
                menu.addItem(item)
            }
            if extra {
                menu.addItem(.separator())
                menu.addItem(NSMenuItem(title: "Look Up", action: nil, keyEquivalent: ""))
            }
            let event = try! XCTUnwrap(
                NSEvent.mouseEvent(
                    with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            web.willOpenMenu(menu, with: event)
            return menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
        }
        XCTAssertEqual(menu(pdf, destination: "media/Report.pdf"), ["Open", "Reveal in Finder", "—", "Copy Path"])
        XCTAssertEqual(menu(script), ["Reveal in Finder", "—", "Copy Path"], "code is never opened from the menu")
        XCTAssertEqual(
            menu(pdf, extra: true), ["Open", "Reveal in Finder", "—", "Copy Path", "—", "Look Up"])
        let webKit = PreviewWebView.webKitLinkItems.sorted()
        XCTAssertEqual(menu(URL(string: "https://example.com")!), webKit, "other links keep WebKit's menu")
        XCTAssertEqual(menu(nil), webKit)

        // Copy Path copies the Markdown destination as written, like the image chip.
        let saved = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let saved { NSPasteboard.general.setString(saved, forType: .string) }
        }
        web.contextLink = .init(url: pdf, destination: "media/Report%202026.pdf")
        let items = NSMenu()
        let link = NSMenuItem(title: "Copy Link", action: nil, keyEquivalent: "")
        link.identifier = NSUserInterfaceItemIdentifier("WKMenuItemIdentifierCopyLink")
        items.addItem(link)
        web.attachmentItems(in: items)
        let copy = try XCTUnwrap(items.items.last)
        XCTAssertEqual(copy.title, "Copy Path")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "media/Report%202026.pdf")
        XCTAssertFalse(window.isVisible)
    }
}

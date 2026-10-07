import AppKit
import SilkwebCore
import SwiftUI
import WebKit
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

    /// #148: clicks on the real preview page reach the link policy. WebKit refuses `file:`/`mailto:` navigations
    /// from the `silkweb-preview:` page before the navigation delegate runs, so the page must report clicks itself.
    func testRealPreviewLinkClicksOpenRevealNavigateAndBeep() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        if SnapshotHarness.isWebKitUnavailable(
            environment: ProcessInfo.processInfo.environment, activationPolicy: NSApp.activationPolicy().rawValue)
        {
            throw XCTSkip(
                "Preview link clicks need real WebKit in a registered offscreen host outside the agent sandbox; run this test on both pre-fix and fixed builds there."
            )
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("media"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pdf = root.appendingPathComponent("media/file.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: pdf)
        let script = root.appendingPathComponent("media/run.sh")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        let other = root.appendingPathComponent("other.md")
        try Data("# Other\n".utf8).write(to: other)
        let document = root.appendingPathComponent("note.md")
        let source =
            "# Links\n\n[pdf](media/file.pdf) [script](media/run.sh) [missing](media/missing.pdf) [mail](mailto:user@example.com) [web](https://example.com/page) [jump](#end) [other](other.md)\n\n"
            + String(repeating: "paragraph\n\n", count: 100) + "## End\n"
        try Data(source.utf8).write(to: document)

        let workspace = LibraryWorkspace(defaults: disposableDefaults("PreviewLinkClicks"))
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.editor.url = document
        workspace.preview.mode = .preview
        workspace.preview.schedule(text: source, document: document, root: root)
        let host = NSHostingController(rootView: PreviewPane(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.contentViewController = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var coordinator: PreviewView.Coordinator?
        try await waitUntil("real preview didFinish", timeout: .seconds(10)) {
            host.view.layoutSubtreeIfNeeded()
            coordinator =
                descendants(host.view).compactMap { $0 as? WKWebView }.first?.navigationDelegate
                as? PreviewView.Coordinator
            return coordinator?.completedPage != nil && coordinator?.restoring == false
        }
        let preview = try XCTUnwrap(coordinator)
        let web = try XCTUnwrap(preview.web)
        let page = try XCTUnwrap(preview.page)
        var effects: [String] = []
        preview.open = { effects.append("open " + ($0.isFileURL ? $0.lastPathComponent : $0.absoluteString)) }
        preview.reveal = { effects.append("reveal " + $0.lastPathComponent) }
        preview.beep = { effects.append("beep") }

        /// Dispatches a click on the link whose href ends with `href`, then waits for one round trip to Swift.
        func click(_ href: String, detail: Int = 1, meta: Bool = false, control: Bool = false) async throws {
            let dispatched = try await web.callAsyncJavaScript(
                """
                const link = Array.from(document.querySelectorAll('a[href]')).find(a => a.getAttribute('href').endsWith(href));
                if (!link) return false;
                link.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, view: window, detail, metaKey: meta, ctrlKey: control}));
                return true;
                """, arguments: ["href": href, "detail": detail, "meta": meta, "control": control], in: nil,
                contentWorld: .page)
            XCTAssertEqual(dispatched as? Bool, true, "no rendered link to \(href)")
            // Messages are delivered in order, so a no-op round trip flushes any click report.
            _ = try await web.callAsyncJavaScript("return 0", in: nil, contentWorld: .defaultClient)
            try await Task.sleep(for: .milliseconds(100))
        }
        func expect(_ expected: [String], _ message: String, line: UInt = #line) {
            XCTAssertEqual(effects, expected, message, line: line)
            effects = []
        }

        try await click("file.pdf")
        expect(["open file.pdf"], "plain click opens a library attachment in its default app")
        try await click("file.pdf", meta: true)
        expect(["reveal file.pdf"], "⌘-click reveals an attachment in Finder")
        try await click("run.sh")
        expect(["reveal run.sh"], "a script is only ever revealed")
        try await click("missing.pdf")
        expect(["beep"], "a missing file beeps")
        try await click("mailto:user@example.com")
        expect(["open mailto:user@example.com"], "mailto: opens the mail client")
        try await click("https://example.com/page")
        expect(["open https://example.com/page"], "http(s) opens the browser")
        try await click("file.pdf", detail: 2)
        expect([], "the second click of a double-click does nothing more")
        try await click("file.pdf", control: true)
        expect([], "⌃-click is the context menu, never an open")

        // Keyboard activation (Return on a focused link) arrives as a click with detail 0.
        _ = try await web.callAsyncJavaScript(
            "Array.from(document.querySelectorAll('a[href]')).find(a => a.getAttribute('href').endsWith('file.pdf')).click()",
            in: nil, contentWorld: .page)
        try await waitUntil("keyboard-style activation opens the attachment") { effects == ["open file.pdf"] }
        effects = []

        // A click during a debounced patch still belongs to this page and document.
        preview.restoring = true
        try await click("file.pdf")
        expect(["open file.pdf"], "a click during a patch is not dropped")
        preview.restoring = false
        // A report from a page that has since been replaced is ignored, without a beep.
        _ = try await web.callAsyncJavaScript(
            "window.webkit.messageHandlers.position.postMessage({link: href, reveal: false, page: 'silkweb-preview://page/old'})",
            arguments: ["href": pdf.absoluteString], in: nil, contentWorld: .defaultClient)
        _ = try await web.callAsyncJavaScript("return 0", in: nil, contentWorld: .defaultClient)
        try await Task.sleep(for: .milliseconds(100))
        expect([], "a stale page's click does nothing")

        try await click("#end")
        var top = Double.infinity
        for _ in 0..<50 where top > 400 {
            top =
                try await web.evaluateJavaScript("document.getElementById('end').getBoundingClientRect().top")
                as? Double ?? .infinity
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertLessThan(top, 401, "a same-page anchor scrolls the preview")
        XCTAssertEqual(web.url, page, "links never navigate the preview page")
        XCTAssertEqual(effects, [])

        try await click("other.md")
        try await waitUntil("document link opens the note in Silkweb") { workspace.editor.url == other }
        XCTAssertEqual(effects, [])
        XCTAssertFalse(window.isVisible)
    }
}

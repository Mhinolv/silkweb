import AppKit
import SwiftUI
import WebKit
import XCTest
import SilkwebCore
@testable import Silkweb

final class PreviewTests: XCTestCase {
    @MainActor
    func testPreviewPaletteMatchesEditorInEveryAppearanceAndStylesheetIsInjected() async throws {
        let variants: [(NSAppearance.Name, Int)] = [
            (.aqua, HeadingPalette.light), (.darkAqua, HeadingPalette.dark),
            (.accessibilityHighContrastAqua, HeadingPalette.highContrastLight),
            (.accessibilityHighContrastDarkAqua, HeadingPalette.highContrastDark)
        ]
        for (name, rgb) in variants {
            let dark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
            let highContrast = name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua
            // AppKit normalizes named accessibility appearances while Increase Contrast
            // is off. Exercise the provider's four palette variants directly as well.
            let color = try XCTUnwrap(HeadingPalette.color(dark: dark, highContrast: highContrast).usingColorSpace(.sRGB))
            XCTAssertEqual(Int((color.redComponent * 255).rounded()), (rgb >> 16) & 255)
            XCTAssertEqual(Int((color.greenComponent * 255).rounded()), (rgb >> 8) & 255)
            XCTAssertEqual(Int((color.blueComponent * 255).rounded()), rgb & 255)
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            if appearance.name == name {
                appearance.performAsCurrentDrawingAppearance {
                    XCTAssertEqual(NSColor.editorHeading.usingColorSpace(.sRGB), color)
                }
            }
        }
        XCTAssertEqual(HeadingPalette.previewCSS, """
        :root { --sw-heading: #2A6A86; }
        @media (prefers-color-scheme: dark) { :root { --sw-heading: #86BCD6; } }
        @media (prefers-contrast: more) { :root { --sw-heading: #1F5570; } }
        @media (prefers-color-scheme: dark) and (prefers-contrast: more) { :root { --sw-heading: #A6D3E6; } }
        """)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.PreviewPalette." + UUID().uuidString))
        let preview = PreviewCoordinator(defaults: defaults)
        preview.mode = .preview
        preview.schedule(text: "# Title\n###### Subtitle", document: nil, root: nil)
        let deadline = Date().addingTimeInterval(3)
        while preview.html.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(preview.html.contains("<style>" + HeadingPalette.previewCSS))
        XCTAssertTrue(preview.html.contains("padding: 16px 48px 80px"), "Bundled stylesheet must load")
        XCTAssertTrue(preview.html.contains("h6 { font-size: .9375em"))
        XCTAssertTrue(preview.html.contains("border-bottom: 1px solid -apple-system-separator"))
    }

    @MainActor
    func testSchemeHandlerServesMemoryAndContainedAssetsAndCancels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("space # 日本語.png")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: file)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        let web = PreviewView.makeWebView()
        let handler = try XCTUnwrap(web.configuration.urlSchemeHandler(forURLScheme: PreviewResource.scheme) as? PreviewSchemeHandler)
        handler.root = root
        handler.page = URL(string: "silkweb-preview://page/test")!
        handler.html = Data("<h1>Memory page</h1>".utf8)
        let page = RecordingSchemeTask(url: try XCTUnwrap(handler.page))
        let image = RecordingSchemeTask(url: try XCTUnwrap(PreviewResource.assetURL(for: file, root: root)))
        for task in [page, image] { handler.webView(web, start: task) }
        let deadline = Date().addingTimeInterval(2)
        while !page.finished || !image.finished {
            if Date() >= deadline { XCTFail("Scheme handler did not finish"); return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(page.data, handler.html)
        XCTAssertEqual(page.response?.mimeType, "text/html")
        XCTAssertEqual(image.data, bytes)
        XCTAssertEqual(image.response?.mimeType, "image/png")
        for value in ["https://example.invalid/image.png", "file:///etc/passwd", "silkweb-preview://asset/../outside.png", "silkweb-preview://asset/escape/outside.png", "silkweb-preview://page/old", "silkweb-preview://asset/missing.png"] {
            let task = RecordingSchemeTask(url: try XCTUnwrap(URL(string: value)))
            handler.webView(web, start: task)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertNotNil(task.error, value)
            XCTAssertNil(task.response, value)
            XCTAssertTrue(task.data.isEmpty, value)
        }
        let cancelled = RecordingSchemeTask(url: try XCTUnwrap(handler.page))
        handler.webView(web, start: cancelled)
        handler.webView(web, stop: cancelled)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(cancelled.finished)
        XCTAssertNil(cancelled.error)
        XCTAssertNil(cancelled.response)
    }

    @MainActor
    func testInitialLoadingDelayAndRetryKeepsFailureUntilSuccess() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.LoadingPreview." + UUID().uuidString))
        let preview = PreviewCoordinator(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/preview-tests/note.md")
        preview.mode = .preview
        preview.error = "Test failure"
        preview.beginLoading(document: document)
        XCTAssertFalse(preview.isLoading)
        XCTAssertEqual(preview.error, "Test failure")
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(preview.isLoading)
        preview.didFinish(document: document)
        XCTAssertFalse(preview.isLoading)
        XCTAssertNil(preview.error)
        preview.beginLoading(document: document)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertFalse(preview.isLoading, "Typing reloads must not show a spinner")
    }

    @MainActor
    func testDebounceLatestResultModesAndOutlineNavigation() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.PreviewTests." + UUID().uuidString))
        let preview = PreviewCoordinator(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/preview-tests/note.md")
        let root = document.deletingLastPathComponent()
        preview.mode = .split
        preview.schedule(text: "# Obsolete", document: document, root: root)
        preview.schedule(text: "# Latest\n## Child", document: document, root: root)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(preview.headings.map(\.text), ["Latest", "Child"])
        XCTAssertFalse(preview.html.contains("Obsolete"))
        XCTAssertTrue(preview.html.contains("script-src 'none'"))
        XCTAssertEqual(preview.currentHeading(caret: 0), "latest")
        XCTAssertEqual(preview.currentHeading(caret: 15), "child")
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        let editor = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        scroll.setFrameSize(NSSize(width: 900, height: 560))
        editor.string = "# Latest\n## Child"
        preview.editor = editor
        preview.navigate(preview.headings[1])
        XCTAssertEqual(editor.selectedRange().location, 9)
        for mode in DocumentViewMode.allCases {
            preview.mode = mode
            XCTAssertEqual(PreviewCoordinator(defaults: defaults).mode, mode)
        }
        preview.mode = .split
        preview.togglePreview(); XCTAssertEqual(preview.mode, .preview)
        let restored = PreviewCoordinator(defaults: defaults)
        restored.togglePreview(); XCTAssertEqual(restored.mode, .split)
        preview.togglePreview(); XCTAssertEqual(preview.mode, .split)
        preview.toggleSplit(); XCTAssertEqual(preview.mode, .editor)
    }

    @MainActor
    func testOffscreenPreviewLoadsLocalImageAndNavigatesAnchor() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        if SnapshotHarness.isWebKitUnavailable(environment: ProcessInfo.processInfo.environment, activationPolicy: NSApp.activationPolicy().rawValue) {
            throw XCTSkip("Real WebKit DOM/image regression requires an unsandboxed registered offscreen host; WebKit is unavailable in this sandbox.")
        }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.WebTests." + UUID().uuidString))
        let workspace = LibraryWorkspace(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("img"), withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32))
        for x in 0..<4 { for y in 0..<4 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: root.appendingPathComponent("img/p.png"))
        let document = root.appendingPathComponent("note.md")
        let source = "# Title\n###### Subtitle\n\n## Level two\n### Level three\n#### Level four\n##### Level five\n\nA paragraph.\n\n| A | B |\n| --- | --- |\n| one | two |\n\n![p](img/p.png)\n![remote](https://example.invalid/image.png)\n" + String(repeating: "paragraph\n\n", count: 100) + "## End"
        try Data(source.utf8).write(to: document)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        workspace.root = root
        workspace.editor.url = document
        workspace.preview.mode = .preview
        workspace.preview.schedule(text: source, document: document, root: root)
        let host = NSHostingController(rootView: PreviewPane(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        defer { window.contentViewController = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let deadline = Date().addingTimeInterval(10)
        var web: WKWebView?
        while Date() < deadline {
            host.view.layoutSubtreeIfNeeded()
            web = descendants(host.view).compactMap { $0 as? WKWebView }.first
            if let coordinator = web?.navigationDelegate as? PreviewView.Coordinator,
               coordinator.completedPage != nil || coordinator.navigationError != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let loaded = try XCTUnwrap(web)
        let coordinator = try XCTUnwrap(loaded.navigationDelegate as? PreviewView.Coordinator)
        XCTAssertNotNil(coordinator.completedPage, "Timed out waiting for real preview didFinish (10 seconds)")
        XCTAssertNil(coordinator.navigationError)
        XCTAssertNil(workspace.preview.error)
        let value = try await loaded.evaluateJavaScript("({title: document.querySelector('h1')?.textContent, paragraph: document.querySelector('p')?.textContent, table: !!document.querySelector('table'), complete: document.images[0]?.complete, width: document.images[0]?.naturalWidth, count: document.images.length, remote: Array.from(document.images).some(i => i.src.startsWith('https:')), placeholder: document.querySelector('.sw-remote-image')?.textContent})")
        let result = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(result["title"] as? String, "Title")
        XCTAssertEqual(result["paragraph"] as? String, "A paragraph.")
        XCTAssertEqual(result["table"] as? Bool, true)
        XCTAssertEqual(result["complete"] as? Bool, true)
        XCTAssertEqual(result["width"] as? Int, 4)
        XCTAssertEqual(result["count"] as? Int, 1)
        XCTAssertEqual(result["remote"] as? Bool, false)
        XCTAssertEqual(result["placeholder"] as? String, "Remote image not loaded: remote")
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = try XCTUnwrap(NSAppearance(named: name))
            try await Task.sleep(for: .milliseconds(100))
            let styles = try await loaded.evaluateJavaScript("""
            (() => {
              const article = document.querySelector('.sw-doc');
              const headings = [1,2,3,4,5,6].map(n => document.querySelector('h' + n));
              const title = headings[0], subtitle = headings[5];
              const style = getComputedStyle(title);
              return {sizes: headings.map(h => parseFloat(getComputedStyle(h).fontSize)),
                weights: headings.slice(4).map(h => getComputedStyle(h).fontWeight),
                body: getComputedStyle(document.body).fontSize,
                top: title.getBoundingClientRect().top, border: style.borderBottomWidth,
                padding: style.paddingBottom, width: title.getBoundingClientRect().width,
                column: article.clientWidth - 96,
                gap: subtitle.getBoundingClientRect().top - title.getBoundingClientRect().bottom,
                color: style.color, allTinted: headings.every(h => getComputedStyle(h).color === style.color),
                dark: matchMedia('(prefers-color-scheme: dark)').matches,
                contrast: matchMedia('(prefers-contrast: more)').matches};
            })()
            """)
            let computed = try XCTUnwrap(styles as? [String: Any])
            XCTAssertEqual(computed["sizes"] as? [Double], [32, 24, 20, 18, 16, 15])
            XCTAssertEqual(computed["weights"] as? [String], ["700", "700"])
            XCTAssertEqual(computed["body"] as? String, "16px")
            XCTAssertEqual(computed["top"] as? Double, 16)
            XCTAssertEqual(computed["border"] as? String, "1px")
            XCTAssertEqual(computed["padding"] as? String, "8px")
            XCTAssertEqual(computed["width"] as? Double, computed["column"] as? Double)
            XCTAssertEqual(computed["gap"] as? Double, 16)
            XCTAssertEqual(computed["allTinted"] as? Bool, true)
            let dark = name == .darkAqua
            XCTAssertEqual(computed["dark"] as? Bool, dark)
            let contrast = computed["contrast"] as? Bool == true
            let rgb = contrast ? (dark ? HeadingPalette.highContrastDark : HeadingPalette.highContrastLight)
                               : (dark ? HeadingPalette.dark : HeadingPalette.light)
            XCTAssertEqual(computed["color"] as? String, "rgb(\((rgb >> 16) & 255), \((rgb >> 8) & 255), \(rgb & 255))")
        }
        for width: CGFloat in [0, 1, 280, 600, 4096] {
            for height: CGFloat in [0, 1, 400, 2160] {
                loaded.setFrameSize(NSSize(width: width, height: height))
                loaded.layoutSubtreeIfNeeded()
                XCTAssertTrue(loaded.frame.width.isFinite && loaded.frame.height.isFinite)
            }
        }
        loaded.setFrameSize(NSSize(width: 600, height: 400))
        workspace.preview.scrollPreview(to: "end")
        try await Task.sleep(for: .milliseconds(700))
        let anchor = try await loaded.evaluateJavaScript("document.getElementById('end').getBoundingClientRect().top")
        XCTAssertLessThan(try XCTUnwrap(anchor as? Double), 401)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["img", "note.md"])
    }

    @MainActor
    func testHiddenPreviewAndIdenticalInputDoNotRender() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.IdlePreview." + UUID().uuidString))
        let preview = PreviewCoordinator(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/preview-tests/note.md")
        preview.mode = .editor
        preview.schedule(text: "# Hidden", document: document, root: document.deletingLastPathComponent())
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(preview.html.isEmpty)
        XCTAssertTrue(preview.headings.isEmpty)
        XCTAssertFalse(preview.isLoading)
        preview.showsOutline = true
        preview.schedule(text: "# Outline", document: document, root: document.deletingLastPathComponent())
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(preview.headings.map(\.text), ["Outline"])
        XCTAssertTrue(preview.html.isEmpty)
        preview.mode = .split
        preview.schedule(text: "# Visible", document: document, root: document.deletingLastPathComponent())
        try await Task.sleep(for: .milliseconds(450))
        let html = preview.html
        XCTAssertTrue(html.contains("Visible"))
        preview.didFinish(document: document)
        for _ in 0..<10 { preview.schedule(text: "# Visible", document: document, root: document.deletingLastPathComponent()) }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(preview.html, html)
        XCTAssertFalse(preview.isLoading)
        preview.schedule(text: "# Cancelled", document: document, root: document.deletingLastPathComponent())
        preview.mode = .editor
        preview.schedule(text: "# Cancelled", document: document, root: document.deletingLastPathComponent())
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(preview.html, "") // outline-only work never publishes preview HTML
    }

    @MainActor
    func testRealPaneLifecycleAndHeightOnlyResizePreservesBuffer() async throws {
        _ = NSApplication.shared
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.PaneTests." + UUID().uuidString))
        let workspace = LibraryWorkspace(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "# Title\n" + String(repeating: "long paragraph\n", count: 500)
        let url = root.appendingPathComponent("a.md")
        try Data(source.utf8).write(to: url)
        workspace.root = root
        await workspace.editor.configure(root: root)
        _ = await workspace.editor.open(url, readOnly: false)
        workspace.preview.mode = .split
        let controller = DocumentPanesController(workspace: workspace)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        host.addSubview(controller.view)
        controller.view.setFrameSize(NSSize(width: 900, height: 760))
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        controller.view.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let editor = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? PlainMarkdownTextView }.first)
        let scroll = try XCTUnwrap(editor.enclosingScrollView)
        let web = PreviewView.makeWebView()
        XCTAssertFalse(web.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(web.configuration.preferences.javaScriptCanOpenWindowsAutomatically)
        XCTAssertFalse(web.configuration.websiteDataStore.isPersistent)
        let selection = NSRange(location: 20, length: 4)
        editor.setSelectedRange(selection)
        for mode in DocumentViewMode.allCases + DocumentViewMode.allCases.reversed() {
            workspace.preview.mode = mode
            controller.updateMode()
            for width: CGFloat in [1, 420, 560, 900, 4096] {
                for height: CGFloat in [1, 200, 760, 2160, 560] {
                    controller.view.setFrameSize(NSSize(width: width, height: height))
                    controller.view.layoutSubtreeIfNeeded()
                    scroll.tile()
                    // No explicit layoutEditor: the clip-view frame notification drives it.
                    XCTAssertEqual(scroll.contentInsets.bottom, 0, accuracy: 0.01)
                    XCTAssertEqual(editor.minSize.height, scroll.contentSize.height, accuracy: 0.01)
                    XCTAssertTrue(editor.frame.height.isFinite)
                    XCTAssertEqual(editor.string, source)
                    XCTAssertEqual(editor.selectedRange(), selection)
                }
            }
        }
        workspace.preview.mode = .preview
        workspace.focus(2)
        XCTAssertNotEqual(workspace.preview.mode, .preview)
        controller.updateMode()
        controller.view.removeFromSuperview(); host.addSubview(controller.view)
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(editor.string, source)
    }
}

private final class RecordingSchemeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var response: URLResponse?
    var data = Data()
    var error: Error?
    var finished = false

    init(url: URL) { request = URLRequest(url: url) }
    func didReceive(_ response: URLResponse) { self.response = response }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}

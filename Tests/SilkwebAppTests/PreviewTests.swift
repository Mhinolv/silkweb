import AppKit
import SwiftUI
import WebKit
import XCTest
import SilkwebCore
@testable import Silkweb

final class PreviewTests: XCTestCase {
    @MainActor
    func testDebounceLatestResultModesAndOutlineNavigation() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.PreviewTests." + UUID().uuidString))
        let preview = PreviewCoordinator(defaults: defaults)
        let document = URL(fileURLWithPath: "/tmp/preview-tests/note.md")
        let root = document.deletingLastPathComponent()
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
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.WebTests." + UUID().uuidString))
        let workspace = LibraryWorkspace(defaults: defaults)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("note.md")
        // A one-pixel GIF exercises real file access without any external resource.
        let gif = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")!
        try gif.write(to: root.appendingPathComponent("image.gif"))
        workspace.root = root
        workspace.editor.url = document
        let source = "# Title\n![local](image.gif)\n![remote](https://example.invalid/image.png)\n" + String(repeating: "paragraph\n\n", count: 100) + "## End"
        workspace.preview.schedule(text: source, document: document, root: root)
        try await Task.sleep(for: .milliseconds(500))
        let web = PreviewView.makeWebView()
        web.setFrameSize(NSSize(width: 600, height: 400))
        let coordinator = PreviewView.Coordinator(workspace: workspace)
        coordinator.web = web
        web.navigationDelegate = coordinator
        workspace.preview.webView = web
        coordinator.load()
        for width: CGFloat in [0, 1, 280, 600, 4096] {
            for height: CGFloat in [0, 1, 400, 2160] {
                web.setFrameSize(NSSize(width: width, height: height))
                web.layoutSubtreeIfNeeded()
                XCTAssertTrue(web.frame.width.isFinite && web.frame.height.isFinite)
            }
        }
        web.setFrameSize(NSSize(width: 600, height: 400))
        for _ in 0..<50 {
            if coordinator.completedPage != nil || coordinator.navigationError != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(coordinator.ready)
        if coordinator.completedPage == nil, ProcessInfo.processInfo.environment["CODEX_SANDBOX_NETWORK_DISABLED"] == "1" {
            // This repository's managed test host denies WebKit mach-bootstrap extensions.
            // Require a compiled rule list before skipping unavailable content-process work.
            guard coordinator.ready else { XCTFail(workspace.preview.error ?? "Offline rules did not compile"); return }
            throw XCTSkip("Offscreen WebKit did not finish loading in the managed sandbox; DOM/image/anchor assertions require a WebKit-capable host.")
        }
        XCTAssertNil(workspace.preview.error)
        let loaded = try XCTUnwrap(web.url)
        XCTAssertEqual(loaded, coordinator.page)
        let value: Any?
        do { value = try await web.callAsyncJavaScript("return { count: document.images.length, width: document.images[0]?.naturalWidth, title: document.querySelector('h1')?.textContent };", arguments: [:], in: nil, contentWorld: .defaultClient) }
        catch let failure as NSError where failure.domain == WKError.errorDomain && failure.code == WKError.webContentProcessTerminated.rawValue {
            throw XCTSkip("Managed sandbox terminated WebKit's offscreen content process.")
        }
        let result = try XCTUnwrap(value as? [String: Any])
        XCTAssertEqual(result["count"] as? Int, 1)
        XCTAssertEqual(result["width"] as? Int, 1)
        XCTAssertEqual(result["title"] as? String, "Title")
        workspace.preview.scrollPreview(to: "end")
        let anchor = try await web.callAsyncJavaScript("return document.getElementById('end').getBoundingClientRect().top;", arguments: [:], in: nil, contentWorld: .defaultClient)
        XCTAssertLessThan(try XCTUnwrap(anchor as? Double), 401)
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
                    XCTAssertEqual(scroll.contentInsets.bottom, scroll.contentSize.height / 2, accuracy: 0.01)
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

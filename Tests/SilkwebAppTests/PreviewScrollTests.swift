import AppKit
import SilkwebCore
import SwiftUI
import WebKit
import XCTest

@testable import Silkweb

final class PreviewScrollTests: XCTestCase {
    @MainActor
    func testRealSplitScrollNeverBouncesDuringEditsAndEntry() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        if SnapshotHarness.isWebKitUnavailable(
            environment: ProcessInfo.processInfo.environment, activationPolicy: NSApp.activationPolicy().rawValue)
        {
            throw XCTSkip(
                "Split scroll sampling needs real WebKit in a registered offscreen host outside the agent sandbox; run this test on both pre-fix and fixed builds there."
            )
        }
        let defaults = disposableDefaults("Scroll")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 160, bitsPerPixel: 32))
        for x in 0..<40 { for y in 0..<80 { bitmap.setColor(.systemBlue, atX: x, y: y) } }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
            to: root.appendingPathComponent("local.png"))
        let source =
            "# Resting viewport\n\n![Local](local.png)\n\n"
            + (0..<100).map {
                "## Section \($0)\n\nParagraph \($0) with **emphasis** and a [local anchor](#section-99).\n\n"
            }.joined()
        let url = root.appendingPathComponent("note.md")
        try Data(source.utf8).write(to: url)
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
        workspace.root = root
        await workspace.editor.configure(root: root)
        let opened = await workspace.editor.open(url, readOnly: false)
        XCTAssertTrue(opened)
        workspace.preview.mode = .split
        let host = NSHostingController(rootView: DocumentDetail(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1400, height: 900))
        defer { window.contentViewController = nil; window.close() }
        func layoutHost() {
            // Unordered windows do not reliably size an NSHostingController.
            // Drive the root's real layout, never the web view's frame directly.
            host.view.frame = window.contentView!.bounds
            host.view.layoutSubtreeIfNeeded()
        }
        layoutHost()
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(10)
            while !predicate(), Date() < deadline {
                layoutHost()
                try await Task.sleep(for: .milliseconds(20))
            }
            // Stop here on failure rather than checking an unloaded/zero-size DOM.
            _ = try XCTUnwrap(predicate() ? true : nil, "Timed out waiting for the real detail preview and layout")
        }
        try await wait {
            guard let coordinator = workspace.preview.webView?.navigationDelegate as? PreviewView.Coordinator else {
                return false
            }
            guard let web = workspace.preview.webView else { return false }
            return coordinator.completedPage != nil && !coordinator.restoring && web.bounds.width > 0
                && web.bounds.height > 0
        }
        let web = try XCTUnwrap(workspace.preview.webView)
        let delegate = try XCTUnwrap(web.navigationDelegate as? PreviewView.Coordinator)
        let sampler = ScrollSampler(delegate: delegate)
        web.navigationDelegate = sampler
        web.configuration.userContentController.add(sampler, contentWorld: .defaultClient, name: "scrollSample")
        defer {
            web.configuration.userContentController.removeScriptMessageHandler(
                forName: "scrollSample", contentWorld: .defaultClient)
            web.navigationDelegate = delegate
        }
        // Injection on every navigation catches the initial zero-offset frame of a
        // replaced page. The same hook also runs continuously on the existing page.
        let script = """
            const postScrollSample = () => window.webkit.messageHandlers.scrollSample.postMessage(scrollY);
            function sampleScrollOffset() {
              postScrollSample();
              requestAnimationFrame(sampleScrollOffset);
            }
            postScrollSample();
            addEventListener('scroll', postScrollSample);
            requestAnimationFrame(sampleScrollOffset);
            """
        web.configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
        _ = try await web.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
        // Hidden pages throttle both requestAnimationFrame and page timers. A
        // serial host-driven poll continues through debounce and mode switches.
        // Keep frame/scroll hooks and navigation samples to catch shorter resets.
        let polling = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    let value = try await web.callAsyncJavaScript(
                        "return scrollY;", arguments: [:], in: nil, contentWorld: .defaultClient)
                    if let value { sampler.recordPoll(value) }
                } catch {
                    // A provisional navigation can invalidate an in-flight query.
                    // Coverage assertions below require successful polls as well.
                    sampler.pollFailures += 1
                }
                do { try await Task.sleep(for: .milliseconds(8)) } catch { return }
            }
        }
        defer { polling.cancel() }
        for outline in [false, true] {
            workspace.preview.showsOutline = outline
            try await Task.sleep(for: .milliseconds(700))
            try await wait { web.bounds.width > 0 && web.bounds.height > 0 }
            // Choose a non-heading-aligned resting offset. Heading/ratio restoration
            // must not pass this test simply by ending at roughly the same section.
            let value = try await web.callAsyncJavaScript(
                "scrollTo(0, Math.floor((document.documentElement.scrollHeight - innerHeight) / 2) + 17); return scrollY;",
                arguments: [:], in: nil, contentWorld: .defaultClient)
            let baseline = try XCTUnwrap(value as? Double)
            XCTAssertGreaterThan(baseline, 1000)
            try await Task.sleep(for: .milliseconds(350))
            sampler.begin(at: baseline)
            for edit in 1...5 {
                let pollsBeforeEdit = sampler.polls
                let changed = source.replacingOccurrences(
                    of: "Resting viewport", with: "Resting viewport \(outline)-\(edit)")
                workspace.editor.text = changed
                try await wait {
                    workspace.preview.html.contains("Resting viewport \(outline)-\(edit)")
                        && delegate.lastHTML == workspace.preview.html && !delegate.restoring
                }
                try await Task.sleep(for: .milliseconds(350))
                let title = try await web.callAsyncJavaScript(
                    "return document.querySelector('h1').textContent;", arguments: [:], in: nil,
                    contentWorld: .defaultClient)
                XCTAssertEqual(title as? String, "Resting viewport \(outline)-\(edit)")
                XCTAssertGreaterThan(
                    sampler.polls - pollsBeforeEdit, 5,
                    "Each edit needs host-driven samples; query failures: \(sampler.pollFailures)")
            }
            XCTAssertGreaterThan(sampler.frames, 25, "High-frequency sampling must actually execute offscreen")
            XCTAssertLessThanOrEqual(
                sampler.maximumDeviation, 2,
                "Split edits exposed a reset/restore frame or changed the resting pixel offset")
            sampler.baseline = nil
            workspace.preview.mode = .editor
            try await Task.sleep(for: .milliseconds(500))
            workspace.editor.text = source.replacingOccurrences(of: "Resting viewport", with: "Edited while hidden")
            try await Task.sleep(for: .milliseconds(500))
            sampler.begin(at: baseline)
            workspace.preview.mode = .split
            try await wait {
                workspace.preview.html.contains("Edited while hidden") && delegate.lastHTML == workspace.preview.html
                    && !delegate.restoring && web.bounds.width > 0 && web.bounds.height > 0
            }
            try await Task.sleep(for: .milliseconds(500))
            XCTAssertGreaterThan(
                sampler.polls, 5, "Split entry needs host-driven samples; query failures: \(sampler.pollFailures)")
            XCTAssertLessThanOrEqual(
                sampler.maximumDeviation, 2, "Entering Split must retain the resting offset on every frame")
            sampler.baseline = nil
        }
        // Explicit navigation still moves the preview; excluded from stability samples.
        try await wait { web.bounds.width > 0 && web.bounds.height > 0 }
        workspace.preview.scrollPreview(to: "section-99")
        try await Task.sleep(for: .milliseconds(700))
        let top = try await web.callAsyncJavaScript(
            "return document.getElementById('section-99').getBoundingClientRect().top;", arguments: [:], in: nil,
            contentWorld: .defaultClient)
        XCTAssertGreaterThan(web.bounds.height, 0, "Outline navigation must use a laid-out preview")
        let anchorTop = try XCTUnwrap(top as? Double)
        XCTAssertGreaterThanOrEqual(anchorTop, -2)
        XCTAssertLessThan(anchorTop, web.bounds.height)
        // Exercise the changed representable lifecycle in the real hierarchy after
        // the scroll assertion: reflow at small/large sizes and every display mode.
        for mode in DocumentViewMode.allCases {
            workspace.preview.mode = mode
            for size in [
                NSSize(width: 560, height: 200), NSSize(width: 1400, height: 900), NSSize(width: 2400, height: 1600),
            ] {
                window.setContentSize(size)
                layoutHost()
                await Task.yield()
                XCTAssertTrue(web.frame.width.isFinite && web.frame.height.isFinite)
            }
        }
        workspace.preview.mode = .split
        window.setContentSize(NSSize(width: 1400, height: 900))
        layoutHost()
        try await wait { web.bounds.width > 0 && web.bounds.height > 0 }
        // Empty, smallest, structured, and long content exercise append/remove,
        // replacement, nested text, Unicode, and image anchors on the live DOM.
        for text in ["", "# A", "# 日本語 👩🏽‍💻\n\n> **Bold**\n\n- one\n- two\n\n![Local](local.png)\n", source] {
            workspace.editor.text = text
            workspace.preview.schedule(text: text, document: url, root: root)
            try await Task.sleep(for: .milliseconds(600))
            try await wait { delegate.lastHTML == workspace.preview.html && !delegate.restoring }
            let rendered = try await web.callAsyncJavaScript(
                "return document.body.innerHTML;", arguments: [:], in: nil, contentWorld: .defaultClient)
            XCTAssertNotNil(rendered as? String)
            XCTAssertNil(workspace.preview.error)
        }
        XCTAssertFalse(window.isVisible)
    }
}

/// Records DOM offsets on animation frames and all navigation delegate callbacks.
/// No production state publishes or production frame timers are needed.
@MainActor
private final class ScrollSampler: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    let delegate: PreviewView.Coordinator
    var baseline: Double?
    var frames = 0
    var polls = 0
    var pollFailures = 0
    var maximumDeviation = 0.0
    init(delegate: PreviewView.Coordinator) { self.delegate = delegate }
    func begin(at offset: Double) { baseline = offset; frames = 0; polls = 0; pollFailures = 0; maximumDeviation = 0 }
    func recordPoll(_ value: Any) {
        guard baseline != nil, let offset = value as? Double, offset.isFinite else { return }
        polls += 1
        record(offset)
    }
    func record(_ value: Any) {
        guard let baseline, let offset = value as? Double, offset.isFinite else { return }
        frames += 1
        maximumDeviation = max(maximumDeviation, abs(offset - baseline))
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        record(message.body)
    }
    func sample(_ web: WKWebView) {
        web.callAsyncJavaScript("return scrollY;", arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            if case .success(let value) = result { self?.record(value) }
        }
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { sample(webView) }
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        sample(webView)
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { sample(webView) }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { sample(webView) }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        sample(webView); delegate.webView(webView, didFinish: navigation)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        sample(webView); delegate.webView(webView, didFail: navigation, withError: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        sample(webView); delegate.webView(webView, didFailProvisionalNavigation: navigation, withError: error)
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        sample(webView); delegate.webView(webView, decidePolicyFor: navigationAction, decisionHandler: decisionHandler)
    }
}

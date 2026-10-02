import AppKit
import SwiftUI
import WebKit
import SilkwebCore

struct PreviewView: NSViewRepresentable {
    let workspace: LibraryWorkspace

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }
    func makeNSView(context: Context) -> WKWebView {
        let web = Self.makeWebView()
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        workspace.preview.webView = web
        web.configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "position")
        // Trusted app code runs in an isolated world; document JavaScript remains disabled.
        let script = """
        let timer;
        function report() {
          const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6'));
          const current = headings.filter(h => h.getBoundingClientRect().top <= 40).pop();
          const extent = Math.max(1, document.documentElement.scrollHeight - innerHeight);
          window.webkit.messageHandlers.position.postMessage({anchor: current?.id || '', ratio: scrollY / extent});
        }
        addEventListener('scroll', () => { clearTimeout(timer); timer = setTimeout(report, 250); });
        report();
        """
        web.configuration.userContentController.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        return web
    }

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.underPageBackgroundColor = .textBackgroundColor
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityLabel("Document preview")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.load() }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "position", contentWorld: .defaultClient)
        coordinator.loadTask?.cancel()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let workspace: LibraryWorkspace
        weak var web: WKWebView?
        var lastHTML = ""
        var requestedDocument: URL?
        var page: URL?
        var document: URL?
        var pageFiles: [URL] = []
        var completedPage: URL?
        var navigationError: NSError?
        var directory = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebPreview-" + UUID().uuidString)
        var loadTask: Task<Void, Never>?
        var ready = false
        var restoring = false
        var restoreAnchor = ""
        var restoreRatio = 0.0
        init(workspace: LibraryWorkspace) { self.workspace = workspace }
        deinit { try? FileManager.default.removeItem(at: directory) }

        func load() {
            let preview = workspace.preview
            guard !preview.html.isEmpty, let root = workspace.root,
                  let document = preview.renderedURL, document == workspace.editor.url,
                  preview.html != lastHTML || document != requestedDocument else { return }
            requestedDocument = document
            lastHTML = preview.html
            let html = preview.html
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self, let web = self.web else { return }
                do {
                    let directory = self.directory
                    try await Task.detached {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    }.value
                    if !self.ready {
                        let rules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^file:"},"action":{"type":"ignore-previous-rules"}}]"#
                        let list = try await WKContentRuleListStore(url: self.directory).compileContentRuleList(forIdentifier: "Silkweb.OfflinePreview.v1", encodedContentRuleList: rules)
                        guard !Task.isCancelled else { return }
                        if let list { web.configuration.userContentController.add(list) }
                        self.ready = true
                    }
                    let file = self.directory.appendingPathComponent(UUID().uuidString + ".html")
                    try await Task.detached {
                        try Data(html.utf8).write(to: file, options: .atomic)
                    }.value
                    guard !Task.isCancelled else { return }
                    self.restoreAnchor = preview.pendingAnchor ?? preview.scrollAnchor ?? ""
                    self.restoreRatio = preview.scrollRatio
                    self.restoring = true
                    self.pageFiles.append(file)
                    self.completedPage = nil
                    self.navigationError = nil
                    self.page = file
                    self.document = document
                    web.loadFileURL(file, allowingReadAccessTo: root)
                    preview.error = nil
                } catch { if !Task.isCancelled { preview.error = "Preview couldn’t load: \(error.localizedDescription)" } }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !restoring, document == workspace.editor.url, message.frameInfo.isMainFrame, let values = message.body as? [String: Any] else { return }
            updatePosition(values)
        }

        private func updatePosition(_ values: [String: Any]) {
            guard let ratio = values["ratio"] as? Double, ratio.isFinite else { return }
            let preview = workspace.preview
            let anchor = values["anchor"] as? String
            preview.scrollAnchor = anchor?.isEmpty == false ? anchor : nil
            preview.scrollRatio = min(1, max(0, ratio))
            if preview.visibleHeading != preview.scrollAnchor { preview.visibleHeading = preview.scrollAnchor }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let preview = workspace.preview
            guard document == workspace.editor.url, webView.url == page else { return }
            completedPage = page
            let anchor = preview.pendingAnchor ?? restoreAnchor
            preview.pendingAnchor = nil
            webView.callAsyncJavaScript("""
                const heading = document.getElementById(anchor);
                if (heading) heading.scrollIntoView();
                else scrollTo(0, ratio * Math.max(0, document.documentElement.scrollHeight - innerHeight));
                const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6'));
                const current = headings.filter(h => h.getBoundingClientRect().top <= 40).pop();
                return {anchor: current?.id || '', ratio: scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)};
                """, arguments: ["anchor": anchor, "ratio": restoreRatio], in: nil, in: .defaultClient) { [weak self] result in
                    self?.restoring = false
                    if case .success(let value) = result, let values = value as? [String: Any] { self?.updatePosition(values) }
                }
            // Each reload has its own URL; remove old files only after WebKit finishes.
            let oldFiles = pageFiles.filter { $0 != page }
            pageFiles.removeAll { $0 != page }
            Task.detached { for file in oldFiles { try? FileManager.default.removeItem(at: file) } }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            failed(error)
        }

        private func failed(_ error: Error) {
            let failure = error as NSError
            guard failure.code != NSURLErrorCancelled else { return }
            navigationError = failure
            workspace.preview.error = "Preview couldn’t load: \(failure.localizedDescription)"
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url, let page else { decisionHandler(.cancel); return }
            if navigationAction.navigationType != .linkActivated {
                decisionHandler(url == page && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
                return
            }
            guard let root = workspace.root, let document else { decisionHandler(.cancel); return }
            switch PreviewNavigation.action(for: url, document: document, root: root, page: page) {
            case .anchor(let id): workspace.preview.scrollPreview(to: id)
            case .document(let url):
                let path = String(url.path.dropFirst(root.path.count + 1))
                if workspace.snapshot?.documents.contains(where: { $0.relativePath == path }) == true { workspace.showDocument(url) }
            case .browser(let url): NSWorkspace.shared.open(url)
            case .blocked: break
            }
            decisionHandler(.cancel)
        }
    }
}

import AppKit
import SilkwebCore
import SwiftUI
import WebKit

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
              const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6,[id^=outline_image_]'));
              const current = headings.filter(h => h.getBoundingClientRect().top <= 40).pop();
              const extent = Math.max(1, document.documentElement.scrollHeight - innerHeight);
              window.webkit.messageHandlers.position.postMessage({anchor: current?.id || '', ratio: scrollY / extent});
            }
            addEventListener('scroll', () => { clearTimeout(timer); timer = setTimeout(report, 250); });
            function blockedLink(event) {
              if (event.target.closest?.('.sw-blocked-link[role="link"]')) {
                event.preventDefault();
                window.webkit.messageHandlers.position.postMessage({blockedLink: true});
              }
            }
            addEventListener('click', blockedLink);
            addEventListener('keydown', event => { if (event.key === 'Enter') blockedLink(event); });
            report();
            """
        web.configuration.userContentController.addUserScript(
            WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        return web
    }

    static func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(PreviewSchemeHandler(), forURLScheme: PreviewResource.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.underPageBackgroundColor = .silkwebPaneBackground
        web.setValue(false, forKey: "drawsBackground")
        web.setAccessibilityLabel("Document preview")
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.load() }
    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.configuration.userContentController.removeScriptMessageHandler(
            forName: "position", contentWorld: .defaultClient)
        coordinator.loadTask?.cancel()
        coordinator.workspace.preview.endLoading()
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let workspace: LibraryWorkspace
        weak var web: WKWebView?
        var lastHTML = ""
        var requestedDocument: URL?
        var requestedRoot: URL?
        var navigation: WKNavigation?
        var page: URL?
        var document: URL?
        var completedPage: URL?
        var navigationError: NSError?
        var loadTask: Task<Void, Never>?
        var ready = false
        var restoring = false
        var restoreAnchor = ""
        var restoreRatio = 0.0
        init(workspace: LibraryWorkspace) { self.workspace = workspace }
        var retry = -1

        func load() {
            let preview = workspace.preview
            guard preview.mode != .editor else {
                loadTask?.cancel()
                restoring = false
                web?.stopLoading()
                if completedPage == nil { lastHTML = "" }
                preview.endLoading()
                return
            }
            guard !preview.html.isEmpty, let root = workspace.root,
                let document = preview.renderedURL, document == workspace.editor.url,
                preview.html != lastHTML || document != requestedDocument || root != requestedRoot
                    || retry != preview.retry
            else { return }
            let canPatch =
                completedPage != nil && self.document == document && requestedRoot == root && retry == preview.retry
            retry = preview.retry
            preview.beginLoading(document: document)
            requestedDocument = document
            requestedRoot = root
            lastHTML = preview.html
            let html = preview.html
            loadTask?.cancel()
            loadTask = Task { [weak self] in
                guard let self, let web = self.web else { return }
                do {
                    if !self.ready {
                        let rules =
                            #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^silkweb-preview:"},"action":{"type":"ignore-previous-rules"}}]"#
                        let list = try await WKContentRuleListStore.default().compileContentRuleList(
                            forIdentifier: "Silkweb.OfflinePreview.v2", encodedContentRuleList: rules)
                        guard !Task.isCancelled, preview.mode != .editor else { return }
                        if let list { web.configuration.userContentController.add(list) }
                        self.ready = true
                    }
                    guard !Task.isCancelled, preview.mode != .editor,
                        let handler = web.configuration.urlSchemeHandler(forURLScheme: PreviewResource.scheme)
                            as? PreviewSchemeHandler
                    else { return }
                    if canPatch {
                        self.restoring = true
                        let value = try await web.callAsyncJavaScript(
                            Self.patchScript,
                            arguments: [
                                "html": html, "images": self.imageAnchors, "anchor": preview.pendingAnchor ?? "",
                            ], in: nil, contentWorld: .defaultClient)
                        guard !Task.isCancelled, preview.mode != .editor, self.document == workspace.editor.url else {
                            return
                        }
                        preview.pendingAnchor = nil
                        self.restoring = false
                        if let values = value as? [String: Any] { self.updatePosition(values) }
                        preview.didFinish(document: document)
                        return
                    }
                    let page = URL(string: "silkweb-preview://page/" + UUID().uuidString)!
                    handler.page = page
                    handler.html = Data(html.utf8)
                    handler.root = root
                    self.restoreAnchor = preview.pendingAnchor ?? preview.scrollAnchor ?? ""
                    self.restoreRatio = preview.scrollRatio
                    self.restoring = true
                    self.completedPage = nil
                    self.navigationError = nil
                    self.page = page
                    self.document = document
                    self.navigation = web.load(URLRequest(url: page))
                } catch { if !Task.isCancelled { self.failed(error) } }
            }
        }

        private var imageAnchors: [[String: Any]] {
            workspace.preview.outlineItems.compactMap { item in
                guard case .image = item.content else { return nil }
                return ["id": item.id, "line": item.sourceLine ?? "", "direct": item.isInlineImage]
            }
        }

        // One isolated-world transaction: retain unchanged nodes (especially decoded
        // images), update changed content, and restore pixels before the next paint.
        // Passive updates never scroll to the last visible heading or a height ratio.
        static let patchScript = """
            const x = scrollX, y = scrollY;
            const next = new DOMParser().parseFromString(html, 'text/html');
            function patch(parent, source) {
              const wanted = Array.from(source.childNodes);
              for (let i = 0; i < wanted.length; i++) {
                const old = parent.childNodes[i], node = wanted[i];
                if (!old) { parent.appendChild(node.cloneNode(true)); continue; }
                if (old.isEqualNode(node)) continue;
                if (old.nodeType !== node.nodeType || old.nodeName !== node.nodeName) {
                  old.replaceWith(node.cloneNode(true)); continue;
                }
                if (old.nodeType === Node.ELEMENT_NODE) {
                  for (const attr of Array.from(old.attributes)) {
                    if (!node.hasAttribute(attr.name)) old.removeAttribute(attr.name);
                  }
                  for (const attr of Array.from(node.attributes)) {
                    if (old.getAttribute(attr.name) !== attr.value) old.setAttribute(attr.name, attr.value);
                  }
                  patch(old, node);
                } else if (old.nodeValue !== node.nodeValue) old.nodeValue = node.nodeValue;
              }
              while (parent.childNodes.length > wanted.length) parent.lastChild.remove();
            }
            patch(document.body, next.body);
            const rendered = Array.from(document.querySelectorAll('img,.sw-missing-image,.sw-remote-image:not(:has(img))'));
            let index = 0;
            for (const image of images) {
              const node = image.direct ? rendered[index++] : Array.from(document.querySelectorAll('p,li')).find(p => p.textContent.includes(image.line));
              if (node) node.id = image.id;
            }
            const target = anchor && document.getElementById(anchor);
            if (target) target.scrollIntoView();
            else scrollTo(x, y);
            const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6,[id^=outline_image_]'));
            const current = headings.filter(h => h.getBoundingClientRect().top <= 40).pop();
            return {anchor: current?.id || '', ratio: scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)};
            """

        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) {
            guard !restoring, document == workspace.editor.url, message.frameInfo.isMainFrame,
                let values = message.body as? [String: Any]
            else { return }
            if values["blockedLink"] as? Bool == true { NSSound.beep(); return }
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
            guard navigation === self.navigation, document == workspace.editor.url, webView.url == page else { return }
            completedPage = page
            preview.didFinish(document: document)
            let anchor = preview.pendingAnchor ?? restoreAnchor
            preview.pendingAnchor = nil
            webView.callAsyncJavaScript(
                """
                // Attach display-only anchors to the existing DOM. Reference images
                // unsupported by the renderer still navigate to their source paragraph.
                const rendered = Array.from(document.querySelectorAll('img,.sw-missing-image,.sw-remote-image:not(:has(img))'));
                let index = 0;
                for (const image of images) {
                  const node = image.direct ? rendered[index++] : Array.from(document.querySelectorAll('p,li')).find(p => p.textContent.includes(image.line));
                  if (node) node.id = image.id;
                }
                const heading = document.getElementById(anchor);
                if (heading) heading.scrollIntoView();
                else scrollTo(0, ratio * Math.max(0, document.documentElement.scrollHeight - innerHeight));
                const headings = Array.from(document.querySelectorAll('h1,h2,h3,h4,h5,h6,[id^=outline_image_]'));
                const current = headings.filter(h => h.getBoundingClientRect().top <= 40).pop();
                return {anchor: current?.id || '', ratio: scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight)};
                """, arguments: ["anchor": anchor, "ratio": restoreRatio, "images": imageAnchors], in: nil,
                in: .defaultClient
            ) { [weak self] result in
                self?.restoring = false
                if case .success(let value) = result, let values = value as? [String: Any] {
                    self?.updatePosition(values)
                }
            }
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            guard navigation === self.navigation else { return }
            failed(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard navigation === self.navigation else { return }
            failed(error)
        }

        private func failed(_ error: Error) {
            restoring = false
            let failure = error as NSError
            guard failure.code != NSURLErrorCancelled else { return }
            navigationError = failure
            workspace.preview.endLoading()
            if workspace.preview.error != failure.localizedDescription, let web {
                NSAccessibility.post(
                    element: web, notification: .announcementRequested,
                    userInfo: [
                        .announcement: "Preview couldn’t load. " + failure.localizedDescription,
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ])
            }
            workspace.preview.error = failure.localizedDescription
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
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
                if workspace.snapshot?.documents.contains(where: { $0.relativePath == path }) == true {
                    workspace.showDocument(url)
                } else {
                    NSSound.beep()
                }
            case .browser(let url): NSWorkspace.shared.open(url)
            case .blocked: NSSound.beep()
            }
            decisionHandler(.cancel)
        }
    }
}

/// Loading and error feedback belongs to the preview half of the split view.
struct PreviewPane: View {
    let workspace: LibraryWorkspace

    var body: some View {
        VStack(spacing: 0) {
            if let reason = workspace.preview.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preview couldn’t load.").font(.callout)
                        Text(reason).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Try Again") { workspace.preview.retry += 1 }
                }
                .controlSize(.small)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .paneStrip(hairline: .bottom)
            }
            PreviewView(workspace: workspace)
                .overlay {
                    if workspace.preview.isLoading { ProgressView().controlSize(.small) }
                }
        }
        .background(Color.silkwebPaneBackground)
    }
}

import AppKit
import WebKit

/// A short-lived, offscreen renderer. The native print operation owns pagination.
@MainActor
final class PrintCoordinator: NSObject, WKNavigationDelegate {
    nonisolated static let stylesheet: String = {
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Silkweb_Silkweb.bundle")
        let resources = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        return resources.url(forResource: "print", withExtension: "css")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }()
    // Content blockers support a restricted regex syntax: keep scheme exceptions
    // separate rather than using unsupported groups or alternation.
    static let offlineRules = #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^about:blank$"},"action":{"type":"ignore-previous-rules"}}]"#
    let web: WKWebView
    private var completion: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 900), configuration: configuration)
        super.init()
        web.navigationDelegate = self
    }

    func load(html: String) async throws {
        let rules = try await WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "Silkweb.OfflinePrint.v1", encodedContentRuleList: Self.offlineRules)
        guard let rules else { throw URLError(.cannotLoadFromNetwork) }
        web.configuration.userContentController.add(rules)
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                self?.finish(.failure(URLError(.timedOut)))
                self?.web.stopLoading()
            }
            web.loadHTMLString(html, baseURL: nil)
        }
    }

    func operation(info: NSPrintInfo, title: String, destination: URL? = nil) -> NSPrintOperation {
        let copy = info.copy() as! NSPrintInfo
        if let destination {
            copy.jobDisposition = .save
            copy.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
        } else { copy.jobDisposition = .spool }
        let operation = web.printOperation(with: copy)
        operation.jobTitle = title
        operation.showsPrintPanel = destination == nil
        operation.showsProgressPanel = true
        operation.canSpawnSeparateThread = true
        operation.printPanel.options.insert(.showsPreview)
        return operation
    }

    static func defaultPrintInfo() -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.topMargin = 18 * 72 / 25.4
        info.bottomMargin = info.topMargin
        info.leftMargin = 16 * 72 / 25.4
        info.rightMargin = info.leftMargin
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true
        return info
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Decode embedded images before asking WebKit to paginate. This isolated script
        // runs only app code; document JavaScript remains disabled.
        webView.callAsyncJavaScript("""
            await Promise.all(Array.from(document.images, image => image.decode().catch(() => {})));
            await document.fonts.ready;
            """, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
                self?.finish(result.map { _ in () })
            }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(URLError(.cannotLoadFromNetwork))) }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.navigationType != .linkActivated && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        let continuation = completion
        completion = nil
        continuation?.resume(with: result)
    }
}

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
    let hostWindow: NSWindow
    private var completion: CheckedContinuation<Void, Error>?
    private var timeout: Task<Void, Never>?

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 720, height: 900), configuration: configuration)
        hostWindow = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        hostWindow.isReleasedWhenClosed = false
        hostWindow.contentView = web
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
        // WKWebView's printing view must paginate on the main thread. AppKit's
        // background printing path can spin indefinitely waiting for WebKit.
        operation.canSpawnSeparateThread = false
        operation.printPanel.options.insert(.showsPreview)
        return operation
    }

    /// Show the standard panel separately so time spent choosing a printer does not
    /// count against the rendering deadline. Never enter run()'s synchronous loop.
    func print(info: NSPrintInfo, title: String, destination: URL? = nil,
               window: NSWindow? = nil, timeoutInterval: TimeInterval = 60,
               showsProgressPanel: Bool = true) async throws -> Bool {
        guard NSPrintOperation.current == nil else { throw CocoaError(.userCancelled) }
        let operation = operation(info: info, title: title, destination: destination)
        return try await run(operation, window: window, timeoutInterval: timeoutInterval,
                             showsProgressPanel: showsProgressPanel)
    }

    func run(_ operation: NSPrintOperation, window: NSWindow? = nil,
             timeoutInterval: TimeInterval = 60, showsProgressPanel: Bool = true) async throws -> Bool {
        let parent = window ?? hostWindow
        if operation.showsPrintPanel {
            // The standard panel queries the current operation for preview pages.
            NSPrintOperation.current = operation
            let response = await withCheckedContinuation { continuation in
                operation.printPanel.beginSheet(using: operation.printInfo, on: parent) { response in
                    continuation.resume(returning: response)
                }
            }
            NSPrintOperation.current = nil
            guard response == .printed else { return false }
        }
        operation.showsPrintPanel = false
        operation.showsProgressPanel = showsProgressPanel
        return try await PrintJob.run(operation, window: parent, timeoutInterval: timeoutInterval) { [web] in
            web.stopLoading()
            // Invalidate the print source and dismiss any system progress sheet.
            web.loadHTMLString("", baseURL: nil)
            if let sheet = parent.attachedSheet { parent.endSheet(sheet, returnCode: .cancel) }
        }
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

/// Owns one completion and deadline, including when AppKit calls back after timeout.
/// The retained context belongs to AppKit until didRun; a late callback is harmless.
@MainActor
final class PrintJob: NSObject {
    private var completion: CheckedContinuation<Bool, Error>?
    private var timer: Timer?

    static func run(_ operation: NSPrintOperation, window: NSWindow,
                    timeoutInterval: TimeInterval, cancel: @escaping () -> Void) async throws -> Bool {
        let job = PrintJob()
        return try await job.wait(timeoutInterval: timeoutInterval, cancel: cancel) {
            operation.runModal(for: window, delegate: job,
                               didRun: #selector(didRun(_:success:contextInfo:)),
                               contextInfo: Unmanaged.passRetained(job).toOpaque())
        }
    }

    // Injectable start permits deterministic deadline and late-callback tests without
    // invoking a printer service or WebKit in the sandbox.
    func wait(timeoutInterval: TimeInterval, cancel: @escaping () -> Void,
              start: () -> Void) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            let timer = Timer(timeInterval: timeoutInterval, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finish(.failure(URLError(.timedOut)))
                    cancel()
                }
            }
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            RunLoop.main.add(timer, forMode: .modalPanel)
            start()
        }
    }

    @objc private func didRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        guard let contextInfo else { return }
        let job = Unmanaged<PrintJob>.fromOpaque(contextInfo).takeRetainedValue()
        job.finish(.success(success))
    }

    func finish(_ result: Result<Bool, Error>) {
        timer?.invalidate()
        timer = nil
        let continuation = completion
        completion = nil
        continuation?.resume(with: result)
    }
}

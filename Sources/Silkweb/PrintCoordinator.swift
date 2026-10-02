import AppKit
import WebKit
import PDFKit

/// A short-lived, offscreen renderer shared by native printing and PDF export.
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

    func operation(info: NSPrintInfo, title: String) -> NSPrintOperation {
        let copy = info.copy() as! NSPrintInfo
        copy.jobDisposition = .spool
        let operation = web.printOperation(with: copy)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.canSpawnSeparateThread = false
        operation.printPanel.options.insert(.showsPreview)
        return operation
    }

    /// Native printing is always a sheet on the document window.
    func print(info: NSPrintInfo, title: String, window: NSWindow,
               timeoutInterval: TimeInterval = 60) async throws -> Bool {
        guard NSPrintOperation.current == nil else { throw CocoaError(.userCancelled) }
        return try await run(operation(info: info, title: title), window: window,
                             timeoutInterval: timeoutInterval)
    }

    /// createPDF captures screen layout, not @page pagination. Fixed-height CSS
    /// columns apply the same break rules, then one capture is sliced into paper
    /// pages. Margins are added exactly once, from the user's Page Setup settings.
    func exportPDF(html: String, info: NSPrintInfo, title: String,
                   timeoutInterval: TimeInterval = 15) async throws -> Data {
        let paper = info.paperSize
        let width = paper.width - info.leftMargin - info.rightMargin
        let height = paper.height - info.topMargin - info.bottomMargin
        guard width.isFinite, height.isFinite, width > 0, height > 0 else {
            throw PDFExportError.invalidPage
        }
        // CSS uses 96 pixels per inch; PDF paper and margins use 72 points.
        // Layout in CSS pixels, then page assembly scales to physical points so
        // the stylesheet's 11pt body type remains 11pt in the deliverable.
        let layoutWidth = width * 96 / 72
        let layoutHeight = height * 96 / 72
        return try await PDFExportJob().wait(timeoutInterval: timeoutInterval, cancel: { [weak self] in
            self?.web.stopLoading()
            self?.finish(.failure(PDFExportError.timedOut))
        }) { [self] in
            web.setFrameSize(NSSize(width: layoutWidth, height: layoutHeight))
            try await load(html: html)
            let value = try await javascript("""
                const style = document.createElement('style');
                style.textContent = `html, body { margin: 0; width: ${width}px; }
                    .sw-doc { width: ${width}px; height: ${height}px;
                        column-width: ${width}px; column-gap: 0; column-fill: auto; }
                    img { max-height: ${height}px; }`;
                document.head.appendChild(style);
                await document.fonts.ready;
                // scrollWidth rounds to integral CSS pixels; ceil would add a
                // blank page for fractional paper widths, even on empty notes.
                return Math.max(1, Math.round(document.querySelector('.sw-doc').scrollWidth / width));
                """, arguments: ["width": layoutWidth, "height": layoutHeight])
            guard let count = value as? Int, count > 0, count <= 10_000 else {
                throw PDFExportError.invalidPage
            }
            try Task.checkCancellation()
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: layoutWidth * CGFloat(count), height: layoutHeight)
            let capture: Data = try await withCheckedThrowingContinuation { continuation in
                web.createPDF(configuration: configuration) { result in
                    continuation.resume(with: result)
                }
            }
            try Task.checkCancellation()
            // PDF parsing and page assembly are independent of AppKit/WebKit.
            let left = info.leftMargin, bottom = info.bottomMargin
            let assembly = Task.detached(priority: .userInitiated) {
                try Self.paginate(capture, count: count, paper: paper,
                                  content: CGSize(width: width, height: height),
                                  left: left, bottom: bottom, title: title)
            }
            return try await withTaskCancellationHandler {
                try await assembly.value
            } onCancel: {
                assembly.cancel()
            }
        }
    }

    func javascript(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                continuation.resume(with: result)
            }
        }
    }

    nonisolated static func paginate(_ capture: Data, count: Int, paper: CGSize,
                                    content: CGSize, left: CGFloat, bottom: CGFloat,
                                    title: String) throws -> Data {
        guard let provider = CGDataProvider(data: capture as CFData),
              let source = CGPDFDocument(provider), source.numberOfPages == 1,
              let page = source.page(at: 1) else { throw PDFExportError.invalidPDF }
        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &box,
                                      [kCGPDFContextTitle: title] as CFDictionary) else {
            throw PDFExportError.invalidPDF
        }
        for index in 0..<count {
            try Task.checkCancellation()
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: left, y: bottom)
            context.clip(to: CGRect(origin: .zero, size: content))
            let strip = CGRect(x: -CGFloat(index) * content.width, y: 0,
                               width: CGFloat(count) * content.width, height: content.height)
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: strip, rotate: 0, preserveAspectRatio: false))
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        // Validate the deliverable rather than publishing a partial capture.
        guard let document = PDFDocument(data: output as Data), document.pageCount == count else {
            throw PDFExportError.invalidPDF
        }
        return output as Data
    }

    private func run(_ operation: NSPrintOperation, window: NSWindow,
                     timeoutInterval: TimeInterval) async throws -> Bool {
        let parent = window
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
        operation.showsProgressPanel = true
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

enum PDFExportError: LocalizedError, Equatable {
    case timedOut, invalidPage, invalidPDF
    var errorDescription: String? {
        switch self {
        case .timedOut: return "PDF rendering took too long. Try exporting a smaller document."
        case .invalidPage: return "The selected paper size and margins leave no printable area."
        case .invalidPDF: return "The rendered PDF could not be read."
        }
    }
}

/// A deadline covers loading, image decoding, capture and page assembly. Late
/// WebKit callbacks cannot complete an export a second time or publish a file.
@MainActor
final class PDFExportJob {
    private var completion: CheckedContinuation<Data, Error>?
    private var deadline: Task<Void, Never>?
    private var work: Task<Void, Never>?

    func wait(timeoutInterval: TimeInterval, cancel: @escaping () -> Void,
              render: @escaping () async throws -> Data) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            deadline = Task { [self] in
                do { try await Task.sleep(for: .seconds(timeoutInterval)) } catch { return }
                work?.cancel()
                finish(.failure(PDFExportError.timedOut))
                cancel()
            }
            work = Task { [self] in
                do { finish(.success(try await render())) }
                catch { finish(.failure(error)) }
            }
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        deadline?.cancel()
        deadline = nil
        let continuation = completion
        completion = nil
        work = nil
        continuation?.resume(with: result)
    }
}

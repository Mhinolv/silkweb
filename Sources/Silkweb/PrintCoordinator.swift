import AppKit
import PDFKit
import WebKit

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
    static let offlineRules =
        #"[{"trigger":{"url-filter":".*"},"action":{"type":"block"}},{"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},{"trigger":{"url-filter":"^about:blank$"},"action":{"type":"ignore-previous-rules"}}]"#
    /// Horizontal space between layout columns. Each page is captured on its own, and the gap
    /// keeps neighbouring columns out of the capture rect entirely, so WebKit paints neither
    /// their pixels nor their text into the page.
    static let columnGap: CGFloat = 128
    let web: WKWebView
    let hostWindow: NSWindow
    /// The last paginated PDF, printed 1:1 by `operation(info:title:)`.
    private(set) var pages: Data?
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

    /// Prints the pages rendered by the last `exportPDF`, so the print preview and
    /// Save as PDF match Export ▸ PDF exactly.
    func operation(info: NSPrintInfo, title: String) throws -> NSPrintOperation {
        guard let pages else { throw PDFExportError.invalidPDF }
        return try Self.printOperation(pages: pages, info: info, title: title)
    }

    /// The pages already carry the Page Setup paper and margins, so they print 1:1
    /// (zero operation margins) and the panel hides paper, orientation and scale.
    static func printOperation(pages: Data, info: NSPrintInfo, title: String) throws -> NSPrintOperation {
        guard let provider = CGDataProvider(data: pages as CFData),
            let document = CGPDFDocument(provider), document.numberOfPages > 0
        else {
            throw PDFExportError.invalidPDF
        }
        let copy = info.copy() as! NSPrintInfo
        copy.jobDisposition = .spool
        copy.topMargin = 0
        copy.bottomMargin = 0
        copy.leftMargin = 0
        copy.rightMargin = 0
        let view = PrintedPagesView(
            document: document, paper: info.paperSize, title: title,
            margins: NSEdgeInsets(
                top: info.topMargin, left: info.leftMargin,
                bottom: info.bottomMargin, right: info.rightMargin))
        let operation = NSPrintOperation(view: view, printInfo: copy)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.canSpawnSeparateThread = false
        operation.printPanel.options.insert(.showsPreview)
        operation.printPanel.options.subtract([.showsPaperSize, .showsOrientation, .showsScaling])
        return operation
    }

    /// Native printing is always a sheet on the document window.
    func print(
        info: NSPrintInfo, title: String, window: NSWindow,
        timeoutInterval: TimeInterval = 60
    ) async throws -> Bool {
        guard NSPrintOperation.current == nil else { throw CocoaError(.userCancelled) }
        return try await run(
            operation(info: info, title: title), window: window,
            timeoutInterval: timeoutInterval)
    }

    /// createPDF captures screen layout, not @page pagination. Fixed-height CSS
    /// columns apply the same break rules; each column is captured as its own page,
    /// so a page holds only its own pixels and text. Margins are added exactly once,
    /// from the user's Page Setup settings.
    func exportPDF(
        html: String, info: NSPrintInfo, title: String,
        timeoutInterval: TimeInterval = 15
    ) async throws -> Data {
        pages = nil
        let paper = info.paperSize
        let width = paper.width - info.leftMargin - info.rightMargin
        let height = paper.height - info.topMargin - info.bottomMargin
        // CSS uses 96 pixels per inch; PDF paper and margins use 72 points. Layout
        // in whole CSS pixels (no fractional column drift between pages), then page
        // assembly scales to physical points so 11pt body type remains 11pt.
        let layoutWidth = (width * 96 / 72).rounded(.down)
        let layoutHeight = (height * 96 / 72).rounded(.down)
        guard layoutWidth.isFinite, layoutHeight.isFinite, layoutWidth >= 1, layoutHeight >= 1 else {
            throw PDFExportError.invalidPage
        }
        let gap = Self.columnGap
        let content = CGRect(
            x: info.leftMargin, y: paper.height - info.topMargin - layoutHeight * 72 / 96,
            width: layoutWidth * 72 / 96, height: layoutHeight * 72 / 96)
        // Final layout is in the document before it loads, so the image decoding awaited
        // on navigation (and again before capture) is for the sizes actually painted.
        let layout = """
            <style>html, body { margin: 0; width: \(Int(layoutWidth))px; }
            ::-webkit-scrollbar { display: none; width: 0; height: 0; }
            .sw-doc { box-sizing: border-box; width: \(Int(layoutWidth))px; height: \(Int(layoutHeight))px;
                column-width: \(Int(layoutWidth))px; column-gap: \(Int(gap))px; column-fill: auto; }
            img { max-height: \(Int(layoutHeight))px; }</style>
            """
        let document =
            html.range(of: "</head>").map { html.replacingCharacters(in: $0, with: layout + "</head>") } ?? layout
            + html
        let data = try await PDFExportJob().wait(
            timeoutInterval: timeoutInterval,
            cancel: { [weak self] in
                self?.web.stopLoading()
                self?.finish(.failure(PDFExportError.timedOut))
            }
        ) { [self] in
            web.setFrameSize(NSSize(width: layoutWidth, height: layoutHeight))
            try await load(html: document)
            let value = try await javascript(
                """
                const images = Array.from(document.images);
                // Paint must never fall back to an asynchronous (blank) decode.
                for (const image of images) image.decoding = 'sync';
                await Promise.all(images.map(image => image.decode().catch(() => {})));
                for (const image of images) {
                    if (image.complete && image.naturalWidth > 0) continue;
                    const placeholder = document.createElement('span');
                    placeholder.className = 'sw-missing-image';
                    placeholder.textContent = 'Image not included: ' + (image.alt || image.title || 'image');
                    image.replaceWith(placeholder);
                }
                await document.fonts.ready;
                // n columns span n * width + (n - 1) * gap whole CSS pixels.
                const span = document.querySelector('.sw-doc').scrollWidth;
                return Math.max(1, Math.round((span + gap) / (width + gap)));
                """, arguments: ["width": layoutWidth, "gap": gap])
            guard let count = value as? Int, count > 0, count <= 10_000 else {
                throw PDFExportError.invalidPage
            }
            var captures: [Data] = []
            captures.reserveCapacity(count)
            for index in 0..<count {
                try Task.checkCancellation()
                let configuration = WKPDFConfiguration()
                configuration.rect = CGRect(
                    x: CGFloat(index) * (layoutWidth + gap), y: 0,
                    width: layoutWidth, height: layoutHeight)
                captures.append(
                    try await withCheckedThrowingContinuation { continuation in
                        web.createPDF(configuration: configuration) { result in
                            continuation.resume(with: result)
                        }
                    })
            }
            try Task.checkCancellation()
            // PDF parsing and page assembly are independent of AppKit/WebKit.
            let assembly = Task.detached(priority: .userInitiated) {
                try Self.assemble(captures, paper: paper, content: content, title: title)
            }
            return try await withTaskCancellationHandler {
                try await assembly.value
            } onCancel: {
                assembly.cancel()
            }
        }
        pages = data
        return data
    }

    func javascript(_ script: String, arguments: [String: Any] = [:]) async throws -> Any? {
        try await withCheckedThrowingContinuation { continuation in
            web.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .defaultClient) { result in
                continuation.resume(with: result)
            }
        }
    }

    /// Places one single-page capture per paper page, scaled into `content` (PDF
    /// coordinates). Each output page draws only its own capture, so its text layer
    /// cannot contain a neighbour's text.
    nonisolated static func assemble(
        _ captures: [Data], paper: CGSize, content: CGRect,
        title: String
    ) throws -> Data {
        guard !captures.isEmpty else { throw PDFExportError.invalidPDF }
        let output = NSMutableData()
        var box = CGRect(origin: .zero, size: paper)
        guard let consumer = CGDataConsumer(data: output),
            let context = CGContext(
                consumer: consumer, mediaBox: &box,
                [kCGPDFContextTitle: title] as CFDictionary)
        else {
            throw PDFExportError.invalidPDF
        }
        for capture in captures {
            try Task.checkCancellation()
            guard let provider = CGDataProvider(data: capture as CFData),
                let source = CGPDFDocument(provider), source.numberOfPages == 1,
                let page = source.page(at: 1)
            else { throw PDFExportError.invalidPDF }
            let media = page.getBoxRect(.mediaBox)
            guard media.width > 0, media.height > 0 else { throw PDFExportError.invalidPDF }
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: content.minX, y: content.minY)
            context.scaleBy(x: content.width / media.width, y: content.height / media.height)
            context.translateBy(x: -media.minX, y: -media.minY)
            context.drawPDFPage(page)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        // Validate the deliverable rather than publishing a partial capture.
        guard let document = PDFDocument(data: output as Data), document.pageCount == captures.count else {
            throw PDFExportError.invalidPDF
        }
        return output as Data
    }

    private func run(
        _ operation: NSPrintOperation, window: NSWindow,
        timeoutInterval: TimeInterval
    ) async throws -> Bool {
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
        webView.callAsyncJavaScript(
            """
            await Promise.all(Array.from(document.images, image => image.decode().catch(() => {})));
            await document.fonts.ready;
            """, arguments: [:], in: nil, in: .defaultClient
        ) { [weak self] result in
            self?.finish(result.map { _ in () })
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(.failure(error))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(URLError(.cannotLoadFromNetwork)))
    }
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        decisionHandler(
            navigationAction.navigationType != .linkActivated
                && navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    private func finish(_ result: Result<Void, Error>) {
        timeout?.cancel()
        timeout = nil
        let continuation = completion
        completion = nil
        continuation?.resume(with: result)
    }
}

/// Draws already-paginated PDF pages for NSPrintOperation, one paper page per print page.
/// Drawing is synchronous and in-process, so preview thumbnails and Save as PDF never wait
/// on (or miss) WebKit content. Header and footer go in the pages' own top/bottom margins.
final class PrintedPagesView: NSView {
    let document: CGPDFDocument
    let paper: CGSize
    let title: String
    let margins: NSEdgeInsets
    private let date = Date().formatted(date: .abbreviated, time: .shortened)

    init(document: CGPDFDocument, paper: CGSize, title: String, margins: NSEdgeInsets) {
        self.document = document
        self.paper = paper
        self.title = title
        self.margins = margins
        super.init(
            frame: NSRect(x: 0, y: 0, width: paper.width, height: paper.height * CGFloat(document.numberOfPages)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var pageHeader: NSAttributedString { NSAttributedString() }
    override var pageFooter: NSAttributedString { NSAttributedString() }

    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: document.numberOfPages)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(page - 1) * paper.height, width: paper.width, height: paper.height)
    }

    /// Each page is the whole sheet: place it at the paper origin, not the printer's
    /// imageable-area origin, so printed pages match the exported PDF exactly.
    override func locationOfPrintRect(_ rect: NSRect) -> NSPoint { .zero }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, paper.height > 0 else { return }
        let first = max(1, Int((dirtyRect.minY / paper.height).rounded(.down)) + 1)
        let last = min(document.numberOfPages, Int((dirtyRect.maxY / paper.height).rounded(.up)))
        guard first <= last else { return }
        for number in first...last {
            guard let page = document.page(at: number) else { continue }
            context.saveGState()
            // Flipped view: move to the bottom of this page and restore PDF's y-up space.
            context.translateBy(x: 0, y: CGFloat(number) * paper.height)
            context.scaleBy(x: 1, y: -1)
            context.drawPDFPage(page)
            context.restoreGState()
        }
    }

    override func drawPageBorder(with borderSize: NSSize) {
        guard let operation = NSPrintOperation.current,
            operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] as? Bool == true
        else { return }
        let font = NSFont.systemFont(ofSize: 8)
        let lineHeight = ceil(font.ascender - font.descender)
        // `top` is measured down from the paper's top edge; the border pass may be unflipped.
        let flipped = NSGraphicsContext.current?.isFlipped ?? true
        func text(_ string: String, _ alignment: NSTextAlignment, y top: CGFloat) {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineBreakMode = .byTruncatingMiddle
            let y = flipped ? top : borderSize.height - top - lineHeight
            (string as NSString).draw(
                in: NSRect(
                    x: margins.left, y: y, width: borderSize.width - margins.left - margins.right, height: lineHeight),
                withAttributes: [.font: font, .foregroundColor: NSColor(white: 0.35, alpha: 1), .paragraphStyle: style])
        }
        let header = max(0, (margins.top - lineHeight) / 2)
        let footer = borderSize.height - margins.bottom + max(0, (margins.bottom - lineHeight) / 2)
        text(title, .left, y: header)
        text(date, .right, y: header)
        text("\(operation.currentPage) of \(document.numberOfPages)", .center, y: footer)
    }
}

/// Owns one completion and deadline, including when AppKit calls back after timeout.
/// The retained context belongs to AppKit until didRun; a late callback is harmless.
@MainActor
final class PrintJob: NSObject {
    private var completion: CheckedContinuation<Bool, Error>?
    private var timer: Timer?

    static func run(
        _ operation: NSPrintOperation, window: NSWindow,
        timeoutInterval: TimeInterval, cancel: @escaping () -> Void
    ) async throws -> Bool {
        let job = PrintJob()
        return try await job.wait(timeoutInterval: timeoutInterval, cancel: cancel) {
            operation.runModal(
                for: window, delegate: job,
                didRun: #selector(didRun(_:success:contextInfo:)),
                contextInfo: Unmanaged.passRetained(job).toOpaque())
        }
    }

    // Injectable start permits deterministic deadline and late-callback tests without
    // invoking a printer service or WebKit in the sandbox.
    func wait(
        timeoutInterval: TimeInterval, cancel: @escaping () -> Void,
        start: () -> Void
    ) async throws -> Bool {
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
        case .timedOut: return "The document took too long to render. Try again, or export a shorter document."
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

    /// Cancelling the awaiting task (the progress sheet's Cancel) stops rendering
    /// and completes immediately with CancellationError.
    func wait(
        timeoutInterval: TimeInterval, cancel: @escaping () -> Void,
        render: @escaping () async throws -> Data
    ) async throws -> Data {
        let limit = ContinuousClock.now + .seconds(timeoutInterval)
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                guard !Task.isCancelled else { return stop(CancellationError(), cancel: cancel) }
                deadline = Task { [self] in
                    do { try await Task.sleep(until: limit, clock: .continuous) } catch { return }
                    stop(PDFExportError.timedOut, cancel: cancel)
                }
                work = Task { [self] in
                    let result: Result<Data, Error>
                    do { result = .success(try await render()) } catch { result = .failure(error) }
                    // On a busy main thread the render can return after the deadline but before
                    // the deadline task runs. The deadline is final: a late result is discarded.
                    if ContinuousClock.now >= limit {
                        stop(PDFExportError.timedOut, cancel: cancel)
                    } else {
                        finish(result)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [self] in stop(CancellationError(), cancel: cancel) }
        }
        // Cancel's stop is queued behind a render that returned in the same turn; the user
        // still asked to stop, so the result is discarded and nothing is written.
        if Task.isCancelled {
            cancel()
            throw CancellationError()
        }
        return data
    }

    private func stop(_ error: Error, cancel: () -> Void) {
        guard completion != nil else { return }
        work?.cancel()
        finish(.failure(error))
        cancel()
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

import AppKit
import SwiftUI
import WebKit
import SilkwebCore

enum DocumentViewMode: String, CaseIterable {
    case editor, split, preview
    var title: String { switch self { case .editor: "Editor"; case .split: "Split Editor and Preview"; case .preview: "Preview" } }
    var symbol: String { switch self { case .editor: "doc.plaintext"; case .split: "rectangle.split.2x1"; case .preview: "eye" } }
}

/// Window-owned presentation state. Rendering has no access to the mutable editor buffer.
@MainActor @Observable
final class PreviewCoordinator {
    var mode: DocumentViewMode { didSet { defaults.set(mode.rawValue, forKey: "Silkweb.Detail.Mode"); if mode != .preview { lastWritingMode = mode; defaults.set(mode.rawValue, forKey: "Silkweb.Detail.LastWritingMode") } } }
    var lastWritingMode: DocumentViewMode = .editor
    var showsOutline: Bool { didSet { defaults.set(showsOutline, forKey: "Silkweb.Detail.Outline") } }
    var headings: [MarkdownHeading] = []
    var outlineItems: [OutlineItem] = []
    var visibleHeading: String?
    var html = ""
    var renderedURL: URL?
    var error: String?
    var isLoading = false
    var retry = 0
    @ObservationIgnored private var loadingTask: Task<Void, Never>?
    @ObservationIgnored private var loadingDocument: URL?
    @ObservationIgnored private var finishedDocument: URL?
    @ObservationIgnored private var input: RenderInput?
    #if DEBUG
    @ObservationIgnored private(set) var renderCount = 0
    #endif

    private struct RenderInput: Equatable {
        let text: String
        let document: URL?
        let root: URL?
        let html: Bool
        let outline: Bool
        var keepsLineBreaks = false
        var showsTableOfContents = true
    }
    @ObservationIgnored weak var editor: PlainMarkdownTextView?
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var scrollAnchor: String?
    @ObservationIgnored var scrollRatio = 0.0
    @ObservationIgnored var pendingAnchor: String?

    nonisolated static let stylesheet: String = {
        // SwiftPM's generated accessor searches beside the executable. A bundled Mac app
        // keeps its resources under Contents/Resources, so check that location first.
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Silkweb_Silkweb.bundle")
        let resources = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = resources.url(forResource: "preview", withExtension: "css") else { return "" }
        return HeadingPalette.previewCSS + "\n" + ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }()

    @ObservationIgnored private var settingsObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = DocumentViewMode(rawValue: defaults.string(forKey: "Silkweb.Detail.Mode") ?? "") ?? .editor
        showsOutline = defaults.bool(forKey: "Silkweb.Detail.Outline")
        let previous = DocumentViewMode(rawValue: defaults.string(forKey: "Silkweb.Detail.LastWritingMode") ?? "") ?? .editor
        lastWritingMode = mode == .preview ? (previous == .preview ? .editor : previous) : mode
        settingsObserver = NotificationCenter.default.addObserver(forName: .writingSettingsDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsDidChange() }
        }
    }

    deinit { if let settingsObserver { NotificationCenter.default.removeObserver(settingsObserver) } }

    /// The live preview's Settings block (1.24): fonts and user colours as CSS variables.
    static func settingsStyle(_ preferences: WritingPreferences) -> String {
        "<style id=\"sw-settings\">" + preferences.previewCSS + "</style>"
    }

    /// Fonts and colours restyle the loaded page in place (no re-parse, scroll kept); line-break and
    /// TOC options re-render the document.
    func settingsDidChange() {
        let preferences = LivePreferences.shared.current
        webView?.underPageBackgroundColor = .silkwebPaneBackground
        if let input, input.keepsLineBreaks != preferences.keepsLineBreaks || input.showsTableOfContents != preferences.showsTableOfContents {
            schedule(text: input.text, document: input.document, root: input.root)
        }
        let style = Self.settingsStyle(preferences)
        if let start = html.range(of: "<style id=\"sw-settings\">"), let end = html.range(of: "</style>", range: start.upperBound..<html.endIndex) {
            let updated = html.replacingCharacters(in: start.lowerBound..<end.upperBound, with: style)
            if updated != html { html = updated }
        }
        webView?.callAsyncJavaScript("const style = document.getElementById('sw-settings'); if (style) style.textContent = css;",
                                     arguments: ["css": preferences.previewCSS], in: nil, in: .defaultClient) { _ in }
    }

    func togglePreview() { mode = mode == .preview ? lastWritingMode : .preview }
    func toggleSplit() { mode = mode == .split ? .editor : .split }

    func schedule(text: String, document: URL?, root: URL?) {
        let preferences = LivePreferences.shared.current
        let next = RenderInput(text: text, document: document, root: root, html: mode != .editor, outline: showsOutline,
                               keepsLineBreaks: preferences.keepsLineBreaks, showsTableOfContents: preferences.showsTableOfContents)
        let settings = Self.settingsStyle(preferences)
        guard next != input else { return }
        input = next
        revision += 1
        let request = revision
        task?.cancel()
        if document != renderedURL { headings = []; outlineItems = []; html = ""; scrollAnchor = nil; scrollRatio = 0; pendingAnchor = nil }
        guard next.html || next.outline else { endLoading(); return }
        if next.html { beginLoading(document: document) } else { endLoading() }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            #if DEBUG
            self?.renderCount += 1
            #endif
            let result = await Task.detached(priority: .userInitiated) {
                let parsed = MarkdownParser.parse(text)
                let items = OutlineItem.parse(text, headings: parsed.headings)
                guard next.html else { return (parsed.headings, "", items) }
                var options = HTMLRenderer.Options(lineBreaks: next.keepsLineBreaks ? .preserve : .standard, libraryRoot: root, documentURL: document, offlinePreview: true)
                options.showsTableOfContents = next.showsTableOfContents
                let fragment = HTMLRenderer.render(parsed, options: options)
                let css = Self.stylesheet + "\n" + SilkwebTokens.previewCSS
                let page = "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src silkweb-preview:; style-src 'unsafe-inline'; script-src 'none'\"><style>" + css + "</style>" + settings + "</head><body>" + fragment + "</body></html>"
                return (parsed.headings, page, items)
            }.value
            guard !Task.isCancelled, let self, request == self.revision else { return }
            self.headings = result.0
            self.outlineItems = result.2
            self.renderedURL = document
            self.html = result.1
        }
    }

    func beginLoading(document: URL?) {
        guard mode != .editor, document != finishedDocument, document != loadingDocument else { return }
        loadingTask?.cancel()
        loadingDocument = document
        isLoading = false
        loadingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            guard let self, self.mode != .editor, self.loadingDocument == document else { return }
            self.isLoading = true
        }
    }

    func endLoading() {
        loadingTask?.cancel()
        loadingTask = nil
        loadingDocument = nil
        if isLoading { isLoading = false }
    }

    func didFinish(document: URL?) {
        finishedDocument = document
        endLoading()
        error = nil
    }

    func currentHeading(caret: Int) -> String? {
        if mode == .preview { return visibleHeading }
        return headings.last { $0.sourceRange.location != NSNotFound && $0.sourceRange.location <= caret }?.id
    }

    func currentItem(caret: Int) -> String? {
        if mode == .preview { return visibleHeading }
        if let image = outlineItems.first(where: {
            if case .image = $0.content { return NSLocationInRange(caret, $0.sourceRange) }
            return false
        }) { return image.id }
        return currentHeading(caret: caret)
    }

    /// The Outline keeps keyboard focus after a click or Return (`focusEditor: false`).
    func navigate(_ item: OutlineItem, focusEditor: Bool = true) {
        navigate(id: item.id, range: item.sourceRange, focusEditor: focusEditor)
    }

    func navigate(_ heading: MarkdownHeading) {
        navigate(id: heading.id, range: heading.sourceRange)
    }

    private func navigate(id: String, range: NSRange, focusEditor: Bool = true) {
        pendingAnchor = id
        if mode != .editor { scrollPreview(to: id) }
        guard let editor, range.location != NSNotFound else { return }
        let location = min(range.location, editor.string.utf16.count)
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.scrollRangeToVisible(NSRange(location: location, length: 0))
        if let layout = editor.layoutManager, editor.textContainer != nil,
           let scroll = editor.enclosingScrollView, location < editor.string.utf16.count {
            let glyph = layout.glyphIndexForCharacter(at: location)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + editor.textContainerOrigin.y - scroll.contentSize.height / 3)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if focusEditor, mode != .preview { editor.window?.makeFirstResponder(editor) }
    }

    func scrollPreview(to anchor: String) {
        if webView?.isLoading == false { pendingAnchor = nil }
        webView?.callAsyncJavaScript("document.getElementById(anchor)?.scrollIntoView({behavior: reduceMotion ? 'instant' : 'smooth'});", arguments: ["anchor": anchor, "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion], in: nil, in: .defaultClient) { _ in }
    }
}

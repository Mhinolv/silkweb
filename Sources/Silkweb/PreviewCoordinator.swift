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
    var visibleHeading: String?
    var html = ""
    var renderedURL: URL?
    var error: String?
    @ObservationIgnored weak var editor: PlainMarkdownTextView?
    @ObservationIgnored weak var webView: WKWebView?
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var scrollAnchor: String?
    @ObservationIgnored var scrollRatio = 0.0
    @ObservationIgnored var pendingAnchor: String?

    nonisolated private static let stylesheet: String = {
        // SwiftPM's generated accessor searches beside the executable. A bundled Mac app
        // keeps its resources under Contents/Resources, so check that location first.
        let packaged = Bundle.main.resourceURL?.appendingPathComponent("Silkweb_Silkweb.bundle")
        let resources = packaged.flatMap { Bundle(url: $0) } ?? Bundle.module
        guard let url = resources.url(forResource: "preview", withExtension: "css") else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        mode = DocumentViewMode(rawValue: defaults.string(forKey: "Silkweb.Detail.Mode") ?? "") ?? .editor
        showsOutline = defaults.bool(forKey: "Silkweb.Detail.Outline")
        let previous = DocumentViewMode(rawValue: defaults.string(forKey: "Silkweb.Detail.LastWritingMode") ?? "") ?? .editor
        lastWritingMode = mode == .preview ? (previous == .preview ? .editor : previous) : mode
    }

    func togglePreview() { mode = mode == .preview ? lastWritingMode : .preview }
    func toggleSplit() { mode = mode == .split ? .editor : .split }

    func schedule(text: String, document: URL?, root: URL?) {
        revision += 1
        let request = revision
        task?.cancel()
        if document != renderedURL { headings = []; html = ""; scrollAnchor = nil; scrollRatio = 0; pendingAnchor = nil }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let result = await Task.detached(priority: .userInitiated) {
                let parsed = MarkdownParser.parse(text)
                let fragment = HTMLRenderer.render(parsed, options: .init(libraryRoot: root, documentURL: document, offlinePreview: true))
                let css = Self.stylesheet
                let page = "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src file:; style-src 'unsafe-inline'; script-src 'none'\"><style>" + css + "</style></head><body>" + fragment + "</body></html>"
                return (parsed.headings, page)
            }.value
            guard !Task.isCancelled, let self, request == self.revision else { return }
            self.headings = result.0
            self.renderedURL = document
            self.html = result.1
        }
    }

    func currentHeading(caret: Int) -> String? {
        if mode == .preview { return visibleHeading }
        return headings.last { $0.sourceRange.location != NSNotFound && $0.sourceRange.location <= caret }?.id
    }

    func navigate(_ heading: MarkdownHeading) {
        pendingAnchor = heading.id
        if mode != .editor { scrollPreview(to: heading.id) }
        guard let editor, heading.sourceRange.location != NSNotFound else { return }
        let location = min(heading.sourceRange.location, editor.string.utf16.count)
        editor.setSelectedRange(NSRange(location: location, length: 0))
        editor.scrollRangeToVisible(NSRange(location: location, length: 0))
        if let layout = editor.layoutManager, editor.textContainer != nil,
           let scroll = editor.enclosingScrollView, location < editor.string.utf16.count {
            let glyph = layout.glyphIndexForCharacter(at: location)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + editor.textContainerOrigin.y - scroll.contentSize.height / 3)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if mode != .preview { editor.window?.makeFirstResponder(editor) }
    }

    func scrollPreview(to anchor: String) {
        if webView?.isLoading == false { pendingAnchor = nil }
        webView?.callAsyncJavaScript("document.getElementById(anchor)?.scrollIntoView();", arguments: ["anchor": anchor], in: nil, in: .defaultClient) { _ in }
    }
}

import AppKit
import SilkwebCore
import SwiftUI
import WebKit

enum DocumentViewMode: String, CaseIterable {
    case editor, split, preview
    var title: String {
        switch self {
        case .editor: "Editor";
        case .split: "Split Editor and Preview";
        case .preview: "Preview"
        }
    }
    var symbol: String {
        switch self {
        case .editor: "doc.plaintext";
        case .split: "rectangle.split.2x1";
        case .preview: "eye"
        }
    }
}

/// Window-owned presentation state. Rendering has no access to the mutable editor buffer.
@MainActor @Observable
final class PreviewCoordinator {
    var mode: DocumentViewMode {
        didSet {
            defaults.set(mode.rawValue, forKey: "Silkweb.Detail.Mode");
            if mode != .preview {
                lastWritingMode = mode; defaults.set(mode.rawValue, forKey: "Silkweb.Detail.LastWritingMode")
            }
        }
    }
    var lastWritingMode: DocumentViewMode = .editor
    var showsOutline: Bool { didSet { defaults.set(showsOutline, forKey: "Silkweb.Detail.Outline") } }
    /// View ▸ Show Status Bar (silkweb-1.25); on unless turned off.
    var showsStatusBar: Bool { didSet { defaults.set(showsStatusBar, forKey: "Silkweb.Detail.StatusBar") } }
    var headings: [MarkdownHeading] = []
    var outlineItems: [OutlineItem] = []
    /// The note `headings` and `outlineItems` describe (#87). Leads `renderedURL` on a note switch: the Outline
    /// follows the list click before the editor buffer, and the debounced HTML, catch up.
    var outlineURL: URL?
    /// A switch to a note too large to parse within a frame: the previous rows stay up, dimmed and inert.
    var outlinePending = false
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
    @ObservationIgnored private var outlineText: String?
    /// The note a list click asked the Outline to show; editor renders of other notes leave the Outline alone.
    @ObservationIgnored private var outlineTarget: URL?
    @ObservationIgnored private var outlineTask: Task<Void, Never>?
    @ObservationIgnored private var outlineRevision = 0
    /// Notes up to this many UTF-8 bytes parse on the main thread, inside the click's frame.
    static let immediateOutlineLimit = 128 * 1024
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

    init(defaults: UserDefaults = AppDefaults.store) {
        self.defaults = defaults
        mode = DocumentViewMode(rawValue: defaults.string(forKey: "Silkweb.Detail.Mode") ?? "") ?? .editor
        showsOutline = defaults.bool(forKey: "Silkweb.Detail.Outline")
        showsStatusBar = defaults.object(forKey: "Silkweb.Detail.StatusBar") as? Bool ?? true
        let previous =
            DocumentViewMode(rawValue: defaults.string(forKey: "Silkweb.Detail.LastWritingMode") ?? "") ?? .editor
        lastWritingMode = mode == .preview ? (previous == .preview ? .editor : previous) : mode
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .writingSettingsDidChange, object: nil, queue: .main
        ) { [weak self] _ in
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
        if let input,
            input.keepsLineBreaks != preferences.keepsLineBreaks
                || input.showsTableOfContents != preferences.showsTableOfContents
        {
            schedule(text: input.text, document: input.document, root: input.root)
        }
        let style = Self.settingsStyle(preferences)
        if let start = html.range(of: "<style id=\"sw-settings\">"),
            let end = html.range(of: "</style>", range: start.upperBound..<html.endIndex)
        {
            let updated = html.replacingCharacters(in: start.lowerBound..<end.upperBound, with: style)
            if updated != html { html = updated }
        }
        webView?.callAsyncJavaScript(
            "const style = document.getElementById('sw-settings'); if (style) style.textContent = css;",
            arguments: ["css": preferences.previewCSS], in: nil, in: .defaultClient
        ) { _ in }
    }

    func togglePreview() { mode = mode == .preview ? lastWritingMode : .preview }
    func toggleSplit() { mode = mode == .split ? .editor : .split }

    func schedule(text: String, document: URL?, root: URL?) {
        let preferences = LivePreferences.shared.current
        let next = RenderInput(
            text: text, document: document, root: root, html: mode != .editor, outline: showsOutline,
            keepsLineBreaks: preferences.keepsLineBreaks, showsTableOfContents: preferences.showsTableOfContents)
        let settings = Self.settingsStyle(preferences)
        guard next != input else { return }
        // A note switch or turning on the Outline skips the typing debounce for the outline (#87).
        let immediateOutline = next.outline && (input?.outline != true || document != input?.document)
        // Only typing in the shown note waits for the debounce; a note switch, mode or setting renders at once (#150).
        let typing = input.map { $0.document == document && $0.html == next.html && $0.text != text } ?? false
        input = next
        revision += 1
        let request = revision
        task?.cancel()
        if document != renderedURL {
            // The previous page stays up until the new one replaces it: no blank pane between notes (#150).
            scrollAnchor = nil; scrollRatio = 0; pendingAnchor = nil
        }
        if outlineTarget == document { outlineTarget = nil }
        if !next.outline, document != outlineURL {
            // Hidden: nothing to keep up, and nothing stale to show when the Outline comes back.
            clearOutline()
        } else if immediateOutline, outlineTarget == nil {
            updateOutline(text: text, document: document)
        }
        guard next.html || next.outline else { endLoading(); return }
        if next.html { beginLoading(document: document) } else { endLoading() }
        task = Task { [weak self] in
            if typing { do { try await Task.sleep(for: .milliseconds(250)) } catch { return } }
            #if DEBUG
                self?.renderCount += 1
            #endif
            let result = await Task.detached(priority: .userInitiated) {
                let parsed = MarkdownParser.parse(text)
                let items = OutlineItem.parse(text, headings: parsed.headings)
                guard next.html else { return (parsed.headings, "", items) }
                var options = HTMLRenderer.Options(
                    lineBreaks: next.keepsLineBreaks ? .preserve : .standard, libraryRoot: root, documentURL: document,
                    offlinePreview: true)
                options.showsTableOfContents = next.showsTableOfContents
                let fragment = HTMLRenderer.render(parsed, options: options)
                let css = Self.stylesheet + "\n" + SilkwebTokens.previewCSS
                let page =
                    "<!doctype html><html><head><meta charset=\"utf-8\"><meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src silkweb-preview:; style-src 'unsafe-inline'; script-src 'none'\"><style>"
                    + css + "</style>" + settings + "</head><body>" + fragment + "</body></html>"
                return (parsed.headings, page, items)
            }.value
            guard !Task.isCancelled, let self, request == self.revision else { return }
            // A list click may already have moved the Outline on to a newer note.
            if self.outlineTarget == nil, self.outlineURL != document || self.outlineText != text {
                self.publishOutline(result.0, result.2, text: text, document: document)
            }
            self.renderedURL = document
            self.html = result.1
        }
    }

    /// A list click (#87): the Outline shows the clicked note in the list selection's own frame, before the editor
    /// buffer loads. `text` is an open tab's buffer; otherwise the file is read here, inline when small enough to
    /// parse within the frame. (Deferring the publish past the click's frame queues it behind the editor swap.)
    func followDocument(_ document: URL, text: String? = nil) {
        guard showsOutline else { return }
        outlineTarget = document
        if let text {
            updateOutline(text: text, document: document)
            return
        }
        guard document != outlineURL else {
            cancelPendingOutline()
            return
        }
        let size = (try? document.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        if size <= Self.immediateOutlineLimit, let text = try? String(contentsOf: document, encoding: .utf8) {
            updateOutline(text: text, document: document)
        } else {
            parseOutlineInBackground(document: document) { try String(contentsOf: document, encoding: .utf8) }
        }
    }

    /// The editor kept its note (a refused switch): the Outline goes back to it.
    func stopFollowing(text: String, document: URL?) {
        guard outlineTarget != nil else { return }
        outlineTarget = nil
        guard showsOutline else { return }
        updateOutline(text: text, document: document)
    }

    private func updateOutline(text: String, document: URL?) {
        guard document != outlineURL || text != outlineText else {
            cancelPendingOutline()
            return
        }
        guard text.utf8.count <= Self.immediateOutlineLimit else {
            parseOutlineInBackground(document: document) { text }
            return
        }
        let parsed = MarkdownParser.parse(text)
        publishOutline(
            parsed.headings, OutlineItem.parse(text, headings: parsed.headings), text: text, document: document)
    }

    private func cancelPendingOutline() {
        outlineTask?.cancel()
        outlineRevision += 1
        if outlinePending { outlinePending = false }
    }

    /// Large notes parse off the main thread; the previous outline stays up, pending, until they land.
    private func parseOutlineInBackground(document: URL?, text: @escaping @Sendable () throws -> String) {
        outlineTask?.cancel()
        outlineRevision += 1
        let request = outlineRevision
        if document != outlineURL { outlinePending = true }
        outlineTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                () -> (String, [MarkdownHeading], [OutlineItem])? in
                guard let text = try? text() else { return nil }
                let parsed = MarkdownParser.parse(text)
                return (text, parsed.headings, OutlineItem.parse(text, headings: parsed.headings))
            }.value
            guard !Task.isCancelled, let self, request == self.outlineRevision else { return }
            if let result {
                self.publishOutline(result.1, result.2, text: result.0, document: document)
            } else if self.outlinePending {
                self.outlinePending = false
            }
        }
    }

    /// Rows, count caption and threads swap in one update, never cleared first (#87).
    private func publishOutline(_ headings: [MarkdownHeading], _ items: [OutlineItem], text: String, document: URL?) {
        outlineTask?.cancel()
        outlineRevision += 1
        self.headings = headings
        outlineItems = items
        outlineText = text
        if outlineURL != document { outlineURL = document }
        if outlinePending { outlinePending = false }
    }

    private func clearOutline() {
        cancelPendingOutline()
        outlineTarget = nil
        outlineText = nil
        if !headings.isEmpty { headings = [] }
        if !outlineItems.isEmpty { outlineItems = [] }
        if outlineURL != nil { outlineURL = nil }
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
        }) {
            return image.id
        }
        return currentHeading(caret: caret)
    }

    /// An Outline click focuses the editor at the jumped-to line ("jump and write", #89); Return
    /// keeps the Outline focused for ↑/↓ (`focusEditor: false`). Preview mode never focuses the editor.
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
        // One scroll: upper third, or Typewriter's 40% anchor while it is on (1.27).
        editor.writingModes.reveal(location)
        if focusEditor, mode != .preview { editor.window?.makeFirstResponder(editor) }
    }

    /// Esc in the Inspector (#89): keyboard focus back to the editor, or to the preview while it shows alone.
    func focusDocument() -> Bool {
        guard let target: NSView = mode == .preview ? webView : editor, let window = target.window else {
            return false
        }
        return window.makeFirstResponder(target)
    }

    func scrollPreview(to anchor: String) {
        if webView?.isLoading == false { pendingAnchor = nil }
        webView?.callAsyncJavaScript(
            "document.getElementById(anchor)?.scrollIntoView({behavior: reduceMotion ? 'instant' : 'smooth'});",
            arguments: ["anchor": anchor, "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion],
            in: nil, in: .defaultClient
        ) { _ in }
    }
}

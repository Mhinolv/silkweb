import AppKit
import Quartz
import SwiftUI
import SilkwebCore

struct EditorStyle: Equatable {
    var fontFamily: String
    var fontSize: CGFloat
    var lineHeight: CGFloat
    var maximumWidth: CGFloat
    var horizontalInset: CGFloat = Spacing.editorHorizontalInset
    var topInset: CGFloat = 16
    var indent = WritingPreferences.Indent.fourSpaces

    init(fontSize: CGFloat? = nil, lineHeight: CGFloat? = nil, maximumWidth: CGFloat? = nil,
         horizontalInset: CGFloat? = nil, topInset: CGFloat = 16,
         preferences: WritingPreferences = LivePreferences.shared.current) {
        fontFamily = preferences.fontFamily
        self.fontSize = fontSize ?? CGFloat(preferences.fontSize)
        self.lineHeight = lineHeight ?? CGFloat(preferences.lineHeight)
        self.maximumWidth = maximumWidth ?? CGFloat(preferences.maximumWidth)
        self.horizontalInset = horizontalInset ?? CGFloat(preferences.horizontalInset)
        self.topInset = topInset
        indent = preferences.indent
    }

    var bodyFont: NSFont { Self.font(family: fontFamily, size: fontSize) }

    /// Settings font choices (1.24). A missing custom family falls back to Menlo without an alert.
    static func font(family: String, size: CGFloat) -> NSFont {
        switch family {
        case "Menlo": return NSFont(name: "Menlo-Regular", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        case "Monospaced": return .monospacedSystemFont(ofSize: size, weight: .regular)
        case "System": return .systemFont(ofSize: size)
        case "Serif":
            let system = NSFont.systemFont(ofSize: size)
            return system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        default:
            return NSFont(name: family, size: size)
                ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size)
                ?? font(family: "Menlo", size: size)
        }
    }

    var paragraphStyle: NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = lineHeight
        paragraph.paragraphSpacing = 0
        paragraph.tabStops = []
        let spaces: CGFloat = indent == .twoSpaces ? 2 : 4
        paragraph.defaultTabInterval = spaces * (" " as NSString).size(withAttributes: [.font: bodyFont]).width
        return paragraph
    }
}

struct MarkdownTextView: NSViewRepresentable {
    let session: DocumentSession
    let workspace: LibraryWorkspace
    var style = EditorStyle()

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeEditorScrollView(style: style)
        let text = scroll.documentView as! PlainMarkdownTextView
        text.delegate = context.coordinator
        text.moveFocus = { workspace.focus($0 ? 1 : 0) }
        context.coordinator.textView = text
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak session] notification in
            MainActor.assumeIsolated {
                session?.scroll = (notification.object as? NSClipView)?.bounds.origin ?? .zero
            }
        }
        return scroll
    }

    /// Shared construction keeps offscreen regression tests on the production editor hierarchy.
    /// `followsSettings` editors restyle live when Settings change; fixed-style editors (conflict sheet) never do.
    static func makeEditorScrollView(style: EditorStyle, followsSettings: Bool = true) -> NSScrollView {
        let scroll = EditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .silkwebPaneBackground
        scroll.automaticallyAdjustsContentInsets = false
        scroll.findBarPosition = .aboveContent
        let text = PlainMarkdownTextView()
        text.style = style
        text.isRichText = false
        text.importsGraphics = false
        text.registerForDraggedTypes([.fileURL])
        text.allowsUndo = true
        text.usesFindBar = true
        text.isIncrementalSearchingEnabled = true
        text.isContinuousSpellCheckingEnabled = true
        text.isGrammarCheckingEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.font = style.bodyFont
        let paragraph = style.paragraphStyle
        text.defaultParagraphStyle = paragraph
        text.typingAttributes = [.font: text.font!, .paragraphStyle: paragraph, .foregroundColor: NSColor.silkwebText]
        text.textColor = .silkwebText
        text.backgroundColor = .silkwebPaneBackground
        text.insertionPointColor = .textColor
        text.isVerticallyResizable = true
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.lineFragmentPadding = 0
        scroll.documentView = text
        text.inlineImages.editor = text
        text.layoutManager?.delegate = text.inlineImages
        text.styler.editor = text
        text.writingModes.editor = text
        text.textStorage?.delegate = text.styler
        scroll.contentView.postsFrameChangedNotifications = true
        text.viewportObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak text] _ in
            MainActor.assumeIsolated { text?.layoutEditor() }
        }
        if followsSettings {
            text.applyBehaviour(LivePreferences.shared.current)
            EditorRegistry.editors.add(text)
        }
        text.layoutEditor()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? PlainMarkdownTextView else { return }
        let coordinator = context.coordinator
        text.configureAssetInsertion(session: session, workspace: workspace)
        if text.zoom != workspace.editorZoom {
            text.zoom = workspace.editorZoom
            text.applySettings()
        }
        text.writingModes.set(focus: workspace.focusMode, typewriter: workspace.typewriterMode)
        let active = workspace.editor === session
        workspace.tabs.first { $0.editor === session }?.textView = text
        if active { workspace.preview.editor = text }
        if coordinator.url != session.url {
            let selection = session.selection
            let position = session.scroll
            let replacingBuffer = coordinator.url == nil || text.string != session.text
            coordinator.url = session.url
            if replacingBuffer { text.string = session.text }
            text.styler.reload()
            text.inlineImages.schedule()
            if replacingBuffer { text.undoManager?.removeAllActions() }
            let count = (text.string as NSString).length
            text.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location))))
            text.layoutEditor()
            scroll.contentView.scroll(to: position)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if text.string != session.text, !text.hasMarkedText() {
            Self.reload(text, in: scroll, value: session.text, selection: session.selection, position: session.scroll)
        }
        let editable = active && !session.readOnly && !session.loading && !text.assetHandler.busy
        if text.isEditable != editable { text.isEditable = editable; text.needsDisplay = true }
        if active, FormattingTarget.shared.editor === text { FormattingTarget.shared.refresh() }
        text.setAccessibilityLabel("Document text, \(session.name)")
        text.setAccessibilityPlaceholderValue(text.placeholderEnabled ? "Start writing…" : nil)
        if active { text.window?.isDocumentEdited = workspace.allEditors.contains { $0.state.isDirty } }
        if coordinator.focusRequest != workspace.focusRequest {
            coordinator.focusRequest = workspace.focusRequest
            if active, workspace.focusColumn == 2 { text.window?.makeFirstResponder(text) }
        }
    }

    /// Reload a clean external edit in place, clamping UTF-16 selection and scroll.
    static func reload(_ text: PlainMarkdownTextView, in scroll: NSScrollView, value: String, selection: NSRange, position: NSPoint) {
        text.string = value
        text.styler.reload()
        text.inlineImages.schedule()
        text.undoManager?.removeAllActions()
        let count = (value as NSString).length
        let location = min(selection.location, count)
        text.setSelectedRange(NSRange(location: location, length: min(selection.length, count - location)))
        text.layoutManager?.ensureLayout(for: text.textContainer!)
        text.layoutEditor()
        scroll.contentView.scroll(to: position)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let session: DocumentSession
        weak var textView: NSTextView?
        var scrollObserver: NSObjectProtocol?
        deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
        var url: URL?
        var focusRequest = 0
        init(session: DocumentSession) { self.session = session }
        func undoManager(for view: NSTextView) -> UndoManager? {
            (view as? PlainMarkdownTextView)?.documentUndoManager
        }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            !session.loading && !session.readOnly
        }
        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            session.edit(textView.string)
            textView.needsDisplay = true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            session.selection = textView.selectedRange()
            session.loadedStatistics?.selectionDidChange(session.selection)
            (textView as? PlainMarkdownTextView)?.inlineImages.refreshSelection()
            session.caretLocation = session.selection.location
            session.scroll = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        }
    }
}

/// The stock text view supplies Unicode, IME, undo and accessibility navigation.
final class PlainMarkdownTextView: NSTextView {
    let documentUndoManager = UndoManager()
    var style = EditorStyle()
    weak var session: DocumentSession?
    /// The window's workspace, for its temporary zoom.
    weak var workspace: LibraryWorkspace?
    let styler = MarkdownStyler()
    let inlineImages = InlineImageLayout()
    let writingModes = WritingModeController()
    lazy var assetHandler: EditorPasteHandler = {
        let handler = EditorPasteHandler()
        handler.editor = self
        return handler
    }()
    var moveFocus: ((Bool) -> Void)?
    func configureAssetInsertion(session: DocumentSession, workspace: LibraryWorkspace) {
        self.session = session
        self.workspace = workspace
        assetHandler.workspace = workspace
        inlineImages.configure(root: workspace.root, document: session.url)
    }
    weak var quickLookImage: InlineImageView?
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { quickLookImage != nil }
    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = quickLookImage
        panel.delegate = quickLookImage
    }
    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        quickLookImage = nil
        window?.makeFirstResponder(self)
    }
    var viewportObserver: NSObjectProtocol?
    deinit {
        if let viewportObserver { NotificationCenter.default.removeObserver(viewportObserver) }
        contentSizingTask?.cancel()
    }
    private var isLayingOutEditor = false
    private var contentSizingTask: Task<Void, Never>?
    private var needsEndMarginAfterEdit = false

    /// TextKit's viewport layout alone leaves the document frame sized to a partial
    /// layout. Coalesce loads, restyling and width changes before fitting the full text.
    /// This never runs in a scroll/gesture callback or on every keystroke.
    func scheduleContentSizing() {
        contentSizingTask?.cancel()
        contentSizingTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, !self.hasMarkedText(), let container = self.textContainer else { return }
            self.layoutManager?.ensureLayout(for: container)
            self.sizeToFit()
            self.inlineImages.positionViews()
            if let bottom = self.inlineImages.imageViews.map({ $0.frame.maxY + 10 + self.textContainerInset.height }).max(), bottom > self.frame.height {
                self.setFrameSize(NSSize(width: self.frame.width, height: bottom))
            }
            if self.needsEndMarginAfterEdit {
                self.needsEndMarginAfterEdit = false
                // Typewriter's own bottom inset already reaches the anchor; never jump past it.
                if self.writingModes.typewriter { self.writingModes.anchorCaret() }
                else if self.selectedRange() == NSRange(location: self.textStorage?.length ?? 0, length: 0) {
                    self.scrollToEndOfDocument(nil)
                }
            }
            if let scroll = self.enclosingScrollView { scroll.reflectScrolledClipView(scroll.contentView) }
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutEditor()
    }

    func layoutEditor() {
        // NSTextView geometry setters can synchronously resize the view and call us again.
        guard !isLayingOutEditor, let scroll = enclosingScrollView else { return }
        isLayingOutEditor = true
        defer { isLayingOutEditor = false }

        // Use the scroll view's viewport, never the text view's content-driven frame.
        let viewport = scroll.contentSize
        let width = max(1, min(style.maximumWidth, viewport.width - 2 * style.horizontalInset))
        let containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let container = textContainer, container.containerSize != containerSize {
            container.containerSize = containerSize
            scheduleContentSizing()
        }
        let inset = NSSize(width: max(style.horizontalInset, (viewport.width - width) / 2), height: style.topInset)
        if textContainerInset != inset {
            textContainerInset = inset
            scheduleContentSizing()
        }
        // No overscroll by default (1.48); Typewriter Mode (1.27) owns top/bottom insets while on.
        var contentInsets = scroll.contentInsets
        let overscroll = writingModes.contentInsets(viewport: viewport.height)
        if let top = overscroll.top { contentInsets.top = top }
        contentInsets.bottom = overscroll.bottom
        if scroll.contentInsets.top != contentInsets.top || scroll.contentInsets.bottom != contentInsets.bottom {
            scroll.contentInsets = contentInsets
        }
        // AppKit applies content insets to the scroller track as well. Cancel all
        // edges so typewriter insets do not shorten or shift the track.
        let scrollerInsets = NSEdgeInsets(top: -contentInsets.top, left: -contentInsets.left,
                                          bottom: -contentInsets.bottom, right: -contentInsets.right)
        let current = scroll.scrollerInsets
        if current.top != scrollerInsets.top || current.left != scrollerInsets.left
            || current.bottom != scrollerInsets.bottom || current.right != scrollerInsets.right {
            scroll.scrollerInsets = scrollerInsets
        }
        let minimum = NSSize(width: 0, height: viewport.height)
        if minSize != minimum { minSize = minimum }
        inlineImages.refit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutEditor()
    }

    override func paste(_ sender: Any?) { assetHandler.paste(from: .general) }
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes + [.fileURL]
    }
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        super.acceptableDragTypes + [.fileURL]
    }
    override func readSelection(from pasteboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let files = assetHandler.files(from: pasteboard)
        if !files.isEmpty { return assetHandler.add(files) }
        return super.readSelection(from: pasteboard, type: type)
    }
    override func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let files = assetHandler.files(from: pasteboard)
        if !files.isEmpty { return assetHandler.add(files) }
        return super.readSelection(from: pasteboard)
    }
    override func pasteAsRichText(_ sender: Any?) { pasteAsPlainText(sender) }
    override func pasteAsPlainText(_ sender: Any?) {
        guard isEditable, let value = NSPasteboard.general.string(forType: .string) else { return }
        insertText(value, replacementRange: selectedRange())
    }
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { FormattingTarget.shared.editor = self; FormattingTarget.shared.refresh() }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted, FormattingTarget.shared.editor === self {
            FormattingTarget.shared.editor = nil
            FormattingTarget.shared.refresh()
        }
        return accepted
    }
    override func didChangeText() {
        super.didChangeText()
        if !hasMarkedText() {
            needsEndMarginAfterEdit = true
            styler.schedule()
            inlineImages.schedule()
        }
        writingModes.textDidChange()
        FormattingTarget.shared.refresh()
    }
    override func unmarkText() {
        super.unmarkText()
        needsEndMarginAfterEdit = true
        styler.schedule()
        inlineImages.schedule()
        FormattingTarget.shared.refresh()
    }
    override func insertNewline(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertNewline(sender); return }
        apply(MarkdownEditing.newline(text: string, selection: selectedRange()), name: "Typing")
    }
    override func insertLineBreak(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertLineBreak(sender); return }
        apply(MarkdownEditing.newline(text: string, selection: selectedRange(), plain: true), name: "Typing")
    }
    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertTab(sender); return }
        let source = string as NSString
        let line = source.substring(with: source.lineRange(for: selectedRange()))
        if selectedRange().length > 0 || MarkdownEditing.listPrefix(line) != nil { format(.indent) }
        else { insertText(style.indent.text, replacementRange: selectedRange()) }
    }
    override func insertBacktab(_ sender: Any?) { format(.outdent) }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, event.modifierFlags.contains(.control) {
            moveFocus?(event.modifierFlags.contains(.shift))
        } else {
            super.keyDown(with: event)
            writingModes.keyboardDidMove()
        }
    }
    #if DEBUG
    private(set) var fullDrawCount = 0
    #endif

    /// Inline images move in the same display pass as the reflowed text: lay out the
    /// visible rect (as drawing would) and place overlays before anything is drawn.
    override func viewWillDraw() {
        if let layout = layoutManager, let container = textContainer, !inlineImages.imageViews.isEmpty {
            var rect = visibleRect
            rect.origin.x -= textContainerOrigin.x; rect.origin.y -= textContainerOrigin.y
            layout.ensureLayout(forBoundingRect: rect, in: container)
            inlineImages.positionViews()
        }
        super.viewWillDraw()
    }

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        if dirtyRect.width > 10 && dirtyRect.height > 30 { fullDrawCount += 1 }
        #endif
        super.draw(dirtyRect)
        writingModes.drawOverlay(in: dirtyRect)
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        if let band = currentLineBand(), band.intersects(rect) {
            NSColor.silkwebSelectionInactive.setFill()
            band.intersection(rect).fill()
        }
        drawPlaceholder()
    }

    // MARK: Settings (silkweb-1.24)

    /// Temporary View ▸ Bigger/Smaller steps for this window; never saved.
    var zoom = 0
    var highlightsCurrentLine = false {
        didSet { if highlightsCurrentLine != oldValue { needsDisplay = true } }
    }

    /// Restyles attributes and layout only: the text storage, selection, scroll position and undo stack stay.
    func applySettings(_ preferences: WritingPreferences = LivePreferences.shared.current) {
        applyBehaviour(preferences)
        var next = EditorStyle(topInset: style.topInset, preferences: preferences)
        next.fontSize = CGFloat(WritingPreferences.clamp(preferences.fontSize + Double(zoom), WritingPreferences.fontSizes,
                                                         fallback: preferences.fontSize))
        guard next != style else { return }
        let restyle = next.fontFamily != style.fontFamily || next.fontSize != style.fontSize
            || next.lineHeight != style.lineHeight || next.indent != style.indent
        let origin = enclosingScrollView?.contentView.bounds.origin
        let selection = selectedRanges
        style = next
        if restyle {
            let paragraph = style.paragraphStyle
            defaultParagraphStyle = paragraph
            typingAttributes = [.font: style.bodyFont, .paragraphStyle: paragraph, .foregroundColor: NSColor.silkwebText]
            styler.reload()
            if selectedRanges != selection { selectedRanges = selection }
        }
        layoutEditor()
        scheduleContentSizing()
        if let origin, let scroll = enclosingScrollView {
            scroll.contentView.scroll(to: origin)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        needsDisplay = true
    }

    /// Settings that need no restyle.
    func applyBehaviour(_ preferences: WritingPreferences) {
        if isContinuousSpellCheckingEnabled != preferences.checksSpelling { isContinuousSpellCheckingEnabled = preferences.checksSpelling }
        if isAutomaticQuoteSubstitutionEnabled != preferences.smartPunctuation { isAutomaticQuoteSubstitutionEnabled = preferences.smartPunctuation }
        if isAutomaticDashSubstitutionEnabled != preferences.smartPunctuation { isAutomaticDashSubstitutionEnabled = preferences.smartPunctuation }
        highlightsCurrentLine = preferences.highlightsCurrentLine
        inlineImages.enabled = preferences.showsInlineImages
    }

    /// The caret line's full-width band when “Highlight the current line” is on; none while text is selected.
    func currentLineBand() -> NSRect? {
        guard highlightsCurrentLine, selectedRange().length == 0, let layout = layoutManager, textContainer != nil else { return nil }
        let length = (string as NSString).length
        let location = selectedRange().location
        let fragment: NSRect
        if location >= length, !layout.extraLineFragmentRect.isEmpty {
            fragment = layout.extraLineFragmentRect
        } else {
            guard length > 0, layout.numberOfGlyphs > 0 else { return nil }
            let glyph = layout.glyphIndexForCharacter(at: min(location, length - 1))
            fragment = layout.lineFragmentRect(forGlyphAt: min(glyph, layout.numberOfGlyphs - 1), effectiveRange: nil)
        }
        guard !fragment.isEmpty else { return nil }
        return NSRect(x: bounds.minX, y: fragment.minY + textContainerOrigin.y, width: bounds.width, height: fragment.height)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let old = highlightsCurrentLine ? currentLineBand() : nil
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        writingModes.selectionDidChange()
        guard highlightsCurrentLine else { return }
        if let old { setNeedsDisplay(old) }
        if let band = currentLineBand() { setNeedsDisplay(band) }
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Shorten before super so AppKit erases exactly the rect it drew.
        let rect = textHeightInsertionRect(for: rect)
        super.drawInsertionPoint(in: rect, color: color, turnedOn: flag)
        // NSTextView clears the caret directly, without calling draw(_:).
        // Restore the placeholder under that narrow strip when the caret turns off.
        if !flag, string.isEmpty, placeholderEnabled {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: rect).addClip()
            drawBackground(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// AppKit spans the whole line fragment, including the 1.6× leading. Keep its x and
    /// width, but cover only the ascender and descender of the font at the caret,
    /// standing on the text baseline. Metrics are read at draw time, never hard-coded.
    func textHeightInsertionRect(for rect: NSRect) -> NSRect {
        guard let layout = layoutManager, let container = textContainer else { return rect }
        let font = typingAttributes[.font] as? NSFont ?? style.bodyFont
        let ascent = font.ascender, descent = abs(font.descender)
        let origin = textContainerOrigin
        let point = NSPoint(x: rect.midX - origin.x, y: rect.midY - origin.y)
        let extra = layout.extraLineFragmentRect
        let baseline: CGFloat
        if !extra.isEmpty, point.y >= extra.minY {
            // TextKit 1 places the extra leading above the glyphs, as on body lines.
            baseline = extra.maxY - descent + origin.y
        } else {
            let count = layout.numberOfGlyphs
            guard count > 0 else { return rect }
            // Prefer the selection's glyph (or the one before it at the end); point lookup
            // lands on the previous line for empty lines, so use it only for other carets.
            let source = string as NSString
            var glyph = min(layout.glyphIndexForCharacter(at: max(0, min(selectedRange().location, source.length - 1))), count - 1)
            var glyphs = NSRange()
            var fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
            if point.y < fragment.minY || point.y >= fragment.maxY {
                glyph = layout.glyphIndex(for: point, in: container)
                fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &glyphs)
            }
            if glyphs.length == 1, source.character(at: layout.characterIndexForGlyph(at: glyph)) == 0x0A {
                // An empty line's newline glyph has no usable location; like the extra
                // fragment, its leading sits above the glyph box.
                baseline = fragment.maxY - descent + origin.y
            } else {
                baseline = fragment.minY + layout.location(forGlyphAt: glyph).y + origin.y
            }
        }
        // Whole points (whole pixels at 1× and 2×), so erasing leaves no anti-aliased
        // caret edges; never grow past the rect AppKit passed.
        let top = max(ceil(rect.minY), (baseline - ascent).rounded())
        let bottom = min(floor(rect.maxY), top + ceil(ascent + descent))
        guard bottom > top else { return rect }
        return NSRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
    }

    // Loading locks input while a new note is prepared. It must not erase the
    // current empty editor's placeholder before the new tab is ready to install.
    var placeholderEnabled: Bool {
        isEditable || (session?.loading == true && session?.readOnly == false)
    }

    private func drawPlaceholder() {
        guard string.isEmpty, placeholderEnabled else { return }
        var attributes = typingAttributes
        attributes[.foregroundColor] = NSColor.tertiaryLabelColor
        let value = NSAttributedString(string: "Start writing…", attributes: attributes)
        value.draw(with: NSRect(origin: textContainerOrigin,
                                size: NSSize(width: textContainer?.containerSize.width ?? 720, height: 100)),
                   options: [.usesLineFragmentOrigin])
    }

}

struct EditorBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity = 1.0
    let session: DocumentSession
    var workspace: LibraryWorkspace? = nil
    private var informational: Bool {
        !session.externalConflict && !session.externalDeleted
            && (session.readOnly || session.recovered || (!session.state.isDirty && session.conflictCopy != nil))
    }
    var body: some View {
        if let message = session.banner {
            HStack(spacing: 8) {
                Image(systemName: informational ? "info.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(informational ? Color.secondary : Color(nsColor: .systemOrange))
                VStack(alignment: .leading, spacing: 4) {
                    Text(message).font(.callout)
                    if session.externalConflict || session.externalDeleted, let error = session.error { Text(error).font(.subheadline).foregroundStyle(.secondary) }
                    if case .failed(let failure, _) = session.state { Text(failure.localizedDescription).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                if session.externalConflict {
                    Button("Compare…") { session.compare() }
                    Button("Keep My Version") { Task { await session.resolveConflict(keepMine: true); await workspace?.reconcileFinderChanges() } }
                    Button("Use Disk Version") { Task { await session.resolveConflict(keepMine: false); await workspace?.reconcileFinderChanges() } }
                } else if session.externalDeleted {
                    Button("Save Again") { Task {
                        await session.saveAgain()
                        await workspace?.reconcileFinderChanges()
                        if !session.externalDeleted, let url = session.url { workspace?.showDocument(url) }
                    } }
                    Button("Close") { Task { await session.closeDeleted(); workspace?.removeClosedTabs() } }
                } else if session.recovered {
                    Button("Keep Recovered Text") { session.keepRecovery() }
                    Button("Discard Recovered Text") { session.discardRecovery() }
                } else if session.state.isDirty {
                    Button("Try Again") { Task { await session.flush() } }
                    Button("Save a Copy…") { session.saveCopy() }
                } else if let copy = session.conflictCopy {
                    Button("Show") {
                        guard let workspace else { return }
                        Task {
                            await workspace.reconcileFinderChanges()
                            workspace.showDocument(copy)
                        }
                    }
                    Button { session.conflictCopy = nil } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Dismiss message")
                }
            }
            .disabled(session.loading)
            .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 36).paneStrip(hairline: .bottom)
            .opacity(opacity)
            .sheet(isPresented: Binding(get: { session.showingComparison }, set: { session.showingComparison = $0 })) { ConflictSheet(session: session) }
            .task(id: session.refusedNavigation) {
                guard session.refusedNavigation > 0, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.12)) { opacity = 0.5 }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeIn(duration: 0.12)) { opacity = 1 }
            }
        }
    }
}

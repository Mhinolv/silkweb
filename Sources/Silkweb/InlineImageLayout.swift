import AppKit
import Quartz
import SilkwebCore

/// Adds space to the final visual line of an image paragraph, leaving glyphs and
/// caret geometry untouched. No text-storage attributes or attachment characters.
@MainActor final class InlineImageLayout: NSObject, @preconcurrency NSLayoutManagerDelegate {
    weak var editor: PlainMarkdownTextView?
    var root: URL?
    var document: URL?
    private let loader = InlineImageLoader()
    private var task: Task<Void, Never>?
    private var paragraphs: [InlineImageParagraph] = []
    private(set) var imageViews: [InlineImageView] = []
    private var geometry = NSSize.zero
    private var generation = 0
    private var heightsByEnd: [Int: CGFloat] = [:]
    private var viewsByStart: [Int: [InlineImageView]] = [:]
    private var selectedViews: [InlineImageView] = []

    func configure(root: URL?, document: URL?) {
        guard self.root != root || self.document != document else { return }
        self.root = root; self.document = document
        paragraphs = []
        install([])
        schedule()
    }

    /// Called from text storage before TextKit lays out the edited characters. Shift
    /// paragraph offsets (and the line heights keyed by them) like glyphs, so images move
    /// with their lines in the same layout pass; the debounced reparse only adds new images.
    func sourceDidChange(editedRange: NSRange, delta: Int) {
        guard !paragraphs.isEmpty else { return }
        let oldEnd = NSMaxRange(editedRange) - delta
        func map(_ index: Int) -> Int {
            if index <= editedRange.location { return index }
            return index >= oldEnd ? index + delta : NSMaxRange(editedRange)
        }
        var shifted: [InlineImageParagraph] = []
        var removed = false
        for paragraph in paragraphs {
            if NSMaxRange(paragraph.range) <= editedRange.location { shifted.append(paragraph); continue }
            let start = map(paragraph.range.location), end = map(NSMaxRange(paragraph.range))
            let views = viewsByStart[paragraph.range.location] ?? []
            guard end > start else {
                // The image line itself was deleted: its images go with it.
                views.forEach { $0.removeFromSuperview() }
                imageViews.removeAll { view in views.contains { $0 === view } }
                removed = true
                continue
            }
            let range = NSRange(location: start, length: end - start)
            views.forEach { $0.sourceRange = range }
            shifted.append(InlineImageParagraph(range: range, contents: paragraph.contents))
        }
        paragraphs = shifted
        if removed { selectedViews.removeAll { $0.superview == nil } }
        indexViews()
        updateHeights()
    }

    private func indexViews() {
        viewsByStart = [:]
        for view in imageViews { viewsByStart[view.sourceRange.location, default: []].append(view) }
    }

    func schedule() {
        generation += 1
        let requested = generation
        task?.cancel()
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard let self, let editor = self.editor, !editor.hasMarkedText(),
                  let root = self.root, let document = self.document else { return }
            let text = editor.string
            let column = editor.textContainer?.containerSize.width ?? 1
            let viewport = editor.enclosingScrollView?.contentSize.height ?? 1
            let scale = editor.window?.backingScaleFactor ?? 2
            let headers = await self.loader.load(text: text, document: document, root: root,
                                                column: column, viewport: viewport, scale: scale, headersOnly: true)
            guard !Task.isCancelled, requested == self.generation, editor.string == text else { return }
            self.install(headers)
            let decoded = await self.loader.load(text: text, document: document, root: root,
                                                column: column, viewport: viewport, scale: scale)
            guard !Task.isCancelled, requested == self.generation, editor.string == text else { return }
            self.install(decoded, fade: true)
        }
    }

    func refit() {
        guard let editor else { return }
        let size = NSSize(width: editor.textContainer?.containerSize.width ?? 1,
                          height: editor.enclosingScrollView?.contentSize.height ?? 1)
        if size != geometry {
            // Width changes (mode switch, sidebars, window) refit in place; the views move
            // in the display pass that lays out the reflowed text. Never hidden.
            geometry = size
            for view in imageViews { view.refit(column: size.width, viewport: size.height) }
            invalidate()
            schedule()
        }
        positionViews()
    }

    private func install(_ updated: [InlineImageParagraph], fade: Bool = false) {
        let equal = paragraphs.count == updated.count && zip(paragraphs, updated).allSatisfy { old, new in
            old.range == new.range && old.contents.count == new.contents.count && zip(old.contents, new.contents).allSatisfy { a, b in
                a.reference == b.reference && a.url == b.url && a.size == b.size && a.naturalSize == b.naturalSize
                    && a.message == b.message && a.bitmap === b.bitmap
            }
        }
        guard !equal else { positionViews(); return }
        paragraphs = updated
        let previousHeights = heightsByEnd
        updateViews(fade: fade)
        updateHeights()
        if heightsByEnd != previousHeights { invalidate() } else { positionViews() }
    }

    /// Reuse the existing view for the same reference (in order), so a reparse, a range
    /// shift or a sharper decode never removes and re-adds a visible image. Only new
    /// images get a new view, hidden until its slot is known.
    private func updateViews(fade: Bool) {
        var pool: [String: [InlineImageView]] = [:]
        for view in imageViews { pool[view.key, default: []].append(view) }
        imageViews = []
        guard let editor else {
            pool.values.joined().forEach { $0.removeFromSuperview() }
            indexViews(); selectedViews = []
            return
        }
        for paragraph in paragraphs {
            for content in paragraph.contents {
                let key = InlineImageView.key(content)
                let view: InlineImageView
                let firstBitmap: Bool
                if let reused = pool[key]?.first {
                    pool[key]?.removeFirst()
                    firstBitmap = reused.content.bitmap == nil && content.bitmap != nil
                    reused.update(content: content, sourceRange: paragraph.range)
                    view = reused
                } else {
                    view = InlineImageView(content: content, sourceRange: paragraph.range, editor: editor)
                    editor.addSubview(view)
                    firstBitmap = content.bitmap != nil
                }
                view.refit(column: geometry.width, viewport: geometry.height)
                imageViews.append(view)
                // Fade once per newly decoded bitmap, never on reuse of a shown bitmap.
                if fade, firstBitmap, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    view.alphaValue = 0
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.12
                        view.animator().alphaValue = 1
                    }
                }
            }
        }
        pool.values.joined().forEach { $0.removeFromSuperview() }
        selectedViews.removeAll { $0.superview == nil }
        indexViews()
    }

    private func updateHeights() {
        heightsByEnd = [:]
        for view in imageViews {
            let end = NSMaxRange(view.sourceRange)
            heightsByEnd[end] = (heightsByEnd[end].map { $0 + 8 } ?? 16) + view.frame.height
        }
    }

    private func invalidate() {
        updateHeights()
        guard let editor, let layout = editor.layoutManager else { return }
        layout.invalidateLayout(forCharacterRange: NSRange(location: 0, length: editor.string.utf16.count), actualCharacterRange: nil)
        editor.needsDisplay = true
        editor.scheduleContentSizing()
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard let height = heightsByEnd[NSMaxRange(characters)] else { return false }
        lineFragmentRect.pointee.size.height += height
        return true
    }

    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd flag: Bool) {
        positionViews()
    }

    /// Moves each image to its slot from geometry TextKit has already computed, in the
    /// same pass as that layout (layout completion and the editor's viewWillDraw). Never
    /// forces layout: an image whose line is not laid out yet lies below all laid-out
    /// text, which covers the visible rect at display time, so it is parked there.
    func positionViews() {
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        let length = editor.string.utf16.count
        let laid = layout.firstUnlaidCharacterIndex()
        let origin = editor.textContainerOrigin
        var parked: CGFloat?
        for paragraph in paragraphs where paragraph.range.length > 0 && NSMaxRange(paragraph.range) <= length {
            let views = viewsByStart[paragraph.range.location] ?? []
            let end = NSMaxRange(paragraph.range) - 1
            var y: CGFloat
            let placed = end < laid
            if placed {
                let glyph = layout.glyphIndexForCharacter(at: end)
                y = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true).maxY + origin.y + 6
            } else {
                let bottom = parked ?? layout.usedRect(for: container).maxY + origin.y + 6
                parked = bottom
                y = max(views.first?.frame.minY ?? bottom, bottom)
            }
            for view in views {
                let target = NSPoint(x: origin.x, y: y)
                if view.frame.origin != target { view.setFrameOrigin(target) }
                if placed, view.isHidden { view.isHidden = false }
                y += view.frame.height + 8
            }
        }
        refreshSelection()
    }

    func refreshSelection() {
        selectedViews.forEach { $0.refreshSelection() }
        selectedViews = viewsByStart[editor?.selectedRange().location ?? -1] ?? []
        selectedViews.forEach { $0.refreshSelection() }
    }
}

@MainActor final class InlineImageView: NSView, @preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate {
    private(set) var content: InlineImageContent
    var sourceRange: NSRange
    weak var editor: PlainMarkdownTextView?
    static func key(_ content: InlineImageContent) -> String {
        "\(content.reference.destination)\u{0}\(content.url?.path ?? "")"
    }
    var key: String { Self.key(content) }
    override var isFlipped: Bool { true }
    init(content: InlineImageContent, sourceRange: NSRange, editor: PlainMarkdownTextView) {
        self.content = content; self.sourceRange = sourceRange; self.editor = editor
        super.init(frame: NSRect(origin: .zero, size: content.size))
        isHidden = true
        identifier = NSUserInterfaceItemIdentifier("inline-image")
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        applyContent()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A sharper decode or changed file updates this view in place (no remove/re-add).
    func update(content: InlineImageContent, sourceRange: NSRange) {
        self.sourceRange = sourceRange
        guard content.bitmap !== self.content.bitmap || content.message != self.content.message || content.reference != self.content.reference
                || content.naturalSize != self.content.naturalSize || content.size != self.content.size else { return }
        self.content = content
        applyContent()
        needsDisplay = true
    }
    private func applyContent() {
        layer?.cornerRadius = content.message == nil ? 4 : 6
        setAccessibilityRole(content.message == nil ? .image : .staticText)
        setAccessibilityLabel(content.message ?? (content.reference.alt.isEmpty ? "Image, \(content.url?.lastPathComponent ?? "")" : content.reference.alt))
        setAccessibilityHelp(content.message == nil ? "Double-click to open in Quick Look" : "Select image source line")
    }

    func refit(column: CGFloat, viewport: CGFloat) {
        let size: NSSize
        if content.message != nil { size = NSSize(width: max(1, min(column, CGFloat((content.message! as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 40)), height: 28) }
        else {
            let fitted = InlineImages.fittedSize(width: content.naturalSize.width, height: content.naturalSize.height, column: column, viewport: viewport)
            size = NSSize(width: fitted.width, height: fitted.height)
        }
        if frame.size != size { setFrameSize(size) }
    }
    func refreshSelection() {
        guard let editor else { return }
        let selected = editor.selectedRange() == selectionRange
        let width: CGFloat = selected ? 2 : 0
        if layer?.borderWidth != width { layer?.borderWidth = width }
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }
    private var selectionRange: NSRange {
        guard let editor, NSMaxRange(sourceRange) <= editor.string.utf16.count else { return NSRange(location: 0, length: 0) }
        let line = (editor.string as NSString).substring(with: sourceRange).trimmingCharacters(in: .newlines)
        return NSRange(location: sourceRange.location, length: line.utf16.count)
    }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.silkwebPaneBackground.setFill(); bounds.fill()
        if let bitmap = content.bitmap {
            NSImage(cgImage: bitmap, size: content.size).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            NSColor.quaternarySystemFill.setFill(); bounds.fill()
            guard content.message != nil else { return }
            let warning = content.message?.hasPrefix("Missing") == true || content.message == "Can’t display image"
            NSImage(systemSymbolName: warning ? "exclamationmark.triangle" : "photo", accessibilityDescription: nil)?.withSymbolConfiguration(.init(paletteColors: [.secondaryLabelColor]))?.draw(in: NSRect(x: 10, y: 8, width: 12, height: 12))
            let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
            ((content.message ?? "") as NSString).draw(in: NSRect(x: 30, y: 6, width: max(0, bounds.width - 40), height: 20),
                withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }
    override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        editor.window?.makeFirstResponder(editor)
        editor.setSelectedRange(selectionRange)
        refreshSelection()
        if event.clickCount == 2 { quickLook(nil) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { editor?.draggingEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { editor?.draggingUpdated(sender) ?? [] }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { editor?.performDragOperation(sender) ?? false }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let actions: [(String, Selector)] = content.bitmap == nil ? [("Copy Path", #selector(copyPath(_:)))] :
            [("Quick Look", #selector(quickLook(_:))), ("Reveal in Finder", #selector(reveal(_:))), ("Copy Image", #selector(copyImage(_:)))]
        for (title, action) in actions { let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item) }
        return menu
    }
    @objc private func quickLook(_ sender: Any?) {
        guard content.bitmap != nil, content.url != nil, let panel = QLPreviewPanel.shared() else { NSSound.beep(); return }
        editor?.quickLookImage = self
        editor?.window?.makeFirstResponder(editor)
        panel.updateController()
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { content.url as NSURL? }
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        if event.type == .keyDown, event.keyCode == 53 || event.keyCode == 49 {
            panel.orderOut(nil); editor?.window?.makeFirstResponder(editor); return true
        }
        return false
    }
    @objc private func reveal(_ sender: Any?) { if let url = content.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
    @objc private func copyPath(_ sender: Any?) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(content.reference.destination, forType: .string) }
    @objc private func copyImage(_ sender: Any?) {
        guard let bitmap = content.bitmap else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([NSImage(cgImage: bitmap, size: content.size)])
    }
}

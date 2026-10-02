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
    private var positionScheduled = false
    private var geometry = NSSize.zero
    private var generation = 0
    private var heightsByEnd: [Int: CGFloat] = [:]
    private var viewsByStart: [Int: [InlineImageView]] = [:]
    private var selectedViews: [InlineImageView] = []

    func configure(root: URL?, document: URL?) {
        guard self.root != root || self.document != document else { return }
        self.root = root; self.document = document
        paragraphs = []
        replaceViews()
        invalidate()
        schedule()
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
            geometry = size
            for view in imageViews { view.refit(column: size.width, viewport: size.height) }
            updateHeights()
            invalidate()
            schedule()
        }
        schedulePosition()
    }

    private func install(_ updated: [InlineImageParagraph], fade: Bool = false) {
        let equal = paragraphs.count == updated.count && zip(paragraphs, updated).allSatisfy { old, new in
            old.range == new.range && old.contents.count == new.contents.count && zip(old.contents, new.contents).allSatisfy { a, b in
                a.reference == b.reference && a.url == b.url && a.size == b.size && a.naturalSize == b.naturalSize
                    && a.message == b.message && a.bitmap === b.bitmap
            }
        }
        guard !equal else { return }
        paragraphs = updated
        replaceViews(fade: fade)
        invalidate()
    }

    private func replaceViews(fade: Bool = false) {
        imageViews.forEach { $0.removeFromSuperview() }
        imageViews = []
        viewsByStart = [:]
        selectedViews = []
        guard let editor else { return }
        for paragraph in paragraphs {
            for content in paragraph.contents {
                let view = InlineImageView(content: content, sourceRange: paragraph.range, editor: editor)
                view.refit(column: geometry.width, viewport: geometry.height)
                editor.addSubview(view)
                imageViews.append(view)
                viewsByStart[paragraph.range.location, default: []].append(view)
                if fade, content.bitmap != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    view.alphaValue = 0
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.12
                        view.animator().alphaValue = 1
                    }
                }
            }
        }
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
        editor.scheduleContentSizing()
        schedulePosition()
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
        schedulePosition()
    }

    private func schedulePosition() {
        guard !positionScheduled else { return }
        positionScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.positionScheduled = false
            self.positionViews()
        }
    }

    func positionViews() {
        guard let editor, let layout = editor.layoutManager, let container = editor.textContainer else { return }
        layout.ensureLayout(for: container)
        for paragraph in paragraphs where NSMaxRange(paragraph.range) <= editor.string.utf16.count {
            let glyph = layout.glyphIndexForCharacter(at: NSMaxRange(paragraph.range) - 1)
            let used = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            var y = used.maxY + editor.textContainerOrigin.y + 6
            for view in viewsByStart[paragraph.range.location] ?? [] {
                let origin = NSPoint(x: editor.textContainerOrigin.x, y: y)
                if view.frame.origin != origin { view.setFrameOrigin(origin) }
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
    let content: InlineImageContent
    let sourceRange: NSRange
    weak var editor: PlainMarkdownTextView?
    override var isFlipped: Bool { true }
    init(content: InlineImageContent, sourceRange: NSRange, editor: PlainMarkdownTextView) {
        self.content = content; self.sourceRange = sourceRange; self.editor = editor
        super.init(frame: NSRect(origin: .zero, size: content.size))
        identifier = NSUserInterfaceItemIdentifier("inline-image")
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
        layer?.cornerRadius = content.message == nil ? 4 : 6
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(content.message == nil ? .image : .staticText)
        setAccessibilityLabel(content.message ?? (content.reference.alt.isEmpty ? "Image, \(content.url?.lastPathComponent ?? "")" : content.reference.alt))
        setAccessibilityHelp(content.message == nil ? "Double-click to open in Quick Look" : "Select image source line")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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
        NSColor.textBackgroundColor.setFill(); bounds.fill()
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

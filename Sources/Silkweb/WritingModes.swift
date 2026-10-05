import AppKit
import SwiftUI
import SilkwebCore

/// View ▸ Focus Mode / Typewriter Mode (silkweb-1.27) for one editor.
///
/// Focus dims everything outside the active paragraph with strips of the editor's own
/// background laid over the text, so each run keeps its colour blended 70% (45% with
/// Increase Contrast) toward the surface. Nothing touches text storage, styling or undo.
/// The strips are layers composited above the text (#65): scrolling re-measures nothing and
/// never blends dimmed pixels into the editor's backing store.
/// Typewriter keeps the caret line's centre at 40% of the visible height while typing.
@MainActor final class WritingModeController {
    weak var editor: PlainMarkdownTextView?
    private(set) var focus = false
    private(set) var typewriter = false
    /// The bright unit while Focus is on.
    private(set) var activeRange: NSRange?

    static let anchor: CGFloat = 0.40
    static let fadeDuration: CFTimeInterval = 0.15
    /// Opacity left to dimmed text and inline images.
    static var dimmedOpacity: CGFloat { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 0.55 : 0.30 }

    /// The state a running fade starts from; nil when no fade runs.
    private var fadeFrom: (on: Bool, range: NSRange?)?
    private var fadeStart: CFTimeInterval = 0
    private var fadeOrigin: CGFloat = 0
    private var progress: CGFloat = 1
    private var timer: Timer?
    private var updateScheduled = false
    private var anchorScheduled = false
    var isFading: Bool { fadeFrom != nil }

    func set(focus: Bool, typewriter: Bool) {
        if focus != self.focus {
            let from = (on: self.focus, range: activeRange)
            self.focus = focus
            if focus { activeRange = computeRange() } else { activeRange = nil }
            begin(from: from, animated: editor?.window != nil)
        }
        if typewriter != self.typewriter { setTypewriter(typewriter) }
    }

    /// Increase Contrast changes the dimmed opacity of the strips and images.
    private var contrastObserver: NSObjectProtocol?

    init() {
        contrastObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.focus || self.fadeFrom != nil else { return }
                self.updateDim()
                self.applyImageAlpha()
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let contrastObserver { NSWorkspace.shared.notificationCenter.removeObserver(contrastObserver) }
    }

    // MARK: Focus

    func selectionDidChange() { if focus { scheduleUpdate() } }

    func textDidChange() {
        if focus { scheduleUpdate() }
        if typewriter { scheduleAnchor() }
    }

    /// Called while the text storage processes an edit, before anything can display. The
    /// queued update below recomputes the unit a turn later; until then the bright band (and
    /// a running fade's start) must cover the same text, or a frame drawn in between lights
    /// the wrong lines — e.g. ⌫ in a heading pulled the band onto the body line below (1.80).
    func sourceDidChange(editedRange: NSRange, delta: Int) {
        guard focus || fadeFrom != nil, let storage = editor?.textStorage else { return }
        let text = storage.string as NSString
        if let range = activeRange {
            activeRange = Self.shift(range, editedRange: editedRange, delta: delta, in: text) ?? computeRange()
        }
        if let from = fadeFrom, let range = from.range {
            fadeFrom = (from.on, Self.shift(range, editedRange: editedRange, delta: delta, in: text))
        }
        dimNeedsUpdate = true
    }

    /// `range` after an edit, or nil when the edit crosses its boundary (the unit itself changes).
    static func shift(_ range: NSRange, editedRange: NSRange, delta: Int, in text: NSString) -> NSRange? {
        let start = editedRange.location
        let oldEnd = NSMaxRange(editedRange) - delta
        let end = NSMaxRange(range)
        if start < range.location {
            guard oldEnd <= range.location else { return nil }
            return NSRange(location: range.location + delta, length: range.length)
        }
        // Text inserted right after a unit that ends with a newline belongs to the next line.
        if start > end || (start == end && range.length > 0 && start > 0 && start <= text.length
                           && text.character(at: start - 1) == 0x0A) {
            return range
        }
        guard oldEnd <= end else { return nil }
        return NSRange(location: range.location, length: max(0, range.length + delta))
    }

    /// Once per run loop turn, after the styler has refreshed its fence checkpoints.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateScheduled = false
            self.updateActiveRange()
        }
    }

    func updateActiveRange() {
        guard focus, let editor, let next = computeRange(), next != activeRange else { return }
        let previous = activeRange
        activeRange = next
        if let previous, NSIntersectionRange(previous, next).length > 0 || previous.location == next.location {
            // Typing or moving within the paragraph: the strips follow its edges.
            updateDim()
            applyImageAlpha()
            return
        }
        // Jumps farther than about one screen switch instantly.
        var animated = true
        if let previous, let old = band(for: previous), let new = band(for: next) {
            let visible = editor.visibleRect
            animated = abs(old.top - new.top) <= visible.height && old.top < visible.maxY && new.top < visible.maxY
                && old.bottom > visible.minY && new.bottom > visible.minY
        }
        begin(from: (true, previous), animated: animated)
    }

    private func computeRange() -> NSRange? {
        guard let editor, let storage = editor.textStorage else { return nil }
        return FocusUnit.range(in: storage.string as NSString, selection: editor.selectedRange(),
                               fencedBefore: { [styler = editor.styler] in styler.fencedBefore(line: $0) })
    }

    /// Snaps any running fade, then fades from `from` to the current state over 150 ms
    /// (instantly under Reduce Motion).
    private func begin(from: (on: Bool, range: NSRange?), animated: Bool) {
        finishFade()
        guard let editor else { return }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            fadeFrom = from
            progress = 0
            fadeStart = CACurrentMediaTime()
            fadeOrigin = editor.enclosingScrollView?.contentView.bounds.minY ?? 0
            let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        updateDim()
        applyImageAlpha()
    }

    private func tick() {
        guard let editor else { finishFade(); return }
        // A scroll during the fade lands it at once.
        let scrolled = editor.enclosingScrollView.map { abs($0.contentView.bounds.minY - fadeOrigin) > 0.5 } ?? true
        progress = scrolled ? 1 : min(1, CGFloat((CACurrentMediaTime() - fadeStart) / Self.fadeDuration))
        if progress >= 1 { finishFade() } else {
            updateDim()
            applyImageAlpha()
        }
    }

    func finishFade() {
        timer?.invalidate()
        timer = nil
        guard fadeFrom != nil else { return }
        fadeFrom = nil
        progress = 1
        updateDim()
        applyImageAlpha()
    }

    /// Vertical extent of a unit in editor coordinates, from layout TextKit has already done.
    /// A unit below the laid-out text lies below everything visible.
    func band(for range: NSRange) -> (top: CGFloat, bottom: CGFloat)? {
        guard let editor, let layout = editor.layoutManager else { return nil }
        let below = (top: CGFloat.greatestFiniteMagnitude, bottom: CGFloat.greatestFiniteMagnitude)
        let length = editor.textStorage?.length ?? 0
        let origin = editor.textContainerOrigin.y
        if range.location >= length {
            let extra = layout.extraLineFragmentRect
            return extra.isEmpty ? below : (extra.minY + origin, extra.maxY + origin)
        }
        let laid = layout.firstUnlaidCharacterIndex()
        guard range.location < laid else { return below }
        let first = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: range.location),
                                            effectiveRange: nil, withoutAdditionalLayout: true)
        let last = max(range.location, NSMaxRange(range) - 1)
        guard last < laid else { return (first.minY + origin, .greatestFiniteMagnitude) }
        let end = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: last),
                                          effectiveRange: nil, withoutAdditionalLayout: true)
        return (first.minY + origin, end.maxY + origin)
    }

    /// Fraction of the surface colour painted over text at `y` (0 = undimmed).
    private func overlay(at y: CGFloat, to: (top: CGFloat, bottom: CGFloat)?, from: (top: CGFloat, bottom: CGFloat)?) -> CGFloat {
        let dim = 1 - Self.dimmedOpacity
        func value(on: Bool, band: (top: CGFloat, bottom: CGFloat)?) -> CGFloat {
            guard on else { return 0 }
            if let band, y >= band.top, y < band.bottom { return 0 }
            return dim
        }
        let target = value(on: focus, band: to)
        guard let fadeFrom else { return target }
        let start = value(on: fadeFrom.on, band: from)
        let eased = 1 - pow(1 - progress, 3)
        return start + (target - start) * eased
    }

    private var bands: (to: (top: CGFloat, bottom: CGFloat)?, from: (top: CGFloat, bottom: CGFloat)?) {
        (focus ? activeRange.flatMap(band(for:)) : nil, fadeFrom?.range.flatMap(band(for:)))
    }

    /// Opacity the displayed strips leave to text at `y`.
    func opacity(at y: CGFloat) -> CGFloat {
        1 - (dimmedStrips.first { y >= $0.top && y < $0.bottom }?.alpha ?? 0)
    }

    // MARK: Dimming (#65)

    /// The dimmed strips on screen in editor coordinates: everything outside the bright band(s).
    private(set) var dimmedStrips: [(top: CGFloat, bottom: CGFloat, alpha: CGFloat)] = []
    private var stripViews: [FocusDimView] = []
    /// Set by edits and layout invalidation: the strips are re-measured before the next frame draws.
    private var dimNeedsUpdate = false
    /// The editor geometry the strips were measured against; `unlaid` while a band edge lay below the laid-out text.
    private var measured: (width: CGFloat, height: CGFloat, origin: NSPoint, unlaid: Int?) = (0, 0, .zero, nil)

    /// Re-measures the bright band(s) and moves the strips, which scroll with the text as
    /// subviews. Runs on Focus, unit, fade, edit and layout changes, never on scroll alone.
    func updateDim() {
        dimNeedsUpdate = false
        guard let editor else { return }
        var strips: [(top: CGFloat, bottom: CGFloat, alpha: CGFloat)] = []
        var incomplete = false
        if focus || fadeFrom != nil {
            let bands = bands
            let height = editor.bounds.height
            var edges: [CGFloat] = [0, height]
            for band in [bands.to, bands.from].compactMap({ $0 }) {
                for edge in [band.top, band.bottom] {
                    if edge == .greatestFiniteMagnitude { incomplete = true } else if edge > 0 && edge < height { edges.append(edge) }
                }
            }
            edges.sort()
            for (top, bottom) in zip(edges, edges.dropFirst()) where bottom > top {
                let alpha = overlay(at: (top + bottom) / 2, to: bands.to, from: bands.from)
                guard alpha > 0.001 else { continue }
                if let last = strips.last, last.bottom == top, last.alpha == alpha { strips[strips.count - 1].bottom = bottom }
                else { strips.append((top, bottom, alpha)) }
            }
        }
        measured = (editor.bounds.width, editor.bounds.height, editor.textContainerOrigin,
                    incomplete ? editor.layoutManager?.firstUnlaidCharacterIndex() : nil)
        dimmedStrips = strips
        while stripViews.count > strips.count { stripViews.removeLast().removeFromSuperview() }
        while stripViews.count < strips.count {
            let view = FocusDimView()
            // Over the text, under inline images and the caret.
            editor.addSubview(view, positioned: .below, relativeTo: nil)
            stripViews.append(view)
        }
        for (view, strip) in zip(stripViews, strips) {
            let frame = NSRect(x: 0, y: strip.top, width: editor.bounds.width, height: strip.bottom - strip.top)
            if view.frame != frame { view.frame = frame }
            view.dimAlpha = strip.alpha
        }
    }

    /// From the editor's viewWillDraw: re-measures only when an edit, layout or geometry change
    /// may have moved a band, so a scrolled frame costs a few comparisons.
    func dimWillDraw() {
        guard let editor, focus || fadeFrom != nil || !stripViews.isEmpty else { return }
        let stale = dimNeedsUpdate || measured.width != editor.bounds.width || measured.height != editor.bounds.height
            || measured.origin != editor.textContainerOrigin
            || measured.unlaid.map { $0 != editor.layoutManager?.firstUnlaidCharacterIndex() } == true
        guard stale else { return }
        if let layout = editor.layoutManager, let container = editor.textContainer {
            var rect = editor.visibleRect
            rect.origin.x -= editor.textContainerOrigin.x; rect.origin.y -= editor.textContainerOrigin.y
            layout.ensureLayout(forBoundingRect: rect, in: container)
        }
        updateDim()
    }

    /// The editor's frame changed, often outside a display pass: content sizing refits the height
    /// a turn after a reflow has drawn, and a shrink draws nothing (#78). The strips span the new
    /// frame at once; a pending re-measure still runs before the next frame draws.
    func editorDidResize() {
        guard let editor, focus || fadeFrom != nil || !stripViews.isEmpty,
              measured.width != editor.bounds.width || measured.height != editor.bounds.height else { return }
        let pending = dimNeedsUpdate
        updateDim()
        dimNeedsUpdate = pending
    }

    /// TextKit invalidated layout (edit, restyle, width, image heights): bands may have moved.
    func layoutDidInvalidate() { if focus || !stripViews.isEmpty { dimNeedsUpdate = true } }

    /// Inline image overlays (1.41) are never part of the bright unit (1.68): dimmed text's
    /// opacity whenever Focus is on, wherever the caret is. Only toggling Focus fades them.
    var imageOpacity: CGFloat { 1 - overlay(at: 0, to: nil, from: nil) }

    func applyImageAlpha() {
        guard let editor else { return }
        let views = editor.inlineImages.imageViews
        guard !views.isEmpty else { return }
        let target = imageOpacity
        for view in views where view.alphaValue != target { view.alphaValue = target }
    }

    // MARK: Typewriter

    private func setTypewriter(_ on: Bool) {
        guard let editor else { typewriter = on; return }
        let scroll = editor.enclosingScrollView
        let origin = scroll?.contentView.bounds.origin
        typewriter = on
        if !on, let scroll, scroll.contentInsets.top != 0 {
            // Typewriter owned the top inset; restore the 1.48 baseline before relayout.
            var insets = scroll.contentInsets
            insets.top = 0
            scroll.contentInsets = insets
        }
        editor.layoutEditor()
        if on { anchorCaret() } else if let scroll, let origin {
            // Keep the caret line where it is on screen, clamped to the inset-free range.
            let maximum = max(0, editor.frame.height - scroll.contentSize.height)
            scroll.contentView.scroll(to: NSPoint(x: origin.x, y: min(max(0, origin.y), maximum)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// Top and bottom overscroll so the first and last lines can reach the anchor. When off,
    /// no bottom overscroll (1.48 baseline) and the top inset is left alone (nil).
    func contentInsets(viewport height: CGFloat) -> (top: CGFloat?, bottom: CGFloat) {
        guard typewriter, let editor else { return (nil, 0) }
        let half = lineHeight(editor) / 2
        return (max(0, (Self.anchor * height - half).rounded()), max(0, ((1 - Self.anchor) * height - half).rounded()))
    }

    private func lineHeight(_ editor: PlainMarkdownTextView) -> CGFloat {
        let font = editor.style.bodyFont
        return (editor.layoutManager?.defaultLineHeight(for: font) ?? font.ascender - font.descender) * editor.style.lineHeight
    }

    private func scheduleAnchor() {
        guard !anchorScheduled else { return }
        anchorScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.anchorScheduled = false
            self.anchorCaret()
        }
    }

    /// Text input and keyboard caret movement re-anchor; mouse and trackpad scrolling never do.
    func keyboardDidMove() { if typewriter { anchorCaret() } }

    func anchorCaret() {
        guard typewriter, let editor else { return }
        scrollLine(at: editor.selectedRange().location, toFraction: Self.anchor)
    }

    /// Find (1.13) and Outline (1.18) jumps: the typewriter anchor while it is on, else the upper third.
    func reveal(_ location: Int) {
        guard let editor, let layout = editor.layoutManager, let scroll = editor.enclosingScrollView else { return }
        if typewriter { scrollLine(at: location, toFraction: Self.anchor); return }
        guard location < editor.string.utf16.count else { return }
        layout.ensureLayout(forCharacterRange: NSRange(location: location, length: 0))
        let rect = layout.lineFragmentRect(forGlyphAt: layout.glyphIndexForCharacter(at: location), effectiveRange: nil)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + editor.textContainerOrigin.y - scroll.contentSize.height / 3)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    /// The caret line (its text height, not an image slot beneath it) in editor coordinates.
    func caretLine(at location: Int) -> NSRect? {
        guard let editor, let layout = editor.layoutManager else { return nil }
        let length = editor.textStorage?.length ?? 0
        let location = max(0, min(location, length))
        layout.ensureLayout(forCharacterRange: NSRange(location: min(location, max(0, length - 1)), length: length > 0 ? 1 : 0))
        var fragment = layout.extraLineFragmentRect
        if location < length || fragment.isEmpty {
            guard length > 0, layout.numberOfGlyphs > 0 else { return nil }
            let glyph = min(layout.glyphIndexForCharacter(at: min(location, length - 1)), layout.numberOfGlyphs - 1)
            fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        }
        guard !fragment.isEmpty else { return nil }
        fragment.size.height = min(fragment.height, lineHeight(editor).rounded(.up))
        fragment.origin.y += editor.textContainerOrigin.y
        return fragment
    }

    private func scrollLine(at location: Int, toFraction fraction: CGFloat) {
        guard let editor, let scroll = editor.enclosingScrollView, let line = caretLine(at: location) else { return }
        let height = scroll.contentSize.height
        let insets = scroll.contentInsets
        let maximum = max(-insets.top, editor.frame.height + insets.bottom - height)
        let y = min(max(line.midY - fraction * height, -insets.top), maximum).rounded()
        let clip = scroll.contentView
        guard abs(clip.bounds.minY - y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y))
        scroll.reflectScrolledClipView(clip)
    }
}

/// One Focus Mode strip (#65): the editor's surface at `dimAlpha`. On screen a plain layer
/// colour composited over the text, so a scrolled frame commits no re-blended pixels.
final class FocusDimView: NSView {
    var dimAlpha: CGFloat = 0 { didSet { if dimAlpha != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = NSUserInterfaceItemIdentifier("focus-dim")
        wantsLayer = true
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private var surface: NSColor { (superview as? NSTextView)?.backgroundColor ?? .silkwebPaneBackground }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        var color: CGColor?
        effectiveAppearance.performAsCurrentDrawingAppearance { color = surface.cgColor }
        layer?.backgroundColor = color.map { $0.copy(alpha: $0.alpha * dimAlpha) ?? $0 }
    }
    /// Offscreen captures (cacheDisplay, printing) draw the same blend.
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(dimAlpha)
        surface.setFill()
        dirtyRect.fill(using: .sourceOver)
        context.restoreGState()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

extension LibraryWorkspace {
    /// Enabled while the source editor is visible; Preview-only keeps the state.
    var canToggleWritingModes: Bool { snapshot != nil && preview.mode != .preview }

    func setWritingModes(focus: Bool? = nil, typewriter: Bool? = nil) {
        if let focus, focus != focusMode { focusMode = focus }
        if let typewriter, typewriter != typewriterMode { typewriterMode = typewriter }
        for editor in EditorRegistry.editors.allObjects where editor.workspace === self {
            editor.writingModes.set(focus: focusMode, typewriter: typewriterMode)
        }
        persistSession()
    }

    func toggleFocusMode() { setWritingModes(focus: !focusMode) }
    func toggleTypewriterMode() { setWritingModes(typewriter: !typewriterMode) }
}

/// The two checkable View menu items, shared by the menu bar and the status-bar chip.
struct WritingModeItems: View {
    let workspace: LibraryWorkspace
    let focus: Bool
    let typewriter: Bool
    var enabled = true
    /// Only the menu bar registers ⌃⇧⌘F / ⌃⇧⌘T, so a key press never toggles twice.
    var shortcuts = true
    var body: some View {
        Toggle("Focus Mode", isOn: Binding(get: { focus }, set: { workspace.setWritingModes(focus: $0) }))
            .keyboardShortcut(shortcuts ? KeyboardShortcut("f", modifiers: [.control, .shift, .command]) : nil).disabled(!enabled)
        Toggle("Typewriter Mode", isOn: Binding(get: { typewriter }, set: { workspace.setWritingModes(typewriter: $0) }))
            .keyboardShortcut(shortcuts ? KeyboardShortcut("t", modifiers: [.control, .shift, .command]) : nil).disabled(!enabled)
    }
}

/// Trailing status-bar chip shown while a writing mode is on; its menu is the quick way out.
struct WritingModesChip: View {
    let workspace: LibraryWorkspace
    @State private var hovering = false

    static func title(focus: Bool, typewriter: Bool) -> String? {
        switch (focus, typewriter) {
        case (true, true): "Focus · Typewriter"
        case (true, false): "Focus"
        case (false, true): "Typewriter"
        case (false, false): nil
        }
    }

    var body: some View {
        if let title = Self.title(focus: workspace.focusMode, typewriter: workspace.typewriterMode) {
            Menu {
                WritingModeItems(workspace: workspace, focus: workspace.focusMode, typewriter: workspace.typewriterMode, shortcuts: false)
            } label: {
                Text(title).font(.caption).foregroundStyle(Color.silkwebAccent)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .tint(.silkwebAccent)
            .fixedSize()
            .padding(.vertical, 2).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 4).fill(hovering ? Color(nsColor: .quaternarySystemFill) : .clear))
            .onHover { hovering = $0 }
            .help("Writing Modes")
            .accessibilityLabel("Writing modes")
            .accessibilityValue(title)
            .accessibilityIdentifier("statusWritingModes")
        }
    }
}

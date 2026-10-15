import AppKit
import SilkwebCore

/// One read-only pane of the Proposal diff (#140): changed lines get a `−` or `+` marker in a 22 pt gutter and a
/// 12 % `systemRed` / `systemGreen` band, so a change reads without colour too. TextKit 1, drawn per visible line
/// in `drawBackground`; nothing is laid out again after `show`.
final class DiffTextView: NSTextView {
    static let gutterWidth: CGFloat = 22
    static let bandAlpha: CGFloat = 0.12

    /// The changed lines' UTF-16 ranges, terminators excluded.
    private(set) var changedRanges: [NSRange] = []
    /// The current pane marks removed lines; the proposed pane added ones.
    private(set) var marksRemovals = true

    static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .silkwebPaneBackground
        scroll.automaticallyAdjustsContentInsets = false
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let text = DiffTextView(frame: .zero, textContainer: container)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = false
        text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        text.textColor = .silkwebText
        text.backgroundColor = .silkwebPaneBackground
        text.drawsBackground = true
        text.textContainerInset = NSSize(width: gutterWidth, height: 12)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.minSize = .zero
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.autoresizingMask = [.width]
        scroll.documentView = text
        return scroll
    }

    /// Replaces the text and the changed lines; `changed` holds `LineDiff` line indices.
    func show(_ value: String, changed: Set<Int>, removed: Bool) {
        let ranges = LineDiff.lineRanges(value)
        let next = changed.sorted().compactMap { $0 < ranges.count ? ranges[$0] : nil }
        guard string != value || next != changedRanges || removed != marksRemovals else { return }
        marksRemovals = removed
        changedRanges = next
        if string != value { string = value }
        needsDisplay = true
    }

    /// The band rectangles of the changed lines, in view coordinates, full width. Empty lines get one line height.
    func bandRects(in rect: NSRect? = nil) -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        let origin = textContainerOrigin
        var rects: [NSRect] = []
        let visible = rect.map { NSRect(x: $0.minX, y: $0.minY - origin.y, width: $0.width, height: $0.height) }
        let visibleGlyphs = visible.map { layoutManager.glyphRange(forBoundingRect: $0, in: textContainer) }
        let length = (string as NSString).length
        for range in changedRanges {
            var lineRect: NSRect
            if range.location >= length {
                // The last line is empty: the extra line fragment after the final break.
                lineRect = layoutManager.extraLineFragmentRect
                if lineRect.isEmpty { continue }
            } else {
                let characters = NSRange(location: range.location, length: max(1, range.length))
                let glyphs = layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                if let visibleGlyphs, NSIntersectionRange(glyphs, visibleGlyphs).length == 0,
                    glyphs.location != NSMaxRange(visibleGlyphs)
                {
                    continue
                }
                // Whole line fragments, wrapped lines included, from the first to the last.
                let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let last = layoutManager.lineFragmentRect(
                    forGlyphAt: max(glyphs.location, NSMaxRange(glyphs) - 1), effectiveRange: nil)
                lineRect = first.union(last)
            }
            rects.append(
                NSRect(x: bounds.minX, y: lineRect.minY + origin.y, width: bounds.width, height: lineRect.height))
        }
        return rects
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        let rects = bandRects(in: rect)
        guard !rects.isEmpty else { return }
        (marksRemovals ? NSColor.systemRed : NSColor.systemGreen).withAlphaComponent(Self.bandAlpha).setFill()
        for band in rects where band.intersects(rect) { band.fill() }
        let marker = marksRemovals ? "−" : "+"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: marksRemovals ? NSColor.systemRed : NSColor.systemGreen,
        ]
        let size = (marker as NSString).size(withAttributes: attributes)
        for band in rects where band.intersects(rect) {
            let lineHeight = min(
                band.height, layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 13)) ?? 16)
            (marker as NSString).draw(
                at: NSPoint(x: (Self.gutterWidth - size.width) / 2, y: band.minY + (lineHeight - size.height) / 2),
                withAttributes: attributes)
        }
    }

    /// VoiceOver reads changed lines with “Removed:” or “Added:” first; the text itself is unchanged.
    override func accessibilityValue() -> String? {
        guard !changedRanges.isEmpty else { return super.accessibilityValue() }
        return Self.annotated(string, changed: changedRanges, removed: marksRemovals)
    }

    static func annotated(_ text: String, changed: [NSRange], removed: Bool) -> String {
        let prefix = removed ? "Removed: " : "Added: "
        let starts = Set(changed.map(\.location))
        let ranges = LineDiff.lineRanges(text)
        let source = text as NSString
        var lines: [String] = []
        for range in ranges {
            let line = source.substring(with: range)
            lines.append(starts.contains(range.location) ? prefix + line : line)
        }
        return lines.joined(separator: "\n")
    }
}

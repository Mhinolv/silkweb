import AppKit
import SwiftUI
import SilkwebCore

/// Width-bound flow; measuring and placement share the same row calculation.
struct RecentTagFlow: Layout {
    private func positions(width: CGFloat, subviews: Subviews) -> (points: [CGPoint], size: CGSize) {
        let width = max(1, width)
        var points: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(ProposedViewSize(width: width, height: 22))
            let itemWidth = min(width, size.width)
            if x > 0 && x + itemWidth > width { x = 0; y += 28 }
            points.append(CGPoint(x: x, y: y))
            x += itemWidth + 6
        }
        return (points, CGSize(width: width, height: subviews.isEmpty ? 0 : y + 22))
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        positions(width: proposal.width ?? 216, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = positions(width: bounds.width, subviews: subviews)
        for (view, point) in zip(subviews, result.points) {
            let width = min(bounds.width, view.sizeThatFits(ProposedViewSize(width: bounds.width, height: 22)).width)
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), anchor: .topLeading,
                       proposal: ProposedViewSize(width: width, height: 22))
        }
    }
}

/// A Suggested tag (#72): an outlined “+ tag” pill for a recent tag the selection doesn't carry yet.
/// Native button action/focus semantics inside the SwiftUI flow; VoiceOver reads an unchecked checkbox.
struct RecentTagPill: NSViewRepresentable {
    let tag: LibraryTag
    let enabled: Bool
    let action: () -> Void
    func makeNSView(context: Context) -> TagPillButton { TagPillButton() }
    func updateNSView(_ button: TagPillButton, context: Context) {
        button.title = tag.name
        button.isEnabled = enabled
        button.onToggle = action
        button.setAccessibilityLabel(tag.name)
        button.setAccessibilityValue("not applied")
        button.setAccessibilityHelp("Adds this tag")
        button.invalidateIntrinsicContentSize()
        button.needsDisplay = true
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TagPillButton, context: Context) -> CGSize? {
        CGSize(width: min(proposal.width ?? .greatestFiniteMagnitude, nsView.intrinsicContentSize.width), height: 22)
    }
}

final class TagPillButton: NSButton {
    var onToggle: (() -> Void)?
    private var hovering = false
    private var tracking: NSTrackingArea?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        isBordered = false
        font = .systemFont(ofSize: 12)
        focusRingType = .exterior
        target = self; action = #selector(toggleTag(_:))
        setAccessibilityRole(.checkBox)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func toggleTag(_ sender: NSButton) { onToggle?() }
    /// “+” and its gap.
    private static let plusWidth: CGFloat = 12
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil((title as NSString).size(withAttributes: [.font: font!]).width) + 18 + Self.plusWidth, height: 22)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.5) }
        let capsule = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10.5, yRadius: 10.5)
        if isHighlighted || hovering && isEnabled {
            (isHighlighted ? NSColor.tertiarySystemFill : .quaternarySystemFill).setFill(); capsule.fill()
        }
        NSColor.separatorColor.setStroke()
        capsule.lineWidth = 1; capsule.stroke()
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let plus: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.silkwebAccent]
        let plusHeight = ("+" as NSString).size(withAttributes: plus).height
        ("+" as NSString).draw(at: NSPoint(x: 9, y: (bounds.height - plusHeight) / 2), withAttributes: plus)
        let attributes: [NSAttributedString.Key: Any] = [.font: font!, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph]
        let height = (title as NSString).size(withAttributes: attributes).height
        let x = 9 + Self.plusWidth
        (title as NSString).draw(in: NSRect(x: x, y: (bounds.height - height) / 2, width: max(0, bounds.width - x - 9), height: height), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 11, yRadius: 11).fill() }
}

extension TagInputField {
    func showCompletions(_ names: [String]) {
        dismissCompletions()
        guard !names.isEmpty else { return }
        completionIndex = 0
        // Bound control creation while typing; narrowing the prefix still reaches every tag.
        let visibleNames = Array(names.prefix(20))
        completionRows = visibleNames.map { name in
            let button = NSButton(title: name, target: self, action: #selector(acceptCompletion(_:)))
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: 13)
            // A mouse acceptance must leave the token field's editor as first responder.
            button.refusesFirstResponder = true
            button.setAccessibilityLabel("Use tag \(name)")
            return button
        }
        let stack = NSStackView(views: completionRows)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        for button in completionRows {
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            button.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        stack.frame = NSRect(x: 0, y: 0, width: max(160, bounds.width), height: CGFloat(visibleNames.count * 24 + 8))
        scroll.documentView = stack
        completionPanel.contentView = scroll
        completionPanel.backgroundColor = .controlBackgroundColor
        completionPanel.hasShadow = true
        completionPanel.isReleasedWhenClosed = false
        highlightCompletion()
        // Offscreen tests build the same rows/action hierarchy but never order a window.
        guard let window, window.isVisible else { return }
        let rect = window.convertToScreen(convert(bounds, to: nil))
        let height = CGFloat(min(visibleNames.count, 8) * 24 + 8)
        completionPanel.setFrame(NSRect(x: rect.minX, y: rect.minY - height, width: max(160, rect.width), height: height), display: false)
        window.addChildWindow(completionPanel, ordered: .above)
    }
    private func highlightCompletion() {
        for (index, button) in completionRows.enumerated() {
            if index == completionIndex { button.scrollToVisible(button.bounds) }
            button.contentTintColor = index == completionIndex ? .silkwebAccent : .labelColor
        }
    }
    func dismissCompletions() {
        completionPanel.parent?.removeChildWindow(completionPanel)
        completionPanel.orderOut(nil)
        completionRows = []
    }
    func handleCompletionCommand(_ selector: Selector) -> Bool {
        guard !completionRows.isEmpty else { return false }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            acceptCompletion(completionRows[completionIndex]); return true
        case #selector(NSResponder.cancelOperation(_:)):
            dismissCompletions(); return true
        case #selector(NSResponder.moveDown(_:)):
            completionIndex = min(completionRows.count - 1, completionIndex + 1); highlightCompletion(); return true
        case #selector(NSResponder.moveUp(_:)):
            completionIndex = max(0, completionIndex - 1); highlightCompletion(); return true
        default: return false
        }
    }
    @objc func acceptCompletion(_ sender: NSButton) {
        guard let coordinator = delegate as? TagChipField.Coordinator,
              let name = coordinator.suggestions.first(where: { $0 == sender.title }) else { return }
        dismissCompletions()
        stringValue = ""
        coordinator.onAdd([name])
        // A mouse acceptance must leave the field focused for the next tag.
        if currentEditor() == nil { window?.makeFirstResponder(self) }
    }
}

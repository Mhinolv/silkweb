import AppKit
import SilkwebCore
import SwiftUI

struct DocumentInfo: View {
    let workspace: LibraryWorkspace
    var body: some View {
        if workspace.tagDocumentIDs.isEmpty {
            ContentUnavailableView("No Document Selected", systemImage: "doc.text")
        } else {
            let applied = workspace.appliedTagStates
            let suggested = workspace.recentTags.filter { applied[$0.id] == nil }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags").font(.headline)
                        TagChipField(
                            chips: workspace.tags.compactMap { tag in
                                applied[tag.id].map { TagChip(tag: tag, mixed: !$0) }
                            },
                            suggestions: workspace.tags.filter { applied[$0.id] != true }.map(\.name),
                            focusRequest: workspace.tagFocusRequest, enabled: workspace.canEditTags,
                            onAdd: workspace.addTags, onRemove: workspace.removeTag)
                        // Suggested: recent tags not on the selection yet; applying one moves it into the chips.
                        if !suggested.isEmpty {
                            Text("Suggested").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 4)
                            RecentTagFlow {
                                ForEach(suggested) { tag in
                                    RecentTagPill(tag: tag, enabled: workspace.canEditTags) {
                                        workspace.addTags([tag.name])
                                    }
                                }
                            }
                            .accessibilityElement(children: .contain).accessibilityLabel("Suggested tags")
                        }
                        Text("Saved in Silkweb’s index, not in the file.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    if let document = workspace.selectedDocument {
                        Text("Location").font(.headline)
                        let parent = (document.relativePath as NSString).deletingLastPathComponent
                        Button(parent.isEmpty ? "Library" : parent.replacingOccurrences(of: "/", with: " › ")) {
                            workspace.reveal(document.relativePath)
                        }
                        .buttonStyle(.link)
                        if let date = document.created {
                            Text("Created").font(.headline); Text(date.formatted()).font(.caption)
                        }
                        if let date = document.modified {
                            Text("Modified").font(.headline); Text(date.formatted()).font(.caption)
                        }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// An applied tag; `mixed` when only some selected documents carry it.
struct TagChip: Equatable {
    let tag: LibraryTag
    let mixed: Bool
}

/// #72 Tags A: applied tags as sage chips followed inline by an “Add tag…” field, over one hairline.
struct TagChipField: NSViewRepresentable {
    let chips: [TagChip]
    let suggestions: [String]
    let focusRequest: Int
    let enabled: Bool
    let onAdd: ([String]) -> Void
    let onRemove: (UUID) -> Void
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> TagChipContainer {
        let container = TagChipContainer()
        container.field.delegate = context.coordinator
        return container
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TagChipContainer, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? 216
        let width = proposedWidth.isFinite ? proposedWidth : 216
        return CGSize(width: width, height: nsView.measuredHeight(width: width))
    }
    func updateNSView(_ container: TagChipContainer, context: Context) {
        let coordinator = context.coordinator
        coordinator.suggestions = suggestions
        coordinator.onAdd = onAdd
        coordinator.onRemove = onRemove
        coordinator.chips = chips
        container.update(chips: chips, enabled: enabled, onAdd: onAdd, onRemove: onRemove)
        container.field.requestedFocus = focusRequest
        container.field.focusIfNeeded()
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onAdd: ([String]) -> Void = { _ in }
        var onRemove: (UUID) -> Void = { _ in }
        var suggestions: [String] = []
        var chips: [TagChip] = []
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? TagInputField else { return false }
            if field.handleCompletionCommand(selector) { return true }
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                commit(field); return true
            case #selector(NSResponder.insertTab(_:)):
                // Tab commits typed text and stays; with nothing typed it moves focus as usual.
                guard !textView.string.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
                commit(field); return true
            case #selector(NSResponder.deleteBackward(_:)):
                // ⌫ in the empty field removes the last chip, like a token field.
                guard textView.string.isEmpty, let last = chips.last else { return false }
                onRemove(last.tag.id); return true
            default: return false
            }
        }
        /// Commits every comma-separated name, leaving no text behind.
        func commit(_ field: TagInputField) {
            let names = field.stringValue.split(separator: ",").compactMap { TagEditor.normalize(String($0)) }
            field.dismissCompletions()
            field.stringValue = ""
            if !names.isEmpty { onAdd(names) }
        }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? TagInputField else { return }
            let text = field.stringValue
            // A comma commits what precedes it, as the token field did; pasted lists commit at once.
            if let comma = text.lastIndex(of: ",") {
                let names = text[..<comma].split(separator: ",").compactMap { TagEditor.normalize(String($0)) }
                field.stringValue = String(text[text.index(after: comma)...])
                if !names.isEmpty { onAdd(names) }
            }
            let prefix = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            field.showCompletions(
                prefix.isEmpty
                    ? []
                    : suggestions.filter {
                        !$0.isEmpty && $0.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil
                    })
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? TagInputField { commit(field) }
        }
    }
}

/// Flow layout of chip buttons and the input field. Chips wrap at the column width and the field takes the
/// rest of the last line (or a line of its own); there is no inner scroller, the Info pane scrolls instead.
final class TagChipContainer: NSView {
    static let chipHeight: CGFloat = 22
    static let spacing: CGFloat = 6
    static let fieldMinWidth: CGFloat = 80
    /// Space between the last line and the hairline.
    static let bottomInset: CGFloat = 6
    let field = TagInputField()
    private(set) var chipButtons: [TagChipButton] = []
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.placeholderString = "Add tag…"
        field.font = .systemFont(ofSize: 12)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.isScrollable = true
        field.cell?.usesSingleLineMode = true
        field.setAccessibilityLabel("Add tag")
        field.container = self
        addSubview(field)
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(
        chips: [TagChip], enabled: Bool, onAdd: @escaping ([String]) -> Void, onRemove: @escaping (UUID) -> Void
    ) {
        while chipButtons.count > chips.count { chipButtons.removeLast().removeFromSuperview() }
        while chipButtons.count < chips.count {
            let button = TagChipButton()
            addSubview(button, positioned: .below, relativeTo: field)
            chipButtons.append(button)
        }
        for (button, chip) in zip(chipButtons, chips) {
            button.configure(chip, enabled: enabled)
            button.onRemove = { onRemove(chip.tag.id) }
            button.onApply = { onAdd([chip.tag.name]) }
        }
        field.isEnabled = enabled
        needsLayout = true
        needsDisplay = true
    }

    struct Frames: Equatable {
        var chips: [NSRect]
        var field: NSRect
        var height: CGFloat
    }
    func frames(width: CGFloat) -> Frames {
        let width = max(1, width), line = Self.chipHeight + Self.spacing
        var x: CGFloat = 0, y: CGFloat = 0, chips: [NSRect] = []
        for button in chipButtons {
            let chipWidth = min(width, button.intrinsicContentSize.width)
            if x > 0 && x + chipWidth > width { x = 0; y += line }
            chips.append(NSRect(x: x, y: y, width: chipWidth, height: Self.chipHeight))
            x += chipWidth + Self.spacing
        }
        if x > 0 && width - x < Self.fieldMinWidth { x = 0; y += line }
        let fieldHeight = ceil(field.intrinsicContentSize.height)
        let fieldRect = NSRect(
            x: x, y: y + floor((Self.chipHeight - fieldHeight) / 2), width: max(1, width - x), height: fieldHeight)
        return Frames(chips: chips, field: fieldRect, height: y + Self.chipHeight + Self.bottomInset + 1)
    }
    func measuredHeight(width: CGFloat) -> CGFloat { frames(width: width).height }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: frames(width: bounds.width).height)
    }

    override func layout() {
        super.layout()
        let frames = frames(width: bounds.width)
        for (button, frame) in zip(chipButtons, frames.chips) { button.frame = frame }
        field.frame = frames.field
    }
    /// The single hairline under the chips and field.
    override func draw(_ dirtyRect: NSRect) {
        let scale = window?.backingScaleFactor ?? 2
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.maxY - 1 / scale, width: bounds.width, height: 1 / scale).fill()
    }
    func editingChanged() {
        if let editor = field.currentEditor() as? NSTextView { editor.scrollRangeToVisible(editor.selectedRange()) }
        noteFocusRingMaskChanged()
        needsDisplay = true
    }
    /// The native focus ring surrounds the whole tag area, and only while typing.
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        if field.currentEditor() != nil { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
    }
}

/// An applied tag: a `SilkwebSelection` capsule with sage text and a quiet ×. Mixed (only some selected
/// documents carry it) draws a dashed sage outline instead; clicking its name applies it to all of them.
/// Pressing the button (× click, Space, VoiceOver) removes the tag from every selected document.
final class TagChipButton: NSButton {
    static let removeWidth: CGFloat = 18
    var onRemove: (() -> Void)?
    var onApply: (() -> Void)?
    private(set) var name = ""
    private(set) var mixed = false
    private var hovering = false
    private var tracking: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setButtonType(.momentaryChange)
        isBordered = false
        font = .systemFont(ofSize: 12)
        focusRingType = .exterior
        target = self; action = #selector(remove(_:))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ chip: TagChip, enabled: Bool) {
        name = chip.tag.name
        mixed = chip.mixed
        title = chip.tag.name
        isEnabled = enabled
        setAccessibilityLabel("Tag \(chip.tag.name), remove")
        setAccessibilityValue(chip.mixed ? "applied to some selected documents" : "applied")
        setAccessibilityHelp("Removes this tag")
        setAccessibilityCustomActions(
            chip.mixed && enabled
                ? [
                    NSAccessibilityCustomAction(name: "Apply to All Selected Documents") { [weak self] in
                        self?.onApply?(); return true
                    }
                ] : [])
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }
    @objc private func remove(_ sender: NSButton) { onRemove?() }

    var titleWidth: CGFloat { ceil((title as NSString).size(withAttributes: [.font: font!]).width) }
    override var intrinsicContentSize: NSSize {
        NSSize(width: titleWidth + 9 + (isEnabled ? Self.removeWidth : 9), height: TagChipContainer.chipHeight)
    }
    /// The × target: the chip's trailing 18 pt.
    var removeRect: NSRect {
        isEnabled
            ? NSRect(x: bounds.maxX - Self.removeWidth, y: bounds.minY, width: Self.removeWidth, height: bounds.height)
            : .zero
    }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        if removeRect.contains(convert(event.locationInWindow, from: nil)) {
            super.mouseDown(with: event)
        } else if mixed {
            onApply?()
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(next); tracking = next
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        if !isEnabled { NSGraphicsContext.current?.cgContext.setAlpha(0.5) }
        let radius = bounds.height / 2
        let capsule = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: radius - 0.5, yRadius: radius - 0.5)
        if mixed {
            capsule.lineWidth = 1
            capsule.setLineDash([3, 2], count: 2, phase: 0)
            NSColor.silkwebAccent.setStroke(); capsule.stroke()
        } else {
            NSColor.silkwebSelection.withAlphaComponent(isHighlighted ? 0.7 : 1).setFill(); capsule.fill()
        }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font!, .foregroundColor: NSColor.silkwebAccent, .paragraphStyle: paragraph,
        ]
        let height = (title as NSString).size(withAttributes: attributes).height
        let trailing = isEnabled ? Self.removeWidth : 9
        (title as NSString).draw(
            in: NSRect(
                x: 9, y: (bounds.height - height) / 2, width: max(0, bounds.width - 9 - trailing), height: height),
            withAttributes: attributes)
        if isEnabled {
            // A stroked × keeps the label colour's own translucency in light and dark.
            let size: CGFloat = 6, cross = NSBezierPath()
            let box = NSRect(x: bounds.maxX - 8 - size, y: (bounds.height - size) / 2, width: size, height: size)
            cross.move(to: NSPoint(x: box.minX, y: box.minY)); cross.line(to: NSPoint(x: box.maxX, y: box.maxY))
            cross.move(to: NSPoint(x: box.minX, y: box.maxY)); cross.line(to: NSPoint(x: box.maxX, y: box.minY))
            cross.lineWidth = 1.25; cross.lineCapStyle = .round
            (hovering || isHighlighted ? NSColor.secondaryLabelColor : .tertiaryLabelColor).setStroke()
            cross.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
    }
}

/// The “Add tag…” field. Requests issued before SwiftUI attaches the field are fulfilled once it has a window.
final class TagInputField: NSTextField {
    weak var container: TagChipContainer?
    var completionRows: [NSButton] = []
    var completionIndex = 0
    let completionPanel = NSPanel(
        contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        container?.editingChanged()
    }
    override func textDidEndEditing(_ notification: Notification) {
        dismissCompletions()
        super.textDidEndEditing(notification)
        container?.editingChanged()
    }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        container?.editingChanged()
        return result
    }
    var requestedFocus = 0
    private(set) var fulfilledFocus = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissCompletions() }
        focusIfNeeded()
    }
    func focusIfNeeded() {
        guard requestedFocus > fulfilledFocus, let window else { return }
        fulfilledFocus = requestedFocus
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.window === window else { return }
            window?.makeFirstResponder(self)
            if let editor = self.currentEditor() as? NSTextView {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }
}

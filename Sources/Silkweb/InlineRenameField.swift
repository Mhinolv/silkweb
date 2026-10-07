import AppKit
import SwiftUI

/// Shared native field for sidebar and document rows. Validation never writes to disk.
/// Return, Tab and focus leaving the field commit a changed, valid name (#106); Escape and removal cancel.
final class RenameNameField: NSTextField, NSTextFieldDelegate {
    var validate: ((String) async -> String?)?
    /// The new name, or nil to keep the old one. `clickedAway` is true when focus left the field, so the
    /// caller must leave first responder where the user put it.
    var finish: ((_ value: String?, _ clickedAway: Bool) -> Void)?
    private var validationTask: Task<Void, Never>?
    private var message: String?
    private let feedback = NSPopover()
    /// Invalid click-away feedback outlives the field, so it is anchored to the row; one at a time.
    private static let rowFeedback = NSPopover()
    private let original: String
    private var finished = false
    private var started = false
    private var detached = false

    init(name: String) {
        original = name
        super.init(frame: .zero)
        stringValue = name
        delegate = self
        isEditable = true
        isSelectable = true
        isBezeled = true
        focusRingType = .default
        setAccessibilityLabel("Name")
        let controller = NSViewController()
        controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
        feedback.contentViewController = controller
        feedback.behavior = .applicationDefined
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A reload or library switch removes the field; that is not the user moving on, so it cancels.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, window != nil { detached = true }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started else { return }
        started = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            // selectText starts editing itself. Calling makeFirstResponder first
            // ends that first edit when selectText restarts it, cancelling rename.
            self.selectText(nil)
        }
    }

    func controlTextDidChange(_ notification: Notification) { check() }

    private func check() {
        validationTask?.cancel()
        let value = stringValue
        validationTask = Task { [weak self] in
            guard let self else { return }
            let error = await validate?(value)
            guard !Task.isCancelled, !finished, stringValue == value else { return }
            show(error)
        }
    }

    private func show(_ error: String?) {
        message = error
        wantsLayer = true
        layer?.borderWidth = error == nil ? 0 : 1
        layer?.borderColor = NSColor.systemRed.cgColor
        feedback.close()
        guard let error else { return }
        Self.fill(feedback, with: error)
        if window != nil { feedback.show(relativeTo: bounds, of: self, preferredEdge: .maxY) }
        announce(error)
    }

    /// After an invalid click-away the field closes, so the message appears under its row instead.
    private func showOnRow(_ error: String) {
        var row = superview
        while let view = row, !(view is NSTableRowView) { row = view.superview }
        guard let anchor = row ?? superview, anchor.window != nil else { return }
        let popover = Self.rowFeedback
        popover.close()
        popover.behavior = .transient
        if popover.contentViewController == nil {
            let controller = NSViewController()
            controller.view = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
            popover.contentViewController = controller
        }
        Self.fill(popover, with: error)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        announce(error)
    }

    private static func fill(_ popover: NSPopover, with error: String) {
        let label = NSTextField(wrappingLabelWithString: error)
        label.textColor = .systemRed
        label.frame = NSRect(x: 12, y: 8, width: 256, height: 44)
        popover.contentViewController?.view.subviews.forEach { $0.removeFromSuperview() }
        popover.contentViewController?.view.addSubview(label)
    }

    private func announce(_ error: String) {
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            end(nil)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)):
            commit()
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard !finished else { return }
        // A reload ends editing before it removes the field, so decide once the current event has settled.
        // The block keeps the field alive so a removed field still ends its rename session.
        DispatchQueue.main.async { [self] in
            guard !finished else { return }
            if detached || window == nil || !isEnabled { end(nil) } else { commit(clickedAway: true) }
        }
    }

    /// An invalid name keeps the field open after Return or Tab; after a click-away the old name stays.
    private func commit(clickedAway: Bool = false) {
        validationTask?.cancel()
        let value = stringValue
        guard value.trimmingCharacters(in: .whitespacesAndNewlines) != original else {
            return end(nil, clickedAway: clickedAway)
        }
        validationTask = Task { [weak self] in
            guard let self else { return }
            let error = await validate?(value)
            guard !Task.isCancelled, !finished, stringValue == value else { return }
            if let error, clickedAway {
                end(nil, clickedAway: true)
                showOnRow(error)
            } else if let error {
                show(error)
                NSSound.beep()
            } else {
                end(value, clickedAway: clickedAway)
            }
        }
    }

    private func end(_ value: String?, clickedAway: Bool = false) {
        guard !finished else { return }
        finished = true
        feedback.close()
        finish?(value, clickedAway)
    }
}

struct InlineRenameField: NSViewRepresentable {
    let item: LibraryRename
    let workspace: LibraryWorkspace
    func makeNSView(context: Context) -> RenameNameField {
        let field = RenameNameField(name: item.name)
        field.validate = { await workspace.validateRename(item, value: $0) }
        field.finish = { workspace.finishRename(item, value: $0, clickedAway: $1) }
        return field
    }
    func updateNSView(_ view: RenameNameField, context: Context) { view.isEnabled = !workspace.mutating }
}

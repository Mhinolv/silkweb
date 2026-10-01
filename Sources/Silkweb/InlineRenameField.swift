import AppKit
import SwiftUI

/// Shared native field for sidebar and document rows. Validation never writes to disk.
final class RenameNameField: NSTextField, NSTextFieldDelegate {
    var validate: ((String) async -> String?)?
    var finish: ((String?) -> Void)?
    private var validationTask: Task<Void, Never>?
    private var message: String?
    private let feedback = NSPopover()
    private var finished = false
    private var started = false

    init(name: String) {
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !started else { return }
        started = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.finished else { return }
            self.window?.makeFirstResponder(self)
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
        let label = NSTextField(wrappingLabelWithString: error)
        label.textColor = .systemRed
        label.frame = NSRect(x: 12, y: 8, width: 256, height: 44)
        feedback.contentViewController?.view.subviews.forEach { $0.removeFromSuperview() }
        feedback.contentViewController?.view.addSubview(label)
        if window != nil { feedback.show(relativeTo: bounds, of: self, preferredEdge: .maxY) }
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: error, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            complete(nil)
        case #selector(NSResponder.insertNewline(_:)):
            commit(clickingAway: false)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            complete(nil)
        default: return false
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if !finished { commit(clickingAway: true) }
    }

    private func commit(clickingAway: Bool) {
        validationTask?.cancel()
        let value = stringValue
        validationTask = Task { [weak self] in
            guard let self else { return }
            let error = await validate?(value)
            guard !Task.isCancelled, !finished, stringValue == value else { return }
            if let error {
                if clickingAway { complete(nil) }
                else { show(error); NSSound.beep() }
            } else { complete(value) }
        }
    }

    private func complete(_ value: String?) {
        guard !finished else { return }
        finished = true
        feedback.close()
        finish?(value)
    }
}

struct InlineRenameField: NSViewRepresentable {
    let item: LibraryRename
    let workspace: LibraryWorkspace
    func makeNSView(context: Context) -> RenameNameField {
        let field = RenameNameField(name: item.name)
        field.validate = { await workspace.validateRename(item, value: $0) }
        field.finish = { workspace.finishRename(item, value: $0) }
        return field
    }
    func updateNSView(_ view: RenameNameField, context: Context) { view.isEnabled = !workspace.mutating }
}

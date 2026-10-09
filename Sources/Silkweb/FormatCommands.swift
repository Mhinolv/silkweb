import AppKit
import SilkwebCore
import SwiftUI

@MainActor @Observable final class FormattingTarget {
    static let shared = FormattingTarget()
    // Commands only read `enabled`; focus changes and unchanged refreshes (every
    // keystroke/updateNSView) must not invalidate the menu bar (silkweb-1.58).
    @ObservationIgnored weak var editor: PlainMarkdownTextView?
    private(set) var enabled = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        // Another window (Settings) becoming key does not resign the editor; resample then (#104). A library
        // window coming back keeps its editor first responder without a new `becomeFirstResponder`, so its
        // editor becomes the target again (#194).
        observers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                MainActor.assumeIsolated {
                    if notification.name == NSWindow.didBecomeKeyNotification,
                        let editor = (notification.object as? NSWindow)?.firstResponder as? PlainMarkdownTextView
                    {
                        self?.editor = editor
                    }
                    self?.refresh()
                }
            }
        }
    }

    /// Same rule as the editor's own Format submenu: its key window's first responder (#104).
    func refresh() {
        let next =
            editor.map {
                $0.window?.isKeyWindow == true && $0.window?.firstResponder === $0 && $0.isEditable
                    && !$0.hasMarkedText()
            } == true
        if enabled != next { enabled = next }
    }

    /// Menu actions re-check live state: key equivalents can fire before a stale `enabled` publishes.
    func perform(_ action: (PlainMarkdownTextView) -> Void) {
        refresh()
        if enabled, let editor { action(editor) }
    }
}

struct FormatItem {
    let command: MarkdownCommand
    let key: String
    let modifiers: NSEvent.ModifierFlags
    static let groups: [[FormatItem]] = [
        [
            .init(command: .bold, key: "b", modifiers: .command),
            .init(command: .italic, key: "i", modifiers: .command),
            .init(command: .strike, key: "x", modifiers: [.command, .shift]),
            .init(command: .inlineCode, key: "c", modifiers: [.command, .control]),
        ],
        [.init(command: .link, key: "k", modifiers: .command)],
        (1...6).map { .init(command: .heading($0), key: "\($0)", modifiers: [.command, .control]) } + [
            .init(command: .heading(0), key: "0", modifiers: [.command, .control])
        ],
        [
            .init(command: .quote, key: "'", modifiers: .command),
            .init(command: .bullet, key: "u", modifiers: [.command, .option]),
            .init(command: .numbered, key: "o", modifiers: [.command, .option]),
            .init(command: .task, key: "x", modifiers: [.command, .option]),
            .init(command: .codeBlock, key: "c", modifiers: [.command, .shift, .control]),
        ],
        [
            .init(command: .indent, key: "]", modifiers: .command),
            .init(command: .outdent, key: "[", modifiers: .command),
        ],
    ]
    var title: String {
        if case .heading(let level) = command { return level == 0 ? "Body Text" : "Heading \(level)" }
        return command.name
    }
    var swiftModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}

struct FormatCommands: Commands {
    private let target = FormattingTarget.shared
    var body: some Commands {
        CommandGroup(replacing: .textFormatting) {
            ForEach(Array(FormatItem.groups.enumerated()), id: \.offset) { index, group in
                if index > 0 { Divider() }
                if index == 2 { Menu("Heading") { items(group) } } else { items(group) }
                if index == 1 {
                    Button("Image…") { target.perform { $0.assetHandler.chooseImages() } }
                        .keyboardShortcut("i", modifiers: [.control, .command])
                        .disabled(!target.enabled)
                }
            }
            Button("Insert Table…") { target.perform { $0.showTableInsertSheet() } }
                .keyboardShortcut("t", modifiers: [.control, .command])
                .disabled(!target.enabled)
        }
    }
    @ViewBuilder private func items(_ group: [FormatItem]) -> some View {
        ForEach(Array(group.enumerated()), id: \.offset) { _, item in
            Button(item.title) { target.perform { $0.format(item.command) } }
                .keyboardShortcut(KeyEquivalent(Character(item.key)), modifiers: item.swiftModifiers)
                .disabled(!target.enabled)
        }
    }
}

extension PlainMarkdownTextView {
    func format(_ command: MarkdownCommand) {
        guard isEditable, !hasMarkedText() else { return }
        apply(
            MarkdownEditing.edit(
                command, text: string, selection: selectedRange(),
                clipboard: command == .link ? NSPasteboard.general.string(forType: .string) : nil,
                indent: style.indent.text), name: command.name)
    }

    func apply(_ edit: MarkdownEdit, name: String) {
        guard isEditable, !hasMarkedText(), let storage = textStorage else { return }
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        defer { undoManager?.endUndoGrouping(); breakUndoCoalescing() }
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        setSelectedRange(edit.selection)
        undoManager?.setActionName(name)
    }

    @objc func performFormat(_ sender: NSMenuItem) {
        if let item = sender.representedObject as? FormatMenuAction { format(item.command) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let formatMenu = NSMenu(title: "Format")
        for (index, group) in FormatItem.groups.enumerated() {
            if index > 0 { formatMenu.addItem(.separator()) }
            let destination: NSMenu
            if index == 2 {
                let heading = NSMenuItem(title: "Heading", action: nil, keyEquivalent: "")
                destination = NSMenu(title: "Heading")
                heading.submenu = destination
                formatMenu.addItem(heading)
            } else {
                destination = formatMenu
            }
            for item in group {
                let entry = NSMenuItem(title: item.title, action: #selector(performFormat(_:)), keyEquivalent: item.key)
                entry.keyEquivalentModifierMask = item.modifiers
                entry.target = self
                entry.representedObject = FormatMenuAction(item.command)
                destination.addItem(entry)
            }
        }
        let table = NSMenuItem(title: "Insert Table…", action: #selector(showTableInsertSheet(_:)), keyEquivalent: "t")
        table.keyEquivalentModifierMask = [.control, .command]
        table.target = self
        formatMenu.addItem(table)
        let parent = NSMenuItem(title: "Format", action: nil, keyEquivalent: "")
        parent.submenu = formatMenu
        menu.addItem(.separator())
        menu.addItem(parent)
        return menu
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performFormat(_:)) || menuItem.action == #selector(showTableInsertSheet(_:)) {
            return window?.firstResponder === self && isEditable && !hasMarkedText()
        }
        return super.validateMenuItem(menuItem)
    }
}

private final class FormatMenuAction: NSObject {
    let command: MarkdownCommand
    init(_ command: MarkdownCommand) { self.command = command }
}

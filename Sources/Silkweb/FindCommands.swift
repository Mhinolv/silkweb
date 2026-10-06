import AppKit
import SwiftUI

struct FindMenu: View {
    let workspace: LibraryWorkspace
    let state: MenuCommandValues

    var body: some View {
        Menu("Find") {
            Button("Find…") { workspace.find(.showFindInterface) }.keyboardShortcut("f").disabled(!state.canFind)
            Button("Find and Replace…") { workspace.find(.showReplaceInterface) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!state.canReplace)
            Button("Find Next") { workspace.find(.nextMatch) }.keyboardShortcut("g").disabled(!state.canFind)
            Button("Find Previous") { workspace.find(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!state.canFind)
            Button("Use Selection for Find") { workspace.find(.setSearchString) }.keyboardShortcut("e").disabled(
                !state.canFind)
            Button("Jump to Selection") { workspace.jumpToSelection() }.keyboardShortcut("j").disabled(!state.canFind)
            Divider()
            Button("Search Library…") { workspace.search.focusRequest += 1 }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!state.hasLibrary)
        }
    }
}

extension LibraryWorkspace {
    var canFind: Bool { editor.url != nil && !editor.loading && preview.mode != .preview }

    func find(_ action: NSTextFinder.Action) {
        guard canFind, let text = preview.editor else { return }
        if action == .showReplaceInterface && editor.readOnly { return }
        // Route directly to the document even when a sidebar, list, or find field has focus.
        if action == .showFindInterface || action == .showReplaceInterface {
            text.window?.makeFirstResponder(text)
        }
        text.find(action)
    }

    func jumpToSelection() {
        guard canFind, let text = preview.editor else { return }
        text.window?.makeFirstResponder(text)
        text.scrollRangeToVisible(text.selectedRange())
        text.writingModes.anchorCaret()
    }
}

extension PlainMarkdownTextView {
    func find(_ action: NSTextFinder.Action) {
        if action == .showFindInterface || action == .showReplaceInterface, selectedRange().length > 0 {
            find(.setSearchString)
        }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag
        let replacesAll =
            tag == NSTextFinder.Action.replaceAll.rawValue || tag == NSTextFinder.Action.replaceAllInSelection.rawValue
        if replacesAll {
            breakUndoCoalescing()
            undoManager?.beginUndoGrouping()
        }
        super.performTextFinderAction(sender)
        if replacesAll {
            undoManager?.setActionName("Replace All")
            undoManager?.endUndoGrouping()
            breakUndoCoalescing()
        }
    }

    override func showFindIndicator(for charRange: NSRange) {
        // Match navigation uses the same anchor as outline navigation: upper third, or Typewriter's 40%.
        writingModes.reveal(charRange.location)
        super.showFindIndicator(for: charRange)
    }
}

/// Keep AppKit's native bar and layout; only supply document focus after dismissal.
final class EditorScrollView: NSScrollView {
    override var isFindBarVisible: Bool {
        didSet {
            if oldValue && !isFindBarVisible, let text = documentView as? NSTextView {
                window?.makeFirstResponder(text)
            }
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if isFindBarVisible { isFindBarVisible = false } else { super.cancelOperation(sender) }
    }

    /// AppKit keeps clicks in the content insets for the scroll view itself. Typewriter's insets
    /// (1.27) are overscroll, not chrome, and cover all but a band around the caret line, so clicks
    /// there go to the text as they do with the mode off (#89). Scrollers and the find bar still win.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit === self, let document = documentView else { return hit }
        let local = contentView.convert(point, from: superview)
        guard contentView.bounds.contains(local) else { return hit }
        // Above the first line or below the last, the text view still places the caret.
        return document.hitTest(local) ?? document
    }
}

import AppKit
import SwiftUI

struct FindMenu: View {
    let workspace: LibraryWorkspace

    var body: some View {
        Menu("Find") {
            Button("Find…") { workspace.find(.showFindInterface) }.keyboardShortcut("f").disabled(!workspace.canFind)
            Button("Find and Replace…") { workspace.find(.showReplaceInterface) }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!workspace.canFind || workspace.editor.readOnly)
            Button("Find Next") { workspace.find(.nextMatch) }.keyboardShortcut("g").disabled(!workspace.canFind)
            Button("Find Previous") { workspace.find(.previousMatch) }
                .keyboardShortcut("g", modifiers: [.command, .shift]).disabled(!workspace.canFind)
            Button("Use Selection for Find") { workspace.find(.setSearchString) }.keyboardShortcut("e").disabled(!workspace.canFind)
            Button("Jump to Selection") { workspace.jumpToSelection() }.keyboardShortcut("j").disabled(!workspace.canFind)
            Divider()
            Button("Search Library…") { workspace.search.focusRequest += 1 }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(workspace.snapshot == nil)
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
    }
}

extension PlainMarkdownTextView {
    func find(_ action: NSTextFinder.Action) {
        if (action == .showFindInterface || action == .showReplaceInterface), selectedRange().length > 0 {
            find(.setSearchString)
        }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        performTextFinderAction(sender)
    }

    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag
        let replacesAll = tag == NSTextFinder.Action.replaceAll.rawValue || tag == NSTextFinder.Action.replaceAllInSelection.rawValue
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
        // Match navigation uses the same upper-third anchor as outline navigation.
        if let layout = layoutManager, textContainer != nil,
           let scroll = enclosingScrollView, charRange.location < string.utf16.count {
            layout.ensureLayout(forCharacterRange: charRange)
            let glyph = layout.glyphIndexForCharacter(at: charRange.location)
            let rect = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, rect.minY + textContainerOrigin.y - scroll.contentSize.height / 3)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
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
        if isFindBarVisible { isFindBarVisible = false }
        else { super.cancelOperation(sender) }
    }
}

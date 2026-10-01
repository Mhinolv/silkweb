import AppKit
import SilkwebCore

/// Keeps paragraph fence checkpoints. Edits restyle their paragraphs, then propagate only
/// while fence state changes. Attribute-only changes never trigger another styling pass.
@MainActor final class MarkdownStyler: NSObject, @preconcurrency NSTextStorageDelegate {
    weak var editor: PlainMarkdownTextView?
    private var checkpoints: [Int: Bool] = [:]
    private var dirty: NSRange?
    private var scheduled = false
    private(set) var lastStyledRange = NSRange(location: 0, length: 0)

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let oldEnd = NSMaxRange(editedRange) - delta
        var shifted: [Int: Bool] = [:]
        for (location, state) in checkpoints {
            if location <= editedRange.location { shifted[location] = state }
            else if location >= oldEnd, location + delta > editedRange.location { shifted[location + delta] = state }
        }
        checkpoints = shifted
        if let previous = dirty {
            // Multiple edits before the coalesced pass: conservatively include their bounds.
            dirty = NSUnionRange(previous, editedRange)
        } else { dirty = editedRange }
        schedule()
    }

    func schedule() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.restyle()
        }
    }

    func restyle() {
        guard let editor, let storage = editor.textStorage, let pending = dirty else { return }
        guard !editor.hasMarkedText() else { return }
        dirty = nil
        let source = storage.string as NSString
        let start = source.lineRange(for: NSRange(location: min(pending.location, source.length), length: 0)).location
        var position = start
        var fenced = checkpoints[start] ?? false
        // Missing checkpoints (load or merged paragraphs) require propagating from a known start.
        if checkpoints[start] == nil, start > 0 {
            position = checkpoints.keys.filter { $0 < start }.max() ?? 0
            fenced = checkpoints[position] ?? false
        }
        let styledStart = position
        let base = NSFont.systemFont(ofSize: editor.style.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = editor.style.lineHeight
        let defaults: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
        let undoRegistration = editor.undoManager?.isUndoRegistrationEnabled == true
        if undoRegistration { editor.undoManager?.disableUndoRegistration() }
        storage.beginEditing()
        repeat {
            let range = source.lineRange(for: NSRange(location: position, length: 0))
            checkpoints[position] = fenced
            let result = MarkdownTokens.paragraph(source.substring(with: range), fenced: fenced)
            if range.length > 0 {
                storage.setAttributes(defaults, range: range)
                for token in result.tokens {
                    let tokenRange = NSRange(location: position + token.range.location, length: token.range.length)
                    switch token.kind {
                    case .marker: storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: tokenRange)
                    case .heading(let level):
                        let scales: [CGFloat] = [1.6, 1.35, 1.15, 1, 1, 1]
                        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: editor.style.fontSize * scales[level - 1], weight: .semibold), range: tokenRange)
                    case .bold, .italic:
                        storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: tokenRange)
                        storage.enumerateAttribute(.font, in: tokenRange) { value, subrange, _ in
                            let font = value as? NSFont ?? base
                            let trait: NSFontTraitMask = token.kind == .bold ? .boldFontMask : .italicFontMask
                            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: subrange)
                        }
                    case .strike:
                        storage.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor], range: tokenRange)
                    case .code:
                        storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: editor.style.fontSize * 0.92, weight: .regular), .backgroundColor: NSColor.quaternarySystemFill], range: tokenRange)
                    case .link: storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: tokenRange)
                    case .quote: storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: tokenRange)
                    }
                }
            }
            let next = NSMaxRange(range)
            let stable = checkpoints[next] == result.fenced
            fenced = result.fenced
            position = next
            if range.length == 0 || position >= source.length { break }
            if position > NSMaxRange(pending), stable { break }
        } while true
        storage.endEditing()
        if undoRegistration { editor.undoManager?.enableUndoRegistration() }
        editor.typingAttributes = defaults
        lastStyledRange = NSRange(location: styledStart, length: position - styledStart)
    }

    func reload() {
        checkpoints = [:]
        dirty = NSRange(location: 0, length: editor?.textStorage?.length ?? 0)
        restyle()
    }
}

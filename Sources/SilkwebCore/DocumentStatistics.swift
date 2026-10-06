import Foundation

/// Live word and character counts for the status bar (silkweb-1.25), measured on the
/// reader-visible text: Markdown markers, link and image destinations, images, raw HTML
/// and code-fence backticks are stripped before counting.
public struct DocumentStatistics: Equatable, Sendable {
    public var words: Int
    public var characters: Int

    public init(words: Int = 0, characters: Int = 0) {
        self.words = words
        self.characters = characters
    }

    public static let zero = DocumentStatistics()

    /// Counts a Markdown source (a whole document or a selected substring).
    public static func count(_ markdown: String) -> DocumentStatistics {
        guard !markdown.isEmpty else { return .zero }
        return measure(visibleText(markdown))
    }

    /// Counts plain text as is. Words: letter/number runs (apostrophes and periods inside a word,
    /// commas and periods inside a number, and `_` join), each CJK ideograph, kana or Hangul
    /// syllable, and each emoji. Characters: grapheme clusters including spaces, excluding line breaks.
    public static func measure(_ text: String) -> DocumentStatistics {
        var words = 0, characters = 0
        var inWord = false
        var lastWasDigit = false
        // A joiner seen inside a word; it only joins when the next character continues the word.
        var pendingJoiner: Character?
        for character in text {
            if character.isNewline { inWord = false; pendingJoiner = nil; continue }
            characters += 1
            if isCJK(character) || isEmoji(character) {
                words += 1
                inWord = false; pendingJoiner = nil
                continue
            }
            if isWordCharacter(character) {
                let digit = character.isNumber
                if inWord, let joiner = pendingJoiner {
                    let joins =
                        digit && lastWasDigit
                        ? numberJoiners.contains(joiner) : letterJoiners.contains(joiner) && !digit && !lastWasDigit
                    if !joins { words += 1 }
                } else if !inWord {
                    words += 1
                }
                inWord = true; lastWasDigit = digit; pendingJoiner = nil
                continue
            }
            if inWord, pendingJoiner == nil, letterJoiners.contains(character) || numberJoiners.contains(character) {
                pendingJoiner = character
                continue
            }
            inWord = false; pendingJoiner = nil
        }
        return DocumentStatistics(words: words, characters: characters)
    }

    private static let letterJoiners: Set<Character> = ["'", "’", ".", "·"]
    private static let numberJoiners: Set<Character> = [",", ".", "'", "’"]

    private static func isWordCharacter(_ character: Character) -> Bool {
        if character == "_" { return true }
        guard let first = character.unicodeScalars.first else { return false }
        return first.properties.isAlphabetic || first.properties.numericType != nil
    }

    static func isCJK(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F: return true // kana
        case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: return true // Hangul
        case 0x3005, 0x3007: return true // 々 〇
        default: return scalar.properties.isIdeographic
        }
    }

    static func isEmoji(_ character: Character) -> Bool {
        let scalars = character.unicodeScalars
        guard let first = scalars.first, first.properties.isEmoji else { return false }
        // Digits, # and * are emoji-capable but read as text unless styled (keycaps, FE0F).
        return first.properties.isEmojiPresentation || scalars.count > 1
    }

    /// The text a reader sees, one block per line.
    public static func visibleText(_ markdown: String) -> String {
        let document = MarkdownParser.parse(markdown)
        var lines: [String] = []
        append(document.blocks, to: &lines)
        for key in document.footnotes.keys.sorted() {
            lines.append(inlineText(document.footnotes[key] ?? []))
        }
        return lines.joined(separator: "\n")
    }

    private static func append(_ blocks: [MarkdownBlock], to lines: inout [String]) {
        for block in blocks {
            switch block {
            case .paragraph(let children), .heading(_, let children):
                lines.append(inlineText(children))
            case .code(_, let text):
                lines.append(text)
            case .quote(let children), .taskItem(_, let children):
                append(children, to: &lines)
            case .list(_, let items):
                for item in items { append(item, to: &lines) }
            case .table(let header, _, let rows):
                for row in [header] + rows {
                    lines.append(row.map(inlineText).joined(separator: " "))
                }
            case .thematicBreak, .tableOfContents:
                continue
            }
        }
    }

    private static func inlineText(_ inlines: [MarkdownInline]) -> String {
        inlines.map { inline -> String in
            switch inline {
            case .text(let text), .code(let text): return text
            case .emphasis(let children), .strong(let children), .strikethrough(let children),
                .link(let children, _, _):
                return inlineText(children)
            case .image, .rawHTML, .footnoteReference: return ""
            case .softBreak, .hardBreak: return "\n"
            }
        }.joined()
    }
}

/// Status-bar copy for document statistics (silkweb-1.25).
public enum DocumentStatisticsPresentation {
    /// `1,204 words · 6,830 characters`, or `38 of 1,204 words · 212 of 6,830 characters` for a selection.
    /// Without characters (narrow widths): `1,204 words` / `38 of 1,204 words`.
    public static func label(
        document: DocumentStatistics, selection: DocumentStatistics? = nil,
        includesCharacters: Bool = true
    ) -> String {
        var parts = [segment(document.words, selection?.words, unit: "word")]
        if includesCharacters { parts.append(segment(document.characters, selection?.characters, unit: "character")) }
        return parts.joined(separator: " · ")
    }

    /// VoiceOver value: `1,204 words, 6,830 characters` or `Selection: 38 of 1,204 words, 212 of 6,830 characters`.
    public static func accessibilityValue(document: DocumentStatistics, selection: DocumentStatistics? = nil) -> String
    {
        let value =
            segment(document.words, selection?.words, unit: "word") + ", "
            + segment(document.characters, selection?.characters, unit: "character")
        return selection == nil ? value : "Selection: " + value
    }

    private static func segment(_ total: Int, _ part: Int?, unit: String) -> String {
        let noun = unit + (total == 1 ? "" : "s")
        if let part { return "\(part.formatted()) of \(total.formatted()) \(noun)" }
        return "\(total.formatted()) \(noun)"
    }
}

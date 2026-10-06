import Foundation

public enum MarkdownCommand: Equatable {
    case bold, italic, strike, inlineCode, link, heading(Int), quote, bullet, numbered, task, codeBlock, indent, outdent
    public var name: String {
        switch self {
        case .bold: return "Bold"
        case .italic: return "Italic"
        case .strike: return "Strikethrough"
        case .inlineCode: return "Inline Code"
        case .link: return "Link"
        case .heading: return "Heading"
        case .quote: return "Quote"
        case .bullet: return "Bulleted List"
        case .numbered: return "Numbered List"
        case .task: return "Task List"
        case .codeBlock: return "Code Block"
        case .indent: return "Shift Right"
        case .outdent: return "Shift Left"
        }
    }
}

public struct MarkdownEdit {
    public let range: NSRange
    public let replacement: String
    public let selection: NSRange
    public func applying(to text: String) -> String {
        (text as NSString).replacingCharacters(in: range, with: replacement)
    }
}

public enum MarkdownEditing {
    private static let listExpression = try! NSRegularExpression(
        pattern: "^([ \\t]*)(?:([-*+])[ \\t]+(?:\\[([ xX])\\][ \\t]+)?|([0-9]+)([.)])[ \\t]+)")
    /// AppKit selections use UTF-16. Expand partial selections to whole graphemes.
    public static func safeRange(_ range: NSRange, in text: NSString) -> NSRange {
        let start = max(0, min(range.location, text.length))
        let length = max(0, min(range.length, text.length - start))
        if length > 0 { return text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: length)) }
        if start < text.length {
            return NSRange(location: text.rangeOfComposedCharacterSequence(at: start).location, length: 0)
        }
        return NSRange(location: start, length: 0)
    }

    public static func edit(
        _ command: MarkdownCommand, text: String, selection: NSRange, clipboard: String? = nil, indent: String = "    "
    ) -> MarkdownEdit {
        let source = text as NSString
        var range = safeRange(selection, in: source)
        let marker: String?
        switch command {
        case .bold: marker = "**";
        case .italic: marker = "*";
        case .strike: marker = "~~";
        case .inlineCode: marker = "`";
        default: marker = nil
        }
        if let marker {
            if range.length == 0, range.location < source.length {
                let word = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}\\p{M}_]+")
                let line = source.lineRange(for: range)
                if let match = word.matches(in: text, range: line).first(where: {
                    NSLocationInRange(range.location, $0.range)
                }) {
                    range = match.range
                }
            }
            let value = source.substring(with: range)
            let size = (marker as NSString).length
            func canUnwrap(around content: NSRange) -> Bool {
                guard command == .italic else { return true }
                // Even asterisk runs are bold; odd runs also carry italic emphasis.
                var start = content.location
                while start > 0, source.character(at: start - 1) == 42 { start -= 1 }
                var openingEnd = content.location
                while openingEnd < NSMaxRange(content), source.character(at: openingEnd) == 42 { openingEnd += 1 }
                var end = NSMaxRange(content)
                while end < source.length, source.character(at: end) == 42 { end += 1 }
                var closingStart = NSMaxRange(content)
                while closingStart > content.location, source.character(at: closingStart - 1) == 42 {
                    closingStart -= 1
                }
                return (openingEnd - start) % 2 == 1 && (end - closingStart) % 2 == 1
            }
            if value.hasPrefix(marker), value.hasSuffix(marker), range.length >= size * 2,
                canUnwrap(around: NSRange(location: range.location + size, length: range.length - size * 2))
            {
                let inner = (value as NSString).substring(
                    with: NSRange(location: size, length: range.length - size * 2))
                return MarkdownEdit(
                    range: range, replacement: inner,
                    selection: NSRange(location: range.location, length: (inner as NSString).length))
            }
            if range.location >= size, NSMaxRange(range) + size <= source.length,
                source.substring(with: NSRange(location: range.location - size, length: size)) == marker,
                source.substring(with: NSRange(location: NSMaxRange(range), length: size)) == marker,
                canUnwrap(around: range)
            {
                return MarkdownEdit(
                    range: NSRange(location: range.location - size, length: range.length + size * 2),
                    replacement: value, selection: NSRange(location: range.location - size, length: range.length))
            }
            return MarkdownEdit(
                range: range, replacement: marker + value + marker,
                selection: NSRange(location: range.location + size, length: range.length))
        }
        if command == .link {
            let url =
                clipboard.flatMap { URL(string: $0) }.flatMap {
                    ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil
                        ? $0.absoluteString : nil
                } ?? ""
            let value = source.substring(with: range)
            let replacement = "[\(value)](\(url))"
            let caret =
                range.length == 0
                ? range.location + 1
                : range.location + (url.isEmpty ? range.length + 3 : (replacement as NSString).length)
            return MarkdownEdit(range: range, replacement: replacement, selection: NSRange(location: caret, length: 0))
        }
        let touched = touchedLines(range, in: source)
        let value = source.substring(with: touched)
        if command == .codeBlock {
            let newline = value.hasSuffix("\n") ? "" : "\n"
            return MarkdownEdit(
                range: touched, replacement: "```\n" + value + newline + "```\n",
                selection: NSRange(location: touched.location + 3, length: 0))
        }
        var lines = value.components(separatedBy: "\n")
        let trailing = value.hasSuffix("\n")
        if trailing { lines.removeLast() }
        let prefixPattern: String
        switch command {
        case .heading: prefixPattern = "^#{1,6}[ \\t]+"
        case .quote: prefixPattern = "^> ?"
        case .bullet: prefixPattern = "^[-*+][ \\t]+(?!\\[[ xX]\\])"
        case .numbered: prefixPattern = "^[0-9]+[.)][ \\t]+"
        case .task: prefixPattern = "^[-*+][ \\t]+\\[[ xX]\\][ \\t]+"
        default: prefixPattern = "(?!)"
        }
        let regex = try! NSRegularExpression(pattern: prefixPattern)
        func parts(_ line: String) -> (String, String) {
            let whitespace = String(line.prefix { $0 == " " || $0 == "\t" })
            return (whitespace, String(line.dropFirst(whitespace.count)))
        }
        let toggle = lines.allSatisfy { line in
            let body = parts(line).1
            if case .heading(let level) = command {
                return level > 0 && body.hasPrefix(String(repeating: "#", count: min(6, level)) + " ")
            }
            return regex.firstMatch(in: body, range: NSRange(location: 0, length: (body as NSString).length)) != nil
        }
        lines = lines.enumerated().map { index, line in
            let (whitespace, body) = parts(line)
            if command == .indent { return indent + line }
            if command == .outdent {
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                // Under Tab, a space-indented level counts as one tab stop.
                let level = indent.contains("\t") ? 4 : indent.count
                return String(line.dropFirst(min(whitespace.prefix { $0 == " " }.count, level)))
            }
            let stripped: String
            if [.bullet, .numbered, .task].contains(command), let prefix = listPrefix(body) {
                stripped = (body as NSString).substring(from: NSMaxRange(prefix.range))
            } else {
                stripped = regex.stringByReplacingMatches(
                    in: body, range: NSRange(location: 0, length: (body as NSString).length), withTemplate: "")
            }
            var prefix = ""
            if !toggle {
                switch command {
                case .heading(let level): prefix = level > 0 ? String(repeating: "#", count: min(6, level)) + " " : ""
                case .quote: prefix = "> "
                case .bullet: prefix = "- "
                case .numbered: prefix = "\(index + 1). "
                case .task: prefix = "- [ ] "
                default: break
                }
            }
            return whitespace + prefix + stripped
        }
        let replacement = lines.joined(separator: "\n") + (trailing ? "\n" : "")
        let caret =
            range.length == 0
            ? max(
                touched.location,
                min(
                    touched.location + (replacement as NSString).length,
                    range.location + (replacement as NSString).length - touched.length)) : touched.location
        return MarkdownEdit(
            range: touched, replacement: replacement,
            selection: NSRange(location: caret, length: range.length == 0 ? 0 : (replacement as NSString).length))
    }

    public static func touchedLines(_ selection: NSRange, in source: NSString) -> NSRange {
        let probe = NSRange(location: selection.location, length: max(0, selection.length - 1))
        return source.lineRange(for: probe)
    }

    public static func listPrefix(_ line: String) -> (range: NSRange, next: String)? {
        let regex = listExpression
        let source = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: source.length)) else {
            return nil
        }
        let whitespace = source.substring(with: match.range(at: 1))
        if match.range(at: 4).location != NSNotFound {
            let number = Int(source.substring(with: match.range(at: 4))) ?? 0
            let next = number == Int.max ? number : number + 1
            return (match.range, whitespace + "\(next)" + source.substring(with: match.range(at: 5)) + " ")
        }
        return (
            match.range,
            whitespace + source.substring(with: match.range(at: 2))
                + (match.range(at: 3).location == NSNotFound ? " " : " [ ] ")
        )
    }

    public static func newline(text: String, selection: NSRange, plain: Bool = false) -> MarkdownEdit {
        let source = text as NSString
        let range = safeRange(selection, in: source)
        let line = source.lineRange(for: NSRange(location: range.location, length: 0))
        let before = source.substring(with: NSRange(location: line.location, length: range.location - line.location))
        if !plain, let prefix = listPrefix(before) {
            let full = source.substring(with: line).trimmingCharacters(in: .newlines)
            if range.length == 0,
                full.trimmingCharacters(in: .whitespaces) == before.trimmingCharacters(in: .whitespaces),
                (before as NSString).length == prefix.range.length
            {
                let whitespace = String(before.prefix { $0 == " " || $0 == "\t" })
                return MarkdownEdit(
                    range: NSRange(location: line.location, length: before.utf16.count), replacement: whitespace,
                    selection: NSRange(location: line.location + whitespace.utf16.count, length: 0))
            }
            let replacement = "\n" + prefix.next
            return MarkdownEdit(
                range: range, replacement: replacement,
                selection: NSRange(location: range.location + replacement.utf16.count, length: 0))
        }
        return MarkdownEdit(
            range: range, replacement: "\n", selection: NSRange(location: range.location + 1, length: 0))
    }
}

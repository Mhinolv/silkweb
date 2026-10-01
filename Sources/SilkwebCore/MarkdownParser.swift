import Foundation

/// Original, deliberately bounded parser; see docs/markdown-rendering.md for deviations.
/// No I/O or shared mutable state. Call off the main thread for full documents.
public enum MarkdownParser {
    public static let maximumNesting = 32

    public static func parse(_ source: String) -> MarkdownDocument {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return MarkdownDocument(blocks: blocks(normalized.components(separatedBy: "\n"), depth: 0))
    }

    private struct ListMarker {
        let indent: Int
        let width: Int
        let start: Int?
        let content: String
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let chars = Array(line)
        let indent = chars.prefix(while: { $0 == " " }).count
        guard indent < chars.count else { return nil }
        var end = indent
        var start: Int?
        if "-*+".contains(chars[end]) { end += 1 }
        else {
            while end < chars.count, chars[end].isASCII, chars[end].isNumber, end - indent < 9 { end += 1 }
            guard end > indent, end < chars.count, chars[end] == "." || chars[end] == ")" else { return nil }
            start = Int(String(chars[indent..<end]))
            end += 1
        }
        guard end == chars.count || chars[end] == " " || chars[end] == "\t" else { return nil }
        if end < chars.count { end += 1 }
        return ListMarker(indent: indent, width: end, start: start, content: String(chars[end...]))
    }

    private static func fence(_ line: String) -> (marker: Character, count: Int, info: String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let text = line.dropFirst(indent)
        guard let marker = text.first, marker == "`" || marker == "~" else { return nil }
        let count = text.prefix(while: { $0 == marker }).count
        guard count >= 3 else { return nil }
        let info = text.dropFirst(count).trimmingCharacters(in: .whitespaces)
        guard marker != "`" || !info.contains("`") else { return nil }
        return (marker, count, info)
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let text = line.dropFirst(indent)
        let level = text.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let rest = text.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var content = rest.trimmingCharacters(in: .whitespaces)
        let closing = content.reversed().prefix(while: { $0 == "#" }).count
        if closing > 0 {
            let before = content.dropLast(closing)
            if before.isEmpty || before.last == " " || before.last == "\t" {
                content = before.trimmingCharacters(in: .whitespaces)
            }
        }
        return (level, content)
    }

    private static func thematic(_ line: String) -> Bool {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return false }
        let chars = line.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func quoteContent(_ line: String) -> String? {
        let indent = line.prefix(while: { $0 == " " }).count
        guard indent <= 3 else { return nil }
        let text = line.dropFirst(indent)
        guard text.first == ">" else { return nil }
        var content = text.dropFirst()
        if content.first == " " { content = content.dropFirst() }
        return String(content)
    }

    private static func unsupported(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), trimmed.contains("]:") { return true }
        if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") { return true }
        if let marker = listMarker(line) {
            return ["[ ]", "[x]", "[X]"].contains { marker.content.hasPrefix($0) }
        }
        return false
    }

    private static func beginsBlock(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty || heading(line) != nil || fence(line) != nil
            || thematic(line) || quoteContent(line) != nil || listMarker(line) != nil || unsupported(line)
    }

    private static func blocks(_ lines: [String], depth: Int) -> [MarkdownBlock] {
        guard depth < maximumNesting else {
            return [.paragraph([.text(lines.joined(separator: "\n"))])]
        }
        var result: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            if unsupported(line) {
                result.append(.paragraph([.text(line)])); index += 1
            } else if let opener = fence(line) {
                index += 1
                var content: [String] = []
                var closed = false
                while index < lines.count {
                    if let closer = fence(lines[index]), closer.marker == opener.marker,
                       closer.count >= opener.count, closer.info.isEmpty { closed = true; index += 1; break }
                    content.append(lines[index]); index += 1
                }
                // Source split includes a terminal empty line, which already represents a final newline.
                let code = content.joined(separator: "\n")
                let text = content.isEmpty || (!closed && content.last == "") ? code : code + "\n"
                result.append(.code(language: opener.info.isEmpty ? nil : opener.info, text: text))
            } else if let (level, content) = heading(line) {
                result.append(.heading(level: level, content: parseInline(content))); index += 1
            } else if thematic(line) {
                result.append(.thematicBreak); index += 1
            } else if quoteContent(line) != nil {
                var content: [String] = []
                while index < lines.count, let quoted = quoteContent(lines[index]) {
                    content.append(quoted); index += 1
                }
                result.append(.quote(blocks(content, depth: depth + 1)))
            } else if let first = listMarker(line), first.indent <= 3 {
                var items: [[MarkdownBlock]] = []
                while index < lines.count, let marker = listMarker(lines[index]),
                      marker.indent == first.indent, (marker.start == nil) == (first.start == nil),
                      !thematic(lines[index]), !unsupported(lines[index]) {
                    var content = [marker.content]
                    index += 1
                    while index < lines.count {
                        let next = lines[index]
                        let indent = next.prefix(while: { $0 == " " }).count
                        if !next.isEmpty, indent >= marker.width {
                            content.append(String(next.dropFirst(marker.width))); index += 1
                        } else if next.isEmpty, index + 1 < lines.count,
                                  lines[index + 1].prefix(while: { $0 == " " }).count >= marker.width {
                            content.append(""); index += 1
                        } else { break }
                    }
                    items.append(blocks(content, depth: depth + 1))
                }
                result.append(.list(start: first.start, items: items))
            } else {
                var content = [line]
                index += 1
                while index < lines.count, !beginsBlock(lines[index]) {
                    content.append(lines[index]); index += 1
                }
                var children: [MarkdownInline] = []
                for (offset, raw) in content.enumerated() {
                    let hard = raw.hasSuffix("  ") || raw.hasSuffix("\\")
                    let text = raw.hasSuffix("\\") ? String(raw.dropLast()) : raw.trimmingCharacters(in: .whitespaces)
                    children += parseInline(text)
                    if offset + 1 < content.count { children.append(hard ? .hardBreak : .softBreak) }
                }
                result.append(.paragraph(children))
            }
        }
        return result
    }

    public static func parseInline(_ text: String) -> [MarkdownInline] {
        let chars = Array(text)
        var budget = chars.count * 16 + 256
        return inline(chars, range: 0..<chars.count, depth: 0, budget: &budget)
    }

    private static func inline(_ chars: [Character], range: Range<Int>, depth: Int,
                               budget: inout Int) -> [MarkdownInline] {
        guard depth < maximumNesting else { return [.text(String(chars[range]))] }
        var result: [MarkdownInline] = []
        var pending = ""
        func flush() {
            if !pending.isEmpty { result.append(.text(pending)); pending = "" }
        }
        var i = range.lowerBound
        while i < range.upperBound {
            guard budget > 0 else { pending += String(chars[i..<range.upperBound]); break }
            budget -= 1
            let c = chars[i]
            if c == "\\", i + 1 < range.upperBound, chars[i + 1].isASCII,
               chars[i + 1].unicodeScalars.allSatisfy({ CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }) {
                pending.append(chars[i + 1]); i += 2; continue
            }
            if c == "`" {
                var end = i
                while end < range.upperBound, chars[end] == "`" { end += 1 }
                let count = end - i
                var cursor = end
                var closing: Int?
                while cursor < range.upperBound, budget > 0 {
                    budget -= 1
                    if chars[cursor] == "`" {
                        let start = cursor
                        while cursor < range.upperBound, chars[cursor] == "`" { cursor += 1 }
                        if cursor - start == count { closing = start; break }
                    } else { cursor += 1 }
                }
                if let closing {
                    var code = String(chars[end..<closing])
                    if code.hasPrefix(" "), code.hasSuffix(" "), !code.allSatisfy({ $0 == " " }) {
                        code = String(code.dropFirst().dropLast())
                    }
                    flush(); result.append(.code(code)); i = closing + count; continue
                }
                pending += String(chars[i..<end]); i = end; continue
            }
            let image = c == "!" && i + 1 < range.upperBound && chars[i + 1] == "["
            if c == "[" || image {
                let labelStart = i + (image ? 2 : 1)
                var cursor = labelStart
                var bracketDepth = 1
                while cursor < range.upperBound, budget > 0 {
                    budget -= 1
                    if chars[cursor] == "\\", cursor + 1 < range.upperBound { cursor += 2; continue }
                    if chars[cursor] == "[" { bracketDepth += 1 }
                    if chars[cursor] == "]" { bracketDepth -= 1; if bracketDepth == 0 { break } }
                    cursor += 1
                }
                if bracketDepth == 0, cursor + 1 < range.upperBound, chars[cursor + 1] == "(",
                   let target = destination(chars, start: cursor + 2, limit: range.upperBound, budget: &budget) {
                    let label = inline(chars, range: labelStart..<cursor, depth: depth + 1, budget: &budget)
                    flush()
                    result.append(image ? .image(alt: label.map(\.plainText).joined(), destination: target.url, title: target.title)
                                  : .link(label: label, destination: target.url, title: target.title))
                    i = target.end; continue
                }
            }
            if c == "*" || c == "_" {
                let count: Int
                if i + 2 < range.upperBound, chars[i + 1] == c, chars[i + 2] == c { count = 3 }
                else { count = i + 1 < range.upperBound && chars[i + 1] == c ? 2 : 1 }
                let before = i > range.lowerBound ? chars[i - 1] : nil
                let after = i + count < range.upperBound ? chars[i + count] : nil
                // Deliberately avoid intraword markers, including arithmetic such as 2*3*4.
                if let after, !after.isWhitespace, before == nil || !(before!.isLetter || before!.isNumber) {
                    var cursor = i + count
                    var closing: Int?
                    while cursor + count <= range.upperBound, budget > 0 {
                        budget -= 1
                        if chars[cursor] == "\\" { cursor += 2; continue }
                        let matches = (0..<count).allSatisfy { chars[cursor + $0] == c }
                        let following = cursor + count < range.upperBound ? chars[cursor + count] : nil
                        if matches, cursor > i + count, !chars[cursor - 1].isWhitespace,
                           following == nil || !(following!.isLetter || following!.isNumber),
                           (count > 1 || following != c) { closing = cursor; break }
                        cursor += 1
                    }
                    if let closing {
                        let children = inline(chars, range: (i + count)..<closing, depth: depth + 1, budget: &budget)
                        flush()
                        if count == 3 { result.append(.strong([.emphasis(children)])) }
                        else { result.append(count == 2 ? .strong(children) : .emphasis(children)) }
                        i = closing + count; continue
                    }
                }
            }
            if c == "<" {
                var cursor = i + 1
                while cursor < range.upperBound, chars[cursor] != ">", budget > 0 { cursor += 1; budget -= 1 }
                if cursor < range.upperBound, chars[cursor] == ">" {
                    flush(); result.append(.rawHTML(String(chars[i...cursor]))); i = cursor + 1; continue
                }
            }
            pending.append(c); i += 1
        }
        flush()
        return result
    }

    private static func destination(_ chars: [Character], start: Int, limit: Int,
                                    budget: inout Int) -> (url: String, title: String?, end: Int)? {
        var i = start
        while i < limit, chars[i].isWhitespace { i += 1 }
        var url = ""
        if i < limit, chars[i] == "<" {
            i += 1
            while i < limit, chars[i] != ">", budget > 0 { url.append(chars[i]); i += 1; budget -= 1 }
            guard i < limit, chars[i] == ">" else { return nil }
            i += 1
        } else {
            var nesting = 0
            while i < limit, budget > 0 {
                budget -= 1
                let c = chars[i]
                if c == "\\", i + 1 < limit { url.append(chars[i + 1]); i += 2; continue }
                if c == "(" { nesting += 1; if nesting > maximumNesting { return nil } }
                if c == ")" { if nesting == 0 { break }; nesting -= 1 }
                if c.isWhitespace && nesting == 0 { break }
                url.append(c); i += 1
            }
            guard nesting == 0 else { return nil }
        }
        let separator = i
        while i < limit, chars[i].isWhitespace { i += 1 }
        var title: String?
        if i > separator, i < limit, chars[i] == "\"" || chars[i] == "'" {
            let delimiter = chars[i]; i += 1
            var value = ""
            while i < limit, chars[i] != delimiter, budget > 0 {
                budget -= 1
                if chars[i] == "\\", i + 1 < limit { i += 1 }
                value.append(chars[i]); i += 1
            }
            guard i < limit, chars[i] == delimiter else { return nil }
            title = value; i += 1
            while i < limit, chars[i].isWhitespace { i += 1 }
        }
        guard i < limit, chars[i] == ")" else { return nil }
        return (url, title, i + 1)
    }
}

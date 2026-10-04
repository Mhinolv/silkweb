import Foundation

/// Original, deliberately bounded parser; see docs/markdown-rendering.md for deviations.
/// No I/O or shared mutable state. Call off the main thread for full documents.
public enum MarkdownParser {
    public static let maximumNesting = 32

    public static func parse(_ source: String) -> MarkdownDocument {
        // Keep original UTF-16 offsets even when source uses CRLF or CR newlines.
        let raw = source as NSString
        var lines: [SourceLine] = []
        var offset = 0
        while offset < raw.length {
            let range = raw.lineRange(for: NSRange(location: offset, length: 0))
            let text = raw.substring(with: range).trimmingCharacters(in: .newlines)
            lines.append(SourceLine(text: text, range: NSRange(location: offset, length: (text as NSString).length)))
            offset = NSMaxRange(range)
        }
        if source.isEmpty || source.last == "\n" || source.last == "\r" {
            lines.append(SourceLine(text: "", range: NSRange(location: raw.length, length: 0)))
        }
        var ranges: [NSRange] = []
        var footnotes: [String: [MarkdownInline]] = [:]
        let parsed = blocks(lines, depth: 0, ranges: &ranges, footnotes: &footnotes)
        return MarkdownDocument(blocks: parsed, headingSourceRanges: ranges, footnotes: footnotes)
    }

    private struct SourceLine {
        let text: String
        let range: NSRange
        func replacingText(_ text: String) -> SourceLine { SourceLine(text: text, range: range) }
    }

    private struct ListMarker {
        let indent: Int
        let width: Int
        let start: Int?
        let content: String
    }

    /// Leading tabs advance to the next 4-column stop so tab-indented lists nest like spaces (1.76).
    private static func expandingLeadingTabs(_ line: String) -> String {
        let leading = line.prefix(while: { $0 == " " || $0 == "\t" })
        guard leading.contains("\t") else { return line }
        let columns = leading.reduce(0) { $1 == "\t" ? $0 + 4 - $0 % 4 : $0 + 1 }
        return String(repeating: " ", count: columns) + line.dropFirst(leading.count)
    }

    private static func listMarker(_ line: String) -> ListMarker? {
        let chars = Array(expandingLeadingTabs(line))
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
        return false
    }

    private static func beginsBlock(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty || heading(line) != nil || fence(line) != nil
            || thematic(line) || quoteContent(line) != nil || listMarker(line) != nil || unsupported(line)
            || line.trimmingCharacters(in: .whitespaces) == "[TOC]"
    }

    private static func blocks(_ sourceLines: [SourceLine], depth: Int, ranges: inout [NSRange],
                               footnotes: inout [String: [MarkdownInline]]) -> [MarkdownBlock] {
        let lines = sourceLines.map(\.text)
        guard depth < maximumNesting else {
            return [.paragraph([.text(lines.joined(separator: "\n"))])]
        }
        var result: [MarkdownBlock] = []
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { index += 1; continue }
            if let definition = MarkdownExtensions.footnoteDefinition(line) {
                var content = [definition.text]
                index += 1
                while index < lines.count, lines[index].hasPrefix("    ") {
                    content.append(String(lines[index].dropFirst(4))); index += 1
                }
                if footnotes[definition.label] == nil {
                    footnotes[definition.label] = content.enumerated().flatMap { offset, text in
                        parseInline(text) + (offset + 1 < content.count ? [.softBreak] : [])
                    }
                }
            } else if line.trimmingCharacters(in: .whitespaces) == "[TOC]" {
                result.append(.tableOfContents); index += 1
            } else if index + 1 < lines.count,
                      let header = MarkdownExtensions.tableCells(line),
                      let alignments = MarkdownExtensions.tableAlignments(lines[index + 1]),
                      header.count == alignments.count {
                index += 2
                var rows: [[[MarkdownInline]]] = []
                while index < lines.count, !beginsBlock(lines[index]),
                      let cells = MarkdownExtensions.tableCells(lines[index]) {
                    let padded = Array((cells + Array(repeating: "", count: max(0, header.count - cells.count))).prefix(header.count))
                    rows.append(padded.map(parseInline)); index += 1
                }
                result.append(.table(header: header.map(parseInline), alignments: alignments, rows: rows))
            } else if unsupported(line) {
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
                result.append(.heading(level: level, content: parseInline(content)))
                ranges.append(sourceLines[index].range); index += 1
            } else if thematic(line) {
                result.append(.thematicBreak); index += 1
            } else if quoteContent(line) != nil {
                var content: [SourceLine] = []
                while index < lines.count, let quoted = quoteContent(lines[index]) {
                    content.append(sourceLines[index].replacingText(quoted)); index += 1
                }
                result.append(.quote(blocks(content, depth: depth + 1, ranges: &ranges, footnotes: &footnotes)))
            } else if let first = listMarker(line), first.indent <= 3 {
                var items: [[MarkdownBlock]] = []
                while index < lines.count, let marker = listMarker(lines[index]),
                      marker.indent == first.indent, (marker.start == nil) == (first.start == nil),
                      !thematic(lines[index]), !unsupported(lines[index]) {
                    let task = MarkdownExtensions.task(marker.content)
                    var content = [sourceLines[index].replacingText(task?.text ?? marker.content)]
                    index += 1
                    while index < lines.count {
                        let next = expandingLeadingTabs(lines[index])
                        let indent = next.prefix(while: { $0 == " " }).count
                        if !next.isEmpty, indent >= marker.width {
                            content.append(sourceLines[index].replacingText(String(next.dropFirst(marker.width)))); index += 1
                        } else if next.isEmpty, index + 1 < lines.count,
                                  expandingLeadingTabs(lines[index + 1]).prefix(while: { $0 == " " }).count >= marker.width {
                            content.append(sourceLines[index].replacingText("")); index += 1
                        } else { break }
                    }
                    let children = blocks(content, depth: depth + 1, ranges: &ranges, footnotes: &footnotes)
                    items.append(task.map { [.taskItem(checked: $0.checked, content: children)] } ?? children)
                }
                result.append(.list(start: first.start, items: items))
            } else {
                var content = [line]
                index += 1
                while index < lines.count, !beginsBlock(lines[index]) {
                    if index + 1 < lines.count, let header = MarkdownExtensions.tableCells(lines[index]),
                       let alignments = MarkdownExtensions.tableAlignments(lines[index + 1]), header.count == alignments.count { break }
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
        return inline(chars, range: 0..<chars.count, depth: 0, allowLinks: true, budget: &budget)
    }

    private static func inline(_ chars: [Character], range: Range<Int>, depth: Int,
                               allowLinks: Bool, budget: inout Int) -> [MarkdownInline] {
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
            if allowLinks, c == "[", i + 2 < range.upperBound, chars[i + 1] == "^" {
                var end = i + 2
                while end < range.upperBound, chars[end] != "]", !chars[end].isWhitespace, chars[end] != "[", budget > 0 {
                    end += 1; budget -= 1
                }
                if end > i + 2, end < range.upperBound, chars[end] == "]" {
                    flush(); result.append(.footnoteReference(String(chars[(i + 2)..<end])))
                    i = end + 1; continue
                }
            }
            // Bare URLs must begin at a word boundary and cannot nest inside link labels.
            if (c == "h" || c == "w"), allowLinks,
               i == range.lowerBound || !(chars[i - 1].isLetter || chars[i - 1].isNumber || "_/@".contains(chars[i - 1])) {
                let prefix = String(chars[i..<min(i + 8, range.upperBound)])
                if prefix.hasPrefix("https://") || prefix.hasPrefix("http://") || prefix.hasPrefix("www.") {
                    var end = i
                    while end < range.upperBound, !chars[end].isWhitespace, !"<>\"".contains(chars[end]), budget > 0 {
                        end += 1; budget -= 1
                    }
                    while end > i, ".,;:!?".contains(chars[end - 1]) { end -= 1 }
                    for (open, close) in [(Character("("), Character(")")), ("[", "]")] {
                        let segment = chars[i..<end]
                        var excess = segment.filter { $0 == close }.count - segment.filter { $0 == open }.count
                        while excess > 0, end > i, chars[end - 1] == close { end -= 1; excess -= 1 }
                    }
                    let label = String(chars[i..<end])
                    flush(); result.append(.link(label: [.text(label)], destination: label.hasPrefix("www.") ? "https://" + label : label, title: nil))
                    i = end; continue
                }
            }
            if allowLinks, c == "[" || image {
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
                    let label = inline(chars, range: labelStart..<cursor, depth: depth + 1, allowLinks: false, budget: &budget)
                    flush()
                    result.append(image ? .image(alt: label.map(\.plainText).joined(), destination: target.url, title: target.title)
                                  : .link(label: label, destination: target.url, title: target.title))
                    i = target.end; continue
                }
            }
            if c == "*" || c == "_" || (c == "~" && i + 1 < range.upperBound && chars[i + 1] == "~") {
                let count: Int
                if c != "~", i + 2 < range.upperBound, chars[i + 1] == c, chars[i + 2] == c { count = 3 }
                else { count = i + 1 < range.upperBound && chars[i + 1] == c ? 2 : 1 }
                let before = i > range.lowerBound ? chars[i - 1] : nil
                let after = i + count < range.upperBound ? chars[i + count] : nil
                // Deliberately avoid intraword markers, including arithmetic such as 2*3*4.
                if let after, !after.isWhitespace, c == "~" || before == nil || !(before!.isLetter || before!.isNumber) {
                    var cursor = i + count
                    var closing: Int?
                    while cursor + count <= range.upperBound, budget > 0 {
                        budget -= 1
                        if chars[cursor] == "\\" { cursor += 2; continue }
                        let matches = (0..<count).allSatisfy { chars[cursor + $0] == c }
                        let following = cursor + count < range.upperBound ? chars[cursor + count] : nil
                        if matches, cursor > i + count, !chars[cursor - 1].isWhitespace,
                           c == "~" || following == nil || !(following!.isLetter || following!.isNumber),
                           (count > 1 || following != c) { closing = cursor; break }
                        cursor += 1
                    }
                    if let closing {
                        let children = inline(chars, range: (i + count)..<closing, depth: depth + 1, allowLinks: allowLinks, budget: &budget)
                        flush()
                        if c == "~" { result.append(.strikethrough(children)) }
                        else if count == 3 { result.append(.strong([.emphasis(children)])) }
                        else { result.append(count == 2 ? .strong(children) : .emphasis(children)) }
                        i = closing + count; continue
                    }
                }
            }
            if c == "<" {
                let prefix = String(chars[i..<min(i + 4, range.upperBound)])
                let terminator = prefix == "<!--" ? Array("-->") : prefix.hasPrefix("<?") ? Array("?>") : [Character(">")]
                var cursor = i + 1
                while cursor < range.upperBound, budget > 0 {
                    budget -= 1
                    if cursor + 1 >= terminator.count,
                       (0..<terminator.count).allSatisfy({ chars[cursor + 1 - terminator.count + $0] == terminator[$0] }) { break }
                    cursor += 1
                }
                if cursor < range.upperBound, chars[cursor] == ">" {
                    let candidate = String(chars[(i + 1)..<cursor])
                    if allowLinks, (candidate.hasPrefix("https://") || candidate.hasPrefix("http://")), !candidate.contains(where: \.isWhitespace) {
                        flush(); result.append(.link(label: [.text(candidate)], destination: candidate, title: nil))
                        i = cursor + 1; continue
                    }
                    let raw = String(chars[i...cursor])
                    if MarkdownExtensions.isRawHTML(raw) {
                        flush(); result.append(.rawHTML(raw)); i = cursor + 1; continue
                    }
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

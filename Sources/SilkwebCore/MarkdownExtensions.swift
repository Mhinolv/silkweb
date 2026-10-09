import Foundation

public struct MarkdownHeading: Equatable, Sendable {
    public let level: Int
    public let text: String
    public let id: String
    /// UTF-16 range in original source; NSNotFound for an AST supplied without ranges.
    public let sourceRange: NSRange
}

public enum MarkdownTableAlignment: String, Equatable, Sendable {
    case left, center, right
}

/// Pure helpers shared by the parser, renderer and future heading outline.
public enum MarkdownExtensions {
    public static func slug(_ text: String) -> String {
        var result = ""
        var separator = false
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                if separator && !result.isEmpty { result += "-" }
                result.append(character)
                separator = false
            } else {
                separator = true
            }
        }
        return result.isEmpty ? "section" : result
    }

    static func headings(in blocks: [MarkdownBlock], sourceRanges: [NSRange]) -> [MarkdownHeading] {
        var result: [MarkdownHeading] = []
        var used: Set<String> = []
        var nextSuffix: [String: Int] = [:]
        func walk(_ blocks: [MarkdownBlock], depth: Int) {
            guard depth <= MarkdownParser.maximumNesting else { return }
            for block in blocks {
                switch block {
                case .heading(let level, let content):
                    let text = content.map(\.plainText).joined()
                    let base = slug(text)
                    var id = base
                    var suffix = nextSuffix[base, default: 1]
                    while used.contains(id) { id = "\(base)-\(suffix)"; suffix += 1 }
                    nextSuffix[base] = suffix
                    used.insert(id)
                    let range =
                        result.count < sourceRanges.count
                        ? sourceRanges[result.count] : NSRange(location: NSNotFound, length: 0)
                    result.append(.init(level: min(6, max(1, level)), text: text, id: id, sourceRange: range))
                case .quote(let children), .taskItem(_, let children): walk(children, depth: depth + 1)
                case .list(_, let items): for item in items { walk(item, depth: depth + 1) }
                default: break
                }
            }
        }
        walk(blocks, depth: 0)
        return result
    }

    /// Split unescaped pipes. Unescape pipe escapes (including in code spans); preserve other escapes.
    static func tableCells(_ line: String) -> [String]? { splitCells(line, tracking: false)?.map(\.text) }

    /// UTF-16 offsets of each cell character (and the cell end), from the start of the trimmed line (#176).
    /// A cell whose offsets can't be matched to its text gets none.
    static func tableCellOffsets(_ line: String) -> [[Int]]? {
        splitCells(line, tracking: true)?.map { cell in
            // One offset per character of `raw`; trim both alike.
            var offsets = ArraySlice(cell.offsets)
            var characters = Substring(cell.raw)
            func space(_ character: Character?) -> Bool {
                character?.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) == true
            }
            while space(characters.first) { characters.removeFirst(); offsets.removeFirst() }
            while space(characters.last) { characters.removeLast(); offsets.removeLast() }
            guard let last = characters.last, String(characters) == cell.text, offsets.count == characters.count
            else { return [] }
            return Array(offsets) + [offsets.last! + last.utf16.count]
        }
    }

    private static func splitCells(_ line: String, tracking: Bool) -> [(text: String, raw: String, offsets: [Int])]? {
        let text = line.trimmingCharacters(in: .whitespaces)
        var cells: [(raw: String, offsets: [Int])] = []
        var pending = ""
        var offsets: [Int] = []
        var offset = 0
        var escaped = false
        var hasPipe = false
        for character in text {
            defer { offset += character.utf16.count }
            if escaped {
                if character == "|" { pending.removeLast(); if tracking { offsets.removeLast() } }
                pending.append(character); escaped = false
            } else if character == "\\" {
                pending.append(character); escaped = true
            } else if character == "|" {
                cells.append((pending, offsets)); pending = ""; offsets = []; hasPipe = true
                continue
            } else {
                pending.append(character)
            }
            if tracking { offsets.append(offset) }
        }
        guard hasPipe else { return nil }
        cells.append((pending, offsets))
        if text.hasPrefix("|") { cells.removeFirst() }
        if cells.last?.raw == "", text.hasSuffix("|") { cells.removeLast() }
        return cells.map { ($0.raw.trimmingCharacters(in: .whitespaces), $0.raw, $0.offsets) }
    }

    static func tableAlignments(_ line: String) -> [MarkdownTableAlignment?]? {
        guard let cells = tableCells(line), !cells.isEmpty else { return nil }
        var result: [MarkdownTableAlignment?] = []
        for cell in cells {
            var dashes = cell[...]
            let left = dashes.first == ":"
            let right = dashes.last == ":"
            if left { dashes = dashes.dropFirst() }
            if right, !dashes.isEmpty { dashes = dashes.dropLast() }
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            result.append(left && right ? .center : right ? .right : left ? .left : nil)
        }
        return result
    }

    static func task(_ text: String) -> (checked: Bool, text: String)? {
        guard text.hasPrefix("[ ]") || text.hasPrefix("[x]") || text.hasPrefix("[X]") else { return nil }
        let rest = text.dropFirst(3)
        guard rest.isEmpty || rest.first?.isWhitespace == true else { return nil }
        return (!text.hasPrefix("[ ]"), String(rest.drop(while: \.isWhitespace)))
    }

    static func footnoteDefinition(_ line: String) -> (label: String, text: String)? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard line.prefix(while: { $0 == " " }).count <= 3, text.hasPrefix("[^"),
            let end = text.range(of: "]:")
        else { return nil }
        let label = String(text[text.index(text.startIndex, offsetBy: 2)..<end.lowerBound])
        guard !label.isEmpty, !label.contains(where: { $0.isWhitespace || $0 == "[" || $0 == "]" }) else { return nil }
        return (label, String(text[end.upperBound...]).trimmingCharacters(in: .whitespaces))
    }

    static func isRawHTML(_ text: String) -> Bool {
        // Recognize tag shapes, declarations, comments and processing instructions only.
        let pattern = #"^<(?:/?[A-Za-z][A-Za-z0-9-]*(?:\s[^<>]*|/?)|!--[\s\S]*--|\?[\s\S]*\?|![A-Z][^<>]*)>$"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}

import Foundation

/// Display-only outline entries. Image ranges identify their original source line.
public struct OutlineItem: Equatable, Sendable, Identifiable {
    public enum Content: Equatable, Sendable {
        case heading(MarkdownHeading)
        case image(InlineImages.Reference)
    }
    public let id: String
    public let content: Content
    public let sourceRange: NSRange
    /// Tree depth: enclosing headings for a heading, parent depth + 1 for an image.
    public let depth: Int
    public private(set) var sourceLine: String? = nil
    public private(set) var isInlineImage = true

    public var label: String {
        switch content {
        case .heading(let heading): return heading.text
        case .image(let reference):
            let alt = reference.alt.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if !alt.isEmpty { return alt }
            let url = URL(string: reference.destination)
            let component = url?.lastPathComponent.removingPercentEncoding ?? ""
            return component.isEmpty ? (url?.host ?? reference.destination) : component
        }
    }

    public var indent: Double { OutlineRowStyle.indent(depth: depth) }

    /// Depth from the actual heading stack, so skipped `#` levels add nothing.
    public static func depths(_ headings: [MarkdownHeading]) -> [Int] {
        var stack: [Int] = []
        return headings.map { heading in
            while let last = stack.last, last >= heading.level { stack.removeLast() }
            defer { stack.append(heading.level) }
            return stack.count
        }
    }

    public static func parse(_ text: String, headings: [MarkdownHeading]? = nil) -> [OutlineItem] {
        let headings = headings ?? MarkdownParser.parse(text).headings
        let depths = depths(headings)
        let headingItems = zip(headings, depths).map { OutlineItem(id: $0.id, content: .heading($0), sourceRange: $0.sourceRange, depth: $1) }
        guard text.contains("![") else { return headingItems }
        let source = text as NSString
        var lines: [(String, NSRange)] = []
        var offset = 0
        var fence: (Character, Int)?
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let line = source.substring(with: range)
            offset = NSMaxRange(range)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = trimmed.first
            let count = trimmed.prefix(while: { $0 == marker }).count
            if let current = fence {
                if marker == current.0, count >= current.1, trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                continue
            }
            // Any indentation: nested list items may hold fences. Indented lines are not code;
            // the parser has no indented code and renders their images.
            if marker == "`" || marker == "~", count >= 3 {
                fence = (marker!, count); continue
            }
            lines.append((line, range))
        }
        // Resolve the bounded single-line reference grammar before using the shared
        // inline parser, which still excludes escaped markers and inline code.
        let definition = try! NSRegularExpression(pattern: #"^ {0,3}\[([^\]\n]+)\]:\s*(<[^>\n]+>|[^\s]+)(?:\s+[^\n]*)?$"#)
        let reference = try! NSRegularExpression(pattern: #"!\[([^\]\n]*)\](?:\[([^\]\n]*)\])?(?!\()"#)
        func key(_ value: String) -> String { value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased() }
        var definitions: [String: String] = [:]
        for (line, _) in lines {
            let ns = line as NSString
            if let match = definition.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                let name = key(ns.substring(with: match.range(at: 1)))
                if definitions[name] == nil { definitions[name] = ns.substring(with: match.range(at: 2)) }
            }
        }
        var result = headingItems
        var imageIndex = 0
        for (line, range) in lines where line.contains("![") {
            let ns = line as NSString
            let expanded = NSMutableString(string: line)
            for match in reference.matches(in: line, range: NSRange(location: 0, length: ns.length)).reversed() {
                let alt = ns.substring(with: match.range(at: 1))
                let name = match.range(at: 2).location == NSNotFound ? alt : ns.substring(with: match.range(at: 2))
                if let destination = definitions[key(name.isEmpty ? alt : name)] {
                    expanded.replaceCharacters(in: match.range, with: "![" + alt + "](" + destination + ")")
                }
            }
            let direct = InlineImages.paragraph(line)
            for image in InlineImages.paragraph(expanded as String) {
                let parent = headings.lastIndex { $0.sourceRange.location <= range.location }
                result.append(OutlineItem(id: "outline_image_\(imageIndex)", content: .image(image), sourceRange: range, depth: parent.map { depths[$0] + 1 } ?? 0, sourceLine: line.trimmingCharacters(in: .newlines), isInlineImage: direct.contains(image)))
                imageIndex += 1
            }
        }
        return result.sorted {
            if $0.sourceRange.location != $1.sourceRange.location { return $0.sourceRange.location < $1.sourceRange.location }
            if case .heading = $0.content { return true }
            if case .heading = $1.content { return false }
            return $0.id.localizedStandardCompare($1.id) == .orderedAscending
        }
    }
}

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
    public let parentLevel: Int?
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

    public func indent(shallowest: Int) -> Double {
        guard let parentLevel else { return 0 }
        return Double(min(6, max(0, parentLevel - shallowest + 1))) * 12
    }

    public static func parse(_ text: String, headings: [MarkdownHeading]? = nil) -> [OutlineItem] {
        let headings = headings ?? MarkdownParser.parse(text).headings
        let headingItems = headings.map { OutlineItem(id: $0.id, content: .heading($0), sourceRange: $0.sourceRange, parentLevel: nil) }
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
            if line.prefix(while: { $0 == " " }).count <= 3, marker == "`" || marker == "~", count >= 3 {
                fence = (marker!, count); continue
            }
            guard !line.hasPrefix("    "), !line.hasPrefix("\t") else { continue }
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
                let parent = headings.last { $0.sourceRange.location <= range.location }?.level
                result.append(OutlineItem(id: "outline_image_\(imageIndex)", content: .image(image), sourceRange: range, parentLevel: parent, sourceLine: line.trimmingCharacters(in: .newlines), isInlineImage: direct.contains(image)))
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

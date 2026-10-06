import Foundation

/// Static list-row text. Calendar days, rather than elapsed hours, determine recency.
public enum DocumentRowPresentation {
    public static func dateLabel(
        _ date: Date, now: Date = Date(),
        calendar: Calendar = .current, locale: Locale = .current
    ) -> String {
        let days =
            calendar.dateComponents(
                [.day], from: calendar.startOfDay(for: date),
                to: calendar.startOfDay(for: now)
            ).day ?? 0
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch days {
        case 0:
            return date.formatted(style.hour().minute())
        case 1:
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.dateTimeStyle = .named
            formatter.formattingContext = .beginningOfSentence
            return formatter.localizedString(from: DateComponents(day: -1))
        case 2...6:
            return date.formatted(style.weekday(.wide))
        default:
            // Future days use an unambiguous date rather than a misleading weekday.
            return date.formatted(style.month(.abbreviated).day().year())
        }
    }

    public static func snippet(_ markdown: String, title: String) -> String {
        var isLeadingLine = true
        for (line, kind) in snippetLines(MarkdownParser.parse(markdown).blocks) {
            let text = summaryText(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if isLeadingLine && kind == .heading && text == title {
                isLeadingLine = false
                continue
            }
            isLeadingLine = false
            // Keep the original row summary bound without splitting CJK or emoji graphemes.
            var result = ""
            var bytes = 0
            for character in text {
                let size = String(character).utf8.count
                guard bytes + size <= 512 else { break }
                result.append(character)
                bytes += size
            }
            return result.isEmpty ? "No additional text" : result
        }
        return "No additional text"
    }

    /// Two-line list excerpt (silkweb-1.64): body text after the leading title heading, Markdown
    /// markers stripped, whitespace collapsed, bounded to `limit` characters. A leading heading that
    /// repeats the title (or that the title was derived from) is skipped; headings and list items are
    /// joined to their neighbours with ` · ` so they never run together (silkweb-1.25).
    public static func excerpt(_ markdown: String, title: String, limit: Int = 240) -> String {
        var result = ""
        var isLeadingLine = true
        var previousIsSegment = false
        for (line, kind) in snippetLines(MarkdownParser.parse(markdown).blocks) {
            let text = summaryText(line).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !text.isEmpty else { continue }
            if isLeadingLine && kind == .heading && headingRepeatsTitle(text, title: title) {
                isLeadingLine = false
                continue
            }
            isLeadingLine = false
            let isSegment = kind != .body
            if !result.isEmpty { result.append(isSegment || previousIsSegment ? " · " : " ") }
            result.append(text)
            previousIsSegment = isSegment
            if result.count >= limit { break }
        }
        let excerpt = result.prefix(max(0, limit)).trimmingCharacters(in: .whitespaces)
        return excerpt.isEmpty ? "No additional text" : excerpt
    }

    /// The heading equals the title ignoring case and whitespace, or begins with it at a word
    /// boundary (a file named “Ten Days in Kyoto” for `# Ten Days in Kyoto（京都の十日間）`).
    static func headingRepeatsTitle(_ heading: String, title: String) -> Bool {
        func normalized(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
        }
        let heading = normalized(heading), title = normalized(title)
        guard !title.isEmpty else { return false }
        if heading == title { return true }
        guard heading.hasPrefix(title) else { return false }
        let next = heading[heading.index(heading.startIndex, offsetBy: title.count)]
        return !(next.isLetter || next.isNumber)
    }

    /// Where a row's document lives, relative to the list scope (`nil` or `""` is the library root).
    /// Documents directly in the scope show `scopeName` (the library or folder name).
    public static func location(for relativePath: String, scope: String?, scopeName: String) -> String {
        let base = scope ?? ""
        let parent = (relativePath as NSString).deletingLastPathComponent
        let relative: String
        if parent == base {
            relative = ""
        } else if !base.isEmpty, parent.hasPrefix(base + "/") {
            relative = String(parent.dropFirst(base.count + 1))
        } else {
            relative = parent
        }
        return relative.isEmpty ? scopeName : relative.split(separator: "/").joined(separator: " › ")
    }

    private enum LineKind { case body, heading, listItem }

    private static func snippetLines(_ blocks: [MarkdownBlock], inList: Bool = false) -> [(String, LineKind)] {
        let body: LineKind = inList ? .listItem : .body
        return blocks.flatMap { block -> [(String, LineKind)] in
            switch block {
            case .paragraph(let children):
                return children.map(\.plainText).joined().components(separatedBy: "\n").map { ($0, body) }
            case .heading(_, let children): return [(children.map(\.plainText).joined(), .heading)]
            case .code(_, let text): return text.components(separatedBy: "\n").map { ($0, body) }
            case .quote(let children): return snippetLines(children, inList: inList)
            case .list(_, let items): return items.flatMap { snippetLines($0, inList: true) }
            case .taskItem(_, let children): return snippetLines(children, inList: true)
            case .table(let header, _, let rows):
                return ([header] + rows).map { ($0.map { $0.map(\.plainText).joined() }.joined(separator: " "), body) }
            case .thematicBreak, .tableOfContents: return []
            }
        }
    }

    /// Retain cleanup for literal or unsupported row-summary syntax.
    private static func summaryText(_ source: String) -> String {
        var text = source.trimmingCharacters(in: .whitespaces)
        var task = false
        for marker in ["- ", "+ ", "* "] {
            if text.hasPrefix(marker), ["[ ]", "[x]", "[X]"].contains(where: { text.dropFirst(2).hasPrefix($0) }) {
                text = String(text.dropFirst(2)); break
            }
        }
        for marker in ["[ ] ", "[x] ", "[X] "] where text.hasPrefix(marker) {
            text = String(text.dropFirst(marker.count)); task = true; break
        }
        if task { text = MarkdownParser.parseInline(text).map(\.plainText).joined() }
        // Paired strike delimiters only; unmatched tildes stay visible.
        let pieces = text.components(separatedBy: "~~")
        if pieces.count > 2, pieces.count % 2 == 1 { text = pieces.joined() }
        return text
    }
}

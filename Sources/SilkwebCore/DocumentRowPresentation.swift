import Foundation

/// Static list-row text. Calendar days, rather than elapsed hours, determine recency.
public enum DocumentRowPresentation {
    public static func dateLabel(_ date: Date, now: Date = Date(),
                                 calendar: Calendar = .current, locale: Locale = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                           to: calendar.startOfDay(for: now)).day ?? 0
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
        for (line, isHeading) in snippetLines(MarkdownParser.parse(markdown).blocks) {
            let text = summaryText(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if isLeadingLine && isHeading && text == title {
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

    private static func snippetLines(_ blocks: [MarkdownBlock]) -> [(String, Bool)] {
        blocks.flatMap { block -> [(String, Bool)] in
            switch block {
            case .paragraph(let children):
                return children.map(\.plainText).joined().components(separatedBy: "\n").map { ($0, false) }
            case .heading(_, let children): return [(children.map(\.plainText).joined(), true)]
            case .code(_, let text): return text.components(separatedBy: "\n").map { ($0, false) }
            case .quote(let children): return snippetLines(children)
            case .list(_, let items): return items.flatMap { snippetLines($0) }
            case .taskItem(_, let children): return snippetLines(children)
            case .table(let header, _, let rows):
                return ([header] + rows).map { ($0.map { $0.map(\.plainText).joined() }.joined(separator: " "), false) }
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

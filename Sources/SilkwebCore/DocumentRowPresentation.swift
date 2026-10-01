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
        for rawLine in markdown.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let isHeading = heading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
            let text = plainText(line)
            if isLeadingLine && isHeading && text == title {
                isLeadingLine = false
                continue
            }
            isLeadingLine = false
            guard !text.isEmpty else { continue }
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

    private static let heading = try! NSRegularExpression(pattern: #"^#{1,6}(?:\s+|$)"#)
    private static let prefixes = try! NSRegularExpression(pattern: #"^(?:>\s*|[-+*]\s+|\d+[.)]\s+|\[[ xX]\]\s+)"#)
    private static let closingHeading = try! NSRegularExpression(pattern: #"\s+#+\s*$"#)
    private static let links = try! NSRegularExpression(pattern: #"!?\[([^\]]*)\]\((?:[^()]|\([^()]*\))*\)"#)
    private static let code = try! NSRegularExpression(pattern: #"(`+)(.*?)\1"#)
    private static let emphasis = [
        #"\*\*(.+?)\*\*"#, #"__(.+?)__"#, #"~~(.+?)~~"#,
        #"\*([^*]+)\*"#, #"(?<!\w)_([^_]+)_(?!\w)"#
    ].map { try! NSRegularExpression(pattern: $0) }

    private static func replacing(_ regex: NSRegularExpression, in text: String, with template: String = "") -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func plainText(_ line: String) -> String {
        var text = line
        // Strip nested block prefixes, e.g. a quoted task list.
        while true {
            let stripped = replacing(prefixes, in: text)
            if stripped == text { break }
            text = stripped
        }
        let withoutHeading = replacing(heading, in: text)
        if withoutHeading != text { text = replacing(closingHeading, in: withoutHeading) }
        text = replacing(links, in: text, with: "$1")
        text = replacing(code, in: text, with: "$2")
        for pattern in emphasis { text = replacing(pattern, in: text, with: "$1") }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

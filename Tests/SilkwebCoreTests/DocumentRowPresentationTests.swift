import XCTest
@testable import SilkwebCore

final class DocumentRowPresentationTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }

    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testDateCategoriesAndClockSkew() {
        let now = date(2026, 10, 10)
        func label(_ value: Date) -> String {
            DocumentRowPresentation.dateLabel(value, now: now, calendar: calendar, locale: locale)
        }
        let today = label(date(2026, 10, 10, 10, 42))
        // Locale formatters can insert narrow no-break spaces before AM/PM.
        XCTAssertEqual(today.replacingOccurrences(of: "\u{202f}", with: " "), "10:42 AM")
        XCTAssertEqual(label(date(2026, 10, 9)), "Yesterday")
        for (day, weekday) in [(8, "Thursday"), (7, "Wednesday"), (6, "Tuesday"), (5, "Monday"), (4, "Sunday")] {
            XCTAssertEqual(label(date(2026, 10, day)), weekday)
        }
        XCTAssertEqual(label(date(2026, 10, 3)), "Oct 3, 2026")
        XCTAssertEqual(label(date(2025, 9, 14)), "Sep 14, 2025")
        XCTAssertEqual(label(date(2026, 10, 11)), "Oct 11, 2026")
        XCTAssertEqual(label(date(2099, 1, 1)), "Jan 1, 2099")
        XCTAssertTrue(label(date(2026, 10, 10, 23, 59)).contains("11:59"))
        XCTAssertEqual(label(date(2026, 10, 10, 10, 42)), today)
    }

    func testDayBoundaryDSTAndLocale() {
        let modified = date(2026, 10, 10, 23, 58)
        XCTAssertTrue(DocumentRowPresentation.dateLabel(modified, now: date(2026, 10, 10, 23, 59),
                                                       calendar: calendar, locale: locale).contains("11:58"))
        XCTAssertEqual(DocumentRowPresentation.dateLabel(modified, now: date(2026, 10, 11, 0, 0),
                                                        calendar: calendar, locale: locale), "Yesterday")
        for (month, day) in [(3, 8), (11, 1)] {
            let now = date(2026, month, day, 23, 59)
            let previous = date(2026, month, day - 1, 0, 1)
            XCTAssertEqual(DocumentRowPresentation.dateLabel(previous, now: now, calendar: calendar, locale: locale), "Yesterday")
        }
        let french = Locale(identifier: "fr_FR")
        XCTAssertEqual(DocumentRowPresentation.dateLabel(date(2026, 10, 9), now: date(2026, 10, 10),
                                                        calendar: calendar, locale: french), "Hier")
        XCTAssertEqual(DocumentRowPresentation.dateLabel(date(2026, 10, 8), now: date(2026, 10, 10),
                                                        calendar: calendar, locale: french), "jeudi")
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        // The same instant is yesterday in New York but still today in UTC.
        XCTAssertTrue(DocumentRowPresentation.dateLabel(modified, now: date(2026, 10, 11, 0, 0),
                                                       calendar: utc, locale: locale).contains("3:58"))
    }

    func testSnippetMarkupAndLeadingTitle() {
        let cases: [(String, String)] = [
            ("\n  \n# Title\n\nBody text\nAnother line", "Body text"),
            ("# **Title** ##\nBody", "Body"),
            ("# Other heading\nBody", "Other heading"),
            ("Title\nBody", "Title"),
            ("# Title\n## Title\nBody", "Title"),
            ("###### Heading ####", "Heading"),
            ("**Bold** and *italic* with __strong__ and _emphasis_ and ~~deleted~~", "Bold and italic with strong and emphasis and deleted"),
            ("- Item", "Item"), ("+ Item", "Item"), ("* Item", "Item"),
            ("1. Item", "Item"), ("42) Item", "Item"),
            ("> > Quoted", "Quoted"),
            ("- [ ] Task", "Task"), ("- [x] Task", "Task"), ("- [X] Task", "Task"),
            ("> - [x] **Done**", "Done"),
            ("[link text](https://example.com/path_(part)) and `code`", "link text and code"),
            ("``inline ` code``", "inline ` code"),
            ("snake_case and C#", "snake_case and C#"),
            ("2*3*4", "2*3*4"),
            ("# Title\n---\n```swift\nlet answer = 42\n```", "let answer = 42"),
            ("```swift\n```\n---\nBody", "Body"),
            ("---\n***\n___", "No additional text"),
            ("\r\n\t\r\n> 日本語 👩🏽‍💻 ☕️ **文章**", "日本語 👩🏽‍💻 ☕️ 文章"),
            ("", "No additional text"), (" \n\t\r\n", "No additional text"),
            ("# Title\n\n", "No additional text")
        ]
        for (source, expected) in cases {
            XCTAssertEqual(DocumentRowPresentation.snippet(source, title: "Title"), expected, source)
        }
    }

    func testSummaryDiskLoadingAndUnicodeReadBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Title.md")
        for source in ["# Title\n\n> - [x] **Body** [link](https://example.com) `code`",
                       String(repeating: " ", count: 4094) + "日本語",
                       "# Title\n" + String(repeating: "👩🏽‍💻", count: 1000), ""] {
            try Data(source.utf8).write(to: url)
            let snapshot = try await LibraryScanner.scan(root: root)
            let summary = await DocumentSummary.load(document: snapshot.documents[0], root: root)
            XCTAssertNotNil(summary.modified)
            XCTAssertLessThanOrEqual(summary.firstLine.utf8.count, 512)
            XCTAssertFalse(summary.firstLine.contains("\u{fffd}"))
            if source.hasPrefix("# Title\n\n") { XCTAssertEqual(summary.firstLine, "Body link code") }
            if source.isEmpty { XCTAssertEqual(summary.firstLine, "No additional text") }
        }
    }

    func testSnippetSizeSweepPreservesGraphemes() {
        for character in ["a", "日", "☕️", "👩🏽‍💻"] {
            for count in [0, 1, 127, 128, 511, 512, 513, 10_000] {
                let snippet = DocumentRowPresentation.snippet(String(repeating: character, count: count), title: "Title")
                XCTAssertLessThanOrEqual(snippet.utf8.count, 512)
                if count == 0 { XCTAssertEqual(snippet, "No additional text") }
                else { XCTAssertTrue(snippet.allSatisfy { String($0) == character }) }
            }
        }
    }
}

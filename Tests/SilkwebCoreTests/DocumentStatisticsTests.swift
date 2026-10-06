import XCTest

@testable import SilkwebCore

final class DocumentStatisticsTests: XCTestCase {
    private func count(_ source: String) -> DocumentStatistics { DocumentStatistics.count(source) }

    func testPlainWordsAndCharacters() {
        XCTAssertEqual(count(""), .zero)
        XCTAssertEqual(count("Hello world"), DocumentStatistics(words: 2, characters: 11))
        XCTAssertEqual(count("  spaced   out  "), DocumentStatistics(words: 2, characters: 12))
        // Apostrophes and inner periods join; hyphens and slashes split (Unicode word boundaries).
        XCTAssertEqual(count("don’t can't e.g. well-known and/or").words, 7)
        XCTAssertEqual(count("Pi is 3.14, about 1,000 times 2").words, 7)
        XCTAssertEqual(count("snake_case word").words, 2)
        XCTAssertEqual(count("End. Next").words, 2)
        XCTAssertEqual(count("café naïve Ångström").words, 3)
    }

    func testCJKCountsOneWordPerCharacter() {
        XCTAssertEqual(count("日本語"), DocumentStatistics(words: 3, characters: 3))
        XCTAssertEqual(count("ひらがなカタカナ"), DocumentStatistics(words: 8, characters: 8))
        XCTAssertEqual(count("한국어 문장"), DocumentStatistics(words: 5, characters: 6))
        XCTAssertEqual(count("京都の十日間 in Kyoto"), DocumentStatistics(words: 8, characters: 15))
        XCTAssertEqual(count("abc日本def").words, 4)
        // Decomposed Hangul (one grapheme of jamo) is one syllable.
        XCTAssertEqual(count("\u{1112}\u{1161}\u{11AB}"), DocumentStatistics(words: 1, characters: 1))
    }

    func testEmojiAreSingleGraphemesAndWords() {
        XCTAssertEqual(count("👩🏽‍💻"), DocumentStatistics(words: 1, characters: 1))
        XCTAssertEqual(count("☕️ coffee 🇯🇵"), DocumentStatistics(words: 3, characters: 10))
        XCTAssertEqual(count("1️⃣ 2"), DocumentStatistics(words: 2, characters: 3))
        XCTAssertEqual(count("coffee☕️"), DocumentStatistics(words: 2, characters: 7))
        // Text-style symbols are not words.
        XCTAssertEqual(count("© ® ™").words, 0)
    }

    func testMarkdownPunctuationIsNotCounted() {
        XCTAssertEqual(count("# Heading"), DocumentStatistics(words: 1, characters: 7))
        XCTAssertEqual(count("- item\n* item\n1. item"), DocumentStatistics(words: 3, characters: 12))
        XCTAssertEqual(count("> quoted"), count("quoted"))
        XCTAssertEqual(count("**bold** _it_ ~~gone~~ `code`"), count("bold it gone code"))
        XCTAssertEqual(count("```swift\nlet x = 1\n```"), count("let x = 1"))
        XCTAssertEqual(count("---\n***\n[TOC]"), .zero)
        XCTAssertEqual(count("| A | B |\n|---|---|\n| 1 | 2 |"), DocumentStatistics(words: 4, characters: 6))
        XCTAssertEqual(count("- [x] done").words, 1)
        XCTAssertEqual(count("# - * | > ```").words, 0)
        XCTAssertEqual(count("<span>hi</span>").words, 1)
    }

    func testLinkAndImageDestinationsAreExcluded() {
        XCTAssertEqual(count("[a link](https://example.com/very/long/path?q=1)"), count("a link"))
        XCTAssertEqual(count("[label](url \"Title words\")"), count("label"))
        XCTAssertEqual(count("Before ![Alt text](media/photo.png) after"), count("Before  after"))
        XCTAssertEqual(count("See <https://example.com> now").words, count("See https://example.com now").words)
        XCTAssertEqual(count("Note[^1]\n\n[^1]: The footnote.").words, 3)
    }

    func testCharactersAreGraphemesExcludingLineBreaks() {
        XCTAssertEqual(count("a\nb").characters, 2)
        XCTAssertEqual(count("a\r\nb").characters, 2)
        XCTAssertEqual(count("line one\n\nline two").characters, 16)
        XCTAssertEqual(DocumentStatistics.measure("e\u{301}"), DocumentStatistics(words: 1, characters: 1))
        XCTAssertEqual(DocumentStatistics.measure("a\u{2028}b").characters, 2)
        XCTAssertEqual(DocumentStatistics.measure("\n\n\n"), .zero)
        XCTAssertEqual(DocumentStatistics.measure(" \t "), DocumentStatistics(words: 0, characters: 3))
    }

    /// A selection is counted with the same rules and never exceeds its document.
    func testSelectionVersusDocumentTotals() {
        let source = "# Ten Days in Kyoto\n\nKyoto rewards **slowness**. 京都 ☕️\n\n- [Temple](https://example.com)\n"
        let document = count(source)
        XCTAssertEqual(document, DocumentStatistics(words: 11, characters: 51))
        let ns = source as NSString
        let selection = count(ns.substring(with: ns.range(of: "Kyoto rewards **slowness**.")))
        XCTAssertEqual(selection, DocumentStatistics(words: 3, characters: 23))
        for length in 0...ns.length {
            let part = count(ns.substring(with: NSRange(location: 0, length: length)))
            XCTAssertLessThanOrEqual(part.characters, ns.length)
        }
        XCTAssertEqual(
            DocumentStatisticsPresentation.label(document: document, selection: selection),
            "3 of 11 words · 23 of 51 characters")
        XCTAssertEqual(
            DocumentStatisticsPresentation.accessibilityValue(document: document, selection: selection),
            "Selection: 3 of 11 words, 23 of 51 characters")
    }

    func testPresentationCopy() {
        let big = DocumentStatistics(words: 1_204, characters: 6_830)
        let separator = Locale.current.groupingSeparator ?? ","
        XCTAssertEqual(
            DocumentStatisticsPresentation.label(document: big), "1\(separator)204 words · 6\(separator)830 characters")
        XCTAssertEqual(
            DocumentStatisticsPresentation.label(document: big, includesCharacters: false), "1\(separator)204 words")
        XCTAssertEqual(
            DocumentStatisticsPresentation.label(
                document: big, selection: DocumentStatistics(words: 38, characters: 212), includesCharacters: false),
            "38 of 1\(separator)204 words")
        XCTAssertEqual(DocumentStatisticsPresentation.label(document: .zero), "0 words · 0 characters")
        XCTAssertEqual(
            DocumentStatisticsPresentation.label(document: DocumentStatistics(words: 1, characters: 1)),
            "1 word · 1 character")
        XCTAssertEqual(
            DocumentStatisticsPresentation.accessibilityValue(document: DocumentStatistics(words: 2, characters: 9)),
            "2 words, 9 characters")
    }

    /// Edge sweep: every prefix of a mixed fixture counts without crashing and grows monotonically in characters.
    func testPrefixSweepIsMonotonicForPlainText() {
        let text = "Hi 👩🏽‍💻 日本語 don't 3.14 — e\u{301}\r\nend"
        var previous = DocumentStatistics.zero
        var prefix = ""
        for character in text {
            prefix.append(character)
            let value = DocumentStatistics.measure(prefix)
            XCTAssertGreaterThanOrEqual(value.characters, previous.characters, prefix)
            previous = value
        }
        XCTAssertEqual(previous, DocumentStatistics(words: 9, characters: 26))
    }

    func testLargeDocumentIsLinear() {
        let paragraph = "Paragraph with **bold**, `code`, café 日本語 and [a link](https://example.com).\n\n"
        let source = String(repeating: paragraph, count: 2_000)
        let started = Date()
        let value = count(source)
        XCTAssertEqual(value.words, 2_000 * count(paragraph).words)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

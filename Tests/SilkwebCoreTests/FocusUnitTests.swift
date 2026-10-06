import XCTest

@testable import SilkwebCore

/// silkweb-1.27: Focus Mode's paragraph unit.
final class FocusUnitTests: XCTestCase {
    private func unit(_ text: String, at marker: String, length: Int = 0, known: [Int: Bool] = [:]) -> String {
        let source = text as NSString
        let location = source.range(of: marker).location
        XCTAssertNotEqual(location, NSNotFound, marker)
        let range = FocusUnit.range(
            in: source, selection: NSRange(location: location, length: length), fencedBefore: { known[$0] })
        return source.substring(with: range)
    }

    private let document = """
        # Title
        Intro line one
        intro line two

        Second paragraph
        wraps here

        - item one
          continued
        - item two
        1. numbered

        ```swift
        let a = 1

        let b = 2
        ```
        After fence
        > quote line
        > more quote

        Last
        """

    func testBlankLineDelimitedParagraphs() {
        XCTAssertEqual(unit(document, at: "intro line two"), "Intro line one\nintro line two\n")
        XCTAssertEqual(unit(document, at: "wraps"), "Second paragraph\nwraps here\n")
        XCTAssertEqual(unit(document, at: "Last"), "Last")
        XCTAssertEqual(unit(document, at: "more quote"), "After fence\n> quote line\n> more quote\n")
    }

    func testHeadingIsItsOwnUnit() {
        XCTAssertEqual(unit(document, at: "# Title"), "# Title\n")
        XCTAssertEqual(unit(document, at: "Intro line one"), "Intro line one\nintro line two\n")
    }

    func testListItemsAreSeparateUnitsWithContinuations() {
        XCTAssertEqual(unit(document, at: "item one"), "- item one\n  continued\n")
        XCTAssertEqual(unit(document, at: "continued"), "- item one\n  continued\n")
        XCTAssertEqual(unit(document, at: "item two"), "- item two\n")
        XCTAssertEqual(unit(document, at: "numbered"), "1. numbered\n")
    }

    func testFencedBlockIsOneUnitIncludingBlankLines() {
        let block = "```swift\nlet a = 1\n\nlet b = 2\n```\n"
        for marker in ["```swift", "let a", "let b", "```\nAfter"] {
            XCTAssertEqual(unit(document, at: marker), block, marker)
        }
        // The blank line inside the fence is code, not a separator.
        let blank = (document as NSString).range(of: "let a = 1\n").location + 10
        let range = FocusUnit.range(in: document as NSString, selection: NSRange(location: blank, length: 0))
        XCTAssertEqual((document as NSString).substring(with: range), block)
        XCTAssertEqual(unit(document, at: "After fence"), "After fence\n> quote line\n> more quote\n")
    }

    func testKnownFenceCheckpointsAgreeWithDerivedState() {
        // Supplying the styler's checkpoints gives the same answer as deriving them.
        let source = document as NSString
        var known: [Int: Bool] = [:]
        var fenced = false
        var position = 0
        while position < source.length {
            let line = source.lineRange(for: NSRange(location: position, length: 0))
            known[line.location] = fenced
            if FocusUnit.isFence(source.substring(with: line)) { fenced.toggle() }
            position = NSMaxRange(line)
        }
        for location in 0...source.length {
            let derived = FocusUnit.range(in: source, selection: NSRange(location: location, length: 0))
            let supplied = FocusUnit.range(
                in: source, selection: NSRange(location: location, length: 0), fencedBefore: { known[$0] })
            XCTAssertEqual(derived, supplied, "at \(location)")
            XCTAssertTrue(
                NSLocationInRange(location, derived) || location == NSMaxRange(derived),
                "unit contains the caret at \(location)")
        }
    }

    func testUnclosedFenceRunsToEnd() {
        let text = "Intro\n\n```\ncode\n\nmore"
        XCTAssertEqual(unit(text, at: "code"), "```\ncode\n\nmore")
        XCTAssertEqual(unit(text, at: "Intro"), "Intro\n")
    }

    func testSelectionSpanningParagraphsLightsAllTouched() {
        let text = "One\n\nTwo\n\nThree\n\nFour\n"
        let source = text as NSString
        let start = source.range(of: "ne").location
        let end = source.range(of: "Thr").location + 2
        let range = FocusUnit.range(in: source, selection: NSRange(location: start, length: end - start))
        XCTAssertEqual(source.substring(with: range), "One\n\nTwo\n\nThree\n")
        // A selection ending at the start of the next line does not touch that line.
        let line = FocusUnit.range(in: source, selection: NSRange(location: 0, length: 4))
        XCTAssertEqual(source.substring(with: line), "One\n")
    }

    func testEdgeCases() {
        XCTAssertEqual(
            FocusUnit.range(in: "", selection: NSRange(location: 0, length: 0)), NSRange(location: 0, length: 0))
        // Caret on a blank line, and on the empty line after a final newline.
        XCTAssertEqual(
            FocusUnit.range(in: "A\n\nB", selection: NSRange(location: 2, length: 0)), NSRange(location: 2, length: 1))
        XCTAssertEqual(
            FocusUnit.range(in: "A\nB\n", selection: NSRange(location: 4, length: 0)), NSRange(location: 4, length: 0))
        // Out-of-range selections clamp (to the end of the one-paragraph text).
        XCTAssertEqual(
            FocusUnit.range(in: "A\nB", selection: NSRange(location: 99, length: 5)), NSRange(location: 0, length: 3))
        XCTAssertEqual(
            FocusUnit.range(in: "A\n\nB", selection: NSRange(location: 99, length: 5)), NSRange(location: 3, length: 1))
        // UTF-16: emoji and CJK keep whole lines.
        let text = "👩🏽‍💻 one\n日本語 two\n\nnext" as NSString
        XCTAssertEqual(
            text.substring(with: FocusUnit.range(in: text, selection: NSRange(location: 3, length: 0))),
            "👩🏽‍💻 one\n日本語 two\n")
        // CRLF and whitespace-only separators.
        let crlf = "A\r\nB\r\n  \r\nC" as NSString
        XCTAssertEqual(
            crlf.substring(with: FocusUnit.range(in: crlf, selection: NSRange(location: 0, length: 0))), "A\r\nB\r\n")
    }

    func testLineLimitBoundsTheWalk() {
        let text = (0..<10_000).map { "line \($0)" }.joined(separator: "\n") as NSString
        let middle = text.range(of: "line 5000").location
        let range = FocusUnit.range(in: text, selection: NSRange(location: middle, length: 0), lineLimit: 100)
        let lines = text.substring(with: range).components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 201)
        XCTAssertTrue(lines.contains("line 5000"))
    }

    func testEveryCaretPositionSweep() {
        // Every caret in a mixed document yields a non-empty unit that contains it (or an empty final line).
        let source = (document + "\n\n```\nx\n```\n- a\n- b\n\n") as NSString
        for location in 0...source.length {
            let range = FocusUnit.range(in: source, selection: NSRange(location: location, length: 0))
            XCTAssertLessThanOrEqual(NSMaxRange(range), source.length)
            if location < source.length { XCTAssertTrue(NSLocationInRange(location, range), "at \(location)") }
        }
    }
}

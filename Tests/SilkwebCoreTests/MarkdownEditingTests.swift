import XCTest
@testable import SilkwebCore

final class MarkdownEditingTests: XCTestCase {
    func testInlineUnicodeWrapAndToggle() {
        for (command, marker) in [(MarkdownCommand.bold, "**"), (.italic, "*"), (.strike, "~~"), (.inlineCode, "`")] {
            for word in ["a", "café", "日本語", "👩🏽‍💻", "e\u{301}", String(repeating: "x", count: 10000)] {
                let range = NSRange(location: 0, length: word.utf16.count)
                let edit = MarkdownEditing.edit(command, text: word, selection: range)
                XCTAssertEqual(edit.applying(to: word), marker + word + marker)
                let wrapped = edit.applying(to: word)
                XCTAssertEqual(MarkdownEditing.edit(command, text: wrapped, selection: edit.selection).applying(to: wrapped), word)
                XCTAssertEqual(MarkdownEditing.edit(command, text: wrapped, selection: NSRange(location: 0, length: wrapped.utf16.count)).applying(to: wrapped), word)
            }
            let empty = MarkdownEditing.edit(command, text: "", selection: NSRange(location: 0, length: 0))
            XCTAssertEqual(empty.replacement, marker + marker)
            XCTAssertEqual(empty.selection.location, marker.utf16.count)
        }
        let emoji = "👩🏽‍💻"
        let edit = MarkdownEditing.edit(.bold, text: emoji, selection: NSRange(location: 2, length: 1))
        XCTAssertEqual(edit.replacement, "**\(emoji)**")
        XCTAssertEqual(MarkdownEditing.edit(.bold, text: "hello world", selection: NSRange(location: 2, length: 0)).replacement, "**hello**")
    }

    func testLineModesAndBoundaries() {
        let text = "one\ntwo\nthree"
        let range = NSRange(location: 0, length: 8) // excludes third line
        for (command, expected) in [(MarkdownCommand.quote, "> one\n> two\nthree"), (.bullet, "- one\n- two\nthree"), (.numbered, "1. one\n2. two\nthree"), (.task, "- [ ] one\n- [ ] two\nthree")] {
            let edit = MarkdownEditing.edit(command, text: text, selection: range)
            let result = edit.applying(to: text)
            XCTAssertEqual(result, expected)
            XCTAssertEqual(MarkdownEditing.edit(command, text: result, selection: edit.selection).applying(to: result), text)
        }
        for level in 0...6 {
            let edit = MarkdownEditing.edit(.heading(level), text: "## café", selection: NSRange(location: 3, length: 0))
            XCTAssertEqual(edit.replacement, level == 0 || level == 2 ? "café" : String(repeating: "#", count: level) + " café")
        }
        let block = MarkdownEditing.edit(.codeBlock, text: text, selection: range)
        XCTAssertEqual(block.applying(to: text), "```\none\ntwo\n```\nthree")
        XCTAssertEqual(block.selection.location, 3)
        XCTAssertEqual(MarkdownEditing.edit(.task, text: "3. item", selection: NSRange(location: 0, length: 0)).replacement, "- [ ] item")
        XCTAssertEqual(MarkdownEditing.edit(.numbered, text: "- [x] item", selection: NSRange(location: 0, length: 0)).replacement, "1. item")
        for value in ["", "x", "\n", "a\nb\n", "👩🏽‍💻\r\n日本語"] {
            for command in [MarkdownCommand.indent, .outdent, .heading(0), .heading(6), .quote, .bullet, .numbered, .task, .codeBlock] {
                let edit = MarkdownEditing.edit(command, text: value, selection: NSRange(location: 0, length: value.utf16.count))
                let result = edit.applying(to: value)
                XCTAssertLessThanOrEqual(NSMaxRange(edit.selection), result.utf16.count)
            }
        }
    }

    func testListContinuationAndIndent() {
        for (line, next) in [("- item", "- "), ("* item", "* "), ("+ item", "+ "), ("3. item", "4. "), ("9) item", "10) "), ("  - [x] done", "  - [ ] "), ("\t+ [ ] item", "\t+ [ ] ")] {
            let caret = NSRange(location: line.utf16.count, length: 0)
            XCTAssertEqual(MarkdownEditing.newline(text: line, selection: caret).applying(to: line), line + "\n" + next)
            XCTAssertEqual(MarkdownEditing.newline(text: line, selection: caret, plain: true).applying(to: line), line + "\n")
        }
        for line in ["- ", "* ", "+ ", "3. ", "- [x] ", "- [ ] "] {
            XCTAssertEqual(MarkdownEditing.newline(text: line, selection: NSRange(location: line.utf16.count, length: 0)).applying(to: line), "")
        }
        XCTAssertEqual(MarkdownEditing.newline(text: "- \nabc", selection: NSRange(location: 2, length: 4)).applying(to: "- \nabc"), "- \n- ")
        for text in ["- item", "a\nb", "", "👩🏽‍💻"] {
            let edit = MarkdownEditing.edit(.indent, text: text, selection: NSRange(location: 0, length: text.utf16.count))
            let indented = edit.applying(to: text)
            XCTAssertEqual(MarkdownEditing.edit(.outdent, text: indented, selection: edit.selection).applying(to: indented), text)
        }
        XCTAssertEqual(MarkdownEditing.edit(.outdent, text: "\t- item", selection: NSRange(location: 0, length: 0)).replacement, "- item")
    }

    func testLinkCaretModes() {
        for clipboard in [nil, "https://example.com/a", "http://example.com", "ftp://example.com", "ordinary text"] as [String?] {
            let valid = clipboard?.hasPrefix("http") == true
            let url = valid ? clipboard! : ""
            let selected = MarkdownEditing.edit(.link, text: "日本語", selection: NSRange(location: 0, length: 3), clipboard: clipboard)
            XCTAssertEqual(selected.replacement, "[日本語](\(url))")
            XCTAssertEqual(selected.selection.location, valid ? selected.replacement.utf16.count : 6)
            let empty = MarkdownEditing.edit(.link, text: "", selection: NSRange(location: 0, length: 0), clipboard: clipboard)
            XCTAssertEqual(empty.replacement, "[](\(url))")
            XCTAssertEqual(empty.selection.location, 1)
        }
    }

    func testStylingTokensAndFenceState() {
        for level in 1...6 {
            let result = MarkdownTokens.paragraph(String(repeating: "#", count: level) + " Title\n", fenced: false)
            XCTAssertTrue(result.tokens.contains { $0.kind == .heading(level) })
        }
        for (value, kind) in [("**bold**", MarkdownToken.Kind.bold), ("_italic_", .italic), ("~~strike~~", .strike), ("`code`", .code), ("[link](url)", .link), ("> quote", .quote)] {
            XCTAssertTrue(MarkdownTokens.paragraph(value, fenced: false).tokens.contains { $0.kind == kind })
        }
        XCTAssertTrue(MarkdownTokens.paragraph("```swift\n", fenced: false).fenced)
        XCTAssertEqual(MarkdownTokens.paragraph("**plain**\n", fenced: true).tokens.first?.kind, .code)
        XCTAssertFalse(MarkdownTokens.paragraph("```\n", fenced: true).fenced)
        XCTAssertFalse(MarkdownTokens.paragraph("`**plain**`", fenced: false).tokens.contains { $0.kind == .bold })
    }
}

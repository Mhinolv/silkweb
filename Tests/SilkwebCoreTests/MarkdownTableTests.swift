import XCTest

@testable import SilkwebCore

final class MarkdownTableTests: XCTestCase {
    func testEveryDimensionAndAlignmentIsCompact() {
        for columns in 1...20 {
            for rows in 1...100 {
                for alignment in TableAlignment.allCases {
                    let source = MarkdownTable.source(
                        options: TableOptions(columns: columns, rows: rows, alignment: alignment))
                    let lines = source.components(separatedBy: "\n")
                    XCTAssertEqual(lines.count, rows + 2)
                    XCTAssertEqual(
                        lines[0], "| " + (1...columns).map { "Column \($0)" }.joined(separator: " | ") + " |")
                    XCTAssertEqual(
                        lines[1],
                        "| " + Array(repeating: alignment.marker, count: columns).joined(separator: " | ") + " |")
                    XCTAssertTrue(
                        lines.dropFirst(2).allSatisfy { $0 == String(repeating: "|  ", count: columns) + "|" })
                    for line in lines {
                        XCTAssertEqual(line.filter { $0 == "|" }.count, columns + 1)
                        XCTAssertTrue(line.hasPrefix("| ") && line.hasSuffix(" |"), line)
                    }
                    // Exactly one space on each side of every pipe: no padding runs (body rows checked above).
                    for line in lines.prefix(2) {
                        XCTAssertFalse(line.contains("  "), line)
                    }
                    let markers = lines[1].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    XCTAssertEqual(markers.count, columns)
                    for marker in markers {
                        XCTAssertEqual(marker.hasPrefix(":"), alignment == .left || alignment == .center)
                        XCTAssertEqual(marker.hasSuffix(":"), alignment == .right || alignment == .center)
                        XCTAssertEqual(marker.filter { $0 == "-" }.count, 3)
                    }
                }
            }
        }
    }
    func testCompactExactOutput() {
        let expected: [TableAlignment: String] = [.default: "---", .left: ":---", .center: ":---:", .right: "---:"]
        for (alignment, marker) in expected {
            XCTAssertEqual(
                MarkdownTable.source(options: TableOptions(columns: 3, rows: 1, alignment: alignment)),
                "| Column 1 | Column 2 | Column 3 |\n| \(marker) | \(marker) | \(marker) |\n|  |  |  |")
            XCTAssertEqual(
                MarkdownTable.source(options: TableOptions(columns: 1, rows: 1, alignment: alignment)),
                "| Column 1 |\n| \(marker) |\n|  |")
        }
    }
    func testEscapingWithoutPadding() {
        XCTAssertEqual(MarkdownTable.escape("a|b\\|c\r\nd\ne\rf"), "a\\|b\\\\\\|c d e f")
        let source = MarkdownTable.source(options: TableOptions(columns: 2, rows: 1), headers: ["A|B", "Long header"])
        XCTAssertEqual(source.components(separatedBy: "\n")[0], "| A\\|B | Long header |")
        XCTAssertEqual(source.components(separatedBy: "\n")[1], "| --- | --- |")
        XCTAssertEqual(source.components(separatedBy: "\n")[2], "|  |  |")
    }
    func testGeneratedSourceParsesAsTableIncludingEscapedHeaders() {
        for alignment in TableAlignment.allCases {
            for columns in [1, 20] {
                for rows in [1, 100] {
                    let source = MarkdownTable.source(
                        options: TableOptions(columns: columns, rows: rows, alignment: alignment), headers: ["A|B"])
                    guard case .table(let header, let markers, let body) = MarkdownParser.parse(source).blocks.first
                    else {
                        XCTFail("Generated source must parse as a table"); continue
                    }
                    XCTAssertEqual(header.count, columns)
                    XCTAssertEqual(body.count, rows)
                    XCTAssertTrue(body.allSatisfy { $0.count == columns })
                    XCTAssertEqual(header[0].map(\.plainText).joined(), "A|B")
                    let expected: MarkdownTableAlignment? =
                        alignment == .default ? nil : MarkdownTableAlignment(rawValue: alignment.rawValue)
                    XCTAssertEqual(markers, Array(repeating: expected, count: columns))
                }
            }
        }
    }
    func testInsertionBoundariesAndReplacement() {
        let options = TableOptions(columns: 1, rows: 1)
        let table = MarkdownTable.source(options: options)
        for before in ["", "before", "before\n", "before\n\n", "before\n\n\n", "😀"] {
            for after in ["", "after", "\nafter", "\n\nafter", "\n\n\nafter", "日本語"] {
                let text = before + "REPLACE" + after
                let edit = MarkdownTable.insertion(
                    text: text, selection: NSRange(location: before.utf16.count, length: 7), options: options)
                let result = edit.applying(to: text)
                let prefix = before.isEmpty || before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
                let suffix = after.isEmpty || after.hasPrefix("\n\n") ? "" : after.hasPrefix("\n") ? "\n" : "\n\n"
                XCTAssertEqual(result, before + prefix + table + suffix + after)
                XCTAssertEqual((result as NSString).substring(with: edit.selection), "Column 1")
            }
        }
        let edit = MarkdownTable.insertion(text: "", selection: NSRange(location: 0, length: 0), options: options)
        XCTAssertEqual(edit.applying(to: ""), table)
    }
    func testTolerantPreferencesAndInput() throws {
        XCTAssertEqual(TableOptions(columns: Int.min, rows: Int.max), TableOptions(columns: 1, rows: 100))
        for payload in ["{}", "{\"version\":0}", "{\"alignment\":\"future\",\"rows\":null,\"columns\":\"bad\"}"] {
            XCTAssertEqual(try JSONDecoder().decode(TableOptions.self, from: Data(payload.utf8)), TableOptions())
        }
        let defaults = disposableDefaults("TableOptions")
        for alignment in TableAlignment.allCases {
            let options = TableOptions(columns: 20, rows: 100, alignment: alignment)
            options.save(to: defaults)
            XCTAssertEqual(TableOptions.load(from: defaults), options)
        }
        XCTAssertNil(TableOptions.dimension("no", within: 1...20))
        XCTAssertNil(TableOptions.dimension("", within: 1...20))
        XCTAssertEqual(TableOptions.dimension(" -1 ", within: 1...20), 1)
        XCTAssertEqual(TableOptions.dimension("1000", within: 1...20), 20)
    }
}

import XCTest
@testable import SilkwebCore

final class OutlineDepthTests: XCTestCase {
    private func indents(_ text: String) -> [Double] {
        OutlineItem.parse(text).map { item in
            switch item.content {
            case .heading(let heading): return OutlineRowStyle(level: heading.level, depth: item.depth).indent
            case .image: return item.indent
            }
        }
    }

    /// Owner example: level-based indent gave 0/60/72/24/60/72 pt on fec8ed0.
    func testSkippedLevelsIndentByTreeDepth() {
        let text = "# Settling In\n###### Jamestown\n![](a.png)\n### Building\n###### Lake Erie\n![](b.png)\n"
        XCTAssertEqual(OutlineItem.parse(text).map(\.depth), [0, 1, 2, 1, 2, 3])
        XCTAssertEqual(indents(text), [0, 16, 28, 16, 28, 40])
    }

    func testCapPreHeadingImagesAndShallowerLaterHeadings() {
        // Every level nested: depths 0...5, the image 6; all clamp to depth 4 (52 pt).
        let chain = (1...6).map { String(repeating: "#", count: $0) + " H\($0)" }.joined(separator: "\n") + "\n![](deep.png)\n"
        XCTAssertEqual(OutlineItem.parse(chain).map(\.depth), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(indents(chain), [0, 16, 28, 40, 52, 52, 52])
        // Images before the first heading stay at depth 0; a later shallower heading resets.
        XCTAssertEqual(indents("![](a.png)\n## Two\n![](b.png)\n# One\n### Three\n## Two again\n"), [0, 0, 16, 0, 16, 16])
        XCTAssertEqual(indents("![](only.png)\n![](also.png)\n"), [0, 0])
        XCTAssertEqual(indents("###### Six\n###### Six\n# One\n"), [0, 0, 0])
        XCTAssertTrue(indents("").isEmpty)
    }

    func testDepthSweepMatchesHeadingStack() {
        // Every 3-heading level combination plus an image: depth never exceeds the
        // number of strictly shallower enclosing headings.
        for a in 1...6 { for b in 1...6 { for c in 1...6 {
            let text = "\(String(repeating: "#", count: a)) A\n\(String(repeating: "#", count: b)) B\n\(String(repeating: "#", count: c)) C\n![](x.png)\n"
            let items = OutlineItem.parse(text)
            var expected: [Int] = []
            var stack: [Int] = []
            for level in [a, b, c] {
                stack = stack.filter { $0 < level }
                expected.append(stack.count); stack.append(level)
            }
            XCTAssertEqual(items.map(\.depth), expected + [expected[2] + 1], text)
            XCTAssertTrue(items.allSatisfy { (0...52).contains($0.indent) })
        } } }
    }
}

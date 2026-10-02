import XCTest
@testable import SilkwebCore

final class OutlineRowStyleTests: XCTestCase {
    func testEveryLevelIndentAndSectionRhythm() {
        for shallowest in 1...6 {
            for level in 1...6 {
                for first in [false, true] {
                    let style = OutlineRowStyle(level: level, shallowest: shallowest, isFirst: first)
                    XCTAssertEqual(style.fontSize, [15, 14, 13, 12, 11, 11][level - 1])
                    XCTAssertEqual(style.isSemibold, level <= 2)
                    XCTAssertEqual(style.indent, Double(max(0, level - shallowest) * 12))
                    XCTAssertEqual(style.spacingAbove, level == 1 && !first ? 6 : level == 2 ? 2 : 0)
                }
            }
        }
        for level in [Int.min, -1, 0, 7, Int.max] {
            for shallowest in [Int.min, 0, 7, Int.max] {
                let style = OutlineRowStyle(level: level, shallowest: shallowest, isFirst: false)
                XCTAssertTrue((11...15).contains(style.fontSize))
                XCTAssertTrue((0...60).contains(style.indent))
            }
        }
    }
}

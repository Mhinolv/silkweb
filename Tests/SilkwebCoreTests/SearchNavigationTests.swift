import XCTest
@testable import SilkwebCore

final class SearchNavigationTests: XCTestCase {
    func testSelectionSweep() {
        for count in [0, 1, 2, 12, 10000, Int.max] {
            for current in [nil, -1, 0, count - 1, count] {
                for delta in [Int.min, -10001, -12, -1, 0, 1, 12, 10001, Int.max] {
                    let next = SearchNavigation.nextIndex(current: current, count: count, delta: delta)
                    if count == 0 { XCTAssertNil(next) }
                    else { XCTAssertTrue((0..<count).contains(next!)) }
                }
            }
        }
        XCTAssertEqual(SearchNavigation.nextIndex(current: 0, count: 12, delta: -1), 11)
        XCTAssertEqual(SearchNavigation.nextIndex(current: 11, count: 12, delta: 1), 0)
    }

    func testHighlightUnicodeAndLiteralQuerySweep() {
        for text in ["", "Café cafe CAFÉ", "👩🏽‍💻", String(repeating: "é👩🏽‍💻 café ", count: 1000)] {
            for query in ["", " \n", "cafe", "é", "👩🏽‍💻", "absent", "tag:x", "cafe é"] {
                for range in SearchNavigation.matchRanges(in: text, query: query) {
                    XCTAssertNotNil(Range(range, in: text))
                    XCTAssertGreaterThan(range.length, 0)
                    XCTAssertLessThanOrEqual(NSMaxRange(range), (text as NSString).length)
                }
            }
        }
        XCTAssertEqual(SearchNavigation.matchRanges(in: "Café cafe CAFÉ", query: "cafe").count, 3)
    }
}

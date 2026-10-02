import XCTest
@testable import SilkwebCore

final class CountPresentationTests: XCTestCase {
    func testEveryUnitAndCountBoundary() {
        XCTAssertEqual(CountPresentation.label(1, unit: .document), "1 document")
        XCTAssertEqual(CountPresentation.label(0, unit: .document), "0 documents")
        XCTAssertEqual(CountPresentation.label(2, unit: .document), "2 documents")
        XCTAssertEqual(CountPresentation.label(1, unit: .heading), "1 heading")
        XCTAssertEqual(CountPresentation.label(2, unit: .heading), "2 headings")
        for unit in CountPresentation.Unit.allCases {
            for count in [0, 1, 2, 999, 1_204, 10_000, Int.max] {
                XCTAssertEqual(CountPresentation.label(count, unit: unit),
                               count.formatted() + " " + unit.rawValue + (count == 1 ? "" : "s"))
            }
        }
    }

    func testSidebarVisibleAndSpokenCountsAgree() {
        for direct in [0, 1, 2, 1_204, Int.max] {
            for recursive in [direct, Int.max] {
                let count = FolderDocumentCount(direct: direct, recursive: recursive)
                XCTAssertEqual(count.tooltip, CountPresentation.label(direct, unit: .document) + " · " + recursive.formatted() + " including subfolders")
                XCTAssertEqual(count.accessibilityValue, CountPresentation.label(direct, unit: .document) + ", " + recursive.formatted() + " including subfolders")
            }
        }
    }
}

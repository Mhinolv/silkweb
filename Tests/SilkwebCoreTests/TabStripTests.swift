import Foundation
import XCTest

@testable import SilkwebCore

final class TabStripTests: XCTestCase {
    func testNoStoredOrderListsEachLibraryInTurn() {
        XCTAssertEqual(TabStripOrder.merge(stored: [String](), groups: [["a1", "a2"], ["b1"]]), ["a1", "a2", "b1"])
        XCTAssertEqual(TabStripOrder.merge(stored: [String](), groups: [[], []]), [])
        XCTAssertEqual(TabStripOrder.merge(stored: ["gone"], groups: [[String]]()), [])
    }

    func testStoredInterleavingIsKept() {
        let stored = ["b1", "a1", "b2", "a2"]
        XCTAssertEqual(TabStripOrder.merge(stored: stored, groups: [["a1", "a2"], ["b1", "b2"]]), stored)
    }

    func testANewTabOpensAfterItsLibrarysPreviousTab() {
        // A Library inserts a new tab after its active one: the strip shows it there, not at the end.
        let merged = TabStripOrder.merge(stored: ["a1", "b1", "a2"], groups: [["a1", "new", "a2"], ["b1"]])
        XCTAssertEqual(merged, ["a1", "new", "b1", "a2"])
        // The first tab of a Library goes before its next one; a Library's only tab goes at the end.
        XCTAssertEqual(
            TabStripOrder.merge(stored: ["b1", "a1"], groups: [["first", "a1"], ["b1"]]), ["b1", "first", "a1"])
        XCTAssertEqual(TabStripOrder.merge(stored: ["a1"], groups: [["a1"], ["b1"]]), ["a1", "b1"])
        // Several new tabs in a row keep their Library's order.
        XCTAssertEqual(
            TabStripOrder.merge(stored: ["a1", "b1"], groups: [["a1", "x", "y"], ["b1"]]), ["a1", "x", "y", "b1"])
    }

    func testClosedAndDuplicateKeysAreDropped() {
        XCTAssertEqual(
            TabStripOrder.merge(stored: ["a1", "closed", "b1", "a1"], groups: [["a1"], ["b1"]]), ["a1", "b1"])
    }

    func testAReorderInsideOneLibraryFillsItsSlots() {
        // Move Tab Right inside A: A's slots swap, B's tab stays between them.
        let merged = TabStripOrder.merge(stored: ["a1", "b1", "a2"], groups: [["a2", "a1"], ["b1"]])
        XCTAssertEqual(merged, ["a2", "b1", "a1"])
    }

    func testAKeyInTwoGroupsBelongsToTheFirst() {
        XCTAssertEqual(TabStripOrder.merge(stored: [String](), groups: [["same"], ["same", "b"]]), ["same", "b"])
    }

    func testMoveToGap() {
        let strip = ["a", "b", "c", "d"]
        XCTAssertEqual(TabStripOrder.move("a", toGap: 4, in: strip), ["b", "c", "d", "a"])
        XCTAssertEqual(TabStripOrder.move("d", toGap: 0, in: strip), ["d", "a", "b", "c"])
        XCTAssertEqual(TabStripOrder.move("b", toGap: 1, in: strip), strip)
        XCTAssertEqual(TabStripOrder.move("b", toGap: 2, in: strip), strip)
        XCTAssertEqual(TabStripOrder.move("b", toGap: 3, in: strip), ["a", "c", "b", "d"])
        XCTAssertEqual(TabStripOrder.move("c", toGap: -5, in: strip), ["c", "a", "b", "d"])
        XCTAssertEqual(TabStripOrder.move("c", toGap: 99, in: strip), ["a", "b", "d", "c"])
        XCTAssertEqual(TabStripOrder.move("x", toGap: 0, in: strip), strip)
    }

    func testSuffixTruncatesBeforeTheTitle() {
        // Room for both.
        XCTAssertEqual(TabTitleWidths.fit(budget: 200, title: 80, suffix: 60), TabTitleWidths(title: 80, suffix: 60))
        // The suffix shrinks first, down to nothing, before the title truncates.
        XCTAssertEqual(TabTitleWidths.fit(budget: 120, title: 80, suffix: 60), TabTitleWidths(title: 80, suffix: 40))
        XCTAssertEqual(TabTitleWidths.fit(budget: 80, title: 80, suffix: 60), TabTitleWidths(title: 80, suffix: 0))
        XCTAssertEqual(TabTitleWidths.fit(budget: 60, title: 200, suffix: 70), TabTitleWidths(title: 60, suffix: 0))
        // No suffix behaves as before; nothing goes negative.
        XCTAssertEqual(TabTitleWidths.fit(budget: 150, title: 200, suffix: 0), TabTitleWidths(title: 150, suffix: 0))
        XCTAssertEqual(TabTitleWidths.fit(budget: -5, title: 20, suffix: 20), TabTitleWidths(title: 0, suffix: 0))
    }

    func testSearchResultInLibraryLeadsItsLocationWithTheLibrary() {
        let result = SearchResult(
            id: UUID(), displayName: "Draft", folderPathComponents: ["Drafts"], modified: nil, matchKind: .title,
            snippet: "s", matchRanges: [NSRange(location: 0, length: 1)])
        let id = UUID()
        let moved = result.inLibrary("Writing", id: id)
        XCTAssertEqual(moved.id, id)
        XCTAssertEqual(moved.folderPathComponents, ["Writing", "Drafts"])
        XCTAssertEqual(moved.displayName, "Draft")
        XCTAssertEqual(moved.snippet, "s")
        XCTAssertEqual(moved.matchRanges, result.matchRanges)
    }
}

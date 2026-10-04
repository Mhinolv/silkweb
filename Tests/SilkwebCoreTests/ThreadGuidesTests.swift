import XCTest
@testable import SilkwebCore

final class ThreadGuidesTests: XCTestCase {
    private let metrics = ThreadGuides.Metrics(leadingInset: 12)

    /// Fixed tree (levels 0–4):
    /// ```
    /// Library            0
    /// ├ A                1  (has children, following sibling F)
    /// │ ├ B              2  (has children, following sibling E)
    /// │ │ └ C            3  (has children, last)
    /// │ │   └ D          4  (leaf, last)
    /// │ └ E              2  (leaf, last)
    /// └ F                1  (leaf, last)
    /// ```
    func testElbowAndRailPositionsForDepthsOneToFour() {
        typealias S = ThreadGuides.Segment
        let g = { (level: Int) in 12 + Double(level) * 16 + 6.5 }
        XCTAssertEqual([0, 1, 2, 3].map { ThreadGuides.guideX(level: $0, metrics: metrics) }, [18.5, 34.5, 50.5, 66.5])
        let rows: [(String, Int, Bool, [Bool], Bool, [S])] = [
            ("Library", 0, true, [], true, []),
            ("A", 1, false, [], true, [.rail(x: g(0)), .elbow(x: g(0), cornerY: 14, radius: 6, endX: 12 + 16 + 2 - 3)]),
            ("B", 2, false, [true], true, [.rail(x: g(0)), .rail(x: g(1)), .elbow(x: g(1), cornerY: 14, radius: 6, endX: 12 + 32 + 2 - 3)]),
            ("C", 3, true, [true, true], true, [.rail(x: g(0)), .rail(x: g(1)), .elbow(x: g(2), cornerY: 14, radius: 6, endX: 12 + 48 + 2 - 3)]),
            ("D", 4, true, [true, true, false], false, [.rail(x: g(0)), .rail(x: g(1)), .elbow(x: g(3), cornerY: 14, radius: 6, endX: 12 + 64 + 13 + 2 - 3)]),
            ("E", 2, true, [true], false, [.rail(x: g(0)), .elbow(x: g(1), cornerY: 14, radius: 6, endX: 12 + 32 + 13 + 2 - 3)]),
            ("F", 1, true, [], false, [.elbow(x: g(0), cornerY: 14, radius: 6, endX: 12 + 16 + 13 + 2 - 3)]),
        ]
        for (name, level, last, ancestors, children, expected) in rows {
            XCTAssertEqual(ThreadGuides.segments(level: level, isLastChild: last, ancestorContinues: ancestors,
                                                 hasChildren: children, metrics: metrics), expected, name)
        }
    }

    func testElbowEndsBeforeChevronOrIconAndNeverBeforeTheArc() {
        for level in 1...12 {
            for children in [false, true] {
                for last in [false, true] {
                    let segments = ThreadGuides.segments(level: level, isLastChild: last,
                                                         ancestorContinues: Array(repeating: true, count: level - 1),
                                                         hasChildren: children, metrics: metrics)
                    guard case let .elbow(x, cornerY, radius, endX)? = segments.last else { return XCTFail("elbow last") }
                    XCTAssertEqual(x, ThreadGuides.guideX(level: level - 1, metrics: metrics))
                    XCTAssertEqual(cornerY, 14)
                    XCTAssertEqual(radius, 6)
                    let target = children ? ThreadGuides.chevronMinX(level: level, metrics: metrics) : ThreadGuides.iconMinX(level: level, metrics: metrics)
                    XCTAssertEqual(endX, target - 3, "level \(level)")
                    XCTAssertGreaterThanOrEqual(endX, x + radius)
                    // Rails: one per continuing ancestor plus the row's own continuation.
                    XCTAssertEqual(segments.count, (level - 1) + (last ? 0 : 1) + 1)
                }
            }
        }
        // A cramped slot still keeps the horizontal at least as long as the arc.
        var tight = metrics
        tight.chevronWidth = 13
        tight.gap = 6
        guard case let .elbow(x, _, radius, endX)? = ThreadGuides.segments(level: 1, isLastChild: true, ancestorContinues: [],
                                                                         hasChildren: true, metrics: tight).last else { return XCTFail() }
        XCTAssertEqual(endX, x + radius)
    }

    func testLevelZeroAndMalformedInputs() {
        for level in [Int.min, -1, 0] {
            XCTAssertEqual(ThreadGuides.segments(level: level, isLastChild: false, ancestorContinues: [true], hasChildren: true, metrics: metrics), [])
        }
        // Missing ancestor flags draw no rails rather than trapping.
        XCTAssertEqual(ThreadGuides.segments(level: 4, isLastChild: true, ancestorContinues: [], hasChildren: false, metrics: metrics).count, 1)
    }
}

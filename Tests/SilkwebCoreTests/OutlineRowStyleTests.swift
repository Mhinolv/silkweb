import XCTest
@testable import SilkwebCore

final class OutlineRowStyleTests: XCTestCase {
    /// #72 thread tree: one 13 pt size; H1 semibold, H2 regular, H3+ secondary; 12 pt per level.
    func testEveryLevelAndDepth() {
        XCTAssertEqual(OutlineRowStyle.fontSize, 13)
        for depth in 0...6 {
            for level in 1...6 {
                let style = OutlineRowStyle(level: level, depth: depth)
                XCTAssertEqual(style.isSemibold, level == 1)
                XCTAssertEqual(style.isSecondary, level >= 3)
                XCTAssertEqual(style.indent, depth == 0 ? 0 : Double(min(depth, 4) * 12 + 4))
            }
        }
        for level in [Int.min, -1, 0, 7, Int.max] {
            for depth in [Int.min, -1, 0, 7, Int.max] {
                let style = OutlineRowStyle(level: level, depth: depth)
                XCTAssertTrue((0...52).contains(style.indent))
                XCTAssertEqual(style.isSemibold, level < 1)
            }
        }
    }

    /// Each elbow hangs from the parent's guide and stops 3 pt before the child's text.
    func testElbowsPointAtTheChildText() {
        let metrics = OutlineRowStyle.threadMetrics()
        for depth in 1...4 {
            let thread = OutlineRowStyle.Thread(level: depth, isLastChild: true, ancestorContinues: Array(repeating: false, count: depth - 1))
            guard case .elbow(let x, let cornerY, let radius, let endX) = thread.segments().last else { return XCTFail("depth \(depth)") }
            XCTAssertEqual(x, ThreadGuides.guideX(level: depth - 1, metrics: metrics))
            XCTAssertEqual(x, Double(depth - 1) * 12 + 5)
            XCTAssertEqual(cornerY, OutlineRowStyle.rowHeight / 2)
            XCTAssertEqual(radius, 6)
            XCTAssertEqual(endX, OutlineRowStyle.indent(depth: depth) - 3)
            XCTAssertGreaterThanOrEqual(endX, x + radius)
        }
        XCTAssertTrue(OutlineRowStyle.Thread(level: 0, isLastChild: true, ancestorContinues: []).segments().isEmpty)
    }

    func testThreadsFromDepths() {
        typealias T = OutlineRowStyle.Thread
        // # A / ## B / ### C / image under B's child / ## D / # E / ## F
        let depths = [0, 1, 2, 3, 1, 0, 1]
        XCTAssertEqual(OutlineRowStyle.threads(depths: depths), [
            T(level: 0, isLastChild: false, ancestorContinues: []),
            T(level: 1, isLastChild: false, ancestorContinues: []),
            T(level: 2, isLastChild: true, ancestorContinues: [true]),
            T(level: 3, isLastChild: true, ancestorContinues: [true, false]),
            T(level: 1, isLastChild: true, ancestorContinues: []),
            T(level: 0, isLastChild: true, ancestorContinues: []),
            T(level: 1, isLastChild: true, ancestorContinues: [])
        ])
        // The rail for B's siblings passes through C and its image, so D connects to B.
        XCTAssertEqual(OutlineRowStyle.threads(depths: depths)[3].segments().first, .rail(x: 5))
        XCTAssertTrue(OutlineRowStyle.threads(depths: []).isEmpty)
        XCTAssertEqual(OutlineRowStyle.threads(depths: [0, 0]).map(\.isLastChild), [false, true])
        // Deep chains clamp to depth 4 like the indent; out-of-range values never trap.
        let clamped = OutlineRowStyle.threads(depths: [0, 1, 2, 3, 4, 5, 6, -3, Int.max])
        XCTAssertEqual(clamped.map(\.level), [0, 1, 2, 3, 4, 4, 4, 0, 4])
        XCTAssertEqual(clamped[4].isLastChild, false)
        XCTAssertEqual(clamped[6].isLastChild, true)
        XCTAssertTrue(clamped.allSatisfy { $0.ancestorContinues.count == max(0, $0.level - 1) })
    }

    /// Brute force: a row's rail at level k continues iff a later row at depth k comes before any shallower row.
    func testThreadSweepMatchesBruteForce() {
        var sequences: [[Int]] = [[0]]
        for _ in 0..<6 { sequences = sequences.flatMap { s in (0...min(4, s.last! + 1)).map { s + [$0] } } }
        for depths in sequences {
            let threads = OutlineRowStyle.threads(depths: depths)
            func continues(after index: Int, at level: Int) -> Bool {
                for j in depths.indices where j > index {
                    if depths[j] < level { return false }
                    if depths[j] == level { return true }
                }
                return false
            }
            for (i, thread) in threads.enumerated() {
                XCTAssertEqual(thread.isLastChild, !continues(after: i, at: depths[i]), "\(depths) row \(i)")
                XCTAssertEqual(thread.ancestorContinues, (0..<max(0, depths[i] - 1)).map { continues(after: i, at: $0 + 1) }, "\(depths) row \(i)")
            }
        }
    }
}

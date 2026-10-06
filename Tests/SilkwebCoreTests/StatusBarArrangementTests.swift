import XCTest

@testable import SilkwebCore

/// #91: path leading, counts on the true midline, trailing cluster fixed; the narrow rules in order.
final class StatusBarArrangementTests: XCTestCase {
    /// Counts like `DocumentStatusCounts`: the full label, then words only, then tail-truncated words.
    static func counts(full: Double = 200, words: Double = 90) -> (Double) -> Double {
        { offered in offered >= full ? full : offered >= words ? words : offered }
    }

    func arrange(
        width: Double, path: (minimum: Double, ideal: Double), full: Double = 200, words: Double = 90,
        trailing: Double = 100
    ) -> StatusBarArrangement {
        StatusBarArrangement.arrange(
            width: width, pathLeading: 12, trailingEdge: width - 16, gap: 12, pathMinimum: path.minimum,
            pathIdeal: path.ideal, counts: Self.counts(full: full, words: words), countsMinimum: 48,
            trailing: trailing)
    }

    func testWideBarCentresTheCountsOnTheMidlineWithTheWholePath() {
        let zones = arrange(width: 1000, path: (120, 300))
        XCTAssertEqual(zones.pathWidth, 300)
        XCTAssertEqual(zones.countsWidth, 200)
        XCTAssertEqual(zones.countsX + zones.countsWidth / 2, 500, "true midline, not the gap between neighbours")
        XCTAssertEqual(zones.trailingX, 1000 - 16 - 100)
    }

    func testPathFoldsBeforeTheCountsLeaveTheMidline() {
        // Room for the path: 12 … 500 - 100 - 12 = 388 → 376 pt.
        let zones = arrange(width: 1000, path: (120, 600))
        XCTAssertEqual(zones.pathWidth, 376)
        XCTAssertEqual(zones.countsX, 400, "still centred")
        XCTAssertEqual(zones.countsX - (12 + zones.pathWidth), 12)
    }

    func testFoldedPathPushesTheCountsTowardTheTrailingSide() {
        let zones = arrange(width: 800, path: (360, 600))
        XCTAssertEqual(zones.pathWidth, 360, "the folded minimum")
        XCTAssertEqual(zones.countsX, 12 + 360 + 12, "12 pt after the path, off-centre")
        XCTAssertGreaterThan(zones.countsX + zones.countsWidth / 2, 400)
        XCTAssertLessThanOrEqual(zones.countsX + zones.countsWidth, zones.trailingX - 12)
    }

    func testCountsNarrowThenHide() {
        // 12 + 300 + 12 = 324 … trailingX - 12 = 540 - 16 - 100 - 12 = 412: 88 pt, below words (90).
        let narrowed = arrange(width: 540, path: (300, 300))
        XCTAssertEqual(narrowed.countsWidth, 88, "tail-truncated words")
        XCTAssertEqual(narrowed.countsX, 324)
        let words = arrange(width: 560, path: (300, 300))
        XCTAssertEqual(words.countsWidth, 90, "characters dropped first")
        let hidden = arrange(width: 480, path: (300, 300))
        XCTAssertFalse(hidden.showsCounts)
        XCTAssertEqual(hidden.pathWidth, 300)
        // Too narrow even for the folded path: the path is clipped short of the trailing cluster.
        let tiny = arrange(width: 300, path: (200, 400))
        XCTAssertFalse(tiny.showsCounts)
        XCTAssertEqual(12 + tiny.pathWidth, tiny.trailingX - 12)
    }

    func testNoPathCentresTheCounts() {
        let zones = arrange(width: 600, path: (0, 0))
        XCTAssertEqual(zones.pathWidth, 0)
        XCTAssertEqual(zones.countsX, 200)
    }

    /// Every width, path and counts combination: zones stay in order and `gap` apart, the trailing cluster keeps
    /// its width, the counts are centred whenever they fit centred, and the path never exceeds its ideal.
    func testSweepNeverOverlaps() {
        for (minimum, ideal) in [(0.0, 0.0), (60, 60), (120, 300), (200, 900), (400, 400)] {
            for (full, words) in [(200.0, 90.0), (320, 140), (60, 40)] {
                for trailing in [40.0, 100, 180] {
                    for width in stride(from: 160.0, through: 2400, by: 7) {
                        let zones = arrange(
                            width: width, path: (minimum, ideal), full: full, words: words, trailing: trailing)
                        let context = "w \(width) path \(minimum)…\(ideal) counts \(full)/\(words) trailing \(trailing)"
                        XCTAssertEqual(zones.trailingX, width - 16 - trailing, context)
                        XCTAssertLessThanOrEqual(zones.pathWidth, ideal, context)
                        XCTAssertGreaterThanOrEqual(zones.pathWidth, 0, context)
                        let pathEnd = 12 + zones.pathWidth
                        if zones.showsCounts {
                            // A short words-only label may be narrower than the minimum, but never a sliver.
                            XCTAssertGreaterThanOrEqual(zones.countsWidth, min(48, words) - 0.001, context)
                            XCTAssertGreaterThanOrEqual(zones.countsX, pathEnd + 12 - 0.001, context)
                            XCTAssertLessThanOrEqual(
                                zones.countsX + zones.countsWidth, zones.trailingX - 12 + 0.001, context)
                            XCTAssertGreaterThanOrEqual(zones.pathWidth, minimum, context)
                            let centred = width / 2 - full / 2
                            if zones.countsWidth == full, centred >= pathEnd + 12,
                                centred + full <= zones.trailingX - 12
                            {
                                XCTAssertEqual(zones.countsX, centred, accuracy: 0.001, context)
                            }
                        } else {
                            XCTAssertLessThanOrEqual(pathEnd, max(12, zones.trailingX - 12) + 0.001, context)
                        }
                    }
                }
            }
        }
    }
}

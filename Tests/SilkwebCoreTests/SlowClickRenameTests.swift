import XCTest

@testable import SilkwebCore

final class SlowClickRenameTests: XCTestCase {
    func testTimingAndSelectionSweep() {
        for interval in [-1.0, 0, 0.49, 0.5, 1, 1.5, 1.51, 100] {
            for count in [1, 2, 3] {
                for before in [false, true] {
                    for after in [false, true] {
                        for modifiers in [false, true] {
                            for path in ["A", "B"] {
                                var timing = SlowClickRename()
                                XCTAssertFalse(
                                    timing.click(
                                        path: "A", timestamp: 10, clickCount: 1,
                                        wasSingleSelected: false, isSingleSelected: true))
                                XCTAssertEqual(
                                    timing.click(
                                        path: path, timestamp: 10 + interval, clickCount: count,
                                        wasSingleSelected: before, isSingleSelected: after,
                                        hasModifiers: modifiers),
                                    path == "A" && (0.5...1.5).contains(interval) && count == 1 && before && after
                                        && !modifiers)
                            }
                        }
                    }
                }
            }
        }
    }

    func testResetAndDoubleClickDoNotSeedRename() {
        var timing = SlowClickRename()
        _ = timing.click(path: "A", timestamp: 0, clickCount: 1, wasSingleSelected: true, isSingleSelected: true)
        timing.reset()
        XCTAssertFalse(
            timing.click(path: "A", timestamp: 1, clickCount: 1, wasSingleSelected: true, isSingleSelected: true))
        XCTAssertFalse(
            timing.click(path: "A", timestamp: 1.6, clickCount: 2, wasSingleSelected: true, isSingleSelected: true))
        XCTAssertFalse(
            timing.click(path: "A", timestamp: 2.2, clickCount: 1, wasSingleSelected: true, isSingleSelected: true))
    }
}

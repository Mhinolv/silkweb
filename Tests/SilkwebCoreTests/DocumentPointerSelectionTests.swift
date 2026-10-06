import XCTest

@testable import SilkwebCore

final class DocumentPointerSelectionTests: XCTestCase {
    func testSelectionModeAndAnchorSweep() {
        for count in [1, 2, 3, 1000, 10000] {
            let paths = (0..<count).map { "\($0).md" }
            for target in [0, count - 1] {
                for anchor in [0, count - 1] {
                    for selected in [Set<String>(), Set([paths[target]]), Set(paths)] {
                        for range in [false, true] {
                            for toggle in [false, true] {
                                let result = DocumentPointerSelection.selection(
                                    path: paths[target], orderedPaths: paths, selected: selected,
                                    anchor: paths[anchor], extendRange: range, toggle: toggle)
                                if range {
                                    let expected = Set(paths[min(anchor, target)...max(anchor, target)])
                                    XCTAssertEqual(result, toggle ? selected.union(expected) : expected)
                                } else if toggle {
                                    XCTAssertEqual(result, selected.symmetricDifference([paths[target]]))
                                } else {
                                    XCTAssertEqual(result, [paths[target]])
                                }
                            }
                        }
                    }
                }
            }
        }
        for paths in [[], ["A.md"]] {
            for anchor: String? in [nil, "missing.md"] {
                XCTAssertEqual(
                    DocumentPointerSelection.selection(
                        path: "A.md", orderedPaths: paths,
                        selected: [], anchor: anchor, extendRange: true, toggle: false), ["A.md"])
            }
        }
    }
}

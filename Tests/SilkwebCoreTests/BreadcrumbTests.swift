import XCTest

@testable import SilkwebCore

final class BreadcrumbTests: XCTestCase {
    func testPathFollowsTheOpenDocumentThenTheScope() {
        let document = Breadcrumb.make(
            libraryName: "Field Notes", documentPath: "Vanlife/East/Settling In.md",
            documentTitle: "Settling In", folder: nil, tagName: "draft")
        XCTAssertEqual(
            document.crumbs,
            [
                .init(title: "Field Notes", folderPath: ""), .init(title: "Vanlife", folderPath: "Vanlife"),
                .init(title: "East", folderPath: "Vanlife/East"),
            ])
        XCTAssertEqual(document.current, "Settling In")
        XCTAssertEqual(
            document.accessibilityValue(count: "12 documents"),
            "Field Notes › Vanlife › East › Settling In, 12 documents")
        let rootDocument = Breadcrumb.make(
            libraryName: "Field Notes", documentPath: "Note.md", documentTitle: "Note", folder: "Vanlife", tagName: nil)
        XCTAssertEqual(rootDocument.crumbs, [.init(title: "Field Notes", folderPath: "")])
        XCTAssertEqual(rootDocument.accessibilityValue(count: nil), "Field Notes › Note")

        let folder = Breadcrumb.make(
            libraryName: "Field Notes", documentPath: nil, documentTitle: "", folder: "Vanlife/East", tagName: nil)
        XCTAssertEqual(folder.crumbs.map(\.folderPath), ["", "Vanlife"])
        XCTAssertEqual(folder.current, "East")
        let root = Breadcrumb.make(
            libraryName: "Field Notes", documentPath: nil, documentTitle: "", folder: "", tagName: nil)
        XCTAssertEqual(root, Breadcrumb(crumbs: [], current: "Field Notes"))
        let all = Breadcrumb.make(
            libraryName: "Field Notes", documentPath: nil, documentTitle: "", folder: nil, tagName: nil)
        XCTAssertEqual(all, Breadcrumb(crumbs: [], current: "All Documents"))
        let tag = Breadcrumb.make(
            libraryName: "Field Notes", documentPath: nil, documentTitle: "", folder: nil, tagName: "draft")
        XCTAssertEqual(tag, Breadcrumb(crumbs: [.init(title: "Tags", folderPath: nil)], current: "draft"))
        XCTAssertEqual(tag.accessibilityValue(count: ""), "Tags › draft")
    }

    func testLadderDropsCountThenCapsThenFoldsAncestorsThenTruncatesTheLastCrumb() {
        let metrics = Breadcrumb.Metrics(separator: 8, ellipsis: 24)
        let crumbs: [Double] = [200, 60, 180, 90]
        let natural = 530.0 + 32 + 150
        func fit(_ available: Double) -> Breadcrumb.Fit {
            Breadcrumb.fit(crumbs: crumbs, current: 150, count: 90, available: available, metrics: metrics)
        }
        XCTAssertEqual(
            fit(natural + 90),
            .init(showsCount: true, collapsed: 0..<0, crumbWidths: crumbs, currentWidth: 150, width: natural + 90))
        XCTAssertEqual(fit(natural + 89).showsCount, false)
        XCTAssertEqual(fit(natural).crumbWidths, crumbs)
        let capped = fit(natural - 1)
        XCTAssertEqual(capped.crumbWidths, [140, 60, 140, 90])
        XCTAssertTrue(capped.collapsed.isEmpty)
        // Folding starts after the root, nearest ancestors stay longest.
        XCTAssertEqual(fit(capped.width - 1).collapsed, 1..<2)
        XCTAssertEqual(fit(140 + 24 + 90 + 24 + 150 - 1).collapsed, 1..<4)
        XCTAssertEqual(fit(24 + 8 + 150).collapsed, 0..<4)
        let narrow = fit(24 + 8 + 100)
        XCTAssertEqual(narrow.collapsed, 0..<4)
        XCTAssertEqual(narrow.currentWidth, 100)
        XCTAssertEqual(fit(10).currentWidth, 80, "the last crumb keeps its minimum")
        XCTAssertEqual(
            Breadcrumb.fit(crumbs: [], current: 50, count: 0, available: 10, metrics: metrics).currentWidth, 50,
            "a short last crumb never grows to the minimum")
    }

    /// Sweep every depth and width: each step fits when possible, the last crumb never disappears,
    /// and collapsed crumbs are always one run that keeps the nearest ancestor longest.
    func testLadderSweep() {
        let metrics = Breadcrumb.Metrics(separator: 7, ellipsis: 22)
        for depth in 0...8 {
            let crumbs = (0..<depth).map { Double(40 + ($0 * 37) % 190) }
            for current in [20.0, 80, 300] {
                for count in [0.0, 70] {
                    var previous = Double.infinity
                    for available in stride(from: 2000.0, through: 0, by: -13) {
                        let fit = Breadcrumb.fit(
                            crumbs: crumbs, current: current, count: count, available: available, metrics: metrics)
                        XCTAssertGreaterThanOrEqual(fit.currentWidth, min(current, 80))
                        XCTAssertLessThanOrEqual(fit.currentWidth, current)
                        XCTAssertTrue(fit.collapsed.isEmpty || fit.collapsed.lowerBound <= 1)
                        XCTAssertLessThanOrEqual(fit.collapsed.upperBound, depth)
                        if fit.collapsed.lowerBound == 0 && !fit.collapsed.isEmpty {
                            XCTAssertEqual(fit.collapsed.upperBound, depth)
                        }
                        if fit.width > available {
                            XCTAssertEqual(fit.currentWidth, min(current, 80), "only overflows at the minimum")
                        }
                        XCTAssertLessThanOrEqual(fit.width, previous + 0.001, "narrower space never widens the path")
                        previous = fit.width
                    }
                }
            }
        }
    }
}

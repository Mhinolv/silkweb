import AppKit
import SwiftUI
import XCTest
@testable import SilkwebCore
@testable import Silkweb

/// #72 Outline B: the real Inspector List draws one fixed-height row per item, so the thread guides drawn in each
/// row join into continuous rails across row boundaries, in light and dark, at every Inspector width.
final class OutlineThreadTreeTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }

    @MainActor
    func testThreadRailsRunUnbrokenThroughFixedHeightRows() async throws {
        _ = NSApplication.shared
        let suite = "Silkweb.OutlineThreads." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = LibraryWorkspace(defaults: defaults)
        let source = "# One\n## Building A Life with No Home and Other Stories From the Road\n### Child\n![Camp](camp.png)\n## Two\n# Three\n"
        let items = OutlineItem.parse(source)
        XCTAssertEqual(items.map(\.depth), [0, 1, 2, 3, 1, 0])
        workspace.preview.headings = MarkdownParser.parse(source).headings
        workspace.preview.outlineItems = items
        let host = NSHostingView(rootView: InspectorView(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        var found: NSTableView?
        for _ in 0..<100 where found == nil {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
            found = descendants(host).compactMap { $0 as? NSTableView }.first { $0.numberOfRows >= items.count }
        }
        let table = try XCTUnwrap(found, "Outline List missing")
        // The rail of "One"'s children runs from row 1 through rows 2–3 (Child, its image) into "Two" (row 4).
        // At the 26 pt the mockup drew, the List kept 28 pt rows and every one of these boundaries broke.
        let boundaries = [2, 3, 4]
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for width: CGFloat in [200, 240, 320] {
                host.setFrameSize(NSSize(width: width, height: 500))
                for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
                let offset = table.numberOfRows - items.count // A section header row, if any.
                XCTAssertEqual(offset, 0, "Outline B has no Headings section header")
                for row in 0..<items.count {
                    XCTAssertEqual(table.rect(ofRow: row).height, OutlineRowStyle.rowHeight, accuracy: 0.5, "row \(row) at \(width)")
                    if row > 0 {
                        XCTAssertEqual(table.rect(ofRow: row).minY, table.rect(ofRow: row - 1).maxY, accuracy: 0.5,
                                       "Rows abut, so rails do not break (row \(row), width \(width))")
                    }
                }
                let scale: CGFloat = 2
                let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(table.bounds.width * scale),
                    pixelsHigh: Int(table.bounds.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                rep.size = table.bounds.size
                table.cacheDisplay(in: table.bounds, to: rep)
                var thread = NSColor.black
                table.effectiveAppearance.performAsCurrentDrawingAppearance {
                    thread = NSColor.silkwebThread.usingColorSpace(.sRGB) ?? .black
                }
                func railColumns(atPixelRow y: Int) -> Set<Int> {
                    Set((0..<Int(80 * scale)).filter { x in
                        guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                        return max(abs(color.redComponent - thread.redComponent), abs(color.greenComponent - thread.greenComponent),
                                   abs(color.blueComponent - thread.blueComponent)) < 0.08
                    })
                }
                // `rep` rows run top-down; the table is flipped, so table y maps directly.
                for boundary in boundaries {
                    let y = Int(table.rect(ofRow: boundary).minY * scale)
                    let above = railColumns(atPixelRow: y - 1), below = railColumns(atPixelRow: y)
                    XCTAssertFalse(above.isEmpty, "A rail reaches the bottom of row \(boundary - 1) (dark \(dark), width \(width))")
                    XCTAssertFalse(above.intersection(below).isEmpty,
                                   "The rail continues into row \(boundary) at the same x (dark \(dark), width \(width))")
                }
                // Level-0 rows hang from nothing: no guide at the top of "One".
                XCTAssertTrue(railColumns(atPixelRow: 1).isEmpty)
            }
        }
        XCTAssertFalse(window.isVisible)
    }
}

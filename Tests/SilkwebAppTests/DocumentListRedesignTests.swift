import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

/// silkweb-1.64: Direction A document list rows in the real `DocumentList` hierarchy, offscreen.
final class DocumentListRedesignTests: XCTestCase {
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    private final class Frames {
        var values: [String: CGRect] = [:]
    }

    @MainActor
    private func measured<Content: View>(_ content: Content, frames: Frames) -> some View {
        content.overlayPreferenceValue(ColumnLayoutAnchors.self) { anchors in
            GeometryReader { geometry in
                let values = anchors.mapValues { geometry[$0] }
                Color.clear
                    .onAppear { frames.values = values }
                    .onChange(of: values) { frames.values = values }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    private struct Fixture {
        let root: URL
        let workspace: LibraryWorkspace
        let suite: String
    }

    static let longBody = "The fog burned off around nine. I made coffee on the tailgate with the little stove and watched the valley wake up below the ridge while the dog slept in the shade of the van."

    @MainActor
    private func fixture(extra: [String: String] = [:]) async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Library " + UUID().uuidString)
        let files = [
            "Vanlife/Settling In.md": "# Settling In\n\n" + Self.longBody,
            "Vanlife/Short.md": "# Short\n\nOne line.",
            "Vanlife/Blank.md": "",
            "Travel/Lisbon.md": "# Lisbon\n\nTiles.",
            "Travel/Japan/Kyoto.md": "# Kyoto\n\nTemples.",
            "Root Note.md": "# Root Note\n\nAt the top."
        ].merging(extra) { $1 }
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        let suite = "Silkweb.ListRedesign." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        }
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedFolder = "Vanlife"
        workspace.session.selectedDocuments = []
        return Fixture(root: root, workspace: workspace, suite: suite)
    }

    @MainActor
    private func settle(_ view: NSView, rounds: Int = 6) async throws {
        for _ in 0..<rounds {
            view.layoutSubtreeIfNeeded()
            for table in Self.descendants(view).compactMap({ $0 as? DocumentTableView }) { table.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(30))
        }
    }

    @MainActor
    private func table(in view: NSView) throws -> DocumentTableView {
        try XCTUnwrap(Self.descendants(view).compactMap { $0 as? DocumentTableView }.first)
    }

    @MainActor
    private func cell(_ table: NSTableView, _ row: Int) throws -> NSHostingView<DocumentRow> {
        try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSHostingView<DocumentRow>, "row \(row)")
    }

    // MARK: Pixels

    private struct Bitmap {
        let rep: NSBitmapImageRep
        let scale: CGFloat
        let view: NSView

        /// `point` in the (flipped) table's coordinates.
        func color(_ point: NSPoint) -> NSColor {
            let y = view.isFlipped ? point.y : view.bounds.height - point.y
            return rep.colorAt(x: Int(point.x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB) ?? .clear
        }

        /// Pixels in `rect` that differ from `background` by more than a faint antialias.
        func ink(in rect: NSRect, against background: NSColor) -> Int {
            var count = 0
            var y = rect.minY
            while y < rect.maxY {
                var x = rect.minX
                while x < rect.maxX {
                    if Self.distance(color(NSPoint(x: x, y: y)), background) > 0.12 { count += 1 }
                    x += 1 / scale
                }
                y += 1 / scale
            }
            return count
        }

        /// The leftmost x in `rect` carrying ink.
        func firstInkX(in rect: NSRect, against background: NSColor) -> CGFloat? {
            var x = rect.minX
            while x < rect.maxX {
                var y = rect.minY
                while y < rect.maxY {
                    if Self.distance(color(NSPoint(x: x, y: y)), background) > 0.12 { return x }
                    y += 1 / scale
                }
                x += 1 / scale
            }
            return nil
        }

        static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
            max(abs(a.redComponent - b.redComponent), abs(a.greenComponent - b.greenComponent), abs(a.blueComponent - b.blueComponent))
        }
    }

    @MainActor
    private func render(_ view: NSView) throws -> Bitmap {
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        return Bitmap(rep: rep, scale: CGFloat(rep.pixelsWide) / max(1, view.bounds.width), view: view)
    }

    /// The token resolved the way the bitmap resolves it (a swatch in a copy of the same rep).
    @MainActor
    private func resolved(_ color: NSColor, like bitmap: Bitmap) throws -> NSColor {
        let swatch = try XCTUnwrap(bitmap.rep.copy() as? NSBitmapImageRep)
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: swatch))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        bitmap.view.effectiveAppearance.performAsCurrentDrawingAppearance {
            color.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(swatch.colorAt(x: 1, y: swatch.pixelsHigh - 2)?.usingColorSpace(.sRGB))
    }

    // MARK: Row anatomy

    @MainActor
    func testRealListRowsShowTitleMetadataAndTwoLineExcerptWithCapsuleSelection() async throws {
        let fixture = try await fixture()
        let workspace = fixture.workspace
        workspace.session.selectedDocuments = ["Vanlife/Settling In.md"]
        let frames = Frames()
        let host = NSHostingView(rootView: measured(DocumentList(workspace: workspace)
            .frame(maxWidth: .infinity, maxHeight: .infinity), frames: frames))
        host.sizingOptions = []
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host // Never ordered on screen.
            defer { window.contentView = nil; window.close() }
            host.setFrameSize(NSSize(width: 320, height: 600))
            try await settle(host)
            // Let the realized rows' bounded summary reads finish off the main thread.
            try await Task.sleep(for: .milliseconds(300))
            try await settle(host)
            let table = try table(in: host)
            let coordinator = try XCTUnwrap(table.delegate as? DocumentTable.Coordinator)
            let titles = workspace.documents.map { URL(fileURLWithPath: $0.name).deletingPathExtension().lastPathComponent }
            XCTAssertEqual(Set(titles), ["Settling In", "Short", "Blank"])

            // Fixed 96 pt rhythm keeps 10k rows virtualized; no per-row height queries.
            XCTAssertEqual(table.rowHeight, 96)
            XCTAssertEqual(table.intercellSpacing, .zero)
            XCTAssertFalse(coordinator.responds(to: #selector(NSTableViewDelegate.tableView(_:heightOfRow:))))
            for row in 0..<table.numberOfRows {
                XCTAssertEqual(table.rect(ofRow: row).height, 96, accuracy: 0.5)
                XCTAssertTrue(table.rowView(atRow: row, makeIfNecessary: true) is CapsuleRowView)
                // Scoped to one folder: the location would repeat on every row.
                XCTAssertNil(try cell(table, row).rootView.location)
            }

            let bitmap = try render(table)
            let pane = try resolved(.silkwebPaneBackground, like: bitmap)
            let capsuleFill = try resolved(.silkwebSelectionInactive, like: bitmap) // Offscreen windows are never key.
            let selected = try XCTUnwrap(titles.firstIndex(of: "Settling In"))
            let short = try XCTUnwrap(titles.firstIndex(of: "Short"))
            let blank = try XCTUnwrap(titles.firstIndex(of: "Blank"))
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: selected))
            func band(_ row: Int, _ top: CGFloat, _ bottom: CGFloat) -> NSRect {
                let rect = table.rect(ofRow: row)
                return NSRect(x: rect.minX + 16, y: rect.minY + top, width: rect.width - 40, height: bottom - top)
            }
            for row in 0..<table.numberOfRows {
                let background = row == selected ? capsuleFill : pane
                let rect = table.rect(ofRow: row)
                let label = "\(appearance.rawValue) row \(titles[row])"
                XCTAssertGreaterThan(bitmap.ink(in: band(row, 12, 29), against: background), 20, "\(label): title line")
                XCTAssertGreaterThan(bitmap.ink(in: band(row, 32, 47), against: background), 10, "\(label): date line")
                XCTAssertGreaterThan(bitmap.ink(in: band(row, 50, 66), against: background), 10, "\(label): excerpt line 1")
                let second = bitmap.ink(in: band(row, 67, 84), against: background)
                if row == selected { XCTAssertGreaterThan(second, 10, "\(label): excerpt wraps to a second line") }
                else { XCTAssertEqual(second, 0, "\(label): short excerpt keeps one line, row keeps its height") }
                XCTAssertEqual(bitmap.ink(in: band(row, 85, 95), against: background), 0, "\(label): no third excerpt line")
                // Text sits 12 pt inside the capsule, which is 10 pt from the table edges.
                let firstInk = try XCTUnwrap(bitmap.firstInkX(in: band(row, 12, 29).offsetBy(dx: -16, dy: 0), against: background))
                XCTAssertEqual(firstInk - rect.minX, Spacing.capsuleInset + 12, accuracy: 2.5, label)
            }
            // Capsule selection: R1 fill inside the selected row, 2 pt pane gap between rows, plain rows unfilled.
            let selectedRect = table.rect(ofRow: selected)
            XCTAssertLessThan(Bitmap.distance(bitmap.color(NSPoint(x: selectedRect.minX + 14, y: selectedRect.minY + 6)), capsuleFill), 0.03)
            XCTAssertLessThan(Bitmap.distance(bitmap.color(NSPoint(x: selectedRect.minX + 14, y: selectedRect.minY + 0.25)), pane), 0.03)
            XCTAssertLessThan(Bitmap.distance(bitmap.color(NSPoint(x: selectedRect.minX + 4, y: selectedRect.midY)), pane), 0.03)
            let shortRect = table.rect(ofRow: short)
            XCTAssertLessThan(Bitmap.distance(bitmap.color(NSPoint(x: shortRect.minX + 14, y: shortRect.minY + 6)), pane), 0.03)
            // Empty documents read “No additional text” in a quieter ink than real excerpts.
            XCTAssertGreaterThan(bitmap.ink(in: band(blank, 50, 66), against: pane), 10)

            // Search Library stays pinned (1.46) for populated and empty folders.
            let populated = try XCTUnwrap(frames.values["library-search"])
            XCTAssertEqual(populated.minY, 8, accuracy: 4)
            workspace.session.selectedFolder = "Empty"
            try await settle(host)
            XCTAssertTrue(workspace.documents.isEmpty)
            XCTAssertEqual(try XCTUnwrap(frames.values["library-search"]).minY, populated.minY, accuracy: 4)
            XCTAssertNotNil(frames.values["column-empty-body"])
            workspace.session.selectedFolder = "Vanlife"
            try await settle(host)
        }
    }

    @MainActor
    func testLocationShowsOnlyWhenTheListSpansFolders() async throws {
        let fixture = try await fixture()
        let workspace = fixture.workspace
        let host = NSHostingView(rootView: DocumentList(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 900), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func locations() async throws -> [String: String?] {
            try await settle(host)
            let table = try table(in: host)
            var result: [String: String?] = [:]
            for row in 0..<table.numberOfRows {
                let view = try cell(table, row).rootView
                result[view.document.relativePath] = view.location
            }
            XCTAssertEqual(result.count, workspace.documents.count)
            return result
        }
        let library = fixture.root.lastPathComponent
        // All Documents spans the library.
        workspace.session.selectedFolder = nil
        var values = try await locations()
        XCTAssertEqual(values["Root Note.md"], library)
        XCTAssertEqual(values["Vanlife/Settling In.md"], "Vanlife")
        XCTAssertEqual(values["Travel/Japan/Kyoto.md"], "Travel › Japan")
        // A single folder hides it.
        workspace.session.selectedFolder = "Travel"
        values = try await locations()
        XCTAssertEqual(values, ["Travel/Lisbon.md": nil])
        // Include Subfolders paths are relative to the scope folder.
        workspace.setIncludeSubfolders(true)
        values = try await locations()
        XCTAssertEqual(values["Travel/Lisbon.md"], "Travel")
        XCTAssertEqual(values["Travel/Japan/Kyoto.md"], "Japan")
        workspace.setIncludeSubfolders(false)
        values = try await locations()
        XCTAssertEqual(values["Travel/Lisbon.md"], .some(nil))
        // The library root folder itself is one folder too.
        workspace.session.selectedFolder = ""
        values = try await locations()
        XCTAssertEqual(values, ["Root Note.md": nil])
    }

    // MARK: Lifecycle

    @MainActor
    func testFolderSortTagSearchAndResizeKeepSelectionAndScroll() async throws {
        var extra: [String: String] = [:]
        for index in 0..<60 { extra[String(format: "Many/Note %02d.md", index)] = "# Note \(index)\n\nBody \(index) " + Self.longBody }
        let fixture = try await fixture(extra: extra)
        let workspace = fixture.workspace
        let target = "Many/Note 45.md"
        _ = try await TagStore.update(root: fixture.root) { metadata in
            let ids = ["Many/Note 45.md", "Many/Note 10.md", "Many/Note 50.md"].compactMap { metadata.IDsByPath[$0] }
            return TagEditor.edit(["draft"], documents: Set(ids), metadata: metadata)
        }
        workspace.install(try await LibraryScanner.scan(root: fixture.root))
        let draft = try XCTUnwrap(workspace.tags.first { $0.name == "draft" })
        workspace.session.selectedFolder = "Many"
        workspace.selectDocuments([target])
        await workspace.waitForNavigation()
        let host = NSHostingView(rootView: DocumentList(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 560), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)

        func assertStable(_ step: String, scrollOrigin: CGFloat? = nil, visible: Bool = true, file: StaticString = #filePath, line: UInt = #line) throws {
            let table = try table(in: host)
            XCTAssertEqual(workspace.session.selectedDocuments, [target], step, file: file, line: line)
            let row = try XCTUnwrap(workspace.documents.firstIndex { $0.relativePath == target }, step, file: file, line: line)
            XCTAssertEqual(table.selectedRowIndexes, IndexSet(integer: row), step, file: file, line: line)
            XCTAssertEqual(table.rowHeight, 96, step, file: file, line: line)
            if visible, table.visibleRect.height >= 96 {
                XCTAssertTrue(table.visibleRect.intersects(table.rect(ofRow: row)),
                              "\(step): selected row scrolled away: visible \(table.visibleRect), row \(table.rect(ofRow: row)), host \(host.frame)", file: file, line: line)
            }
            if let scrollOrigin {
                XCTAssertEqual(table.visibleRect.minY, scrollOrigin, accuracy: 1, "\(step): scroll position jumped", file: file, line: line)
            }
        }
        // Bring the selection into view the way a click or navigation does.
        try table(in: host).scrollRowToVisible(try XCTUnwrap(workspace.documents.firstIndex { $0.relativePath == target }))
        try await settle(host)
        try assertStable("initial")
        let origin = try table(in: host).visibleRect.minY
        XCTAssertGreaterThan(origin, 0, "fixture must scroll")

        // Resize sweep at a fixed height: scroll position does not move.
        for width: CGFloat in [240, 320, 480, 900, 240, 320] {
            window.setContentSize(NSSize(width: width, height: 560))
            try await settle(host, rounds: 2)
            try assertStable("width \(width)", scrollOrigin: origin)
        }
        for height: CGFloat in [300, 900, 1400, 560] {
            window.setContentSize(NSSize(width: 320, height: height))
            try await settle(host, rounds: 2)
            try assertStable("height \(height)")
        }

        // Sort changes reorder rows; the selection follows the document.
        for key in [DocumentSortKey.name, .created, .modified] {
            workspace.setSortKey(key)
            try await settle(host)
            try assertStable("sort \(key)")
        }
        workspace.setSortDescending(!workspace.listPreference.descending)
        try await settle(host)
        try assertStable("sort direction")
        workspace.setSortDescending(!workspace.listPreference.descending)

        // Tag filter on and off.
        workspace.tagFilters = [draft.id]
        try await settle(host)
        XCTAssertEqual(workspace.documents.count, 3)
        try assertStable("tag filter on")
        workspace.tagFilters = []
        try await settle(host)
        XCTAssertEqual(workspace.documents.count, 60)
        try assertStable("tag filter off")

        // Search mode overlays results with the same row metrics, then restores the list.
        workspace.search.text = "fog"
        await workspace.search.query(quick: false)
        try await settle(host)
        XCTAssertFalse(workspace.filteredSearchResults.isEmpty)
        let resultRows = Self.descendants(host).compactMap { $0 as? NSTableView }.filter { !($0 is DocumentTableView) }
        XCTAssertFalse(resultRows.isEmpty, "1.20 results list is shown")
        try assertStable("search mode")
        workspace.search.text = ""
        workspace.search.results = []
        try await settle(host)
        try assertStable("search cleared")

        // Folder switch and back: the list restores the same rows and selection.
        workspace.session.selectedFolder = "Vanlife"
        try await settle(host)
        XCTAssertEqual(try table(in: host).numberOfRows, 3)
        workspace.session.selectedFolder = "Many"
        workspace.selectDocuments([target])
        await workspace.waitForNavigation()
        try await settle(host)
        // A folder switch starts the new list at the top; only the selection must survive.
        try assertStable("folder switch", visible: false)
    }

    // MARK: Performance

    /// 10,000 rows: fast scrolling realizes reused fixed-height cells only. Main-thread time per
    /// scroll step stays within a frame and summary reads never run on the main thread.
    @MainActor
    func testFastScrollThroughTenThousandRowsStaysResponsive() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("Big")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let body = Data(("# Note\n\n" + Self.longBody).utf8)
        for index in 0..<10_000 {
            try body.write(to: folder.appendingPathComponent(String(format: "Note %05d.md", index)))
        }
        let suite = "Silkweb.ListScroll." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedFolder = "Big"
        XCTAssertEqual(workspace.documents.count, 10_000)
        let host = NSHostingView(rootView: DocumentList(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 900), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        try await settle(host)
        let table = try table(in: host)
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertEqual(table.numberOfRows, 10_000)
        XCTAssertEqual(table.rect(ofRow: 9_999).maxY - table.rect(ofRow: 0).minY, 96 * 10_000, accuracy: 0.5)

        var samples: [Double] = []
        let clip = scroll.contentView
        let maxY = table.frame.height - clip.bounds.height
        // Momentum flick: large, uneven steps through the whole list and back.
        var positions: [CGFloat] = stride(from: 0, through: maxY, by: 1_237).map { $0 }
        positions += positions.reversed()
        for y in positions {
            let start = DispatchTime.now().uptimeNanoseconds
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            scroll.layoutSubtreeIfNeeded()
            table.displayIfNeeded()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        samples.sort()
        let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
        let median = samples[samples.count / 2]
        print("DocumentList 10k scroll: \(samples.count) steps, median \(String(format: "%.2f", median)) ms, p95 \(String(format: "%.2f", p95)) ms")
        // One 60 Hz frame. Rows are fixed height, so no step measures or lays out off-screen rows.
        XCTAssertLessThan(p95, 16.7)
        let realized = (0..<table.numberOfRows).filter { table.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil }
        XCTAssertLessThan(realized.count, 40, "only visible rows are realized")
    }
}

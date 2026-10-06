import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #70: clicking through the library list must move the capsule at once, with the editor following when its
/// buffer loads. The real library window (sidebar, list, compact toolbar with the breadcrumb, editor), opened
/// through the app's own path and never ordered on screen, takes plain clicks through the hit-tested row views.
final class DocumentSelectionLatencyTests: XCTestCase {
    static let folder = "Field Notes"
    static let documentCount = 30
    static let clicks = 20
    /// The list segment's budget, from the press to the end of the display pass that shows the capsule: one
    /// 60 Hz frame. Locally that pass measures about 10 ms, most of it SwiftUI re-rendering for the new selection.
    static let listBudget = TestEnvironment.frameBudget(16)
    /// Focus Mode may cost the editor segment this much more than the plain run (dim strips are rebuilt after the swap).
    static let focusMargin = 1.5

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @MainActor private final class Harness {
        let window: NSWindow
        let workspace: LibraryWorkspace
        let root: URL
        let cleanUp: () -> Void
        private var eventNumber = 0
        init(window: NSWindow, workspace: LibraryWorkspace, root: URL, cleanUp: @escaping () -> Void) {
            self.window = window; self.workspace = workspace; self.root = root; self.cleanUp = cleanUp
        }
        var content: NSView { window.contentView! }
        var table: DocumentTableView? {
            DocumentSelectionLatencyTests.descendants(content).compactMap { $0 as? DocumentTableView }.first
        }
        var paths: [String] { workspace.documents.map(\.relativePath) }
        func url(_ row: Int) -> URL { root.appendingPathComponent(paths[row]).standardizedFileURL }
        var editorURL: URL? { workspace.editor.url?.standardizedFileURL }

        /// A display-cycle pass: lets SwiftUI commit pending updates, then lays out.
        func pump() async throws {
            try await Task.sleep(for: .milliseconds(1))
            content.superview?.layoutSubtreeIfNeeded()
        }

        /// The native row and its capsule show exactly this selection.
        func showsSelection(_ rows: IndexSet) -> Bool {
            guard let table, table.selectedRowIndexes == rows else { return false }
            return rows.allSatisfy { table.rowView(atRow: $0, makeIfNecessary: false)?.isSelected == true }
        }
        func shows(_ row: Int) -> Bool {
            showsSelection(IndexSet(integer: row)) && workspace.session.selectedDocuments == [paths[row]]
        }

        /// Press and release events at the row's centre, with the row view the press lands on, hit-tested like a
        /// real click (hidden windows don't dispatch events).
        func click(_ row: Int, modifiers: NSEvent.ModifierFlags = []) throws -> (
            source: DocumentRowClickView, down: NSEvent, up: NSEvent
        ) {
            let table = try XCTUnwrap(self.table)
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let now = ProcessInfo.processInfo.systemUptime
            func event(_ type: NSEvent.EventType, _ timestamp: TimeInterval) throws -> NSEvent {
                eventNumber += 1
                return try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: type, location: point, modifierFlags: modifiers, timestamp: timestamp,
                        windowNumber: window.windowNumber, context: nil, eventNumber: eventNumber, clickCount: 1,
                        pressure: type == .leftMouseUp ? 0 : 1))
            }
            let frame = try XCTUnwrap(content.superview)
            let source = try XCTUnwrap(
                frame.hitTest(frame.convert(point, from: nil)) as? DocumentRowClickView, "row source at \(point)")
            XCTAssertEqual(source.path, paths[row])
            return (source, try event(.leftMouseDown, now), try event(.leftMouseUp, now + 0.01))
        }
    }

    @MainActor private func makeHarness() async throws -> Harness {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebSelection-" + UUID().uuidString)
        let root = container.appendingPathComponent("Library")
        let folder = root.appendingPathComponent(Self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Realistic notes: headings, paragraphs, a list and a link, about 6 KB each.
        for index in 0..<Self.documentCount {
            var text = "# Day \(index + 1) on the Road\n\n"
            for section in 0..<6 {
                text += "## Stop \(section + 1)\n\n"
                text +=
                    String(
                        repeating: "We pulled in after a long drive and set up camp before the light went. ", count: 8)
                    + "\n\n"
                text +=
                    "- Water at the trailhead\n- Firewood from the ranger station\n- [Map](https://example.com/\(index)/\(section))\n\n"
            }
            try Data(text.utf8).write(to: folder.appendingPathComponent(String(format: "Note %02d.md", index + 1)))
        }
        let suite = "Silkweb.SelectionLatency." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        let harness = Harness(window: window, workspace: workspace, root: root.resolvingSymlinksInPath()) {
            window.contentViewController = nil
            window.close()
            NSApp.appearance = oldAppearance
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: container)
        }
        // The app's own open path: scan, session, search index and the Finder watcher.
        workspace.open(root)
        try await waitUntil("the library opens", timeout: .seconds(10)) {
            workspace.snapshot != nil && !workspace.loading
        }
        workspace.selectFolder(Self.folder)
        await workspace.waitForNavigation()
        try await waitUntil("the list realizes its rows", timeout: .seconds(10)) {
            harness.content.superview?.layoutSubtreeIfNeeded()
            return harness.table.map {
                $0.numberOfRows == Self.documentCount && $0.rows(in: $0.visibleRect).length >= 8
            } == true
        }
        XCTAssertNotNil(window.toolbar, "the compact toolbar with the breadcrumb is part of the measured window")
        return harness
    }

    private struct Run {
        var list: [Double] = []
        var editor: [Double] = []
        var selectedOnPress = 0
        static func percentile(_ samples: [Double], _ p: Double) -> Double {
            let sorted = samples.sorted()
            return sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * p).rounded())]
        }
        func summary(_ name: String) -> String {
            String(
                format: "%@: list p50 %.2f ms p95 %.2f ms; editor p50 %.2f ms p95 %.2f ms; selected on press %d/%d",
                name, Self.percentile(list, 0.5), Self.percentile(list, 0.95),
                Self.percentile(editor, 0.5), Self.percentile(editor, 0.95), selectedOnPress, list.count)
        }
    }

    /// Fully visible rows (below the toolbar) in a scan order that never clicks the same row twice in a row.
    @MainActor private func order(_ h: Harness) throws -> [Int] {
        let table = try XCTUnwrap(h.table)
        let visible = table.rows(in: table.visibleRect)
        let rows = (visible.location..<(visible.location + visible.length)).filter {
            h.window.contentLayoutRect.contains(table.convert(table.rect(ofRow: $0), to: nil))
        }
        XCTAssertGreaterThanOrEqual(rows.count, 6)
        return (0..<Self.clicks).map { rows[($0 * 3 + $0 / rows.count) % rows.count] }
    }

    /// One plain click per row, waiting for the editor each time. Both segments run from the press to the end of
    /// the display pass that shows them, so main-thread work the click queues counts against them.
    @MainActor private func clickThrough(_ h: Harness, rows: [Int]) async throws -> Run {
        var run = Run()
        for (index, row) in rows.enumerated() {
            let (source, down, up) = try h.click(row)
            let start = ContinuousClock.now
            source.mouseDown(with: down)
            if h.shows(row) { run.selectedOnPress += 1 }
            source.mouseUp(with: up)
            var listDone: Duration?
            let deadline = start + .seconds(5)
            while ContinuousClock.now < deadline {
                try await h.pump()
                if listDone == nil, h.shows(row) { listDone = ContinuousClock.now - start }
                if listDone != nil, h.editorURL == h.url(row) { break }
            }
            let editorDone = ContinuousClock.now - start
            XCTAssertNotNil(listDone, "click \(index): row \(row) never showed the selection")
            XCTAssertEqual(h.editorURL, h.url(row), "click \(index): the editor never showed row \(row)")
            run.list.append(Self.milliseconds(listDone ?? editorDone))
            run.editor.append(Self.milliseconds(editorDone))
            if h.workspace.focusMode {
                // The new document's text view is dimmed from the moment it exists.
                func textView() -> PlainMarkdownTextView? {
                    h.workspace.tabs.first { $0.id == h.workspace.activeTabID }?.textView
                }
                try await waitUntil("click \(index): the swapped-in text view") { textView() != nil }
                XCTAssertEqual(
                    textView()?.writingModes.focus, true, "click \(index): Focus Mode on the swapped-in editor")
            }
            // Let this document's debounced styling, sizing and autosave land before the next click.
            try await Task.sleep(for: .milliseconds(20))
        }
        await h.workspace.waitForNavigation()
        return run
    }

    /// The benchmark (p50/p95 printed for the PR) and the regression guard: the press selects the row, and the
    /// capsule shows within one frame, with Focus Mode off and on.
    @MainActor
    func testClickingThroughTwentyDocumentsSelectsRowsWithinOneFrame() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let rows = try order(h)
        // Warm up: the first open realizes the editor hierarchy.
        _ = try await clickThrough(h, rows: [rows[2], rows[1]])
        var runs: [Bool: Run] = [:]
        for focus in [false, true] {
            h.workspace.setWritingModes(focus: focus)
            try await h.pump()
            let run = try await clickThrough(h, rows: rows)
            print("DocumentSelectionLatency " + run.summary(focus ? "focus on" : "focus off"))
            runs[focus] = run
        }
        for (focus, run) in runs {
            let mode = focus ? "Focus on" : "Focus off"
            // Finder's rule: the press itself selects the row, before any run-loop turn.
            XCTAssertEqual(
                run.selectedOnPress, run.list.count, "\(mode) — rows selected by the press: \(run.summary(mode))")
            XCTAssertLessThanOrEqual(
                Run.percentile(run.list, 0.95), Self.listBudget,
                "\(mode) — list p95 over one frame: \(run.summary(mode))")
        }
        if let off = runs[false], let on = runs[true] {
            let base = Run.percentile(off.editor, 0.95)
            XCTAssertLessThanOrEqual(
                Run.percentile(on.editor, 0.95), max(base * Self.focusMargin, base + TestEnvironment.frameBudget(16)),
                "Focus Mode must not slow the editor swap: \(on.summary("on")) vs \(off.summary("off"))")
        }
    }

    /// A rapid burst: the capsule follows every click and the editor coalesces to the last one instead of replaying
    /// every queued open.
    @MainActor
    func testRapidClickThroughKeepsTheListCurrentAndCoalescesEditorOpens() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let rows = try order(h)
        let single = try await clickThrough(h, rows: Array(rows.prefix(6)))
        var behind = 0
        let start = ContinuousClock.now
        for row in rows {
            let (source, down, up) = try h.click(row)
            source.mouseDown(with: down)
            source.mouseUp(with: up)
            // One display pass between clicks: never enough for the editor to load every document.
            try await h.pump()
            if !h.shows(row) { behind += 1 }
        }
        let clicked = ContinuousClock.now
        let last = try XCTUnwrap(rows.last)
        try await waitUntil("the editor shows the last clicked document") { h.editorURL == h.url(last) }
        await h.workspace.waitForNavigation()
        let drained = Self.milliseconds(ContinuousClock.now - clicked)
        let open = Run.percentile(single.editor, 0.95)
        print(
            String(
                format:
                    "DocumentSelectionLatency rapid: %d clicks in %.1f ms, list behind on %d, editor settled %.1f ms after the last click (single open p95 %.1f ms)",
                rows.count, Self.milliseconds(clicked - start), behind, drained, open))
        XCTAssertEqual(behind, 0, "the capsule must track every click")
        // A coalesced queue finishes the open in flight and then the latest target: two opens, not one per click.
        XCTAssertLessThanOrEqual(
            drained, 2 * open + TestEnvironment.frameBudget(16), "the editor must coalesce to the latest click")
        XCTAssertTrue(h.shows(last))
        XCTAssertEqual(h.editorURL, h.url(last))
    }

    /// Finder's rule around the press: only a plain press on an unselected row selects at once. A press on a row
    /// of a multi-row selection keeps every row (so a drag carries them) and narrows on release; ⌘ and ⇧ still act
    /// on release.
    @MainActor
    func testPressSelectsOnlyUnselectedRowsAndModifiersActOnRelease() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let paths = h.paths
        var dragged: [[String]] = []
        let table = try XCTUnwrap(h.table)
        table.startDraggingSession = { items, _, _ in
            let type = NSPasteboard.PasteboardType(UTType.silkwebMove.identifier)
            guard let data = (items.first?.item as? NSPasteboardItem)?.data(forType: type) else {
                return XCTFail("Missing move payload")
            }
            dragged.append(h.workspace.pathsForDrag(data) ?? [])
        }
        // The first press opens the editor; the second swaps it. Either way the pressed row survives the swap, so a
        // drag that starts after the editor has loaded still carries that row.
        for row in [1, 2] {
            let plain = try h.click(row)
            plain.source.mouseDown(with: plain.down)
            XCTAssertTrue(h.shows(row), "a plain press selects an unselected row")
            await h.workspace.waitForNavigation()
            for _ in 0..<5 { try await h.pump() }
            XCTAssertEqual(h.editorURL, h.url(row))
            let point = NSPoint(x: plain.down.locationInWindow.x - 12, y: plain.down.locationInWindow.y)
            plain.source.mouseDragged(
                with: try XCTUnwrap(
                    NSEvent.mouseEvent(
                        with: .leftMouseDragged, location: point, modifierFlags: [],
                        timestamp: plain.up.timestamp, windowNumber: h.window.windowNumber, context: nil,
                        eventNumber: 0, clickCount: 1, pressure: 1)))
            XCTAssertEqual(
                dragged.last, [paths[row]], "row \(row): the drag after the editor swap carries the pressed row")
            plain.source.mouseUp(with: plain.up)
            XCTAssertTrue(h.shows(row))
        }
        XCTAssertEqual(dragged.count, 2)
        let plain = try h.click(1)
        plain.source.mouseDown(with: plain.down)
        plain.source.mouseUp(with: plain.up)
        await h.workspace.waitForNavigation()
        XCTAssertTrue(h.shows(1))

        let command = try h.click(3, modifiers: .command)
        command.source.mouseDown(with: command.down)
        XCTAssertEqual(h.workspace.session.selectedDocuments, [paths[1]], "⌘-press waits for the release")
        command.source.mouseUp(with: command.up)
        XCTAssertEqual(h.workspace.session.selectedDocuments, [paths[1], paths[3]])
        XCTAssertTrue(h.showsSelection(IndexSet([1, 3])), "the ⌘-click shows in the table at once")
        let shift = try h.click(5, modifiers: .shift)
        shift.source.mouseDown(with: shift.down)
        XCTAssertEqual(h.workspace.session.selectedDocuments, [paths[1], paths[3]], "⇧-press waits for the release")
        shift.source.mouseUp(with: shift.up)
        await h.workspace.waitForNavigation()
        let selected = h.workspace.session.selectedDocuments
        XCTAssertGreaterThan(selected.count, 2)

        let inside = try h.click(3)
        inside.source.mouseDown(with: inside.down)
        XCTAssertEqual(h.workspace.session.selectedDocuments, selected, "a press inside the selection keeps every row")
        inside.source.mouseUp(with: inside.up)
        XCTAssertTrue(h.shows(3), "the release narrows to the clicked row")
        await h.workspace.waitForNavigation()
        XCTAssertEqual(h.editorURL, h.url(3))
        XCTAssertNil(h.workspace.rename, "a fast click-through never starts a rename")
    }
}

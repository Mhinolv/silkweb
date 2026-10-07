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
                // Distinct heading sets per note, so a stale Outline never matches the clicked one (#87).
                text += "## Stop \(section + 1) of Day \(index + 1)\n\n"
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
        try await withDeadline("navigation") { await workspace.waitForNavigation() }
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
        static func percentile(_ samples: [Double], _ p: Double) -> Double { LatencyGate.percentile(samples, p) }
        func summary(_ name: String) -> String {
            String(
                format:
                    "%@: list p50 %.2f ms p90 %.2f ms p95 %.2f ms; editor p50 %.2f ms p95 %.2f ms; selected on press %d/%d",
                name, Self.percentile(list, 0.5), LatencyGate.value(list), Self.percentile(list, 0.95),
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
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
        return run
    }

    /// The benchmark (p50/p95 printed for the PR) and the regression guard: the press selects the row, and the
    /// capsule shows within one frame (p90 over 20 clicks, #124), with Focus Mode off and on.
    @MainActor
    func testClickingThroughTwentyDocumentsSelectsRowsWithinOneFrame() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        let rows = try order(h)
        // Warm up: the first open realizes the editor hierarchy.
        _ = try await clickThrough(h, rows: [rows[2], rows[1]])
        var runs: [Bool: Run] = [:]
        for focus in [false, true] {
            let mode = focus ? "focus on" : "focus off"
            h.workspace.setWritingModes(focus: focus)
            try await h.pump()
            let outcome = try await LatencyGate.measure("list \(mode)", budget: Self.listBudget, samples: \.list) {
                let run = try await clickThrough(h, rows: rows)
                print("DocumentSelectionLatency " + run.summary(mode))
                return run
            }
            // Finder's rule: the press itself selects the row, before any run-loop turn. Checked on every run.
            for run in outcome.runs {
                XCTAssertEqual(
                    run.selectedOnPress, run.list.count, "\(mode) — rows selected by the press: \(run.summary(mode))")
            }
            let run = try XCTUnwrap(outcome.runs.last)
            XCTAssertTrue(
                outcome.passed,
                "\(mode) — list p90 over one frame (\(Self.listBudget) ms): \(run.summary(mode))"
                    + (outcome.note.map { "; \($0)" } ?? ""))
            runs[focus] = run
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
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
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
            try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
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
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
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
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
        let selected = h.workspace.session.selectedDocuments
        XCTAssertGreaterThan(selected.count, 2)

        let inside = try h.click(3)
        inside.source.mouseDown(with: inside.down)
        XCTAssertEqual(h.workspace.session.selectedDocuments, selected, "a press inside the selection keeps every row")
        inside.source.mouseUp(with: inside.up)
        XCTAssertTrue(h.shows(3), "the release narrows to the clicked row")
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
        XCTAssertEqual(h.editorURL, h.url(3))
        XCTAssertNil(h.workspace.rename, "a fast click-through never starts a rename")
    }

    // MARK: - #87: the Outline inspector follows the list

    /// One outline sample per display pass after a press.
    private enum OutlineSample { case current, empty, stale }

    @MainActor private func expectedOutline(_ h: Harness, _ row: Int) throws -> [String] {
        let text = try String(contentsOf: h.url(row), encoding: .utf8)
        return OutlineItem.parse(text, headings: MarkdownParser.parse(text).headings).map(\.label)
    }
    @MainActor private func outlineSample(_ h: Harness, expected: [String]) -> OutlineSample {
        let labels = h.workspace.preview.outlineItems.map(\.label)
        return labels == expected ? .current : labels.isEmpty ? .empty : .stale
    }

    /// Within this long of the press (two 60 Hz frames), the Outline shows the clicked note. Locally the shared
    /// pass that shows the capsule and the Outline measures about 18 ms; before #87 it took the editor swap plus the
    /// 250 ms typing debounce.
    static let outlineBudget = TestEnvironment.frameBudget(33)

    private struct OutlineRun {
        var latencies: [Double] = []
        var empty = 0
        var behindList = 0
        var summary: String {
            String(
                format:
                    "DocumentSelectionLatency outline: p50 %.2f ms p90 %.2f ms p95 %.2f ms; behind the list on %d, empty frames %d over %d clicks",
                Run.percentile(latencies, 0.5), LatencyGate.value(latencies), Run.percentile(latencies, 0.95),
                behindList, empty, latencies.count)
        }
    }

    /// The benchmark (p50/p95 printed for the PR) and regression guard for #87: with Show Outline on, the Outline
    /// shows the clicked note's headings in the same display pass as the list capsule (p90 over 20 clicks, #124),
    /// never flashing No Headings.
    @MainActor
    func testOutlineFollowsEachClickWithinOneFrame() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        h.workspace.preview.mode = .editor
        h.workspace.preview.showsOutline = true
        let rows = try order(h)
        // Warm up: the first open realizes the editor and the inspector's list.
        _ = try await clickThrough(h, rows: [rows[2], rows[1]])
        try await waitUntil("the warm-up outline", timeout: .seconds(2)) {
            try outlineSample(h, expected: expectedOutline(h, rows[1])) == .current
        }
        let outcome = try await LatencyGate.measure("outline", budget: Self.outlineBudget, samples: \.latencies) {
            let run = try await outlineClickThrough(h, rows: rows)
            print(run.summary)
            return run
        }
        // Functional guards hold on every run, the re-measure included.
        for run in outcome.runs {
            XCTAssertEqual(run.behindList, 0, "the Outline must update in the list capsule's pass: \(run.summary)")
            XCTAssertEqual(run.empty, 0, "the Outline must not flash No Headings between notes: \(run.summary)")
        }
        let summary = try XCTUnwrap(outcome.runs.last).summary + (outcome.note.map { "; \($0)" } ?? "")
        XCTAssertTrue(outcome.passed, "outline p90 over two frames (\(Self.outlineBudget) ms): \(summary)")
    }

    /// One click per row with the Outline sampled on every display pass after the press.
    @MainActor private func outlineClickThrough(_ h: Harness, rows: [Int]) async throws -> OutlineRun {
        var run = OutlineRun()
        for (index, row) in rows.enumerated() {
            let expected = try expectedOutline(h, row)
            let (source, down, up) = try h.click(row)
            let start = ContinuousClock.now
            source.mouseDown(with: down)
            source.mouseUp(with: up)
            var done: Duration?
            var listShown = false
            let deadline = start + .seconds(2)
            while ContinuousClock.now < deadline {
                try await h.pump()
                let sample = outlineSample(h, expected: expected)
                if sample == .empty { run.empty += 1 }
                if sample == .current {
                    done = ContinuousClock.now - start
                    break
                }
                // A pass that shows the capsule but not this note's Outline: the inspector lags the list.
                if h.shows(row), !listShown {
                    listShown = true
                    run.behindList += 1
                }
            }
            XCTAssertNotNil(done, "click \(index): the Outline never showed row \(row)")
            run.latencies.append(Self.milliseconds(done ?? (ContinuousClock.now - start)))
            try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
            try await waitUntil("click \(index): the editor shows row \(row)") { h.editorURL == h.url(row) }
            // The editor's own render must keep the same outline (no step back, no blank).
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(outlineSample(h, expected: expected), .current, "click \(index): the outline after the swap")
        }
        // Past the typing debounce, the editor's own render still keeps the last note's outline.
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(
            outlineSample(h, expected: try expectedOutline(h, try XCTUnwrap(rows.last))), .current,
            "the outline after the debounced render")
        return run
    }

    /// A rapid burst with the Outline open: it settles on the last clicked note and never steps back to an
    /// earlier one while the coalesced editor opens drain.
    @MainActor
    func testRapidClickThroughSettlesTheOutlineOnTheLastDocument() async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        h.workspace.preview.mode = .editor
        h.workspace.preview.showsOutline = true
        let rows = try order(h)
        _ = try await clickThrough(h, rows: Array(rows.prefix(3)))
        for row in rows {
            let (source, down, up) = try h.click(row)
            source.mouseDown(with: down)
            source.mouseUp(with: up)
            try await h.pump()
        }
        let last = try XCTUnwrap(rows.last)
        let expected = try expectedOutline(h, last)
        // From the end of the burst until well past the typing debounce, every pass shows the last note.
        var samples: [OutlineSample] = []
        let deadline = ContinuousClock.now + .milliseconds(600)
        while ContinuousClock.now < deadline {
            try await h.pump()
            samples.append(outlineSample(h, expected: expected))
        }
        try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
        XCTAssertEqual(h.editorURL, h.url(last))
        XCTAssertEqual(outlineSample(h, expected: expected), .current, "the Outline settles on the last clicked note")
        let off = samples.filter { $0 != .current }.count
        XCTAssertEqual(off, 0, "passes after the burst not showing the last note's outline: \(off) of \(samples.count)")
    }

    // MARK: - #124: the latency gate under load

    /// Scheduler noise from a concurrent suite slows one or two clicks; a #70/#87 regression slows every click.
    func testLatencyGateToleratesTwoOutliersButFailsEverySlowClick() {
        let noisy = Array(repeating: 10.0, count: 18) + [100, 100]
        XCTAssertTrue(LatencyGate.passes(noisy, budget: 16), "two loaded clicks pass the one-frame list budget")
        XCTAssertTrue(LatencyGate.passes(noisy, budget: 33), "two loaded clicks pass the two-frame outline budget")
        XCTAssertFalse(
            LatencyGate.passes(Array(repeating: 10.0, count: 17) + [100, 100, 100], budget: 33),
            "three slow clicks are not noise")
        XCTAssertFalse(LatencyGate.passes(Array(repeating: 40.0, count: 20), budget: 16), "#70: async-gated selection")
        XCTAssertFalse(LatencyGate.passes(Array(repeating: 260.0, count: 20), budget: 33), "#87: 250 ms debounce")
        XCTAssertTrue(LatencyGate.passes(Array(repeating: 16.0, count: 20), budget: 16), "the budget itself passes")
    }

    /// One re-measure, only when the first run is over budget; a regression is over budget both times.
    @MainActor
    func testLatencyGateReMeasuresOnceAndFailsOnlyWhenBothRunsAreOver() async throws {
        func gate(_ runs: [[Double]]) async throws -> (LatencyGate.Outcome<[Double]>, measured: Int) {
            var measured = 0
            let outcome = try await LatencyGate.measure("synthetic", budget: 16, samples: { $0 }) {
                defer { measured += 1 }
                return runs[measured]
            }
            return (outcome, measured)
        }
        let fast = Array(repeating: 10.0, count: 20)
        let loaded = Array(repeating: 10.0, count: 15) + Array(repeating: 60.0, count: 5)
        let slow = Array(repeating: 40.0, count: 20)

        var (outcome, measured) = try await gate([fast, slow])
        XCTAssertTrue(outcome.passed)
        XCTAssertEqual(measured, 1, "a run within budget is not re-measured")
        XCTAssertNil(outcome.note)

        (outcome, measured) = try await gate([loaded, fast])
        XCTAssertTrue(outcome.passed, "a loaded first run passes when the re-measure is within budget")
        XCTAssertEqual(measured, 2)
        XCTAssertEqual(outcome.runs, [loaded, fast], "both runs are returned for the functional guards")
        XCTAssertEqual(outcome.note, "DocumentSelectionLatency synthetic: retried after p90 60.0 ms (first run)")

        (outcome, measured) = try await gate([slow, slow])
        XCTAssertFalse(outcome.passed, "#70: every click over budget fails both runs")
        XCTAssertEqual(measured, 2, "at most one re-measure")
        XCTAssertEqual(outcome.value, 40)
    }
}

/// #124: judges the click-through benchmarks by a typical click, not the slowest one, at the unchanged local
/// budgets. A real #70/#87 regression (async-gated selection, a 250 ms debounce) slows every click, so p90 over
/// 20 clicks still fails it; scheduler noise from a concurrent suite slows one or two clicks, which p90 tolerates.
/// When a whole run lands in a loaded stretch, the timing segment is re-measured once, logged, and fails only if
/// it is over budget again. Functional guards are never judged here.
enum LatencyGate {
    static let quantile = 0.9

    /// Nearest-rank percentile of `samples` (0 when empty).
    static func percentile(_ samples: [Double], _ p: Double) -> Double {
        let sorted = samples.sorted()
        return sorted.isEmpty ? 0 : sorted[Int((Double(sorted.count - 1) * p).rounded())]
    }

    static func value(_ samples: [Double]) -> Double { percentile(samples, quantile) }

    static func passes(_ samples: [Double], budget: Double) -> Bool { value(samples) <= budget }

    struct Outcome<Run> {
        /// Every measured run, first run first: callers check their functional guards on each.
        var runs: [Run]
        /// The judged run's p90.
        var value: Double
        var passed: Bool
        /// The log line when the re-measure ran.
        var note: String?
    }

    /// Measures `run`, and once more only when its p90 is over `budget`. Passes when the last run is within budget.
    @MainActor
    static func measure<Run>(
        _ name: String, budget: Double, samples: (Run) -> [Double], _ run: () async throws -> Run
    ) async throws -> Outcome<Run> {
        let first = try await run()
        let firstValue = value(samples(first))
        guard firstValue > budget else { return Outcome(runs: [first], value: firstValue, passed: true) }
        let note = String(
            format: "DocumentSelectionLatency %@: retried after p90 %.1f ms (first run)", name, firstValue)
        print(note)
        let second = try await run()
        let secondValue = value(samples(second))
        return Outcome(runs: [first, second], value: secondValue, passed: secondValue <= budget, note: note)
    }
}

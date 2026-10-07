import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #150: opening a note from the list shows its content within the ~150 ms budget in every mode, as one swap from
/// the previous note: no blank preview, no placeholder, and inline images arrive with the text. The real library
/// window (never ordered on screen) on a copy of `Test_Library` plus image-bearing notes, the owner's library size.
final class DocumentOpenLatencyTests: XCTestCase {
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    /// From the selection to the pass that shows the note's content. Before #150 the preview waited for the
    /// 250 ms typing debounce on every switch (about 300 ms), and inline images for a 150 ms one.
    static let openBudget = TestEnvironment.frameBudget(150)
    static let passes = 2

    @MainActor private final class Harness {
        let window: NSWindow
        let workspace: LibraryWorkspace
        let root: URL
        let cleanUp: () -> Void
        init(window: NSWindow, workspace: LibraryWorkspace, root: URL, cleanUp: @escaping () -> Void) {
            self.window = window; self.workspace = workspace; self.root = root; self.cleanUp = cleanUp
        }
        var paths: [String] { workspace.documents.map(\.relativePath) }
        func url(_ path: String) -> URL { root.appendingPathComponent(path).standardizedFileURL }
        var textView: PlainMarkdownTextView? { workspace.tabs.first { $0.id == workspace.activeTabID }?.textView }
        func pump() async throws {
            try await Task.sleep(for: .milliseconds(1))
            window.contentView?.superview?.layoutSubtreeIfNeeded()
        }
    }

    @MainActor private func makeHarness() async throws -> Harness {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebOpen-" + UUID().uuidString)
        let root = container.appendingPathComponent("Library")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.repository.appendingPathComponent("Test_Library"), to: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".silkweb"))
        // The owner's copy adds photos under `media/`.
        let media = root.appendingPathComponent("media")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for index in 0..<3 { try Self.photo(index).write(to: media.appendingPathComponent("photo\(index).jpg")) }
        try Data(
            "# Photo Walk\n\nWe left early.\n\n![Harbour](../media/photo0.jpg)\n\nThen the hill.\n\n![Hill](../media/photo1.jpg)\n\nHome by dark.\n"
                .utf8
        ).write(to: root.appendingPathComponent("Travel/Photo Walk.md"))
        try Data("# Coffee Photos\n\n![Cup](../media/photo2.jpg)\n\nThe end.\n".utf8).write(
            to: root.appendingPathComponent("Coffee/Coffee Photos.md"))
        let defaults = disposableDefaults("OpenLatency")
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
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
        workspace.open(root)
        try await waitUntil("the library opens", timeout: .seconds(10)) {
            workspace.snapshot != nil && !workspace.loading
        }
        workspace.selectFolder(nil)
        try await withDeadline("navigation") { await workspace.waitForNavigation() }
        let harness = Harness(window: window, workspace: workspace, root: try XCTUnwrap(workspace.snapshot?.rootURL)) {
            window.contentViewController = nil
            window.close()
            NSApp.appearance = oldAppearance
            try? FileManager.default.removeItem(at: container)
        }
        XCTAssertEqual(harness.paths.count, 10, "Test_Library's eight notes plus the two photo notes")
        return harness
    }

    /// A 1600×1200 camera-sized JPEG.
    private static func photo(_ seed: Int) throws -> Data {
        let rep = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 1600, pixelsHigh: 1200, bitsPerSample: 8, samplesPerPixel: 3,
                hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let pixels = try XCTUnwrap(rep.bitmapData)
        for y in 0..<1200 {
            for x in 0..<1600 {
                let offset = y * rep.bytesPerRow + x * 3
                pixels[offset] = UInt8((x + seed * 40) % 256)
                pixels[offset + 1] = UInt8(y % 256)
                pixels[offset + 2] = UInt8((x ^ y) % 256)
            }
        }
        return try XCTUnwrap(rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
    }

    private struct Run {
        var latencies: [Double] = []
        /// Passes after the selection that showed an empty preview or the editor's empty-note placeholder.
        var blank: [String] = []
        /// A switch to a small note that raised the delayed loading spinner.
        var spinners = 0
        func summary(_ mode: DocumentViewMode) -> String {
            String(
                format: "%@: open p50 %.1f ms p90 %.1f ms max %.1f ms over %d switches; blank passes %d; spinners %d",
                mode.rawValue, LatencyGate.percentile(latencies, 0.5), LatencyGate.value(latencies),
                latencies.max() ?? 0, latencies.count, blank.count, spinners)
                + (blank.isEmpty ? "" : " (" + blank.prefix(3).joined(separator: "; ") + ")")
        }
    }

    /// Whether the window shows `path`'s content in `mode`: the editor's text with every inline image's space
    /// reserved, and, with a preview pane, the rendered page.
    @MainActor private func shows(_ h: Harness, _ path: String, text: String, mode: DocumentViewMode) -> Bool {
        guard h.workspace.editor.url?.standardizedFileURL == h.url(path) else { return false }
        if mode != .preview {
            guard let view = h.textView, view.string == text else { return false }
            let images = text.components(separatedBy: "![").count - 1
            if view.inlineImages.imageViews.count < images { return false }
        }
        if mode != .editor {
            guard h.workspace.preview.renderedURL?.standardizedFileURL == h.url(path),
                !h.workspace.preview.html.isEmpty
            else { return false }
        }
        return true
    }

    /// Selects every note in turn, sampling each display pass from the selection until its content shows.
    @MainActor private func switchThrough(_ h: Harness, mode: DocumentViewMode) async throws -> Run {
        var run = Run()
        let paths = h.paths
        for pass in 0..<Self.passes {
            for (index, path) in paths.enumerated() {
                let text = try String(contentsOf: h.url(path), encoding: .utf8)
                let start = ContinuousClock.now
                h.workspace.selectDocuments([path])
                var done: Duration?
                while ContinuousClock.now - start < .seconds(3) {
                    try await h.pump()
                    let preview = h.workspace.preview
                    if mode != .editor, preview.html.isEmpty { run.blank.append("\(path): empty preview") }
                    if mode != .preview, let view = h.textView, view.string.isEmpty, view.placeholderEnabled {
                        run.blank.append("\(path): placeholder")
                    }
                    if preview.isLoading { run.spinners += 1 }
                    if shows(h, path, text: text, mode: mode) {
                        done = ContinuousClock.now - start
                        break
                    }
                }
                XCTAssertNotNil(done, "\(mode) pass \(pass) switch \(index): \(path) never showed")
                run.latencies.append(Self.milliseconds(done ?? (ContinuousClock.now - start)))
                try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
                // Let this note's autosave, sizing and image decode settle before the next switch.
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        return run
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
    }

    @MainActor private func assertOpensWithinBudget(_ mode: DocumentViewMode) async throws {
        let h = try await makeHarness()
        defer { h.cleanUp() }
        h.workspace.preview.mode = mode
        // Warm up: the first open realizes the editor (and preview) hierarchy for this mode.
        let paths = h.paths
        for path in [paths[1], paths[0]] {
            h.workspace.selectDocuments([path])
            try await withDeadline("navigation") { await h.workspace.waitForNavigation() }
            let text = try String(contentsOf: h.url(path), encoding: .utf8)
            let deadline = ContinuousClock.now + .seconds(3)
            while !shows(h, path, text: text, mode: mode), ContinuousClock.now < deadline { try await h.pump() }
            XCTAssertTrue(shows(h, path, text: text, mode: mode), "warm-up \(path)")
        }
        let outcome = try await LatencyGate.measure(
            "open \(mode.rawValue)", budget: Self.openBudget, samples: \.latencies
        ) {
            let run = try await switchThrough(h, mode: mode)
            print("DocumentOpenLatency " + run.summary(mode))
            return run
        }
        for run in outcome.runs {
            XCTAssertEqual(
                run.blank.count, 0, "\(mode): a note switch must be one swap, never blank: \(run.summary(mode))")
            XCTAssertEqual(run.spinners, 0, "\(mode): small warm notes never show the spinner: \(run.summary(mode))")
        }
        let summary = try XCTUnwrap(outcome.runs.last).summary(mode) + (outcome.note.map { "; \($0)" } ?? "")
        XCTAssertTrue(outcome.passed, "\(mode): open p90 over \(Self.openBudget) ms: \(summary)")
        await h.workspace.didCloseWindow()
    }

    @MainActor func testEditorShowsEachNoteAndItsImagesWithinBudget() async throws {
        try await assertOpensWithinBudget(.editor)
    }

    @MainActor func testPreviewShowsEachNoteWithinBudgetWithoutBlankPane() async throws {
        try await assertOpensWithinBudget(.preview)
    }

    @MainActor func testSplitShowsEachNoteWithinBudgetWithoutBlankPane() async throws {
        try await assertOpensWithinBudget(.split)
    }
}

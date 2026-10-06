import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

final class IdleStabilityTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> (LibraryWorkspace, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "".write(to: root.appendingPathComponent("Empty.md"), atomically: true, encoding: .utf8)
        try "coffee coffee".write(to: root.appendingPathComponent("Coffee.md"), atomically: true, encoding: .utf8)
        let defaults = disposableDefaults("Idle")
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.open(root)
        for _ in 0..<200 {
            if workspace.snapshot != nil && !workspace.loading { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(workspace.error)
        _ = try XCTUnwrap(workspace.snapshot)
        await workspace.search.waitForIndex()
        workspace.showDocument(root.appendingPathComponent("Empty.md"))
        await workspace.waitForNavigation()
        return (workspace, root)
    }

    @MainActor
    func testEmptyDocumentIdleInEveryPaneMode() async throws {
        let (workspace, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let host = NSHostingView(rootView: DocumentDetail(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host // never ordered on screen
        defer { window.contentView = nil }
        for mode in DocumentViewMode.allCases {
            workspace.preview.mode = mode
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(700))
            let editor = try XCTUnwrap(workspace.preview.editor)
            XCTAssertEqual(editor.string, "")
            let renders = workspace.preview.renderCount
            let draws = editor.fullDrawCount
            let revision = workspace.revision
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(workspace.preview.renderCount, renders, "idle render in \(mode)")
            if mode == .editor { XCTAssertEqual(renders, 0) }
            XCTAssertLessThanOrEqual(editor.fullDrawCount - draws, 2, "full-editor idle redraws in \(mode)")
            XCTAssertEqual(workspace.revision, revision, "cache/FSEvents feedback in \(mode)")
            for width: CGFloat in [1, 420, 1000, 4096] {
                host.setFrameSize(NSSize(width: width, height: 700))
                host.layoutSubtreeIfNeeded()
                XCTAssertTrue(editor.frame.height.isFinite)
            }
            host.setFrameSize(NSSize(width: 1000, height: 700))
        }
    }

    @MainActor
    func testSearchLibraryAndQuickOpenIdleAndNoOpReconcile() async throws {
        let (workspace, root) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.search.text = "coffee"
        let host = NSHostingView(rootView: DocumentList(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 700),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(workspace.search.results.count, 1)
        let hit = try XCTUnwrap(workspace.search.results.first)
        XCTAssertEqual(SearchNavigation.selection(hit.id, in: workspace.search.results), hit.id)
        XCTAssertEqual(SearchNavigation.selection(UUID(), in: workspace.search.results), hit.id)
        XCTAssertNil(SearchNavigation.selection(hit.id, in: []))
        let queries = workspace.search.queryCount
        let builds = workspace.search.resultsBodyCount
        let revision = workspace.search.revision
        let cache = root.appendingPathComponent(".silkweb/search-index.json")
        await workspace.search.index?.flushCache()
        let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
        for _ in 0..<30 {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(workspace.search.queryCount, queries)
        XCTAssertLessThanOrEqual(workspace.search.resultsBodyCount - builds, 1)
        // Deterministically replay the watcher callback, even if sandbox FSEvents
        // delivery is unavailable. Unchanged scans may not restart search.
        for _ in 0..<3 { await workspace.reconcileFinderChanges() }
        await workspace.search.waitForIndex()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(workspace.search.queryCount, queries)
        XCTAssertEqual(workspace.search.revision, revision)
        let after = try FileManager.default.attributesOfItem(atPath: cache.path)
        XCTAssertEqual(attributes[.systemFileNumber] as? NSNumber, after[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(attributes[.modificationDate] as? Date, after[.modificationDate] as? Date)
        workspace.search.toggleQuickOpen()
        workspace.search.quickText = "coffee"
        let quick = NSHostingView(rootView: QuickOpenPanel(workspace: workspace))
        quick.sizingOptions = []
        window.contentView = quick
        quick.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(workspace.search.quickResults.count, 1)
        let quickQueries = workspace.search.queryCount
        try await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(workspace.search.queryCount, quickQueries)
        workspace.search.quickText = "absent"
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(workspace.search.quickResults.isEmpty)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        workspace.search.text = "absent"
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(workspace.search.results.isEmpty)
        XCTAssertEqual(LibrarySearch.resultCount(1), "1 result")
        XCTAssertEqual(LibrarySearch.resultCount(0), "0 results")
    }

    @MainActor
    func testPlaceholderCaretRestorationAndTextStates() throws {
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        scroll.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        scroll.tile()
        let editor = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        editor.layoutEditor()
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 500,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        editor.drawBackground(in: editor.bounds)
        let before = Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let caret = NSRect(x: editor.textContainerOrigin.x + 4, y: editor.textContainerOrigin.y, width: 1, height: 24)
        editor.drawInsertionPoint(in: caret, color: .controlAccentColor, turnedOn: true)
        editor.drawInsertionPoint(in: caret, color: .controlAccentColor, turnedOn: false)
        let after = Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        XCTAssertEqual(before, after, "caret clearing erased placeholder pixels")
        editor.insertText("a", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(editor.string, "a")
        editor.setMarkedText(
            "あ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 1))
        XCTAssertFalse(editor.string.isEmpty)
        editor.unmarkText()
        editor.string = ""
        editor.isEditable = false
        editor.drawBackground(in: editor.bounds)
        let readOnly = Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        XCTAssertNotEqual(before, readOnly)
    }
}

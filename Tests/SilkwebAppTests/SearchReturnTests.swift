import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

/// silkweb-1.75: Return while the 150 ms debounce is pending opens the current query's result, never the stale first row.
final class SearchReturnTests: XCTestCase {
    @MainActor
    private func makeWorkspace() async throws -> (LibraryWorkspace, URL) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, text) in [("Kyoto.md", "kyo travel"), ("Coffee.md", "coffee beans")] {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(snapshot)
        await workspace.editor.configure(root: root)
        await workspace.search.waitForIndex()
        return (workspace, root)
    }

    @MainActor
    private func host<Content: View>(_ view: Content, width: CGFloat) -> (NSHostingView<Content>, NSWindow) {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        return (host, window)
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable { return field }
        return view.subviews.lazy.compactMap { self.textField(in: $0) }.first
    }

    /// Types into the real SwiftUI field through its field editor, then presses Return (`onSubmit`).
    @MainActor
    private func typeAndReturn(_ text: String, host: NSView, window: NSWindow) throws {
        let field = try XCTUnwrap(textField(in: host))
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        editor.insertNewline(nil)
    }

    @MainActor
    private func waitForOpen(_ workspace: LibraryWorkspace) async throws {
        // A loaded runner can resume the open well past any fixed budget (#63).
        try await waitUntil("Return to open a document") { !workspace.session.selectedDocuments.isEmpty }
        await workspace.waitForNavigation()
    }

    @MainActor
    func testQuickOpenReturnBeforeDebounceOpensCurrentQuery() async throws {
        let (workspace, root) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.search.toggleQuickOpen()
        let (host, window) = host(QuickOpenPanel(workspace: workspace), width: 900)
        defer { window.contentView = nil }
        workspace.search.quickText = "kyo"
        await workspace.search.query(quick: true)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.search.quickResults.map(\.displayName), ["Kyoto"])
        try typeAndReturn("coffee", host: host, window: window)
        XCTAssertEqual(workspace.search.quickText, "coffee")
        XCTAssertTrue(workspace.search.quickHasPendingQuery, "Return must arrive inside the debounce window")
        try await waitForOpen(workspace)
        XCTAssertEqual(workspace.session.selectedDocuments, ["Coffee.md"])
        XCTAssertFalse(workspace.search.showsQuickOpen)
    }

    @MainActor
    func testSearchLibraryReturnBeforeDebounceOpensCurrentQuery() async throws {
        let (workspace, root) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let (host, window) = host(SearchView(workspace: workspace, search: workspace.search) { Color.clear }, width: 480)
        defer { window.contentView = nil }
        workspace.search.text = "kyo"
        await workspace.search.query(quick: false)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(workspace.filteredSearchResults.map(\.displayName), ["Kyoto"])
        try typeAndReturn("coffee", host: host, window: window)
        XCTAssertEqual(workspace.search.text, "coffee")
        XCTAssertTrue(workspace.search.hasPendingQuery, "Return must arrive inside the debounce window")
        try await waitForOpen(workspace)
        XCTAssertEqual(workspace.session.selectedDocuments, ["Coffee.md"])
    }

    @MainActor
    func testSettleRunsThePendingQueryOnce() async throws {
        let (workspace, root) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let search = workspace.search
        let emptySettled = await search.settle(quick: false)
        XCTAssertFalse(emptySettled, "an empty Search field has nothing to open")
        for quick in [true, false] {
            if quick { search.quickText = "coffee" } else { search.text = "coffee" }
            let start = search.queryCount
            let debounced = Task { await search.query(quick: quick) }
            await Task.yield()
            let settled = await search.settle(quick: quick)
            XCTAssertTrue(settled)
            XCTAssertEqual((quick ? search.quickResults : search.results).map(\.displayName), ["Coffee"])
            await debounced.value
            let again = await search.settle(quick: quick)
            XCTAssertTrue(again)
            XCTAssertEqual(search.queryCount - start, 1, "the debounced view task must not repeat a query Return already settled")
        }
    }

    @MainActor
    func testReturnWithNoMatchesOpensNothing() async throws {
        let (workspace, root) = try await makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.search.toggleQuickOpen()
        let (host, window) = host(QuickOpenPanel(workspace: workspace), width: 900)
        defer { window.contentView = nil }
        workspace.search.quickText = "kyo"
        await workspace.search.query(quick: true)
        host.layoutSubtreeIfNeeded()
        try typeAndReturn("zzzabsent", host: host, window: window)
        // Prove the query ran before checking that nothing opened, instead of sleeping past the debounce (#63).
        try await waitUntil("the no-match query to settle") {
            !workspace.search.quickHasPendingQuery && workspace.search.quickResults.isEmpty
        }
        await workspace.waitForNavigation()
        XCTAssertTrue(workspace.session.selectedDocuments.isEmpty)
        XCTAssertTrue(workspace.search.showsQuickOpen)
        XCTAssertTrue(workspace.search.quickResults.isEmpty)
    }
}

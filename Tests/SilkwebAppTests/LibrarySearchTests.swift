import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

final class LibrarySearchTests: XCTestCase {
    /// #179: Search Library ranks with the window's knowledge index and reads typed `tag:` from its Tags.
    @MainActor
    func testSearchLibraryRanksWithKnowledgeAndFiltersTypedTags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            ("Flock.md", "Unrelated."), ("Notes.md", "flock flock, twice."),
            ("Long.md", "flock " + String(repeating: "filler words for a long body ", count: 40)),
            ("Tagged.md", "a tagged flock note"),
        ]
        for (offset, (path, text)) in files.enumerated() {
            let url = root.appendingPathComponent(path)
            try text.write(to: url, atomically: true, encoding: .utf8)
            // Long is the newest: without BM25 it would come before Notes.
            let date = Date(timeIntervalSince1970: path == "Long.md" ? 9_000 : 1_000 + Double(offset))
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        await workspace.search.waitForIndex()
        await workspace.knowledge.waitForIndex()
        workspace.search.text = "flock"
        await workspace.search.query(quick: false)
        let names = workspace.search.results.map(\.displayName)
        XCTAssertEqual(names.first, "Flock", "an exact title stays first")
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "Notes")), try XCTUnwrap(names.firstIndex(of: "Long")))

        // Typed `tag:` matches the sidebar's Tag; a Tag edit alone re-runs the query.
        workspace.search.text = "flock tag:research"
        await workspace.search.query(quick: false)
        XCTAssertTrue(workspace.search.results.isEmpty)
        let snapshot = try XCTUnwrap(workspace.snapshot)
        let tagged = try XCTUnwrap(snapshot.documents.first { $0.name == "Tagged.md" })
        _ = try await TagStore.update(root: root) { TagEditor.edit(["Research"], documents: [tagged.id], metadata: $0) }
        let revision = workspace.search.revision
        workspace.install(try await LibraryScanner.scan(root: root, previousSnapshot: snapshot))
        XCTAssertEqual(workspace.search.revision, revision + 1)
        await workspace.search.waitForIndex()
        await workspace.search.query(quick: false)
        XCTAssertEqual(workspace.search.results.map(\.displayName), ["Tagged"])
        XCTAssertNil(ParsedSearchQuery("tag:research").findText, "a filter-only query selects nothing")
    }

    @MainActor
    func testScopesTitleOnlyOpeningRecentsAndSaveRefresh() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Writing/Drafts"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, text) in [
            ("Writing/Café.md", "body needle"), ("Writing/Drafts/Plan.md", "other needle"), ("Else.md", "needle"),
        ] {
            try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(snapshot)
        await workspace.editor.configure(root: root)
        await workspace.search.waitForIndex()
        workspace.search.text = "needle"
        await workspace.search.query(quick: false)
        XCTAssertEqual(workspace.search.results.count, 3)
        workspace.search.folderScope = snapshot.folders.first { $0.relativePath == "Writing" }?.id
        await workspace.search.query(quick: false)
        XCTAssertEqual(workspace.search.results.count, 2)
        XCTAssertTrue(
            workspace.search.results.contains {
                $0.folderPathComponents == ["Writing", "Drafts"] && $0.snippet.contains("needle")
            })
        workspace.search.quickText = "needle"
        await workspace.search.query(quick: true)
        XCTAssertTrue(workspace.search.quickResults.isEmpty)
        workspace.search.quickText = "cafe"
        await workspace.search.query(quick: true)
        let result = try XCTUnwrap(workspace.search.quickResults.first)
        let pasteboard = NSPasteboard(name: .find)
        let previousFind = pasteboard.string(forType: .string)
        let probe = UUID().uuidString
        pasteboard.clearContents()
        let pasteboardAvailable =
            pasteboard.setString(probe, forType: .string) && pasteboard.string(forType: .string) == probe
        defer {
            pasteboard.clearContents()
            if let previousFind { pasteboard.setString(previousFind, forType: .string) }
        }
        let editorHost = NSHostingView(rootView: TabEditorContent(workspace: workspace))
        editorHost.sizingOptions = []
        let editorWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled], backing: .buffered,
            defer: false)
        editorWindow.contentView = editorHost
        defer { editorWindow.contentView = nil }
        editorHost.layoutSubtreeIfNeeded()
        await workspace.openSearchResult(result, findText: "needle")
        let textView = try XCTUnwrap(workspace.preview.editor)
        XCTAssertEqual((textView.string as NSString).substring(with: textView.selectedRange()), "needle")
        if pasteboardAvailable {
            XCTAssertEqual(pasteboard.string(forType: .string), "needle")
        } else {
            print(
                "Find-pasteboard assertion unavailable: independent write/read probe failed in this sandbox; selected editor match was verified."
            )
        }
        XCTAssertEqual(workspace.session.selectedFolder, "Writing")
        XCTAssertEqual(workspace.session.selectedDocuments, ["Writing/Café.md"])
        XCTAssertEqual(workspace.editor.text, "body needle")
        workspace.search.quickText = ""
        await workspace.search.query(quick: true)
        XCTAssertEqual(workspace.search.quickResults.map(\.id), [result.id])
        workspace.editor.edit("saved replacement")
        _ = await workspace.editor.save()
        await workspace.refreshSavedDocumentDates()
        await workspace.search.waitForIndex()
        workspace.search.text = "replacement"
        workspace.search.folderScope = nil
        await workspace.search.query(quick: false)
        XCTAssertEqual(workspace.search.results.map(\.id), [result.id])
        workspace.search.text = "replacement"
        let cancelled = Task { await workspace.search.query(quick: false) }
        cancelled.cancel()
        workspace.search.text = "absent"
        await workspace.search.query(quick: false)
        await cancelled.value
        XCTAssertTrue(workspace.search.results.isEmpty)
    }

    @MainActor
    func testOffscreenSearchAndQuickOpenResizeLifecycle() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for number in 0..<100 {
            try "body needle".write(
                to: root.appendingPathComponent("Plan \(number).md"), atomically: true, encoding: .utf8)
        }
        let workspace = LibraryWorkspace()
        workspace.root = root
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot)
        await workspace.search.waitForIndex()
        let host = NSHostingView(rootView: DocumentList(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 560), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func nativeTable(in view: NSView) -> DocumentTableView? {
            if let table = view as? DocumentTableView { return table }
            return view.subviews.lazy.compactMap { nativeTable(in: $0) }.first
        }
        host.setFrameSize(NSSize(width: 480, height: 560))
        for _ in 0..<20 {
            host.layoutSubtreeIfNeeded()
            if nativeTable(in: host) != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let table = try XCTUnwrap(nativeTable(in: host))
        table.enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: 500))
        let position = table.enclosingScrollView?.contentView.bounds.origin
        let selection = workspace.session.selectedDocuments
        for query in ["", "needle", "absent", ""] {
            workspace.search.text = query
            await workspace.search.query(quick: false)
            for width in [240.0, 300, 480] {
                host.setFrameSize(NSSize(width: width, height: 560))
                host.layoutSubtreeIfNeeded()
                await Task.yield()
            }
        }
        XCTAssertTrue(nativeTable(in: host) === table)
        XCTAssertEqual(table.enclosingScrollView?.contentView.bounds.origin, position)
        XCTAssertEqual(workspace.session.selectedDocuments, selection)
        workspace.search.toggleQuickOpen()
        let quick = NSHostingView(rootView: QuickOpenPanel(workspace: workspace))
        quick.sizingOptions = []
        window.contentView = quick
        workspace.search.quickText = "plan"
        await workspace.search.query(quick: true)
        XCTAssertEqual(workspace.search.quickResults.count, 12)
        for width in [900.0, 1200, 1800] {
            quick.setFrameSize(NSSize(width: width, height: 760))
            quick.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        workspace.search.dismissQuickOpen()
        XCTAssertFalse(workspace.search.showsQuickOpen)
    }
}

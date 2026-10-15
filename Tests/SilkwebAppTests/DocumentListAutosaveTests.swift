import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #262: saving the open document must not blink the document list. Under Date Modified the saved row moves to the
/// top in place (no `reloadData`), every row keeps its excerpt, the selection follows the row, the list never
/// scrolls, and the editor keeps focus.
final class DocumentListAutosaveTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    func testSingleMoveDetection() {
        let folder = UUID()
        let docs = (0..<6).map {
            LibraryDocument(id: UUID(), folderID: folder, relativePath: "N\($0).md", name: "N\($0).md")
        }
        let move = DocumentTable.Coordinator.singleMove
        func moved(_ from: Int, _ to: Int) -> [LibraryDocument] {
            var result = docs
            result.insert(result.remove(at: from), at: to)
            return result
        }
        for from in docs.indices {
            for to in docs.indices where to != from {
                // An adjacent swap is either row moving; both give the same order.
                let result = try? XCTUnwrap(move(docs, moved(from, to)), "\(from)→\(to)")
                XCTAssertEqual(result.map { moved($0.from, $0.to) }, moved(from, to), "\(from)→\(to)")
                if abs(from - to) > 1 { XCTAssertTrue(result?.from == from && result?.to == to, "\(from)→\(to)") }
            }
        }
        XCTAssertNil(move(docs, docs), "no change")
        XCTAssertNil(move([], []))
        XCTAssertNil(move(docs, Array(docs.dropLast())), "a removed row")
        XCTAssertNil(move(docs, Array(docs.reversed())), "a full reorder")
        var swapped = docs
        swapped.swapAt(1, 4)
        XCTAssertNil(move(docs, swapped), "two rows swapped")
        var renamed = moved(5, 0)
        renamed[0] = LibraryDocument(id: docs[5].id, folderID: folder, relativePath: "Renamed.md", name: "Renamed.md")
        XCTAssertNil(move(docs, renamed), "a moved row with a new path")
        var replaced = docs
        replaced[2] = LibraryDocument(id: UUID(), folderID: folder, relativePath: "N2.md", name: "N2.md")
        XCTAssertNil(move(docs, replaced), "a replaced row")
    }

    @MainActor
    func testSavingMovesTheRowInPlaceWithoutReloadingTheList() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preferences = TestPreferences("DocumentListAutosave")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            preferences.remove()
        }
        // Note 00 is the newest; each later note is an hour older.
        let now = Date()
        for index in 0..<20 {
            let url = root.appendingPathComponent(String(format: "Note %02d.md", index))
            try Data("# Note \(index)\n\nExcerpt for note \(index).\n".utf8).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-3600 * Double(index + 1))], ofItemAtPath: url.path)
        }
        let workspace = LibraryWorkspace(defaults: preferences.defaults)
        workspace.canSaveWindowSession = false; workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        XCTAssertEqual(workspace.listPreference.key, .modified)
        let saved = try XCTUnwrap(workspace.documents.first { $0.name == "Note 05.md" })
        XCTAssertEqual(workspace.documents.firstIndex(of: saved), 5)
        workspace.session.selectedDocuments = [saved.relativePath]
        let opened = await workspace.openTab(saved, pinned: true)
        XCTAssertTrue(opened)
        workspace.preview.mode = .editor
        let controller = LibrarySplitViewController(workspace: workspace)
        let window = KeyableWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(NSSize(width: 1400, height: 900))
        controller.view.setFrameSize(NSSize(width: 1400, height: 900))
        window.makeKey() // Never ordered on screen.
        defer { window.contentViewController = nil; window.close() }

        func settle(_ turns: Int = 5) async throws {
            for _ in 0..<turns {
                controller.view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20))
            }
            window.displayIfNeeded()
        }
        var table: DocumentTableView?
        for _ in 0..<150 where table == nil {
            try await settle(1)
            table = descendants(controller.view).compactMap { $0 as? DocumentTableView }.first { $0.numberOfRows == 20 }
        }
        let list = try XCTUnwrap(table, "no document list")
        let scroll = try XCTUnwrap(list.enclosingScrollView)
        // Rows 3… are at the top; the saved row 5 is visible and selected.
        list.scroll(NSPoint(x: 0, y: list.rect(ofRow: 3).minY))
        try await settle(30) // Excerpts load.
        XCTAssertEqual(list.selectedRowIndexes, [5])
        XCTAssertTrue(list.visibleRect.intersects(list.rect(ofRow: 5)))
        let editor = try XCTUnwrap(workspace.preview.editor)
        window.makeFirstResponder(editor)
        let savedHost = list.view(atColumn: 0, row: 5, makeIfNecessary: false)
        XCTAssertNotNil(savedHost)
        let origin = scroll.contentView.bounds.origin
        let revision = workspace.revision

        workspace.listEventCounts = [:]
        workspace.editor.edit(workspace.editor.text + "More.\n")
        let didSave = await workspace.editor.save()
        XCTAssertTrue(didSave)
        await workspace.refreshSavedDocumentDates() // What the window runs when the editor turns clean.
        try await settle(30)

        XCTAssertEqual(workspace.documents.first?.relativePath, saved.relativePath, "the saved note sorts first")
        XCTAssertEqual(list.numberOfRows, 20)
        XCTAssertEqual(workspace.listEventCounts["reloadData"] ?? 0, 0, "a save reloaded the whole list")
        XCTAssertEqual(workspace.listEventCounts["summaryCleared"] ?? 0, 0, "a save blanked a row's excerpt")
        XCTAssertEqual(list.selectedRowIndexes, [0], "the selection follows the moved row")
        XCTAssertEqual(scroll.contentView.bounds.origin, origin, "a save scrolled the list")
        XCTAssertEqual(workspace.revision, revision, "a save bumped the library revision (folder sidebar reload)")
        XCTAssertTrue(window.firstResponder === editor, "the editor keeps focus")
        // The moved row is the same cell, refreshed with its new date.
        let movedHost = list.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSHostingView<DocumentRow>
        if let movedHost, list.visibleRect.intersects(list.rect(ofRow: 0)) {
            XCTAssertTrue(movedHost === savedHost)
        }
        XCTAssertEqual(
            (list.view(atColumn: 0, row: 3, makeIfNecessary: false) as? NSHostingView<DocumentRow>)?.rootView
                .document.relativePath, workspace.documents[3].relativePath, "visible rows show the new order")

        // Sort By Name: a save changes no order and still blanks no excerpt.
        workspace.setSortKey(.name)
        try await settle(30)
        workspace.listEventCounts = [:]
        let order = workspace.documents.map(\.relativePath)
        workspace.editor.edit(workspace.editor.text + "Again.\n")
        let savedAgain = await workspace.editor.save()
        XCTAssertTrue(savedAgain)
        await workspace.refreshSavedDocumentDates()
        try await settle(30)
        XCTAssertEqual(workspace.documents.map(\.relativePath), order)
        XCTAssertEqual(workspace.listEventCounts["reloadData"] ?? 0, 0, "Name: a save reloaded the whole list")
        XCTAssertEqual(workspace.listEventCounts["summaryCleared"] ?? 0, 0, "Name: a save blanked a row's excerpt")
    }
}

private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

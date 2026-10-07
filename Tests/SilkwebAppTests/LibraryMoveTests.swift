import AppKit
import SilkwebCore
import SwiftUI
import UniformTypeIdentifiers
import XCTest

@testable import Silkweb

final class LibraryMoveTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> (URL, LibraryWorkspace) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createFolder(named: "A")
        _ = try await engine.createFolder(named: "Child", in: "A")
        _ = try await engine.createFolder(named: "B")
        _ = try await engine.createDocument(named: "One.md", in: "A", text: "[two](../Two.md)")
        _ = try await engine.createDocument(named: "Two.md", text: "[one](A/One.md)")
        let workspace = LibraryWorkspace()
        workspace.root = root
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot)
        await workspace.editor.configure(root: root)
        return (root, workspace)
    }
    @MainActor
    private func wait(_ workspace: LibraryWorkspace) async throws {
        for _ in 0..<500 {
            if !workspace.mutating { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Move did not finish")
    }
    @MainActor
    func testDirtySaveMoveFollowsIDAndUndo() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.session.selectedFolder = "A"
        workspace.session.selectedDocuments = ["A/One.md"]
        let id = workspace.selectedDocument!.id
        _ = await workspace.editor.open(root.appendingPathComponent("A/One.md"), readOnly: false)
        workspace.editor.edit("dirty [two](../Two.md)")
        workspace.move(["A/One.md"], to: "B")
        try await wait(workspace)
        XCTAssertNil(workspace.mutationError)
        XCTAssertEqual(workspace.session.selectedFolder, "A")
        XCTAssertEqual(workspace.session.selectedDocuments, ["B/One.md"])
        XCTAssertEqual(workspace.snapshot?.documents.first { $0.relativePath == "B/One.md" }?.id, id)
        XCTAssertEqual(workspace.editor.url, root.appendingPathComponent("B/One.md"))
        XCTAssertEqual(workspace.editor.text, "dirty [two](../Two.md)")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Two.md"), encoding: .utf8), "[one](B/One.md)")
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertEqual(workspace.editor.url, root.appendingPathComponent("A/One.md"))
        XCTAssertEqual(workspace.editor.text, "dirty [two](../Two.md)")
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("Two.md"), encoding: .utf8), "[one](A/One.md)")
    }
    /// silkweb-1.72: renaming a document or folder rewrites incoming links; one undo restores name and links.
    @MainActor
    func testRenameRewritesIncomingLinksAndUndoRestoresBoth() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        func two() throws -> String { try String(contentsOf: root.appendingPathComponent("Two.md"), encoding: .utf8) }
        for (item, expected, renamed) in [
            (LibraryRename(path: "A/One.md", isFolder: false), "[one](A/Renamed.md)", "A/Renamed.md"),
            (LibraryRename(path: "A", isFolder: true), "[one](Renamed/One.md)", "Renamed/One.md"),
        ] {
            workspace.rename = item
            workspace.finishRename(item, value: "Renamed")
            try await wait(workspace)
            XCTAssertNil(workspace.mutationError)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(renamed).path))
            XCTAssertEqual(try two(), expected)
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent(renamed), encoding: .utf8), "[two](../Two.md)")
            XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Rename")
            XCTAssertTrue(workspace.canUndoLibrary)
            workspace.undoLibrary()
            try await wait(workspace)
            XCTAssertNil(workspace.mutationError)
            XCTAssertTrue(workspace.libraryUndo.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("A/One.md").path))
            XCTAssertEqual(try two(), "[one](A/One.md)")
        }
        // Undo still restores name and links after an unrelated edit invalidated the exact snapshot.
        let item = LibraryRename(path: "A/One.md", isFolder: false)
        workspace.rename = item
        workspace.finishRename(item, value: "Renamed")
        try await wait(workspace)
        XCTAssertEqual(try two(), "[one](A/Renamed.md)")
        try Data("[one](A/Renamed.md)\nedited".utf8).write(to: root.appendingPathComponent("Two.md"), options: .atomic)
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertNil(workspace.mutationError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("A/One.md").path))
        XCTAssertEqual(try two(), "[one](A/One.md)\nedited")
    }
    /// #110: a rename whose incoming links can't be rewritten asks first, like Move To…; Cancel changes nothing.
    @MainActor
    func testRenameConfirmsUnsupportedLinksLikeMove() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
        func links() throws -> String {
            try String(contentsOf: root.appendingPathComponent("Links.md"), encoding: .utf8)
        }
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createDocument(named: "a(b).md", in: "A", text: "target")
        _ = try await engine.createDocument(named: "Links.md", text: "[bad](A/a(b).md)")
        try await workspace.refresh(LibraryChangeSet(changes: []))
        var alerts: [(buttons: [String], message: String, list: String)] = []
        var answer = false
        workspace.presentMoveAlert = { alert, _ in
            let list = ((alert.accessoryView as? NSScrollView)?.documentView as? NSTextView)?.string ?? ""
            alerts.append((alert.buttons.map(\.title), alert.messageText, list))
            return answer
        }
        for (item, renamed) in [
            (LibraryRename(path: "A/a(b).md", isFolder: false), "A/Renamed.md"),
            (LibraryRename(path: "A", isFolder: true), "Renamed"),
        ] {
            workspace.session.selectedFolder = item.isFolder ? item.path : "A"
            workspace.session.selectedDocuments = item.isFolder ? [] : [item.path]
            let selection = (workspace.session.selectedFolder, workspace.session.selectedDocuments)
            let count = alerts.count
            answer = false
            workspace.rename = item
            workspace.finishRename(item, value: "Renamed")
            try await wait(workspace)
            XCTAssertEqual(alerts.count, count + 1, "\(item.path): rename committed without asking")
            XCTAssertEqual(alerts.last?.buttons, ["Rename Anyway", "Cancel"])
            XCTAssertEqual(alerts.last?.message, "Some links might stop working")
            XCTAssertTrue(alerts.last?.list.hasPrefix("Links.md › ") == true, alerts.last?.list ?? "")
            // Cancel works like Escape: old name, same selection, nothing on disk or on the undo stack.
            XCTAssertNil(workspace.rename)
            XCTAssertNil(workspace.mutationError)
            XCTAssertTrue(exists(item.path), item.path)
            XCTAssertFalse(exists(renamed), renamed)
            XCTAssertTrue(workspace.libraryUndo.isEmpty)
            XCTAssertEqual(workspace.session.selectedFolder, selection.0)
            XCTAssertEqual(workspace.session.selectedDocuments, selection.1)

            answer = true
            workspace.rename = item
            workspace.finishRename(item, value: "Renamed")
            try await wait(workspace)
            XCTAssertEqual(alerts.count, count + 2)
            XCTAssertNil(workspace.mutationError)
            XCTAssertTrue(exists(renamed), renamed)
            XCTAssertEqual(try links(), "[bad](A/a(b).md)")
            XCTAssertEqual(workspace.libraryUndo.map(\.title), ["Undo Rename"])
            workspace.undoLibrary()
            try await wait(workspace)
            XCTAssertNil(workspace.mutationError)
            XCTAssertTrue(exists(item.path), item.path)
            XCTAssertTrue(workspace.libraryUndo.isEmpty)
        }
        // Move To… shares the sheet and keeps its own action name.
        answer = false
        workspace.move(["A/a(b).md"], to: "B")
        try await wait(workspace)
        XCTAssertEqual(alerts.last?.buttons, ["Move Anyway", "Cancel"])
        XCTAssertTrue(exists("A/a(b).md"))
        XCTAssertTrue(workspace.libraryUndo.isEmpty)
    }
    /// #103: an edit saved anywhere after a move must not leave Undo Move stuck on the stack.
    @MainActor
    func testMoveUndoAfterUnrelatedEditRestoresPathsAndLinks() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
        func text(_ path: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
        _ = try await LibraryMutations(root: root).createDocument(named: "Three.md", in: "B", text: "three")
        try await workspace.refresh(LibraryChangeSet(changes: []))
        workspace.move(["A/One.md"], to: "B")
        try await wait(workspace)
        XCTAssertNil(workspace.mutationError)
        XCTAssertEqual(try text("Two.md"), "[one](B/One.md)")
        // A one-character edit in an unrelated open document is saved by the flush before undo.
        _ = await workspace.editor.open(root.appendingPathComponent("B/Three.md"), readOnly: false)
        workspace.editor.edit("three!")
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertNil(workspace.mutationError)
        XCTAssertTrue(exists("A/One.md"))
        XCTAssertFalse(exists("B/One.md"))
        XCTAssertEqual(try text("Two.md"), "[one](A/One.md)")
        XCTAssertEqual(try text("B/Three.md"), "three!")
        XCTAssertTrue(workspace.libraryUndo.isEmpty)

        // The linking document itself was edited, and Keep Both renamed the item: both come back.
        _ = try await LibraryMutations(root: root).createDocument(named: "One.md", in: "B", text: "other")
        let engine = try LibraryMutations(root: root)
        let plan = try await engine.planMove(["A/One.md"], toFolder: "B", keepBoth: true)
        _ = try await workspace.commitMove(plan, using: engine)
        workspace.libraryUndo.append(.move(plan.reversed))
        XCTAssertEqual(try text("Two.md"), "[one](B/One%202.md)")
        try Data("[one](B/One%202.md)\nedited".utf8).write(to: root.appendingPathComponent("Two.md"), options: .atomic)
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertNil(workspace.mutationError)
        XCTAssertEqual(try text("A/One.md"), "[two](../Two.md)")
        XCTAssertEqual(try text("B/One.md"), "other")
        XCTAssertFalse(exists("B/One 2.md"))
        XCTAssertEqual(try text("Two.md"), "[one](A/One.md)\nedited")
        XCTAssertTrue(workspace.libraryUndo.isEmpty)
    }
    /// #103: an impossible Undo Move changes nothing, reports once and exposes the older entry.
    @MainActor
    func testImpossibleMoveUndoDropsEntryAndReachesOlderUndo() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
        let item = LibraryRename(path: "A/Child", isFolder: true)
        workspace.rename = item
        workspace.finishRename(item, value: "Kid")
        try await wait(workspace)
        XCTAssertTrue(exists("A/Kid"))
        workspace.move(["A/One.md", "Two.md"], to: "B")
        try await wait(workspace)
        XCTAssertNil(workspace.mutationError)
        XCTAssertEqual(workspace.libraryUndo.map(\.title), ["Undo Rename", "Undo Move"])
        // Something now occupies one original path: neither item may go back.
        try Data("blocker".utf8).write(to: root.appendingPathComponent("Two.md"))
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertEqual(workspace.mutationErrorTitle, "The move couldn’t be undone.")
        XCTAssertTrue(workspace.mutationError?.contains("Two") == true)
        XCTAssertTrue(workspace.mutationError?.hasSuffix("Nothing was changed.") == true)
        XCTAssertTrue(exists("B/One.md"))
        XCTAssertTrue(exists("B/Two.md"))
        XCTAssertFalse(exists("A/One.md"))
        XCTAssertEqual(workspace.libraryUndo.map(\.title), ["Undo Rename"])
        XCTAssertTrue(workspace.canUndoLibrary)
        workspace.mutationError = nil
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertNil(workspace.mutationError)
        XCTAssertTrue(exists("A/Child"))
        XCTAssertTrue(workspace.libraryUndo.isEmpty)

        // A moved item deleted outside Silkweb is reported the same way.
        workspace.mutationError = nil
        workspace.move(["B/One.md"], to: "A")
        try await wait(workspace)
        XCTAssertNil(workspace.mutationError)
        XCTAssertEqual(workspace.libraryUndo.map(\.title), ["Undo Move"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("A/One.md"))
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertEqual(workspace.mutationErrorTitle, "The move couldn’t be undone.")
        XCTAssertTrue(workspace.mutationError?.contains("no longer exists") == true)
        XCTAssertTrue(workspace.libraryUndo.isEmpty)
        XCTAssertFalse(workspace.canUndoLibrary)
    }
    @MainActor
    func testFailedDirtySaveAbortsMove() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("A/One.md")
        _ = await workspace.editor.open(url, readOnly: false)
        workspace.editor.edit("unsaved")
        try Data("external".utf8).write(to: url, options: .atomic)
        workspace.move(["A"], to: "B")
        try await wait(workspace)
        XCTAssertNotNil(workspace.editor.banner)
        XCTAssertEqual(workspace.editor.text, "unsaved")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/A").path))
    }
    @MainActor
    func testDropValidationInternalIDsAndOffscreenLifecycle() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.session.selectedDocuments = ["A/One.md", "Two.md"]
        XCTAssertEqual(workspace.documentDragPaths("A/One.md"), ["A/One.md", "Two.md"])
        XCTAssertEqual(workspace.documentDragPaths("Other.md"), ["Other.md"])
        let snapshot = try XCTUnwrap(workspace.snapshot)
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: snapshot)
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        let outline = try XCTUnwrap(scroll.documentView as? SidebarOutlineView)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        host.addSubview(scroll)
        for path in ["A", "A/Child", ""] {
            XCTAssertFalse(coordinator.allowsDrop(["A"], item: coordinator.itemsByPath[path]))
        }
        XCTAssertFalse(coordinator.allowsDrop(["A"], item: coordinator.roots.first))
        XCTAssertTrue(coordinator.allowsDrop(["A/One.md", "Two.md"], item: coordinator.itemsByPath["B"]))
        XCTAssertTrue(coordinator.allowsDrop(["A/One.md"], item: coordinator.itemsByPath[""]))
        XCTAssertNil(coordinator.outlineView(outline, pasteboardWriterForItem: coordinator.itemsByPath[""]!))
        let writer = try XCTUnwrap(
            coordinator.outlineView(outline, pasteboardWriterForItem: coordinator.itemsByPath["A"]!)
                as? NSPasteboardItem)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.writeObjects([writer])
        let payload = try XCTUnwrap(writer.data(forType: NSPasteboard.PasteboardType(UTType.silkwebMove.identifier)))
        XCTAssertEqual(workspace.pathsForDrag(payload), ["A"])
        workspace.dragIdentity = UUID()
        XCTAssertNil(workspace.pathsForDrag(payload))
        XCTAssertNil(workspace.pathsForDrag(Data("invalid".utf8)))
        coordinator.setHover(coordinator.itemsByPath["A"])
        coordinator.expandHover()
        XCTAssertTrue(outline.isItemExpanded(coordinator.itemsByPath["A"]!))
        coordinator.finishDrag(accepted: false)
        XCTAssertFalse(outline.isItemExpanded(coordinator.itemsByPath["A"]!))
        for width: CGFloat in [0, 1, 180, 440, 4096] {
            for height: CGFloat in [0, 1, 24, 480, 2160] {
                scroll.setFrameSize(NSSize(width: width, height: height))
                scroll.tile(); scroll.layoutSubtreeIfNeeded()
                FolderSidebar.update(scroll, coordinator: coordinator, snapshot: snapshot)
                XCTAssertGreaterThan(outline.numberOfRows, 0)
            }
        }
        // Build the real picker and list inside hosting views, without a window.
        let progress = makeMoveProgressPanel()
        for size in [NSSize(width: 1, height: 1), NSSize(width: 300, height: 100), NSSize(width: 4096, height: 2160)] {
            progress.setContentSize(size)
            progress.contentView?.layoutSubtreeIfNeeded()
        }
        progress.orderOut(nil)
        let picker = NSHostingView(rootView: MovePicker(workspace: workspace, request: MoveRequest(paths: ["A"])))
        let list = NSHostingView(rootView: DocumentList(workspace: workspace))
        host.addSubview(picker); host.addSubview(list)
        for size in [
            NSSize.zero, NSSize(width: 1, height: 1), NSSize(width: 440, height: 480),
            NSSize(width: 4096, height: 2160),
        ] {
            picker.setFrameSize(size); list.setFrameSize(size)
            picker.layoutSubtreeIfNeeded(); list.layoutSubtreeIfNeeded()
        }
        scroll.removeFromSuperview(); host.addSubview(scroll)
        FolderSidebar.dismantleNSView(scroll, coordinator: coordinator)
    }
}

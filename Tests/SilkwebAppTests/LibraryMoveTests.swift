import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import SilkwebCore
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
        workspace.install(snapshot, sorted: snapshot.documents)
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
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Two.md"), encoding: .utf8), "[one](B/One.md)")
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertEqual(workspace.editor.url, root.appendingPathComponent("A/One.md"))
        XCTAssertEqual(workspace.editor.text, "dirty [two](../Two.md)")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Two.md"), encoding: .utf8), "[one](A/One.md)")
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
        let writer = try XCTUnwrap(coordinator.outlineView(outline, pasteboardWriterForItem: coordinator.itemsByPath["A"]!) as? NSPasteboardItem)
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
        for size in [NSSize.zero, NSSize(width: 1, height: 1), NSSize(width: 440, height: 480), NSSize(width: 4096, height: 2160)] {
            picker.setFrameSize(size); list.setFrameSize(size)
            picker.layoutSubtreeIfNeeded(); list.layoutSubtreeIfNeeded()
        }
        scroll.removeFromSuperview(); host.addSubview(scroll)
        FolderSidebar.dismantleNSView(scroll, coordinator: coordinator)
    }
}

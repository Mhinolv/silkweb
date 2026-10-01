import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

final class LibraryTrashTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> (URL, URL, LibraryWorkspace, TrashService) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let trash = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for url in [root, trash] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createFolder(named: "A")
        _ = try await engine.createFolder(named: "B")
        for name in ["First.md", "Middle.md", "Last.md"] {
            _ = try await engine.createDocument(named: name, in: "A", text: "original")
        }
        let workspace = LibraryWorkspace()
        workspace.root = root
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot, sorted: snapshot.documents.sorted { $0.name < $1.name })
        await workspace.editor.configure(root: root)
        let service = try TrashService(root: root) { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        return (root, trash, workspace, service)
    }
    @MainActor
    func testDirtyTrashSelectionAndUndo() async throws {
        let (root, trash, workspace, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        workspace.session.selectedFolder = "A"
        workspace.session.selectedDocuments = ["A/Middle.md"]
        workspace.focusColumn = 1
        _ = await workspace.editor.open(root.appendingPathComponent("A/Middle.md"), readOnly: false)
        workspace.editor.edit("latest text")
        XCTAssertEqual(workspace.trashMenuTitle, "Move “Middle” to Trash")
        let plan = try await service.plan(["A/Middle.md"])
        await workspace.performTrash(plan, using: service)
        XCTAssertNil(workspace.mutationError)
        XCTAssertEqual(try String(contentsOf: trash.appendingPathComponent("Middle.md"), encoding: .utf8), "latest text")
        XCTAssertEqual(workspace.session.selectedDocuments, ["A/Last.md"])
        XCTAssertEqual(workspace.editor.url, root.appendingPathComponent("A/Last.md"))
        XCTAssertEqual(workspace.focusColumn, 1)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Move to Trash")
        workspace.undoLibrary()
        for _ in 0..<500 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(workspace.mutating)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("A/Middle.md").path))
        XCTAssertTrue(workspace.libraryUndo.isEmpty)
    }
    @MainActor
    func testFailedSaveAndRecoveryBlockAllTrashing() async throws {
        let (root, trash, workspace, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        let url = root.appendingPathComponent("A/Middle.md")
        _ = await workspace.editor.open(url, readOnly: false)
        workspace.editor.edit("unsaved text")
        try Data("external edit".utf8).write(to: url, options: .atomic)
        let plan = try await service.plan(["A", "B"])
        await workspace.performTrash(plan, using: service)
        XCTAssertEqual(workspace.editor.text, "unsaved text")
        XCTAssertEqual(workspace.editor.url, url)
        XCTAssertTrue(workspace.mutationErrorTitle.contains("nothing was moved"))
        XCTAssertTrue(workspace.libraryUndo.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        workspace.editor.recovered = true
        await workspace.performTrash(plan, using: service)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("B").path))
    }
    @MainActor
    func testFolderConfirmationCancellationAndSidebarSuccessor() async throws {
        let (root, trash, workspace, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        workspace.focusColumn = 0
        workspace.session.selectedFolder = ""
        XCTAssertFalse(workspace.canTrashSelection)
        workspace.session.selectedFolder = nil
        XCTAssertFalse(workspace.canTrashSelection)
        workspace.session.selectedFolder = "A"
        workspace.requestTrash()
        for _ in 0..<500 where workspace.trashPlan == nil && workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(workspace.trashPlan)
        XCTAssertTrue(workspace.trashMessage.contains("3 documents"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
        workspace.cancelTrash()
        XCTAssertFalse(workspace.mutating)
        XCTAssertNil(workspace.trashPlan)
        let plan = try await service.plan(["A"])
        await workspace.performTrash(plan, using: service)
        XCTAssertEqual(workspace.session.selectedFolder, "B")
        XCTAssertEqual(workspace.focusColumn, 0)
        workspace.focusColumn = 2
        XCTAssertFalse(workspace.canTrashSelection)
    }
    @MainActor
    func testUndoConflictRetainsTrashAndRevealAction() async throws {
        let (root, trash, workspace, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        let plan = try await service.plan(["A/Middle.md"])
        await workspace.performTrash(plan, using: service)
        let replacement = root.appendingPathComponent("A/Middle.md")
        try Data("replacement".utf8).write(to: replacement)
        workspace.undoLibrary()
        for _ in 0..<500 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(workspace.mutating)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Move to Trash")
        XCTAssertTrue(workspace.mutationErrorTitle.contains("now exists"))
        XCTAssertEqual(workspace.mutationRevealTitle, "Reveal in Trash")
        XCTAssertEqual(workspace.mutationRevealURLs, [trash.appendingPathComponent("Middle.md")])
        XCTAssertEqual(try String(contentsOf: replacement, encoding: .utf8), "replacement")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Middle.md").path))
    }
    @MainActor
    func testOffscreenTrashViewsResizeSweep() async throws {
        let (root, trash, workspace, service) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: trash) }
        workspace.trashPlan = try await service.plan(["A"])
        let snapshot = try XCTUnwrap(workspace.snapshot)
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: snapshot)
        let sidebar = FolderSidebar.makeScrollView(coordinator: coordinator)
        let list = NSHostingView(rootView: DocumentList(workspace: workspace))
        let content = NSHostingView(rootView: LibraryWorkspaceView(workspace: workspace))
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        host.addSubview(sidebar); host.addSubview(list); host.addSubview(content)
        for size in [NSSize.zero, NSSize(width: 1, height: 1), NSSize(width: 180, height: 24), NSSize(width: 1200, height: 760), NSSize(width: 4096, height: 2160)] {
            for view in [sidebar, list, content] as [NSView] {
                view.setFrameSize(size); view.layoutSubtreeIfNeeded()
            }
            sidebar.tile()
            FolderSidebar.update(sidebar, coordinator: coordinator, snapshot: snapshot)
        }
        FolderSidebar.dismantleNSView(sidebar, coordinator: coordinator)
    }
}

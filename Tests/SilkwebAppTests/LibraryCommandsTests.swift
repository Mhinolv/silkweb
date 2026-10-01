import AppKit
import XCTest
import SilkwebCore
@testable import Silkweb

final class LibraryCommandsTests: XCTestCase {
    @MainActor
    private func fixture() async throws -> (URL, LibraryWorkspace) {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createFolder(named: "Writing")
        _ = try await engine.createDocument(named: "Plan.markdown", in: "Writing", text: "# Heading\n")
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
        XCTFail("Mutation did not finish")
    }

    @MainActor
    func testTargetCreateRenameDirtyBufferAndSelection() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.session.selectedFolder = nil
        XCTAssertEqual(workspace.targetFolder, "")
        workspace.session.selectedDocuments = ["Writing/Plan.markdown"]
        XCTAssertEqual(workspace.targetFolder, "Writing")
        workspace.session.selectedFolder = ""
        XCTAssertEqual(workspace.targetFolder, "")
        workspace.session.selectedFolder = "Writing"
        _ = await workspace.editor.open(root.appendingPathComponent("Writing/Plan.markdown"), readOnly: false)
        workspace.editor.edit("# Heading stays unchanged\nUnsaved text")
        let id = try XCTUnwrap(workspace.selectedDocument?.id)
        let item = LibraryRename(path: "Writing/Plan.markdown", isFolder: false)
        workspace.rename = item
        workspace.finishRename(item, value: "  PLAN  ")
        try await wait(workspace)
        XCTAssertNil(workspace.mutationError)
        XCTAssertEqual(workspace.selectedDocument?.id, id)
        XCTAssertEqual(workspace.session.selectedDocuments, ["Writing/PLAN.markdown"])
        XCTAssertEqual(workspace.editor.url, root.appendingPathComponent("Writing/PLAN.markdown"))
        XCTAssertEqual(try String(contentsOf: workspace.editor.url!, encoding: .utf8), "# Heading stays unchanged\nUnsaved text")
        XCTAssertTrue(workspace.canUndoLibrary)
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertEqual(workspace.session.selectedDocuments, ["Writing/Plan.markdown"])
        workspace.session.selectedFolder = nil
        workspace.create(folder: false)
        try await wait(workspace)
        XCTAssertEqual(workspace.session.selectedFolder, "Writing")
        XCTAssertEqual(workspace.session.selectedDocuments, ["Writing/Untitled.md"])
        XCTAssertEqual(workspace.editor.text, "")
        XCTAssertEqual(workspace.rename?.name, "Untitled")
        workspace.finishRename(workspace.rename!, value: nil)
        workspace.create(folder: false)
        try await wait(workspace)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Writing/Untitled 2.md").path))
        workspace.finishRename(workspace.rename!, value: nil)
        workspace.create(folder: true, parent: "")
        try await wait(workspace)
        XCTAssertEqual(workspace.session.selectedFolder, "Untitled Folder")
        workspace.finishRename(workspace.rename!, value: nil)
        XCTAssertTrue(workspace.canUndoLibrary)
        workspace.undoLibrary()
        try await wait(workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Untitled Folder").path))
    }

    @MainActor
    func testFailedSaveAbortsRenameAndNavigation() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.session.selectedFolder = "Writing"
        workspace.session.selectedDocuments = ["Writing/Plan.markdown"]
        let url = root.appendingPathComponent("Writing/Plan.markdown")
        _ = await workspace.editor.open(url, readOnly: false)
        workspace.editor.edit("Unsaved buffer")
        try Data("External edit".utf8).write(to: url, options: .atomic)
        let item = LibraryRename(path: "Writing/Plan.markdown", isFolder: false)
        workspace.rename = item
        workspace.finishRename(item, value: "Renamed")
        try await wait(workspace)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Writing/Renamed.markdown").path))
        XCTAssertEqual(workspace.editor.text, "Unsaved buffer")
        XCTAssertNotNil(workspace.editor.banner)
        workspace.selectDocuments([])
        await workspace.waitForNavigation()
        XCTAssertEqual(workspace.session.selectedDocuments, ["Writing/Plan.markdown"])
        XCTAssertGreaterThan(workspace.editor.refusedNavigation, 0)
    }

    @MainActor
    func testExplicitSaveKeepsPendingRecovery() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Writing/Plan.markdown")
        _ = await workspace.editor.open(url, readOnly: false)
        workspace.editor.recovered = true
        workspace.editor.edit("Recovered buffer")
        let refused = await workspace.editor.flush()
        XCTAssertFalse(refused)
        let saved = await workspace.editor.save()
        XCTAssertTrue(saved)
        XCTAssertFalse(workspace.editor.recovered)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Recovered buffer")
    }

    @MainActor
    func testOffscreenSidebarAndRenameLifecycleResizeSweep() async throws {
        let (root, workspace) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshot = try XCTUnwrap(workspace.snapshot)
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: snapshot)
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        let outline = try XCTUnwrap(scroll.documentView as? SidebarOutlineView)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        host.addSubview(scroll)
        workspace.session.selectedFolder = "Writing"
        workspace.session.expandedFolders = [""]
        workspace.rename = LibraryRename(path: "Writing", isFolder: true)
        FolderSidebar.update(scroll, coordinator: coordinator, snapshot: snapshot)
        let row = outline.row(forItem: coordinator.itemsByPath["Writing"]!)
        let cell = try XCTUnwrap(coordinator.outlineView(outline, viewFor: outline.tableColumns.first,
                                                       item: coordinator.itemsByPath["Writing"]!) as? SidebarFolderCell)
        let field = try XCTUnwrap(cell.renameField)
        XCTAssertEqual(field.stringValue, "Writing")
        XCTAssertEqual(field.accessibilityLabel(), "Name")
        for width: CGFloat in [0, 1, 180, 220, 320, 4096] {
            for height: CGFloat in [0, 1, 24, 560, 2160] {
                scroll.setFrameSize(NSSize(width: width, height: height))
                scroll.tile()
                scroll.layoutSubtreeIfNeeded()
                FolderSidebar.update(scroll, coordinator: coordinator, snapshot: snapshot)
                XCTAssertEqual(outline.selectedRow, row)
            }
        }
        host.addSubview(cell)
        cell.setFrameSize(NSSize(width: 220, height: 24))
        cell.layoutSubtreeIfNeeded()
        field.viewDidMoveToWindow()
        var cancelled = false
        field.finish = { cancelled = $0 == nil }
        XCTAssertTrue(field.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertTrue(cancelled)
        scroll.removeFromSuperview()
        host.addSubview(scroll)
        workspace.rename = nil
        FolderSidebar.update(scroll, coordinator: coordinator, snapshot: snapshot)
    }

    func testBaseNameValidationAndExtensionLengths() throws {
        for ext in ["md", "markdown", "MD"] {
            let item = LibraryRename(path: "Writing/Old." + ext, isFolder: false)
            XCTAssertEqual(try item.filename("  New  "), "New." + ext)
            for invalid in ["", "  ", ".hidden", "a/b", "a:b", "a\u{0}b", String(repeating: "a", count: 256)] {
                XCTAssertThrowsError(try item.filename(invalid))
            }
            let longest = String(repeating: "a", count: 254 - ext.utf8.count)
            XCTAssertEqual(try item.filename(longest).utf8.count, 255)
            XCTAssertThrowsError(try item.filename(longest + "a"))
        }
    }
}

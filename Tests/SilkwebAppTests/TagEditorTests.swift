import AppKit
import SwiftUI
import XCTest
@testable import Silkweb
@testable import SilkwebCore

final class TagEditorTests: XCTestCase {
    @MainActor
    func testRealInfoHierarchyTokenLifecycleAndMultiSelection() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A.md", "B.md"] { try Data("# Title".utf8).write(to: root.appendingPathComponent(name)) }
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedDocuments = ["A.md", "B.md"]
        workspace.inspectorInfo = true
        let controller = NSHostingController(rootView: InspectorView(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for _ in 0..<30 {
            controller.view.layoutSubtreeIfNeeded()
            if descendants(controller.view).contains(where: { $0 is NSTokenField }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let field = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? NSTokenField }.first)
        let input = try XCTUnwrap(field as? TagInputField)
        input.requestedFocus = 1
        input.focusIfNeeded()
        XCTAssertEqual(input.fulfilledFocus, 1)
        let coordinator = try XCTUnwrap(field.delegate as? TagTokenField.Coordinator)
        coordinator.suggestions = ["research", "draft"]
        XCTAssertEqual(coordinator.tokenField(field, completionsForSubstring: "R", indexOfToken: 0, indexOfSelectedItem: nil) as? [String], ["research"])
        XCTAssertEqual(coordinator.tokenField(field, shouldAdd: ["  Research ", "a,b", String(repeating: "x", count: 65)], at: 0) as? [String], ["research"])
        let text = NSTextView()
        text.string = "abc\u{FFFC}"
        text.setSelectedRange(NSRange(location: 2, length: 0))
        XCTAssertFalse(TagTokenField.Coordinator.isTokenDeletion(text, backwards: true))
        text.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertTrue(TagTokenField.Coordinator.isTokenDeletion(text, backwards: true))
        field.objectValue = ["Research"]
        coordinator.commit(field)
        for _ in 0..<100 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(workspace.tags.map(\.name), ["Research"])
        XCTAssertEqual(workspace.snapshot?.metadata.tagsByDocument.count, 2)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Add Tag")
        for info in [false, true, false, true] {
            workspace.inspectorInfo = info
            for width in [200.0, 240.0, 320.0, 200.0] {
                controller.view.setFrameSize(NSSize(width: width, height: 700))
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(10))
                XCTAssertTrue(controller.view.frame.width.isFinite)
            }
        }
        workspace.editTags([])
        for _ in 0..<100 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(workspace.tags.isEmpty)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Remove Tag")
        workspace.undoLibrary()
        for _ in 0..<100 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(workspace.tags.map(\.name), ["Research"])
        workspace.session.selectedDocuments = []
        controller.view.layoutSubtreeIfNeeded()
    }

    @MainActor
    func testRealSidebarClearsFolderSelectionForTagAndRestoresAllDocuments() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# A".utf8).write(to: root.appendingPathComponent("A.md"))
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedDocuments = ["A.md"]
        workspace.editTags(["research"])
        for _ in 0..<100 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
        let tag = try XCTUnwrap(workspace.tags.first)
        let snapshot = try XCTUnwrap(workspace.snapshot)
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: snapshot)
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        let outline = try XCTUnwrap(coordinator.outline)
        XCTAssertGreaterThanOrEqual(outline.selectedRow, 0)
        workspace.selectTag(tag.id)
        await workspace.waitForNavigation()
        for _ in 0..<10 { await Task.yield() }
        FolderSidebar.update(scroll, coordinator: coordinator, snapshot: snapshot)
        XCTAssertEqual(workspace.session.selectedTagID, tag.id)
        XCTAssertEqual(outline.selectedRow, -1)
        for width in [180.0, 220.0, 320.0] {
            scroll.setFrameSize(NSSize(width: width, height: 600))
            scroll.layoutSubtreeIfNeeded()
        }
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        await workspace.waitForNavigation()
        XCTAssertNil(workspace.session.selectedTagID)
        XCTAssertNil(workspace.session.selectedFolder)
        XCTAssertEqual(outline.selectedRow, 0)
    }

    @MainActor
    func testTagSortPreferencesFiltersAndContextMenu() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# A".utf8).write(to: root.appendingPathComponent("A.md"))
        try Data("# B".utf8).write(to: root.appendingPathComponent("B.md"))
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedDocuments = ["A.md"]
        workspace.editTags(["research"])
        for _ in 0..<100 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
        let tag = try XCTUnwrap(workspace.tags.first)
        workspace.session.selectedTagID = tag.id
        workspace.session.selectedFolder = nil
        workspace.setSortKey(.name)
        XCTAssertEqual(workspace.session.listPreferences["tag:" + tag.id.uuidString]?.key, .name)
        XCTAssertEqual(workspace.documents.map(\.name), ["A.md"])
        workspace.session.selectedTagID = nil
        workspace.tagFilters = [tag.id]
        XCTAssertEqual(workspace.documents.map(\.name), ["A.md"])
        workspace.session.selectedDocuments = ["A.md", "B.md"]
        let coordinator = DocumentTable.Coordinator(workspace: workspace)
        let menu = coordinator.menu(path: "A.md")
        let submenu = try XCTUnwrap(menu.items.first { $0.title == "Tags" }?.submenu)
        XCTAssertEqual(submenu.items.first?.state, .mixed)
    }
}

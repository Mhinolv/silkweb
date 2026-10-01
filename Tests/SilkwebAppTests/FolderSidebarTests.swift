import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

final class FolderSidebarTests: XCTestCase {
    @MainActor
    func testOffscreenCountsResizeAndCountOnlyUpdatesPreserveRows() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LibraryMutations(root: root)
        for name in ["Chapter 10", "Chapter 2", "Empty"] { _ = try await engine.createFolder(named: name) }
        _ = try await engine.createFolder(named: "Drafts", in: "Chapter 2")
        _ = try await engine.createDocument(named: "Root.md")
        _ = try await engine.createDocument(named: "Direct.md", in: "Chapter 2")
        _ = try await engine.createDocument(named: "Nested.md", in: "Chapter 2/Drafts")
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.session.selectedFolder = "Chapter 2"
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot)
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: snapshot)
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        container.addSubview(scroll)
        let outline = try XCTUnwrap(coordinator.outline)
        let item = try XCTUnwrap(coordinator.itemsByPath["Chapter 2"])
        func cell(_ item: FolderSidebar.Item) throws -> SidebarFolderCell {
            try XCTUnwrap(coordinator.outlineView(outline, viewFor: outline.tableColumns[0], item: item) as? SidebarFolderCell)
        }
        XCTAssertEqual(try cell(item).countBadge.stringValue, "1")
        XCTAssertEqual(try cell(item).accessibilityValue() as? String, "1 documents, 2 including subfolders")
        XCTAssertEqual(try cell(coordinator.roots[0]).countBadge.stringValue, "3")
        XCTAssertEqual(try cell(coordinator.itemsByPath[""]!).countBadge.stringValue, "1")
        XCTAssertEqual(try cell(coordinator.itemsByPath["Empty"]!).countBadge.stringValue, "")
        XCTAssertEqual(coordinator.itemsByPath[""]?.children.map(\.title), ["Chapter 2", "Chapter 10", "Empty"])
        for width: CGFloat in [0, 1, 180, 260, 4096] {
            for height: CGFloat in [0, 1, 24, 560, 2160] {
                scroll.setFrameSize(NSSize(width: width, height: height))
                scroll.layoutSubtreeIfNeeded()
                outline.layoutSubtreeIfNeeded()
            }
        }
        _ = try await engine.createDocument(named: "Second.md", in: "Chapter 2")
        let rescanned = try await LibraryScanner.scan(root: root)
        workspace.install(rescanned)
        workspace.revision += 1
        FolderSidebar.update(scroll, coordinator: coordinator, snapshot: rescanned)
        XCTAssertTrue(coordinator.itemsByPath["Chapter 2"] === item)
        XCTAssertEqual(try cell(item).countBadge.stringValue, "2")
        XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? FolderSidebar.Item === item)
        workspace.rename = LibraryRename(path: "Chapter 2", isFolder: true)
        FolderSidebar.update(scroll, coordinator: coordinator, snapshot: rescanned)
        XCTAssertNotNil(try cell(item).renameField)
        scroll.layoutSubtreeIfNeeded()
        workspace.rename = nil
        FolderSidebar.update(scroll, coordinator: coordinator, snapshot: rescanned)
        scroll.removeFromSuperview()
        container.addSubview(scroll)
        scroll.layoutSubtreeIfNeeded()
    }

    @MainActor
    func testSavedDateRefreshReordersWithoutLosingSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, timestamp) in [("Old.md", 1_500_000_000.0), ("Recent.md", 1_600_000_000.0)] {
            let url = root.appendingPathComponent(name)
            try Data("text".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: url.path)
        }
        let workspace = LibraryWorkspace()
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot)
        XCTAssertEqual(workspace.documents.map(\.name), ["Recent.md", "Old.md"])
        let url = root.appendingPathComponent("Old.md")
        _ = await workspace.editor.open(url, readOnly: false)
        workspace.session.selectedDocuments = ["Old.md"]
        workspace.editor.edit("changed text")
        let saved = await workspace.editor.save()
        XCTAssertTrue(saved)
        await workspace.refreshSavedDocumentDates()
        XCTAssertEqual(workspace.documents.map(\.name), ["Old.md", "Recent.md"])
        XCTAssertEqual(workspace.session.selectedDocuments, ["Old.md"])
        XCTAssertEqual(workspace.editor.url, url)
    }

    @MainActor
    func testListModesAndPreferencesOffscreen() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createFolder(named: "Drafts")
        _ = try await engine.createDocument(named: "Nested.md", in: "Drafts")
        let workspace = LibraryWorkspace()
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot)
        let host = NSHostingView(rootView: DocumentList(workspace: workspace))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        container.addSubview(host)
        XCTAssertTrue(workspace.documents.isEmpty)
        for key in DocumentSortKey.allCases {
            workspace.setSortKey(key)
            for descending in [false, true] {
                workspace.setSortDescending(descending)
                for include in [false, true] {
                    workspace.setIncludeSubfolders(include)
                    XCTAssertEqual(workspace.documents.count, include ? 1 : 0)
                    for width: CGFloat in [0, 1, 240, 480, 4096] {
                        host.setFrameSize(NSSize(width: width, height: 560))
                        host.layoutSubtreeIfNeeded()
                    }
                    await Task.yield()
                }
            }
        }
        workspace.session.selectedFolder = "Drafts"
        XCTAssertEqual(workspace.listPreference, LibraryListPreference())
        workspace.setSortKey(.name)
        workspace.session.selectedFolder = nil
        XCTAssertEqual(workspace.documents.count, 1)
        XCTAssertEqual(workspace.listPreference, LibraryListPreference())
        workspace.setIncludeSubfolders(true)
        XCTAssertFalse(workspace.includesSubfolders)
        workspace.session.selectedFolder = "Drafts"
        XCTAssertEqual(workspace.listPreference.key, .name)
        workspace.session.selectedFolder = ""
        XCTAssertTrue(workspace.includesSubfolders)
    }
}

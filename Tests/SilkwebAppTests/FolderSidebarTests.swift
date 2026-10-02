import AppKit
import SwiftUI
import XCTest
@testable import SilkwebCore
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
        XCTAssertEqual(try cell(item).countBadge.stringValue, " (1)")
        XCTAssertEqual(try cell(item).accessibilityValue() as? String, "1 document, 2 including subfolders")
        XCTAssertEqual(try cell(coordinator.roots[0]).countBadge.stringValue, " (3)")
        XCTAssertEqual(try cell(coordinator.itemsByPath[""]!).countBadge.stringValue, " (1)")
        XCTAssertEqual(try cell(coordinator.itemsByPath["Empty"]!).countBadge.stringValue, " (0)")
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
        XCTAssertEqual(try cell(item).countBadge.stringValue, " (2)")
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
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor private func settle(_ controller: LibrarySplitViewController) async throws {
        for _ in 0..<8 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor func testInlineCountsInRealSplitResizeReuseAndRenameLifecycle() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let longName = "A very long folder name that must truncate before its count"
        let privateName = "Private folder with a very long unreadable name"
        for path in ["Short/Nested", longName, privateName] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for path in ["Root.md", "Short/Direct.md", "Short/Nested/Child.md", longName + "/Note.md"] {
            try Data("# Fixture".utf8).write(to: root.appendingPathComponent(path))
        }
        let scanned = try await LibraryScanner.scan(root: root)
        var folders = scanned.folders
        folders[try XCTUnwrap(folders.firstIndex { $0.relativePath == privateName })].isUnreadable = true
        let largeFolder = try XCTUnwrap(folders.first { $0.relativePath == longName })
        let documents = scanned.documents + (0..<1_203).map {
            LibraryDocument(id: UUID(), folderID: largeFolder.id, relativePath: longName + "/Fixture \($0).md", name: "Fixture \($0).md")
        }
        let snapshot = LibrarySnapshot(rootURL: root, folders: folders, documents: documents,
            presentation: LibraryPresentation(folders: folders, documents: documents), metadata: scanned.metadata,
            recoveredMetadataURL: nil, isReadOnly: false)
        let suite = "Silkweb.SidebarTests." + UUID().uuidString
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let workspace = LibraryWorkspace(columnAutosaveName: suite)
        workspace.root = root
        workspace.loading = true
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: suite)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = controller // Never ordered on screen.
        defer { window.contentViewController = nil; workspace.search.reset() }
        controller.view.setFrameSize(NSSize(width: 1400, height: 900))
        try await settle(controller)
        workspace.session.selectedFolder = "Short"
        workspace.session.expandedFolders = ["", "Short"]
        workspace.install(snapshot)
        workspace.loading = false
        try await settle(controller)
        let outline = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? SidebarOutlineView }.first)
        let coordinator = try XCTUnwrap(outline.delegate as? FolderSidebar.Coordinator)
        let short = try XCTUnwrap(coordinator.itemsByPath["Short"])
        let scroll = try XCTUnwrap(outline.enclosingScrollView)
        let navigation = controller.navigationController.splitView
        controller.splitView.setPosition(800, ofDividerAt: 0)
        try await settle(controller)

        for width: CGFloat in [180, 320, 200, 260] {
            navigation.setPosition(width, ofDividerAt: 0)
            try await settle(controller)
            XCTAssertEqual(navigation.arrangedSubviews[0].frame.width, width, accuracy: 1)
            for expanded in [false, true] {
                coordinator.restoring = true
                if expanded { outline.expandItem(short) } else { outline.collapseItem(short) }
                coordinator.restoring = false
                try await settle(controller)
                for row in 0..<outline.numberOfRows {
                    let item = try XCTUnwrap(outline.item(atRow: row) as? FolderSidebar.Item)
                    let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFolderCell)
                    cell.layoutSubtreeIfNeeded()
                    let text = try XCTUnwrap(cell.textField)
                    let titleRect = text.alignmentRect(forFrame: text.frame)
                    let countRect = cell.countBadge.alignmentRect(forFrame: cell.countBadge.frame)
                    let lockRect = cell.lockBadge.alignmentRect(forFrame: cell.lockBadge.frame)
                    let count = item.folder.flatMap { snapshot.presentation.counts[$0.id] }
                        ?? FolderDocumentCount(direct: snapshot.documents.count, recursive: snapshot.documents.count)
                    XCTAssertEqual(cell.countBadge.stringValue, count.inlineSuffix)
                    XCTAssertFalse(cell.countBadge.isHidden)
                    XCTAssertGreaterThanOrEqual(countRect.width + 0.5, cell.countBadge.intrinsicContentSize.width)
                    XCTAssertLessThanOrEqual(countRect.maxX, cell.bounds.maxX - 3.5)
                    XCTAssertGreaterThan(titleRect.width, 0)
                    XCTAssertEqual(text.lineBreakMode, .byTruncatingTail)
                    XCTAssertEqual(cell.accessibilityValue() as? String, count.accessibilityValue)
                    XCTAssertFalse(cell.accessibilityLabel()?.contains(count.inlineSuffix) ?? true)
                    if item.folder?.isUnreadable == true {
                        XCTAssertFalse(cell.lockBadge.isHidden)
                        XCTAssertEqual(lockRect.minX, titleRect.maxX + 4, accuracy: 0.5)
                        XCTAssertEqual(countRect.minX, lockRect.maxX + 4, accuracy: 0.5)
                        XCTAssertEqual(cell.toolTip, "You don't have permission to view this folder.")
                    } else {
                        XCTAssertTrue(cell.lockBadge.isHidden)
                        XCTAssertEqual(countRect.minX, titleRect.maxX, accuracy: 0.5)
                        XCTAssertEqual(cell.toolTip, count.tooltip)
                    }
                    if item.title == "Short" {
                        XCTAssertEqual(titleRect.width, text.intrinsicContentSize.width, accuracy: 0.5)
                        XCTAssertLessThan(countRect.maxX, cell.bounds.maxX - 10)
                    }
                    if item.title == longName, width == 180 {
                        XCTAssertLessThan(titleRect.width, text.intrinsicContentSize.width)
                    }
                    for style: NSView.BackgroundStyle in [.normal, .emphasized] {
                        cell.backgroundStyle = style
                        let expected = style == .emphasized
                            ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : .secondaryLabelColor
                        XCTAssertEqual(cell.countBadge.textColor, expected)
                        XCTAssertEqual(cell.lockBadge.contentTintColor, expected)
                    }
                }
                XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? FolderSidebar.Item === short)
                XCTAssertEqual(workspace.session.selectedFolder, "Short")
            }
        }
        // Reload the real rows into and out of inline rename, including unreadable rows.
        for path in ["Short", privateName] {
            workspace.rename = LibraryRename(path: path, isFolder: true)
            FolderSidebar.update(scroll, coordinator: coordinator, snapshot: snapshot)
            try await settle(controller)
            let item = try XCTUnwrap(coordinator.itemsByPath[path])
            let row = outline.row(forItem: item)
            let editing = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFolderCell)
            XCTAssertNotNil(editing.renameField)
            XCTAssertTrue(editing.countBadge.isHidden)
            XCTAssertTrue(editing.lockBadge.isHidden)
            workspace.rename = nil // Same transition after commit or Escape.
            FolderSidebar.update(scroll, coordinator: coordinator, snapshot: snapshot)
            try await settle(controller)
            let restored = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFolderCell)
            XCTAssertNil(restored.renameField)
            XCTAssertFalse(restored.countBadge.isHidden)
            XCTAssertEqual(restored.lockBadge.isHidden, path != privateName)
        }
    }
}

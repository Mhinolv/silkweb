import AppKit
import SwiftUI
import XCTest
@testable import Silkweb
@testable import SilkwebCore

final class TagEditorTests: XCTestCase {
    @MainActor
    func testFolderSearchIncludesDescendantsRegardlessOfListPreference() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Writing/Drafts/Deep"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let direct = "Writing/A.md", nested = "Writing/Drafts/B.md"
        let deep = "Writing/Drafts/Deep/C.md", outside = "Else.md"
        for path in [direct, nested, deep, outside] {
            try "needle".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        try "unrelated".write(to: root.appendingPathComponent("Writing/Drafts/Other.md"), atomically: true, encoding: .utf8)
        let initial = try await LibraryScanner.scan(root: root)
        let researchIDs = Set(initial.documents.map(\.id))
        let draftIDs = Set(initial.documents.filter { [nested, deep, outside].contains($0.relativePath) }.map(\.id))
        _ = try await TagStore.update(root: root) {
            TagEditor.edit(["research", "draft"], documents: draftIDs,
                           metadata: TagEditor.edit(["research"], documents: researchIDs, metadata: $0))
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(snapshot)
        await workspace.search.waitForIndex()
        workspace.session.selectedFolder = "Writing"
        let folder = try XCTUnwrap(workspace.selectedFolder)
        let research = try XCTUnwrap(workspace.tags.first { $0.name == "research" }?.id)
        let draft = try XCTUnwrap(workspace.tags.first { $0.name == "draft" }?.id)
        let cases: [(filters: Set<UUID>, folderPaths: Set<String>, libraryPaths: Set<String>)] = [
            ([], [direct, nested, deep], [direct, nested, deep, outside]),
            ([research], [direct, nested, deep], [direct, nested, deep, outside]),
            ([research, draft], [nested, deep], [nested, deep, outside]),
            ([UUID()], [], [])
        ]
        for scoped in [false, true] {
            workspace.search.folderScope = scoped ? folder.id : nil
            for query in ["needle", "absent"] {
                workspace.search.text = query
                await workspace.search.query(quick: false)
                for testCase in cases {
                    workspace.tagFilters = testCase.filters
                    let expected = query == "absent" ? Set<String>() : (scoped ? testCase.folderPaths : testCase.libraryPaths)
                    for include in [false, true] {
                        workspace.setIncludeSubfolders(include)
                        XCTAssertEqual(Set(workspace.filteredSearchResults.compactMap { snapshot.presentation.documentsByID[$0.id]?.relativePath }), expected,
                                       "scope=\(scoped), query=\(query), tags=\(testCase.filters.count), include=\(include)")
                        XCTAssertEqual(workspace.subtitle, LibrarySearch.resultCount(expected.count))
                    }
                }
            }
        }
        // The toggle still controls the ordinary folder list, including non-search matches.
        workspace.search.text = ""
        workspace.tagFilters = []
        workspace.setIncludeSubfolders(false)
        XCTAssertEqual(Set(workspace.documents.map(\.relativePath)), [direct])
        workspace.setIncludeSubfolders(true)
        XCTAssertEqual(Set(workspace.documents.map(\.relativePath)), [direct, nested, deep, "Writing/Drafts/Other.md"])
    }

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
        XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? FolderSidebar.Item === coordinator.itemsByTag[tag.id])
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

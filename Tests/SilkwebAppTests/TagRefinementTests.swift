import AppKit
import SwiftUI
import Observation
import XCTest
@testable import Silkweb
import SilkwebCore

final class TagRefinementTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private func settle(_ view: NSView) async throws {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }
    @MainActor private func recency(_ workspace: LibraryWorkspace) throws -> [String]? {
        let metadata = try XCTUnwrap(workspace.snapshot?.metadata)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(metadata)) as! [String: Any]
        return json["tagRecency"] as? [String]
    }
    @MainActor private func fixture() async throws -> LibraryWorkspace {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        for path in ["A.md", "B.md", "Folder/C.md", "Other.md"] {
            try "fixture".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let initial = try await LibraryScanner.scan(root: root)
        _ = try await TagStore.update(root: root) {
            let a = initial.metadata.IDsByPath["A.md"]!, b = initial.metadata.IDsByPath["B.md"]!
            return TagEditor.edit(["draft"], documents: [b], metadata: TagEditor.edit(["coffee"], documents: [a], metadata: $0))
        }
        let workspace = LibraryWorkspace()
        workspace.root = root; workspace.install(try await LibraryScanner.scan(root: root))
        return workspace
    }

    @MainActor func testCompletionClickActionAndReturnAcceptExistingTag() async throws {
        let workspace = try await fixture()
        workspace.session.selectedFolder = nil; workspace.session.selectedDocuments = ["Other.md"]
        let host = NSHostingController(rootView: DocumentInfo(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        try await settle(host.view)
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? TagInputField }.first)
        let coordinator = try XCTUnwrap(field.delegate as? TagTokenField.Coordinator)
        XCTAssertEqual(coordinator.tokenField(field, completionsForSubstring: "CO", indexOfToken: 0, indexOfSelectedItem: nil) as? [String], ["coffee"])
        field.selectText(nil)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.string = "CO"; editor.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        let accept = NSSelectorFromString("acceptCompletion:")
        if field.responds(to: accept) {
            let click = try XCTUnwrap(NSApp.windows.flatMap { $0.contentView.map(descendants) ?? [] }
                .compactMap { $0 as? NSButton }.first { $0.target as? TagInputField === field && $0.action == accept },
                "Completion popup must wire its real rows to acceptance")
            click.performClick(nil)
        } else {
            // Before the fix, drive the native completion mouse-acceptance callback.
            editor.insertCompletion("coffee", forPartialWordRange: NSRange(location: 0, length: 2), movement: NSReturnTextMovement, isFinal: true)
            for _ in 0..<8 { await Task.yield() }
        }
        await workspace.tagEditTask?.value
        XCTAssertEqual(workspace.commonTagNames, ["coffee"], "Click must apply the existing tag")
        XCTAssertNotNil(field.currentEditor(), "Completion must retain field focus")
        workspace.editTags([]); await workspace.tagEditTask?.value
        editor.string = "CO"; editor.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))), "Return must accept the highlighted completion")
        await workspace.tagEditTask?.value
        XCTAssertEqual(workspace.commonTagNames, ["coffee"], "Return must apply the existing spelling")
        editor.string = "DR"; editor.setSelectedRange(NSRange(location: 2, length: 0))
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.moveUp(_:))))
        XCTAssertTrue(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(editor.string, "DR", "Escape must keep the uncommitted prefix")
        XCTAssertFalse(coordinator.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))), "Second Escape behaves natively")
        XCTAssertNotNil(field.currentEditor())
        field.requestedFocus = 1; field.focusIfNeeded()
        try await settle(host.view)
        XCTAssertEqual(field.tokenStyle, .rounded)
        XCTAssertEqual(editor.selectedRange().length, 0)
        XCTAssertEqual(editor.selectedRange().location, (editor.string as NSString).length)
        for width: CGFloat in [180, 320, 240] {
            host.view.setFrameSize(NSSize(width: width, height: 700)); try await settle(host.view)
        }
        window.contentViewController = nil
        XCTAssertFalse(NSApp.windows.contains { $0.parent === window })
    }

    @MainActor func testRecentPillActionTogglesMixedSelectionAndUndo() async throws {
        let workspace = try await fixture()
        workspace.session.selectedFolder = nil; workspace.session.selectedDocuments = ["A.md", "B.md"]
        let host = NSHostingController(rootView: DocumentInfo(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        try await settle(host.view)
        let pill = try XCTUnwrap(descendants(host.view).compactMap { $0 as? NSButton }.first { $0.title == "coffee" }, "Recent must expose clickable tag pills")
        XCTAssertEqual(pill.state, .mixed)
        pill.performClick(nil); await workspace.tagEditTask?.value
        XCTAssertEqual(workspace.commonTagNames, ["coffee"])
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Add Tag “coffee”")
        try await settle(host.view)
        let appliedRecency = try recency(workspace)
        pill.performClick(nil); await workspace.tagEditTask?.value
        XCTAssertTrue(workspace.commonTagNames.isEmpty)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Remove Tag “coffee”")
        workspace.undoLibrary()
        for _ in 0..<100 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(workspace.commonTagNames, ["coffee"])
        XCTAssertEqual(try recency(workspace), appliedRecency)
        for width: CGFloat in [100, 180, 320, 240] {
            host.view.setFrameSize(NSSize(width: width, height: 700)); try await settle(host.view)
            XCTAssertLessThanOrEqual(pill.frame.width, width)
        }
    }

    @MainActor func testSidebarScopeSequenceNeverPublishesAllDocuments() async throws {
        let workspace = try await fixture()
        let coffee = try XCTUnwrap(workspace.tags.first { $0.name == "coffee" }), draft = try XCTUnwrap(workspace.tags.first { $0.name == "draft" })
        workspace.session.selectedFolder = nil; workspace.session.selectedTagID = coffee.id
        let snapshot = try XCTUnwrap(workspace.snapshot)
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: snapshot)
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        let tableHost = NSHostingView(rootView: DocumentTable(workspace: workspace, documents: workspace.documents, dateReference: Date()))
        let hierarchy = NSStackView(views: [scroll, tableHost]); hierarchy.orientation = .horizontal
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hierarchy
        defer { window.contentView = nil }
        let outline = try XCTUnwrap(coordinator.outline)
        var published: [(String?, UUID?, Set<String>)] = []
        func record() {
            published.append((workspace.session.selectedFolder, workspace.session.selectedTagID, Set(workspace.documents.map(\.relativePath))))
            tableHost.rootView = DocumentTable(workspace: workspace, documents: workspace.documents, dateReference: Date())
            FolderSidebar.update(scroll, coordinator: coordinator, snapshot: snapshot)
        }
        func observe() {
            withObservationTracking { _ = workspace.session; _ = workspace.documents } onChange: {
                // Observation's willSet notification: sample after mutation, re-arm for every publish.
                MainActor.assumeIsolated {
                    DispatchQueue.main.async { record(); observe() }
                }
            }
        }
        observe()
        for item in [coordinator.itemsByTag[draft.id]!, coordinator.itemsByPath["Folder"]!, coordinator.itemsByTag[coffee.id]!] {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: item)), byExtendingSelection: false)
            await workspace.waitForNavigation()
            for _ in 0..<12 { await Task.yield() }
            record()
        }
        XCTAssertFalse(published.isEmpty)
        for (folder, tag, paths) in published {
            XCTAssertFalse(folder == nil && tag == nil, "Tag/folder navigation must never publish All Documents")
            XCTAssertNotEqual(paths, Set(snapshot.documents.map(\.relativePath)), "No full-library list may be published")
        }
        XCTAssertEqual(workspace.session.selectedTagID, coffee.id)
        // All Documents can already be narrowed by toolbar filters. Preserve that list until
        // the new sidebar tag scope is installed, rather than clearing the filters first.
        workspace.tagFilters = [draft.id]
        var filtered = workspace.session
        filtered.selectedTagID = nil; filtered.selectedFolder = nil
        workspace.session = filtered
        for _ in 0..<12 { await Task.yield() }
        published.removeAll()
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: coordinator.itemsByTag[coffee.id]!)), byExtendingSelection: false)
        await workspace.waitForNavigation()
        for _ in 0..<12 { await Task.yield() }
        record()
        XCTAssertEqual(workspace.documents.map(\.relativePath), ["A.md"])
        XCTAssertTrue(workspace.tagFilters.isEmpty)
        for (folder, tag, paths) in published {
            XCTAssertFalse(folder == nil && tag == nil)
            XCTAssertNotEqual(paths, Set(snapshot.documents.map(\.relativePath)))
        }
    }

    @MainActor func testEmptyLibraryAlwaysShowsTagsZero() async throws {
        let workspace = try await fixture()
        let snapshot = try XCTUnwrap(workspace.snapshot)
        _ = try await TagStore.update(root: snapshot.rootURL) { metadata in
            metadata.tags.reduce(metadata) { TagEditor.delete($1.id, metadata: $0) }
        }
        workspace.install(try await LibraryScanner.scan(root: snapshot.rootURL))
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: workspace.snapshot!)
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        let outline = try XCTUnwrap(coordinator.outline)
        let group = try XCTUnwrap(coordinator.roots.last { $0.title == "Tags" }, "An empty library must show Tags (0)")
        let cell = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: group), makeIfNecessary: true) as? SidebarFolderCell)
        XCTAssertEqual(cell.countBadge.stringValue, " (0)")
        XCTAssertTrue(group.children.isEmpty)
        scroll.layoutSubtreeIfNeeded()
        workspace.session.selectedFolder = nil; workspace.session.selectedDocuments = ["A.md"]
        let host = NSHostingView(rootView: DocumentInfo(workspace: workspace))
        host.setFrameSize(NSSize(width: 240, height: 700)); try await settle(host)
        XCTAssertTrue(descendants(host).compactMap { $0 as? NSButton }.filter { $0.accessibilityHelp() == "Adds or removes this tag" }.isEmpty)
    }
}

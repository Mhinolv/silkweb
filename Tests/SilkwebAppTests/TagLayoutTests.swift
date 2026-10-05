import AppKit
import SwiftUI
import XCTest
@testable import Silkweb
import SilkwebCore

final class TagLayoutTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private func scrollContainerHeight(_ field: NSTokenField) -> CGFloat {
        field.enclosingScrollView?.superview?.frame.height ?? 0
    }
    @MainActor private func settle(_ view: NSView) async throws {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor func testRoundedTokensRemainUnselectedAcrossFocusAndResize() async throws {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: TagTokenField(names: ["coffee", "research"], suggestions: [], focusRequest: 0, enabled: true, onChange: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 216, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        try await settle(host.view)
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? TagInputField }.first)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for count in [0, 1, 2, 20, 100] {
                let names = (0..<count).map { "research topic \($0)" }
                host.rootView = TagTokenField(names: names, suggestions: [], focusRequest: 0, enabled: true, onChange: { _ in })
                for width: CGFloat in [180, 216, 400] {
                    host.view.setFrameSize(NSSize(width: width, height: 200))
                    try await settle(host.view)
                    XCTAssertNil(field.currentEditor(), "Loading and resizing must not focus or select the tokens")
                    XCTAssertEqual(field.tokenStyle, .rounded)
                    XCTAssertEqual((field.cell as? NSTokenFieldCell)?.tokenStyle, .rounded)
                    XCTAssertFalse(try XCTUnwrap(field.cell).isHighlighted)
                    let value = field.attributedStringValue
                    var tokenCount = 0
                    value.enumerateAttribute(.attachment, in: NSRange(location: 0, length: value.length)) { attachment, _, _ in
                        guard let attachment = attachment as? NSTextAttachment else { return }
                        tokenCount += 1
                        XCTAssertEqual((attachment.attachmentCell as? NSCell)?.isHighlighted, false,
                                       "Check the actual native attachments, not just the field's configured style")
                    }
                    XCTAssertEqual(tokenCount, count)
                }
                // Keyboard focus goes through selectText; AppKit selects all AFTER
                // textDidBeginEditing, so that callback alone cannot place the caret.
                field.selectText(nil)
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: (editor.string as NSString).length, length: 0),
                               "Focusing must put the caret after the tokens without selecting them")
                XCTAssertTrue(window.makeFirstResponder(nil))
                try await settle(host.view)
                XCTAssertNil(field.currentEditor())
                XCTAssertEqual(field.objectValue as? [String], names)
            }
        }
        // Exercise teardown and reattachment as the Info tab is hidden and shown.
        window.contentViewController = nil
        window.contentViewController = host
        try await settle(host.view)
        XCTAssertNil(field.currentEditor())
        XCTAssertEqual(field.tokenStyle, .rounded)
    }

    @MainActor func testTokenFieldWrapsGrowsAndScrollsOnlyVertically() async throws {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: TagTokenField(names: ["draft"], suggestions: [], focusRequest: 0, enabled: true, onChange: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 216, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        try await settle(host.view)
        let field = try XCTUnwrap(descendants(host.view).compactMap { $0 as? TagInputField }.first)
        let small = field.enclosingScrollView?.superview?.intrinsicContentSize.height ?? field.intrinsicContentSize.height
        field.objectValue = (0..<20).map { "research topic \($0)" }
        for width: CGFloat in [216, 300, 180, 400, 216] {
            host.view.setFrameSize(NSSize(width: width, height: 200))
            try await settle(host.view)
            XCTAssertEqual(scrollContainerHeight(field), field.enclosingScrollView?.frame.height ?? 0, accuracy: 1)
            XCTAssertTrue(field.cell?.wraps == true, "Token cell must word-wrap")
            XCTAssertFalse(field.cell?.isScrollable ?? true, "Token cell must not scroll horizontally")
            XCTAssertFalse(field.cell?.usesSingleLineMode ?? true)
            let scroll = try XCTUnwrap(field.enclosingScrollView, "Many tags need a vertical scroll container")
            XCTAssertFalse(scroll.hasHorizontalScroller)
            XCTAssertTrue(scroll.hasVerticalScroller)
            XCTAssertEqual(field.frame.width, scroll.contentSize.width, accuracy: 1)
            XCTAssertGreaterThan(scroll.superview!.intrinsicContentSize.height, small, "Many tokens must grow the visible field")
            XCTAssertEqual(scroll.superview!.intrinsicContentSize.height, 108, accuracy: 1)
            XCTAssertGreaterThan(field.frame.height, scroll.contentSize.height)
        }
        for count in [0, 1, 2, 4, 8, 20, 100] {
            field.objectValue = (0..<count).map { "topic \($0)" }
            try await settle(host.view)
            let container = try XCTUnwrap(field.enclosingScrollView?.superview)
            let height = container.intrinsicContentSize.height
            XCTAssertTrue((28...108).contains(height))
            XCTAssertEqual((height - 28).truncatingRemainder(dividingBy: 20), 0)
            if count <= 1 { XCTAssertEqual(height, 28) }
            if count == 100 { XCTAssertEqual(height, 108) }
        }
        field.selectText(nil)
        try await settle(host.view)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        XCTAssertFalse(editor.isHorizontallyResizable)
        XCTAssertTrue(editor.textContainer?.widthTracksTextView == true)
        field.objectValue = []
        try await settle(host.view)
        XCTAssertEqual(field.enclosingScrollView?.superview?.intrinsicContentSize.height, 28)
        host.view.removeFromSuperview()
        window.contentViewController = host
        try await settle(host.view)
    }

    @MainActor func testTagsAreOutlineSiblingCollapsePersistsAndSelectionRestores() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder/Nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "fixture".write(to: root.appendingPathComponent("A.md"), atomically: true, encoding: .utf8)
        let initial = try await LibraryScanner.scan(root: root)
        _ = try await TagStore.update(root: root) { TagEditor.edit(["topic 10", "topic 2"], documents: Set(initial.documents.map(\.id)), metadata: $0) }
        let snapshot = try await LibraryScanner.scan(root: root)
        let workspace = LibraryWorkspace()
        workspace.root = root; workspace.install(snapshot)
        workspace.session.expandedFolders = ["", "Folder"]
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: snapshot)
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = scroll
        defer { window.contentView = nil; workspace.search.reset() }
        try await settle(scroll)
        let outline = try XCTUnwrap(coordinator.outline)
        let group = try XCTUnwrap(coordinator.roots.last { $0.title == "Tags" }, "Tags must belong to FolderSidebar, after the library root")
        XCTAssertTrue(coordinator.roots.last === group)
        XCTAssertNil(outline.parent(forItem: group))
        XCTAssertEqual(group.children.map(\.title), ["topic 2", "topic 10"])
        XCTAssertTrue(outline.isItemExpanded(group))
        XCTAssertEqual(outline.row(forItem: group), outline.row(forItem: coordinator.itemsByPath["Folder/Nested"]!) + 1)
        let scope = workspace.session.selectedFolder
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: group)), byExtendingSelection: false)
        XCTAssertEqual(workspace.session.selectedFolder, scope)
        XCTAssertEqual((outline.view(atColumn: 0, row: outline.row(forItem: group), makeIfNecessary: true) as? SidebarFolderCell)?.accessibilityValue() as? String, "2 tags")
        outline.collapseItem(group)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(workspace.windowMetadata())) as! [String: Any]
        XCTAssertEqual(json["tagsExpanded"] as? Bool, false)
        await workspace.saveSessionNow()
        let loaded = try await WindowSessionMetadata.load(root: root)
        let saved = try XCTUnwrap(loaded)
        await workspace.restoreTabs(saved)
        coordinator.restore()
        XCTAssertFalse(outline.isItemExpanded(group))
        for width: CGFloat in [180, 320, 240] {
            scroll.setFrameSize(NSSize(width: width, height: 500)); outline.expandItem(group)
            try await settle(scroll)
            for item in [group] + group.children {
                let cell = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: item), makeIfNecessary: true) as? SidebarFolderCell)
                XCTAssertEqual(cell.countBadge.stringValue, item === group ? " (2)" : " (1)")
                XCTAssertNil(coordinator.outlineView(outline, pasteboardWriterForItem: item))
                XCTAssertFalse(coordinator.allowsDrop(["A.md"], item: item))
            }
            outline.collapseItem(group)
        }
        workspace.session.selectedTagID = workspace.tags.first!.id
        coordinator.restore()
        XCTAssertTrue(outline.isItemExpanded(group), "Restoring a selected tag must reveal it")
        XCTAssertEqual((outline.item(atRow: outline.selectedRow) as? FolderSidebar.Item)?.title, workspace.tags.first!.name)
        // Exercise the actual sidebar/list split with tag rows present (1.55).
        let split = LibrarySplitViewController(workspace: workspace)
        window.contentViewController = split
        split.view.setFrameSize(NSSize(width: 1400, height: 900))
        try await settle(split.view)
        for hidden in [true, false, true, false] {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            workspace.setSidebarsHidden(hidden)
            split.applySidebars(animated: false)
            NSAnimationContext.endGrouping()
            try await settle(split.view)
            XCTAssertEqual(split.navigationItem.isCollapsed, hidden)
            XCTAssertTrue(descendants(split.view).contains { view in
                guard let tree = view as? SidebarOutlineView, let delegate = tree.delegate as? FolderSidebar.Coordinator else { return false }
                return delegate.roots.contains { $0.title == "Tags" }
            })
        }
        window.contentViewController = nil
        workspace.session.selectedTagID = nil
        workspace.install(initial); coordinator.configure(initial); coordinator.restore()
        XCTAssertTrue(coordinator.roots.contains { $0.title == "Tags" })
    }
}

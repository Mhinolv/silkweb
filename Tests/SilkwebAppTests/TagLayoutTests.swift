import AppKit
import SwiftUI
import XCTest
@testable import Silkweb
import SilkwebCore

final class TagLayoutTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
    @MainActor private func settle(_ view: NSView) async throws {
        for _ in 0..<8 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }

    @MainActor private func chips(_ names: [String], mixed: Set<String> = []) -> [TagChip] {
        names.map { TagChip(tag: LibraryTag(name: $0), mixed: mixed.contains($0)) }
    }
    @MainActor private func chipField(_ chips: [TagChip], enabled: Bool = true, focus: Int = 0) -> TagChipField {
        TagChipField(chips: chips, suggestions: [], focusRequest: focus, enabled: enabled, onAdd: { _ in }, onRemove: { _ in })
    }

    /// #72 Tags A: real SwiftUI-hosted chip field through load, appearance, count, width and focus sweeps.
    @MainActor func testChipFieldFlowsChipsAndFieldAcrossFocusAndResize() async throws {
        _ = NSApplication.shared
        let host = NSHostingController(rootView: chipField(chips(["coffee", "research"])))
        host.sizingOptions = [] // The Inspector column sets the width; the field never sizes the window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 216, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        try await settle(host.view)
        let container = try XCTUnwrap(descendants(host.view).compactMap { $0 as? TagChipContainer }.first)
        let field = container.field
        XCTAssertFalse(descendants(host.view).contains { $0 is NSTokenField }, "Tags A replaces the token field")
        XCTAssertFalse(descendants(host.view).contains { $0 is NSScrollView }, "No bezeled viewport: the Info pane scrolls")
        XCTAssertEqual(field.placeholderString, "Add tag…")
        XCTAssertFalse(field.isBezeled); XCTAssertFalse(field.isBordered); XCTAssertFalse(field.drawsBackground)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for count in [0, 1, 2, 20, 100] {
                let names = (0..<count).map { $0 == 3 ? String(repeating: "long tag name ", count: 4) + "end" : "research topic \($0)" }
                host.rootView = chipField(chips(names, mixed: count > 1 ? [names[1]] : []))
                for width: CGFloat in [180, 216, 400] {
                    host.view.setFrameSize(NSSize(width: width, height: 400))
                    try await settle(host.view)
                    XCTAssertNil(field.currentEditor(), "Loading and resizing must not focus the field")
                    XCTAssertEqual(container.chipButtons.map(\.name), names)
                    XCTAssertEqual(container.chipButtons.map(\.mixed), names.map { count > 1 && $0 == names[1] })
                    let frames = container.chipButtons.map(\.frame) + [field.frame]
                    for frame in frames {
                        XCTAssertGreaterThanOrEqual(frame.minX, 0)
                        XCTAssertLessThanOrEqual(frame.maxX, container.bounds.width + 0.5, "Chips wrap within the column")
                        XCTAssertLessThanOrEqual(frame.maxY, container.bounds.height)
                    }
                    for (i, a) in frames.enumerated() { for b in frames[(i + 1)...] { XCTAssertFalse(a.intersects(b), "\(a) overlaps \(b)") } }
                    XCTAssertGreaterThanOrEqual(field.frame.width, min(TagChipContainer.fieldMinWidth, container.bounds.width),
                                                "“Add tag…” always stays visible")
                    XCTAssertEqual(container.frame.height, container.measuredHeight(width: container.bounds.width), accuracy: 1,
                                   "The hosted height follows the flow, so later rows keep their spacing")
                    let lines = Set(frames.map { (($0.midY) / (TagChipContainer.chipHeight + TagChipContainer.spacing)).rounded(.down) }).count
                    XCTAssertEqual(container.measuredHeight(width: container.bounds.width),
                                   CGFloat(lines) * TagChipContainer.chipHeight + CGFloat(lines - 1) * TagChipContainer.spacing
                                   + TagChipContainer.bottomInset + 1, accuracy: 0.5)
                }
                // Keyboard focus goes through selectText and leaves the caret in the empty field.
                field.selectText(nil)
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                XCTAssertEqual(editor.selectedRange(), NSRange(location: 0, length: 0))
                XCTAssertTrue(window.makeFirstResponder(nil))
                try await settle(host.view)
                XCTAssertNil(field.currentEditor())
            }
        }
        // Read-only: no × targets and a disabled field; chips narrow to their names.
        host.rootView = chipField(chips(["coffee"]), enabled: true)
        try await settle(host.view)
        let editable = try XCTUnwrap(container.chipButtons.first)
        let editableWidth = editable.frame.width
        XCTAssertGreaterThan(editable.removeRect.width, 0)
        host.rootView = chipField(chips(["coffee"]), enabled: false)
        try await settle(host.view)
        XCTAssertFalse(field.isEnabled)
        XCTAssertFalse(editable.isEnabled)
        XCTAssertEqual(editable.removeRect, .zero)
        XCTAssertLessThan(editable.frame.width, editableWidth)
        // Exercise teardown and reattachment as the Info tab is hidden and shown; a focus request made while
        // detached is fulfilled on reattachment.
        window.contentViewController = nil
        host.rootView = chipField(chips(["coffee"]), focus: 1)
        window.contentViewController = host
        try await settle(host.view)
        XCTAssertNotNil(field.currentEditor())
        XCTAssertEqual(field.fulfilledFocus, 1)
    }

    /// Mouse targets: only the × removes; a mixed chip's name applies it to every selected document.
    @MainActor func testChipRemoveTargetAndMixedApply() async throws {
        _ = NSApplication.shared
        var added: [[String]] = [], removed: [UUID] = []
        let tags = [LibraryTag(name: "coffee"), LibraryTag(name: "research")]
        let host = NSHostingController(rootView: TagChipField(chips: [TagChip(tag: tags[0], mixed: false), TagChip(tag: tags[1], mixed: true)],
            suggestions: [], focusRequest: 0, enabled: true, onAdd: { added.append($0) }, onRemove: { removed.append($0) }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        try await settle(host.view)
        let container = try XCTUnwrap(descendants(host.view).compactMap { $0 as? TagChipContainer }.first)
        let (coffee, research) = (container.chipButtons[0], container.chipButtons[1])
        func click(_ button: NSButton, at point: NSPoint) throws {
            let location = button.convert(point, to: nil)
            let time = ProcessInfo.processInfo.systemUptime
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: time,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: time + 0.01,
                windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            NSApp.postEvent(up, atStart: true) // The button's tracking loop ends on this mouse-up.
            button.mouseDown(with: down)
            _ = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true)
        }
        try click(coffee, at: NSPoint(x: 12, y: coffee.bounds.midY))
        XCTAssertTrue(removed.isEmpty, "Clicking a chip's name never removes it")
        XCTAssertTrue(added.isEmpty, "A fully applied chip has nothing to apply")
        try click(research, at: NSPoint(x: 12, y: research.bounds.midY))
        XCTAssertEqual(added, [["research"]], "A mixed chip's name applies it to all selected documents")
        // The × hands the click to NSButton's own tracking (act on mouse-up, cancel by dragging off);
        // an unordered window cannot run that loop, so check the target and press the button.
        XCTAssertTrue(coffee.removeRect.contains(NSPoint(x: coffee.bounds.maxX - 8, y: coffee.bounds.midY)))
        XCTAssertFalse(coffee.removeRect.contains(NSPoint(x: 12, y: coffee.bounds.midY)))
        coffee.performClick(nil)
        XCTAssertEqual(removed, [tags[0].id], "The × removes")
        research.performClick(nil) // Space / VoiceOver press.
        XCTAssertEqual(removed, [tags[0].id, tags[1].id])
        XCTAssertEqual(coffee.accessibilityLabel(), "Tag coffee, remove")
        XCTAssertEqual(coffee.accessibilityValue() as? String, "applied")
        XCTAssertEqual(research.accessibilityValue() as? String, "applied to some selected documents")
        XCTAssertEqual(research.accessibilityCustomActions()?.map(\.name), ["Apply to All Selected Documents"])
        XCTAssertEqual(coffee.accessibilityCustomActions()?.isEmpty ?? true, true)
        _ = research.accessibilityCustomActions()?.first?.handler?()
        XCTAssertEqual(added, [["research"], ["research"]])
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
        let autosave = "Silkweb.TagLayout." + UUID().uuidString
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(autosave) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let split = LibrarySplitViewController(workspace: workspace, autosaveName: autosave)
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

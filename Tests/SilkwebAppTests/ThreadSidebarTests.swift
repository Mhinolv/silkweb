import AppKit
import QuartzCore
import UniformTypeIdentifiers
import XCTest
@testable import SilkwebCore
@testable import Silkweb

/// silkweb-1.63 (Redesign R2): thread guides and the coral “you are here” node in the real sidebar.
final class ThreadSidebarTests: XCTestCase {
    private static let longName = "A very long folder name that must truncate before its count"
    private static let privateName = "Private folder with a very long unreadable name"

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }

    @MainActor private func settle(_ controller: LibrarySplitViewController) async throws {
        for _ in 0..<8 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private struct Fixture {
        let root: URL
        let suite: String
        let workspace: LibraryWorkspace
        let snapshot: LibrarySnapshot
        func cleanUp() {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebThread-" + UUID().uuidString)
        for path in ["Coffee/Brewing Guides", "Travel/Japan", "Vanlife", "Deep/A/B/C", Self.longName, Self.privateName] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        for path in ["Root.md", "Vanlife/Settling In.md", "Coffee/Brewing Guides/Pour-Over.md", "Travel/Japan/Kyoto.md",
                     "Deep/A/B/C/Leaf.md", Self.longName + "/Note.md"] {
            try Data("# Fixture\n".utf8).write(to: root.appendingPathComponent(path))
        }
        let initial = try await LibraryScanner.scan(root: root)
        _ = try await TagStore.update(root: root) {
            TagEditor.edit(["draft", "research"], documents: Set(initial.documents.map(\.id)), metadata: $0)
        }
        let scanned = try await LibraryScanner.scan(root: root)
        var folders = scanned.folders
        folders[try XCTUnwrap(folders.firstIndex { $0.relativePath == Self.privateName })].isUnreadable = true
        let snapshot = LibrarySnapshot(rootURL: root, folders: folders, documents: scanned.documents,
            presentation: LibraryPresentation(folders: folders, documents: scanned.documents), metadata: scanned.metadata,
            recoveredMetadataURL: nil, isReadOnly: false)
        let suite = "Silkweb.Thread." + UUID().uuidString
        let workspace = LibraryWorkspace(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(snapshot)
        workspace.session.selectedFolder = "Vanlife"
        workspace.session.expandedFolders = ["", "Coffee", "Travel", "Deep", "Deep/A", "Deep/A/B"]
        workspace.tagsExpanded = true
        return Fixture(root: root, suite: suite, workspace: workspace, snapshot: snapshot)
    }

    // MARK: Pixels

    struct Pixel {
        let color: NSColor
        let rep: NSBitmapImageRep
    }

    @MainActor private func pixel(_ row: NSView, at point: NSPoint) throws -> Pixel {
        let rep = try XCTUnwrap(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / row.bounds.width
        let top = row.isFlipped ? point.y : row.bounds.height - point.y
        return Pixel(color: try XCTUnwrap(rep.colorAt(x: Int(point.x * scale), y: Int(top * scale))), rep: rep)
    }

    /// Compares against a swatch of `expected` painted into the same kind of bitmap, so colour matching cancels out.
    @MainActor private func assertColor(_ pixel: Pixel, _ expected: NSColor, in view: NSView, _ message: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        guard let swatch = pixel.rep.copy() as? NSBitmapImageRep, let context = NSGraphicsContext(bitmapImageRep: swatch) else {
            return XCTFail("swatch \(message)", file: file, line: line)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            expected.setFill()
            NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let actual = pixel.color.usingColorSpace(.sRGB),
              let resolved = swatch.colorAt(x: 1, y: swatch.pixelsHigh - 2)?.usingColorSpace(.sRGB) else {
            return XCTFail("unresolved \(message)", file: file, line: line)
        }
        let distance = max(abs(actual.redComponent - resolved.redComponent), abs(actual.greenComponent - resolved.greenComponent),
                           abs(actual.blueComponent - resolved.blueComponent))
        XCTAssertLessThan(distance, 0.03, "\(message): \(actual) vs \(resolved)", file: file, line: line)
    }

    /// A point `distance` below the row's top edge.
    private func point(_ row: NSView, x: CGFloat, below distance: CGFloat) -> NSPoint {
        NSPoint(x: x, y: row.isFlipped ? distance : row.bounds.height - distance)
    }

    // MARK: Structure

    /// Checks every row against AppKit's own tree and frames; returns the number of rows carrying the node.
    @MainActor @discardableResult
    private func verifyRows(_ outline: NSOutlineView, _ coordinator: FolderSidebar.Coordinator, _ context: String) throws -> Int {
        var nodes = 0
        for row in 0..<outline.numberOfRows {
            let item = try XCTUnwrap(outline.item(atRow: row) as? FolderSidebar.Item)
            let where_ = "\(item.title) \(context)"
            let rowView = try XCTUnwrap(outline.rowView(atRow: row, makeIfNecessary: true) as? ThreadRowView, where_)
            let cell = try XCTUnwrap(outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarFolderCell, where_)
            cell.layoutSubtreeIfNeeded()
            let thread = try XCTUnwrap(rowView.thread, where_)
            let level = outline.level(forRow: row)
            XCTAssertEqual(thread.level, level, where_)
            let parent = outline.parent(forItem: item)
            XCTAssertEqual(thread.isLastChild, outline.childIndex(forItem: item) == outline.numberOfChildren(ofItem: parent) - 1, where_)
            XCTAssertEqual(thread.hasChildren, outline.isExpandable(item), where_)
            XCTAssertEqual(thread.ancestorContinues.count, max(0, level - 1), where_)
            let metrics = try XCTUnwrap(rowView.metrics, where_)
            XCTAssertEqual(metrics.indentation, 16)
            let segments = ThreadGuides.segments(level: level, isLastChild: thread.isLastChild, ancestorContinues: thread.ancestorContinues,
                                                 hasChildren: thread.hasChildren, metrics: metrics)
            XCTAssertEqual(segments.isEmpty, level == 0, where_)
            if let parent, case let .elbow(guide, _, _, end)? = segments.last {
                let x = CGFloat(guide), endX = CGFloat(end)
                // The guide is the centre of the parent's real disclosure button.
                let parentRow = outline.row(forItem: parent)
                let parentView = try XCTUnwrap(outline.rowView(atRow: parentRow, makeIfNecessary: true))
                let chevron = try XCTUnwrap(parentView.subviews.first { $0.identifier == NSOutlineView.disclosureButtonIdentifier }, where_)
                XCTAssertEqual(parentView.convert(chevron.frame, to: outline).midX, x, accuracy: 0.5, where_)
                // The horizontal stops before this row's chevron glyph or icon.
                if thread.hasChildren {
                    let own = try XCTUnwrap(rowView.subviews.first { $0.identifier == NSOutlineView.disclosureButtonIdentifier }, where_)
                    XCTAssertLessThan(endX, rowView.convert(own.frame, to: outline).midX - 3, where_)
                } else {
                    let icon = try XCTUnwrap(cell.imageView)
                    XCTAssertLessThanOrEqual(endX, cell.convert(icon.frame, to: outline).minX - 3 + 0.5, where_)
                }
                XCTAssertGreaterThan(endX, x, where_)
            }
            XCTAssertNil(rowView.layer?.sublayers?.first { !($0.delegate is NSView) }, "threads draw in draw(_:), no extra layers")
            // 1.49 suffix glued to the title; lock rows unchanged.
            let text = try XCTUnwrap(cell.textField)
            let titleRect = text.alignmentRect(forFrame: text.frame)
            let countRect = cell.countBadge.alignmentRect(forFrame: cell.countBadge.frame)
            if cell.renameField == nil {
                XCTAssertFalse(cell.countBadge.isHidden, where_)
                XCTAssertGreaterThanOrEqual(countRect.width + 0.5, cell.countBadge.intrinsicContentSize.width, where_)
                XCTAssertLessThanOrEqual(countRect.maxX, cell.bounds.maxX - 3.5, where_)
                if item.folder?.isUnreadable == true {
                    let lockRect = cell.lockBadge.alignmentRect(forFrame: cell.lockBadge.frame)
                    XCTAssertFalse(cell.lockBadge.isHidden, where_)
                    XCTAssertEqual(lockRect.minX, titleRect.maxX + 4, accuracy: 0.5, where_)
                    XCTAssertEqual(countRect.minX, lockRect.maxX + 4, accuracy: 0.5, where_)
                } else {
                    XCTAssertTrue(cell.lockBadge.isHidden, where_)
                    XCTAssertEqual(countRect.minX, titleRect.maxX, accuracy: 0.5, where_)
                }
            }
            let value = cell.accessibilityValue() as? String ?? ""
            if rowView.isCurrent {
                nodes += 1
                XCTAssertTrue(item === coordinator.scopeItem(), where_)
                XCTAssertTrue(value.hasSuffix(", current folder"), where_)
                XCTAssertNotNil(rowView.nodeCenter)
            } else {
                XCTAssertFalse(value.contains("current folder"), where_)
                XCTAssertNil(rowView.nodeCenter)
            }
        }
        XCTAssertEqual(nodes, 1, "exactly one coral node \(context)")
        return nodes
    }

    @MainActor private func row(_ outline: NSOutlineView, _ item: FolderSidebar.Item) throws -> ThreadRowView {
        try XCTUnwrap(outline.rowView(atRow: outline.row(forItem: item), makeIfNecessary: true) as? ThreadRowView, item.title)
    }

    /// The node is coral, threads draw over the capsule, and a plain row shows its elbow.
    @MainActor private func verifyPixels(_ outline: NSOutlineView, _ coordinator: FolderSidebar.Coordinator, current: FolderSidebar.Item,
                                         plain: FolderSidebar.Item, _ context: String) throws {
        let node = try row(outline, current)
        let center = try XCTUnwrap(node.nodeCenter, context)
        assertColor(try pixel(node, at: center), .silkwebCoral, in: node, "node \(context)")
        if let metrics = node.metrics, node.thread?.level ?? 0 > 0 {
            let x = ThreadGuides.guideX(level: node.thread!.level - 1, metrics: metrics) - node.frame.minX
            if node.isSelected {
                assertColor(try pixel(node, at: point(node, x: x, below: 3)), .silkwebThread, in: node, "thread over capsule \(context)")
            }
        }
        let other = try row(outline, plain)
        let metrics = try XCTUnwrap(other.metrics)
        let x = ThreadGuides.guideX(level: other.thread!.level - 1, metrics: metrics) - other.frame.minX
        assertColor(try pixel(other, at: point(other, x: x, below: 3)), .silkwebThread, in: other, "elbow \(context)")
        // The elbow's horizontal, past the arc.
        assertColor(try pixel(other, at: point(other, x: x + metrics.radius + 1, below: metrics.rowHeight / 2)), .silkwebThread,
                    in: other, "horizontal \(context)")
        // Nothing drawn in the empty space right of the guide above the corner.
        assertColor(try pixel(other, at: point(other, x: x + metrics.radius + 1, below: 3)), .silkwebPaneBackground,
                    in: other, "background \(context)")
    }

    @MainActor
    func testThreadsNodeSuffixAndLocksAcrossWidthsExpandRenameDropTagsAndToggle() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let workspace = fixture.workspace
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: fixture.suite)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentViewController = controller // Never ordered on screen.
        defer { window.contentViewController = nil; window.close(); workspace.search.reset() }
        controller.view.setFrameSize(NSSize(width: 1400, height: 900))
        try await settle(controller)
        let outline = try XCTUnwrap(Self.descendants(controller.view).compactMap { $0 as? SidebarOutlineView }.first)
        let coordinator = try XCTUnwrap(outline.delegate as? FolderSidebar.Coordinator)
        let scroll = try XCTUnwrap(outline.enclosingScrollView)
        XCTAssertEqual(outline.indentationPerLevel, 16)
        let vanlife = try XCTUnwrap(coordinator.itemsByPath["Vanlife"])
        let japan = try XCTUnwrap(coordinator.itemsByPath["Travel/Japan"])
        XCTAssertTrue(coordinator.currentItem === vanlife)
        XCTAssertTrue(outline.item(atRow: outline.selectedRow) as? FolderSidebar.Item === vanlife)
        let group = try XCTUnwrap(coordinator.tagsGroup)
        XCTAssertEqual(group.children.count, 2)
        XCTAssertTrue(outline.isItemExpanded(group))

        // Width sweep 180 → 320 pt.
        let navigation = controller.navigationController.splitView
        controller.splitView.setPosition(800, ofDividerAt: 0)
        try await settle(controller)
        for width: CGFloat in [180, 220, 260, 320, 180] {
            navigation.setPosition(width, ofDividerAt: 0)
            try await settle(controller)
            XCTAssertEqual(navigation.arrangedSubviews[0].frame.width, width, accuracy: 1, "navigation \(navigation.bounds.width)")
            try verifyRows(outline, coordinator, "at \(width)")
            try verifyPixels(outline, coordinator, current: vanlife, plain: japan, "at \(width)")
            // Tag rows hang from the Tags chevron with the same rules.
            let tag = try row(outline, group.children[0])
            XCTAssertEqual(tag.thread, ThreadRowView.Thread(level: 1, isLastChild: false, ancestorContinues: [], hasChildren: false))
            XCTAssertEqual(try row(outline, group.children[1]).thread?.isLastChild, true)
            try verifyPixels(outline, coordinator, current: vanlife, plain: group.children[1], "tag at \(width)")
        }
        // Deep rails: C (level 4) carries rails for Deep's following sibling and none for the last-child chain.
        let c = try row(outline, try XCTUnwrap(coordinator.itemsByPath["Deep/A/B/C"]))
        XCTAssertEqual(c.thread?.level, 4)
        XCTAssertEqual(c.thread?.ancestorContinues, [true, false, false])

        // Expand/collapse: rows above keep their views and guides; inserted rows get guides.
        let a = try XCTUnwrap(coordinator.itemsByPath["Deep/A"])
        let coffeeThread = try row(outline, try XCTUnwrap(coordinator.itemsByPath["Coffee"])).thread
        let travelThread = try row(outline, try XCTUnwrap(coordinator.itemsByPath["Travel"])).thread
        for expanded in [false, true, false, true] {
            if expanded { outline.expandItem(a) } else { outline.collapseItem(a) }
            try await settle(controller)
            XCTAssertEqual(try row(outline, try XCTUnwrap(coordinator.itemsByPath["Coffee"])).thread, coffeeThread)
            XCTAssertEqual(try row(outline, try XCTUnwrap(coordinator.itemsByPath["Travel"])).thread, travelThread)
            XCTAssertEqual(outline.row(forItem: coordinator.itemsByPath["Deep/A/B"]!) >= 0, expanded)
            try verifyRows(outline, coordinator, "expanded \(expanded)")
        }

        // Inline rename: the field replaces the label, the suffix hides, threads and node stay.
        workspace.rename = LibraryRename(path: "Vanlife", isFolder: true)
        FolderSidebar.update(scroll, coordinator: coordinator, snapshot: fixture.snapshot)
        try await settle(controller)
        let editing = try XCTUnwrap(outline.view(atColumn: 0, row: outline.row(forItem: vanlife), makeIfNecessary: true) as? SidebarFolderCell)
        XCTAssertNotNil(editing.renameField)
        XCTAssertTrue(editing.countBadge.isHidden)
        try verifyRows(outline, coordinator, "renaming")
        try verifyPixels(outline, coordinator, current: vanlife, plain: japan, "renaming")
        workspace.rename = nil
        FolderSidebar.update(scroll, coordinator: coordinator, snapshot: fixture.snapshot)
        try await settle(controller)
        try verifyRows(outline, coordinator, "after rename")

        // Drop-on feedback: the capsule with a 1.5 pt sage outline, threads still on top.
        XCTAssertTrue(coordinator.allowsDrop(["Vanlife/Settling In.md"], item: japan))
        XCTAssertFalse(coordinator.allowsDrop(["Vanlife/Settling In.md"], item: group.children[0]))
        let target = try row(outline, japan)
        target.isTargetForDropOperation = true
        let capsule = target.capsuleRect
        assertColor(try pixel(target, at: NSPoint(x: capsule.maxX - 0.75, y: capsule.midY)), .silkwebAccent, in: target, "drop outline")
        assertColor(try pixel(target, at: NSPoint(x: capsule.maxX - 12, y: capsule.midY)), .silkwebSelection, in: target, "drop fill")
        let targetMetrics = try XCTUnwrap(target.metrics)
        let guide = ThreadGuides.guideX(level: 1, metrics: targetMetrics) - target.frame.minX
        assertColor(try pixel(target, at: point(target, x: guide, below: 3)), .silkwebThread, in: target, "thread over drop capsule")
        target.isTargetForDropOperation = false

        // Tag A → tag B moves the node directly, never via All Documents (1.21 guard).
        var seen: [String] = []
        for tag in group.children {
            outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: tag)), byExtendingSelection: false)
            let deadline = Date().addingTimeInterval(3)
            while coordinator.currentItem !== tag, Date() < deadline {
                FolderSidebar.update(scroll, coordinator: coordinator, snapshot: fixture.snapshot)
                seen.append(coordinator.currentItem?.title ?? "nil")
                let nodes = (0..<outline.numberOfRows).filter { (outline.rowView(atRow: $0, makeIfNecessary: false) as? ThreadRowView)?.isCurrent == true }
                XCTAssertLessThanOrEqual(nodes.count, 1)
                try await Task.sleep(for: .milliseconds(1))
            }
            XCTAssertTrue(coordinator.currentItem === tag, tag.title)
            try await settle(controller)
            try verifyRows(outline, coordinator, "tag \(tag.title)")
            try verifyPixels(outline, coordinator, current: tag, plain: japan, "tag \(tag.title)")
        }
        XCTAssertFalse(seen.contains("All Documents"), "\(seen)")
        XCTAssertFalse(seen.contains("nil"))
        // Selecting the Tags group keeps the scope, so the node stays on the tag.
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: group)), byExtendingSelection: false)
        try await settle(controller)
        XCTAssertTrue(coordinator.currentItem === group.children[1])
        try verifyRows(outline, coordinator, "group selected")

        // 1.55 Toggle Sidebar: both columns restore with threads intact.
        for hidden in [true, false, true, false] {
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            workspace.setSidebarsHidden(hidden)
            controller.applySidebars(animated: false)
            NSAnimationContext.endGrouping()
            controller.updateRequests()
            try await settle(controller)
            XCTAssertEqual(controller.navigationItem.isCollapsed, hidden)
            guard !hidden else { continue }
            let shown = try XCTUnwrap(Self.descendants(controller.view).compactMap { $0 as? SidebarOutlineView }.first)
            let shownCoordinator = try XCTUnwrap(shown.delegate as? FolderSidebar.Coordinator)
            XCTAssertGreaterThan(navigation.arrangedSubviews[0].frame.width, 0)
            XCTAssertGreaterThan(navigation.arrangedSubviews[1].frame.width, 0)
            try verifyRows(shown, shownCoordinator, "after show")
            try verifyPixels(shown, shownCoordinator, current: try XCTUnwrap(shownCoordinator.currentItem),
                             plain: try XCTUnwrap(shownCoordinator.itemsByPath["Travel/Japan"]), "after show")
        }
        XCTAssertFalse(window.isVisible)
    }

    /// The drop path through the real delegate lands on a folder row and leaves its guides alone.
    @MainActor
    func testValidateDropOnFolderRowKeepsThreads() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let workspace = fixture.workspace
        let id = try XCTUnwrap(fixture.snapshot.metadata.IDsByPath["Vanlife/Settling In.md"])
        let payload = try JSONEncoder().encode(InternalMove(library: workspace.dragIdentity, ids: [id]))
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: fixture.snapshot, readDragData: { _ in payload })
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        defer { FolderSidebar.dismantleNSView(scroll, coordinator: coordinator) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        scroll.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(coordinator.outline)
        let japan = try XCTUnwrap(coordinator.itemsByPath["Travel/Japan"])
        let before = try row(outline, japan).thread
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let info = ThreadDraggingInfo(pasteboard: board, window: window)
        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: japan,
                                               proposedChildIndex: NSOutlineViewDropOnItemIndex), .move)
        XCTAssertTrue(coordinator.hovered === japan)
        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: coordinator.tagsGroup!.children[0],
                                               proposedChildIndex: NSOutlineViewDropOnItemIndex), [])
        coordinator.finishDrag(accepted: false)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertEqual(try row(outline, japan).thread, before)
        try verifyRows(outline, coordinator, "after drag")
    }

    /// 1,000 nested folders: per-row guides, no hang, no bitmap layers per row.
    @MainActor
    func testThousandFolderScrollAndExpandStayPerRow() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebThreadPerf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanned = try await LibraryScanner.scan(root: root)
        let rootFolder = try XCTUnwrap(scanned.folders.first)
        var folders = [rootFolder]
        for parent in 0..<40 {
            let p = LibraryFolder(id: UUID(), parentID: rootFolder.id, relativePath: "P\(parent)", name: "Parent \(parent)")
            folders.append(p)
            for child in 0..<4 {
                let c = LibraryFolder(id: UUID(), parentID: p.id, relativePath: "P\(parent)/C\(child)", name: "Child \(child)")
                folders.append(c)
                for leaf in 0..<5 {
                    folders.append(LibraryFolder(id: UUID(), parentID: c.id, relativePath: "P\(parent)/C\(child)/L\(leaf)", name: "Leaf \(leaf)"))
                }
            }
        }
        XCTAssertGreaterThanOrEqual(folders.count, 1_000)
        let snapshot = LibrarySnapshot(rootURL: root, folders: folders, documents: [],
            presentation: LibraryPresentation(folders: folders, documents: []), metadata: scanned.metadata,
            recoveredMetadataURL: nil, isReadOnly: false)
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.session.selectedFolder = "P20/C2/L3"
        workspace.session.expandedFolders = Set(folders.map(\.relativePath))
        workspace.install(snapshot)
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: snapshot)
        let start = CACurrentMediaTime()
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        defer { window.contentView = nil; window.close() }
        let outline = try XCTUnwrap(coordinator.outline)
        outline.tile()
        scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThan(CACurrentMediaTime() - start, 2, "initial load")
        XCTAssertGreaterThanOrEqual(outline.numberOfRows, 1_000)
        let contentHeight = outline.rect(ofRow: outline.numberOfRows - 1).maxY
        var offset: CGFloat = 0
        var worst = 0.0
        var drawnRows = 0
        for step in 0..<150 {
            offset = step < 75 ? min(offset + 280, contentHeight - scroll.contentSize.height) : max(0, offset - 280)
            let begin = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            scroll.layoutSubtreeIfNeeded()
            scroll.contentView.display()
            worst = max(worst, CACurrentMediaTime() - begin)
            let visible = outline.rows(in: scroll.contentView.bounds)
            for row in visible.location..<NSMaxRange(visible) {
                guard let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? ThreadRowView else { continue }
                drawnRows += 1
                XCTAssertEqual(rowView.thread?.level, outline.level(forRow: row))
                XCTAssertNil(rowView.layer?.sublayers?.first { !($0.delegate is NSView) })
                if let layer = rowView.layer {
                    XCTAssertLessThanOrEqual(layer.bounds.height, outline.rowHeight + 0.5, "per-row layer only")
                }
            }
        }
        print("R2 thread scroll benchmark: worst \(String(format: "%.2f", worst * 1000)) ms over \(drawnRows) row checks")
        XCTAssertLessThan(worst, 2, "main-thread hang")
        XCTAssertGreaterThan(drawnRows, 0)
        // Expanding one parent keeps every visible row view and only adds the inserted rows.
        let parent = try XCTUnwrap(coordinator.itemsByPath["P0"])
        outline.collapseItem(parent)
        scroll.contentView.scroll(to: .zero)
        scroll.layoutSubtreeIfNeeded()
        let above = try XCTUnwrap(outline.rowView(atRow: outline.row(forItem: parent), makeIfNecessary: false))
        let begin = CACurrentMediaTime()
        outline.expandItem(parent, expandChildren: false)
        scroll.layoutSubtreeIfNeeded()
        XCTAssertLessThan(CACurrentMediaTime() - begin, 2)
        XCTAssertTrue(outline.rowView(atRow: outline.row(forItem: parent), makeIfNecessary: false) === above)
        let firstChild = try XCTUnwrap(outline.rowView(atRow: outline.row(forItem: parent) + 1, makeIfNecessary: true) as? ThreadRowView)
        XCTAssertEqual(firstChild.thread?.level, 2)
        XCTAssertEqual(firstChild.thread?.ancestorContinues, [true])
    }
}

/// Supplies only the drag-session information consumed by the real sidebar delegate.
private final class ThreadDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingSource: Any? = nil
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingLocation: NSPoint = .zero
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

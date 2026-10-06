import AppKit
import SwiftUI
import XCTest
import UniformTypeIdentifiers
import SilkwebCore
@testable import Silkweb

final class DocumentListTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor
    func testWindowMouseEventsBeginDocumentDrags() async throws {
        try await exerciseDocumentPointerEvents(nativeWindowDispatch: true)
    }

    @MainActor
    func testOffscreenRowMouseTrackingAndSelection() async throws {
        try await exerciseDocumentPointerEvents(nativeWindowDispatch: false)
    }

    @MainActor
    private func exerciseDocumentPointerEvents(nativeWindowDispatch: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B", "C"] {
            try Data("# \(name)".utf8).write(to: root.appendingPathComponent(name + ".md"))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Destination"), withIntermediateDirectories: false)
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        await workspace.editor.configure(root: root)
        workspace.session.selectedFolder = ""
        workspace.session.selectedDocuments = []
        let name = "Silkweb.DragTests." + UUID().uuidString
        defer {
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(name) {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: name)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1200, height: 760),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        if nativeWindowDispatch {
            window.makeKey()
            window.orderBack(nil) // Outside all screens; never launch the app GUI.
        }
        controller.view.setFrameSize(NSSize(width: 1200, height: 760))
        defer { window.orderOut(nil); window.contentViewController = nil }
        // Nested hosting controllers realize their content over several layout turns.
        for _ in 0..<50 {
            controller.view.layoutSubtreeIfNeeded()
            for table in descendants(controller.view).compactMap({ $0 as? NSTableView }) {
                for row in 0..<table.numberOfRows {
                    _ = table.rowView(atRow: row, makeIfNecessary: true)
                    _ = table.view(atColumn: 0, row: row, makeIfNecessary: true)
                }
                table.layoutSubtreeIfNeeded()
            }
            if descendants(controller.view).compactMap({ $0 as? DocumentRowClickView }).count == 3 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(workspace.documents.count, 3)
        let paths = workspace.documents.map(\.relativePath)
        var starts: [Data] = []
        let type = NSPasteboard.PasteboardType(UTType.silkwebMove.identifier)
        let sources = descendants(controller.view).compactMap { $0 as? DocumentRowClickView }
        let table = try XCTUnwrap(descendants(controller.view).compactMap { $0 as? DocumentTableView }.first)
        table.startDraggingSession = { items, event, sender in
            XCTAssertEqual(event.type, .leftMouseDragged)
            XCTAssertEqual((sender as? DocumentRowClickView)?.path, paths[0])
            XCTAssertEqual(items.count, 1)
            XCTAssertGreaterThan(items[0].draggingFrame.width, 0)
            guard let writer = items[0].item as? NSPasteboardItem,
                  let data = writer.data(forType: type) else { XCTFail("Missing move payload"); return }
            starts.append(data)
        }
        let source = try XCTUnwrap(sources.first { $0.path == paths[0] })
        XCTAssertFalse(source.mouseDownCanMoveWindow)
        let row = try XCTUnwrap(source.nativeRow)
        let firstRowIndex = table.row(for: row)
        XCTAssertEqual(firstRowIndex, 0)
        var trackedSource: DocumentRowClickView?
        func send(_ type: NSEvent.EventType, offset: CGFloat = 0, rowIndex: Int = 0,
                  modifiers: NSEvent.ModifierFlags = [], timestamp: TimeInterval? = nil) throws {
            let rect = table.rect(ofRow: rowIndex)
            let point = table.convert(NSPoint(x: rect.maxX - 20 + offset, y: rect.midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: modifiers, timestamp: timestamp ?? ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1))
            if nativeWindowDispatch {
                // No direct handler, provider or canDragRows calls on the required path.
                window.sendEvent(event)
            } else {
                // Explicit sandbox fallback, separate from the required native-window test.
                // Exercise the actual hit-tested row, not a provider or gesture helper.
                if type == .leftMouseDown {
                    let content = try XCTUnwrap(window.contentView)
                    trackedSource = try XCTUnwrap(content.hitTest(content.convert(point, from: nil)) as? DocumentRowClickView)
                }
                let target = try XCTUnwrap(trackedSource)
                switch type {
                case .leftMouseDown: target.mouseDown(with: event)
                case .leftMouseDragged: target.mouseDragged(with: event)
                case .leftMouseUp: target.mouseUp(with: event); trackedSource = nil
                default: XCTFail("Unexpected pointer event")
                }
            }
        }
        if nativeWindowDispatch {
            // A nonzero window number does not guarantee event delivery in a
            // sandbox. Probe dispatch independently of the document source so
            // a broken row hit test or drag handler cannot cause a false skip.
            let content = try XCTUnwrap(window.contentView)
            let rect = table.rect(ofRow: 0)
            let point = content.convert(table.convert(NSPoint(x: rect.maxX - 20, y: rect.midY), to: nil), from: nil)
            let probe = MouseDispatchProbe(frame: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            content.addSubview(probe)
            XCTAssertTrue(content.hitTest(content.convert(point, to: content.superview)) === probe)
            try send(.leftMouseDown)
            try send(.leftMouseUp)
            probe.removeFromSuperview()
            guard probe.receivedMouseDown else {
                throw XCTSkip("NSWindow.sendEvent cannot deliver mouseDown to an independent hit-tested NSView (window number: \(window.windowNumber)). Row-handler test asserts the beginDraggingSession boundary; native-window drag proof still requires a dispatch-capable host.")
            }
        }
        for selected in [Set<String>(), Set([paths[0]]), Set(paths)] {
            workspace.session.selectedDocuments = selected
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let previous = starts.count
            try send(.leftMouseDown)
            // Run layout between down and drag to catch row invalidation. A press on an unselected row now selects it
            // and starts navigation (#70); this harness's rows are force-realized outside the table's visible rect, so
            // a run-loop turn would recycle them. Drags across a finished navigation are covered in a real window by
            // DocumentSelectionLatencyTests.testPressSelectsOnlyUnselectedRowsAndModifiersActOnRelease.
            controller.view.layoutSubtreeIfNeeded()
            try send(.leftMouseDragged, offset: 2)
            XCTAssertEqual(starts.count, previous, "Below threshold must remain a click")
            for offset: CGFloat in [-8, -16, -24] { try send(.leftMouseDragged, offset: offset) }
            try send(.leftMouseUp, offset: -24)
            XCTAssertEqual(starts.count, previous + 1, "Selection: \(selected)")
            if let data = starts.last {
                XCTAssertEqual(Set(try XCTUnwrap(workspace.pathsForDrag(data))),
                               selected.isEmpty ? [paths[0]] : selected)
            }
            XCTAssertNil(workspace.rename)
            await workspace.waitForNavigation()
        }
        workspace.mutating = true
        let previous = starts.count
        try send(.leftMouseDown)
        try send(.leftMouseDragged, offset: -8)
        try send(.leftMouseUp, offset: -8)
        XCTAssertEqual(starts.count, previous, "Mutation-disabled lists cannot start drags")
        workspace.mutating = false
        func click(_ rowIndex: Int, modifiers: NSEvent.ModifierFlags = [], timestamp: TimeInterval? = nil) async throws {
            try send(.leftMouseDown, rowIndex: rowIndex, modifiers: modifiers, timestamp: timestamp)
            try send(.leftMouseUp, rowIndex: rowIndex, modifiers: modifiers, timestamp: timestamp)
            await workspace.waitForNavigation()
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(30))
        }
        try await click(0)
        XCTAssertEqual(workspace.session.selectedDocuments, [paths[0]])
        try await click(1, modifiers: .command)
        XCTAssertEqual(workspace.session.selectedDocuments, Set(paths.prefix(2)))
        try await click(0)
        try await click(2, modifiers: .shift)
        XCTAssertEqual(workspace.session.selectedDocuments, Set(paths))
        // Native keyboard selection remains on the same table.
        try await click(0)
        let arrow = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "\u{f701}", charactersIgnoringModifiers: "\u{f701}", isARepeat: false, keyCode: 125))
        table.keyDown(with: arrow)
        await workspace.waitForNavigation()
        XCTAssertEqual(workspace.session.selectedDocuments, [paths[1]])
        // Use native event timestamps to exercise slow-click timing without sleeping between clicks.
        let timestamp = ProcessInfo.processInfo.systemUptime + 3
        try await click(0, timestamp: timestamp)
        try await click(0, timestamp: timestamp + 0.75)
        try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
        XCTAssertEqual(workspace.rename?.path, paths[0])
        workspace.rename = nil

        // Feed payloads captured at the actual begin-session boundary into the
        // existing sidebar delegate, for both a single document and a selection.
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        XCTAssertEqual(starts.count, 3)
        guard starts.count == 3 else { return }
        for payload in [starts[0], starts[2]] {
            let moving = try XCTUnwrap(workspace.pathsForDrag(payload))
            let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: try XCTUnwrap(workspace.snapshot),
                                                         readDragData: { _ in payload })
            let sidebar = FolderSidebar.makeScrollView(coordinator: coordinator)
            let outline = try XCTUnwrap(sidebar.documentView as? NSOutlineView)
            let destination = try XCTUnwrap(coordinator.itemsByPath["Destination"])
            let info = DocumentListDraggingInfo(pasteboard: board, window: window, source: table)
            XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: destination,
                                                 proposedChildIndex: NSOutlineViewDropOnItemIndex), .move)
            XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: destination,
                                                 childIndex: NSOutlineViewDropOnItemIndex))
            for _ in 0..<500 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(workspace.mutating)
            XCTAssertNil(workspace.mutationError)
            for path in moving {
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Destination/" + path).path))
            }
            FolderSidebar.dismantleNSView(sidebar, coordinator: coordinator)
            workspace.move(moving.map { "Destination/" + $0 }, to: "")
            for _ in 0..<500 where workspace.mutating { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(workspace.mutating)
            XCTAssertNil(workspace.mutationError)
        }
    }

    @MainActor
    func testRealMouseClicksSelectRowsAndExtendSelection() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["A", "B", "C"] {
            try Data("# \(name)\n\nBody".utf8).write(to: root.appendingPathComponent(name + ".md"))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Destination"), withIntermediateDirectories: false)
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        await workspace.editor.configure(root: root)
        workspace.session.selectedFolder = ""
        workspace.session.selectedDocuments = []
        var nativeProvider: NSItemProvider?
        let host = NSHostingView(rootView: DocumentList(workspace: workspace, makeDragProvider: { paths in
            let provider = workspace.dragProvider(paths)
            nativeProvider = provider
            return provider
        }))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host // Deliberately never ordered front.
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        var table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.numberOfRows, 3)
        let paths = workspace.documents.map(\.relativePath)

        func click(row: Int, point: NSPoint, modifiers: NSEvent.ModifierFlags = []) async throws {
            let rect = table.rect(ofRow: row)
            let location = table.convert(NSPoint(x: rect.minX + point.x, y: rect.minY + point.y), to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: modifiers, timestamp: timestamp, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                modifierFlags: modifiers, timestamp: timestamp + 0.05, windowNumber: window.windowNumber,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            // Native table mouseDown tracks until mouseUp; queue the up event before dispatch.
            NSApp.postEvent(up, atStart: true)
            window.sendEvent(down)
            // Hidden NSWindows do not dispatch clicks to SwiftUI List. Drive its real
            // NSTableView with the same NSEvents (no programmatic selection).
            table.mouseDown(with: down)
            window.sendEvent(up)
            table.mouseUp(with: up)
            await workspace.waitForNavigation()
            try await Task.sleep(for: .milliseconds(50))
        }
        let height = table.rect(ofRow: 0).height
        for point in [NSPoint(x: 24, y: 12), // Title
                      NSPoint(x: table.bounds.width - 20, y: height / 2), // Empty right area
                      NSPoint(x: 30, y: 24)] { // Between title and summary
            try await click(row: 0, point: point)
            XCTAssertEqual(workspace.session.selectedDocuments, [paths[0]], "Click at \(point)")
            try await click(row: 1, point: point)
            XCTAssertEqual(workspace.session.selectedDocuments, [paths[1]], "Click at \(point)")
        }
        try await click(row: 0, point: NSPoint(x: 24, y: 12))
        try await click(row: 1, point: NSPoint(x: 24, y: 12), modifiers: .command)
        XCTAssertEqual(workspace.session.selectedDocuments, Set(paths.prefix(2)))
        try await click(row: 0, point: NSPoint(x: 24, y: 12))
        try await click(row: 2, point: NSPoint(x: 24, y: 12), modifiers: .shift)
        XCTAssertEqual(workspace.session.selectedDocuments, Set(paths))

        func requestMoveFromMenu(_ table: NSTableView) throws {
            let location = table.convert(NSPoint(x: 24, y: table.rect(ofRow: 0).midY), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
            let menu = try XCTUnwrap(table.menu(for: event))
            let index = menu.indexOfItem(withTitle: "Move To…")
            XCTAssertGreaterThanOrEqual(index, 0)
            guard index >= 0 else { return }
            XCTAssertTrue(menu.items[index].isEnabled)
            menu.performActionForItem(at: index)
        }

        // Preserve the legacy provider/drop coverage alongside the new row-source tests.
        XCTAssertTrue(table.canDragRows(with: IndexSet(integersIn: 0..<3),
                                        at: NSPoint(x: 24, y: table.rect(ofRow: 0).midY)))
        let provider = try XCTUnwrap(nativeProvider, "Native table must request the row item provider")
        let payload = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.silkwebMove.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let type = NSPasteboard.PasteboardType(UTType.silkwebMove.identifier)
        let item = NSPasteboardItem()
        XCTAssertTrue(item.setData(payload, forType: type))
        // The sandbox cannot contact the pasteboard server. Keep the real
        // NSDraggingInfo/delegate path and substitute only the pasteboard read.
        XCTAssertEqual(Set(try XCTUnwrap(workspace.pathsForDrag(payload))), Set(paths))
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: try XCTUnwrap(workspace.snapshot),
                                                    readDragData: { _ in item.data(forType: type) })
        let sidebar = FolderSidebar.makeScrollView(coordinator: coordinator)
        defer { FolderSidebar.dismantleNSView(sidebar, coordinator: coordinator) }
        let outline = try XCTUnwrap(sidebar.documentView as? NSOutlineView)
        let destination = try XCTUnwrap(coordinator.itemsByPath["Destination"])
        let info = DocumentListDraggingInfo(pasteboard: board, window: window, source: table)
        XCTAssertEqual(coordinator.outlineView(outline, validateDrop: info, proposedItem: destination,
                                             proposedChildIndex: NSOutlineViewDropOnItemIndex), .move)
        XCTAssertTrue(coordinator.outlineView(outline, acceptDrop: info, item: destination,
                                            childIndex: NSOutlineViewDropOnItemIndex))
        for _ in 0..<500 where workspace.mutating {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(workspace.mutating)
        XCTAssertNil(workspace.mutationError)
        for path in paths {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Destination/" + path).path))
        }

        // Invoke the actual row menu, then select a destination and press the
        // real picker button. The app-scene keyboard command still needs owner QA.
        workspace.session.selectedFolder = "Destination"
        workspace.focusColumn = 1
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        table = try XCTUnwrap(descendants(host).compactMap { $0 as? NSTableView }.first)
        try requestMoveFromMenu(table)
        let request = try XCTUnwrap(workspace.moveRequest)
        XCTAssertEqual(Set(request.paths), Set(paths.map { "Destination/" + $0 }))
        let picker = NSHostingView(rootView: MovePicker(workspace: workspace, request: request))
        window.contentView = picker
        picker.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        picker.layoutSubtreeIfNeeded()
        let pickerTable = try XCTUnwrap(descendants(picker).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(pickerTable.numberOfRows, 5) // Recent header/item, Library header/root/item.
        table = pickerTable
        try await click(row: 3, point: NSPoint(x: 100, y: pickerTable.rect(ofRow: 3).height / 2))
        let buttons = descendants(picker).compactMap { $0 as? NSButton }
        let moveButton = try XCTUnwrap(buttons.first { $0.keyEquivalent == "\r" })
        XCTAssertTrue(moveButton.isEnabled)
        moveButton.performClick(nil)
        for _ in 0..<500 where workspace.mutating {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(workspace.moveRequest)
        XCTAssertNil(workspace.mutationError)
        for path in paths {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Destination/" + path).path))
        }
    }

    @MainActor
    func testFullRowClickBoundsAndSidebarHitTesting() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# A\n\nBody".utf8).write(to: root.appendingPathComponent("A.md"))
        let workspace = LibraryWorkspace()
        workspace.root = root
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot)
        let host = NSHostingView(rootView: DocumentList(workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 560),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host // Never order the window on screen.
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        for width: CGFloat in [240, 480, 4096] {
            host.setFrameSize(NSSize(width: width, height: 560))
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let observer = try XCTUnwrap(descendants(host).compactMap { $0 as? DocumentRowClickView }.first)
            XCTAssertEqual(observer.path, "A.md")
            let row = try XCTUnwrap(observer.nativeRow)
            let rect = observer.convert(observer.clickBounds, to: row)
            XCTAssertEqual(rect.width, row.bounds.width, accuracy: 1)
            XCTAssertEqual(rect.height, row.bounds.height, accuracy: 1)
            for point in [NSPoint(x: 1, y: 1), NSPoint(x: 20, y: 12),
                          NSPoint(x: rect.width - 1, y: rect.height / 2),
                          NSPoint(x: 30, y: 24), NSPoint(x: 30, y: rect.height - 1)] {
                let hit = try XCTUnwrap(row.hitTest(row.convert(point, to: row.superview)))
                XCTAssertTrue(hit === row || hit.isDescendant(of: row))
                XCTAssertTrue(rect.contains(point), "Row excludes \(point)")
                XCTAssertTrue(observer.hitTest(row.convert(point, to: observer.superview)) === observer,
                              "AppKit source owns primary-button tracking")
            }
        }
        let coordinator = FolderSidebar.Coordinator(workspace: workspace, snapshot: snapshot)
        let scroll = FolderSidebar.makeScrollView(coordinator: coordinator)
        scroll.setFrameSize(NSSize(width: 300, height: 560))
        scroll.tile(); scroll.layoutSubtreeIfNeeded()
        let outline = try XCTUnwrap(scroll.documentView as? SidebarOutlineView)
        let rect = outline.rect(ofRow: 0)
        for x in [rect.minX + 1, rect.midX, rect.maxX - 1] {
            XCTAssertEqual(outline.row(at: NSPoint(x: x, y: rect.midY)), 0)
        }
        FolderSidebar.dismantleNSView(scroll, coordinator: coordinator)
    }

    @MainActor
    func testOffscreenDocumentListLoadResizeAndDateNotifications() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Title\n\n> - [x] **Body** 日本語 👩🏽‍💻".utf8).write(to: root.appendingPathComponent("Title.md"))
        let workspace = LibraryWorkspace()
        workspace.root = root
        let snapshot = try await LibraryScanner.scan(root: root)
        workspace.install(snapshot)
        let host = NSHostingView(rootView: DocumentList(workspace: workspace))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 4096, height: 2160))
        container.addSubview(host)
        host.setFrameSize(NSSize(width: 300, height: 560))
        host.layoutSubtreeIfNeeded()
        // Let the actual row's asynchronous summary task finish, without opening a window.
        try await Task.sleep(for: .milliseconds(100))
        for notification in [Notification.Name.NSCalendarDayChanged, .NSSystemTimeZoneDidChange,
                             .NSSystemClockDidChange, NSApplication.didBecomeActiveNotification] {
            NotificationCenter.default.post(name: notification, object: nil)
            await Task.yield()
            for width: CGFloat in [0, 1, 240, 300, 480, 4096] {
                for height: CGFloat in [0, 1, 36, 560, 2160] {
                    host.setFrameSize(NSSize(width: width, height: height))
                    host.layoutSubtreeIfNeeded()
                }
            }
        }
        XCTAssertEqual(workspace.documents.count, 1)
        host.removeFromSuperview()
        container.addSubview(host)
        host.layoutSubtreeIfNeeded()
    }
}

/// Supplies only the drag-session information consumed by the real sidebar delegate.
/// An OS drag session cannot be completed between windows that are never on screen.
private final class DocumentListDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingDestinationWindow: NSWindow?
    let draggingSource: Any?
    let draggingSourceOperationMask: NSDragOperation = .move
    let draggingLocation: NSPoint = .zero
    let draggedImageLocation: NSPoint = .zero
    let draggedImage: NSImage? = nil
    let draggingSequenceNumber = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(pasteboard: NSPasteboard, window: NSWindow, source: NSTableView) {
        draggingPasteboard = pasteboard
        draggingDestinationWindow = window
        draggingSource = source
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

/// Detects window dispatch availability without invoking document-list code.
private final class MouseDispatchProbe: NSView {
    private(set) var receivedMouseDown = false
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { receivedMouseDown = true }
    override func mouseUp(with event: NSEvent) { }
}

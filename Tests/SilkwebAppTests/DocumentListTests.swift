import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

final class DocumentListTests: XCTestCase {
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
        workspace.install(snapshot, sorted: snapshot.documents)
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
                XCTAssertNil(observer.hitTest(point), "Observer must not intercept native selection or dragging")
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
        workspace.install(snapshot, sorted: snapshot.documents)
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

import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

final class DocumentListTests: XCTestCase {
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

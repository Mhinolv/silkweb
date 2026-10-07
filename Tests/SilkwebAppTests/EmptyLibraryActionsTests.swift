import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #153: an empty library's New Document / New Folder pair must fit inside the list column at every width,
/// side by side when they fit and stacked (equal width) when they don't.
@MainActor
final class EmptyLibraryActionsTests: XCTestCase {
    override func tearDown() {
        StatusBarCountsTests.exposeAccessibility(false)
        super.tearDown()
    }

    func testEmptyLibraryActionsStayInsideTheListColumnAcrossWidths() async throws {
        StatusBarCountsTests.exposeAccessibility(true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebEmptyLibrary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = LibraryWorkspace(defaults: disposableDefaults("EmptyLibraryActions"))
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedFolder = ""
        let columns = LibrarySplitViewController(workspace: workspace, autosaveName: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = columns
        defer { window.contentViewController = nil; window.close() }
        window.setContentSize(NSSize(width: 1400, height: 900))
        columns.view.layoutSubtreeIfNeeded()
        let list = columns.navigationController.splitViewItems[1].viewController.view
        var layouts: [CGFloat: (document: NSRect, folder: NSRect)] = [:]
        for width: CGFloat in [420, 240, 300, 260, 360, 240] {
            columns.splitView.setPosition(
                220 + columns.navigationController.splitView.dividerThickness + width, ofDividerAt: 0)
            columns.view.layoutSubtreeIfNeeded()
            columns.navigationController.splitView.setPosition(220, ofDividerAt: 0)
            var document: AnyObject?, folder: AnyObject?
            for _ in 0..<10 {
                columns.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                document = StatusBarCountsTests.element("New Document", in: list)
                folder = StatusBarCountsTests.element("New Folder", in: list)
                if document != nil, folder != nil { break }
            }
            XCTAssertEqual(list.frame.width, width, accuracy: 1)
            let column = window.convertToScreen(list.convert(list.bounds, to: nil))
            let documentFrame = StatusBarCountsTests.frame(try XCTUnwrap(document, "New Document at \(width)"))
            let folderFrame = StatusBarCountsTests.frame(try XCTUnwrap(folder, "New Folder at \(width)"))
            // The capsule inset keeps both buttons off the column edges and the divider.
            let inset = column.insetBy(dx: Spacing.capsuleInset - 1, dy: 0)
            for (name, frame) in [("New Document", documentFrame), ("New Folder", folderFrame)] {
                XCTAssertGreaterThanOrEqual(frame.minX, inset.minX, "\(name) clipped at the leading edge at \(width)")
                XCTAssertLessThanOrEqual(frame.maxX, inset.maxX, "\(name) clipped at the divider at \(width)")
            }
            XCTAssertFalse(documentFrame.intersects(folderFrame), "buttons overlap at \(width)")
            // Focus order and reading order: New Document first, then New Folder.
            if documentFrame.maxY <= folderFrame.minY || folderFrame.maxY <= documentFrame.minY {
                XCTAssertGreaterThan(documentFrame.minY, folderFrame.minY, "New Document is not above at \(width)")
                XCTAssertEqual(documentFrame.width, folderFrame.width, accuracy: 1, "stacked widths at \(width)")
                XCTAssertEqual(documentFrame.midX, column.midX, accuracy: 2, "stack is not centred at \(width)")
                XCTAssertLessThan(documentFrame.width, column.width - 2 * Spacing.capsuleInset - 1)
            } else {
                XCTAssertLessThan(documentFrame.maxX, folderFrame.minX, "New Document is not leading at \(width)")
            }
            layouts[width] = (documentFrame, folderFrame)
        }
        // A wide column keeps the pair side by side; the 240 pt minimum stacks it.
        let wide = try XCTUnwrap(layouts[420])
        XCTAssertEqual(wide.document.midY, wide.folder.midY, accuracy: 1, "side by side at 420")
        let narrow = try XCTUnwrap(layouts[240])
        XCTAssertNotEqual(narrow.document.midY, narrow.folder.midY, accuracy: 1, "stacked at 240")
        XCTAssertFalse(window.isVisible)
    }
}

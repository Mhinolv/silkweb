import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #69: Outline and Info are two segments of one Inspector. The toolbar and ⌘7/⌘8 switch to the other
/// segment, close the one already showing, and never close the panel when switching.
final class InspectorSegmentTests: XCTestCase {
    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// The real toolbar in an unordered window; its hosted NSButtons are clicked.
    @MainActor
    func testToolbarButtonsSwitchOrCloseTheInspectorSegment() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebInspector-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Title\n\n## Section\n".utf8).write(to: root.appendingPathComponent("A.md"))
        let suite = "Silkweb.Inspector." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        XCTAssertFalse(workspace.preview.showsOutline)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
        controller.sizingOptions = []
        window.contentViewController = controller
        defer {
            window.contentViewController = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: root)
        }
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        func settle() async throws {
            for _ in 0..<8 {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        workspace.navigate(folder: nil, documents: ["A.md"], pinned: true)
        await workspace.waitForNavigation()
        try await settle()
        let toolbar = try XCTUnwrap(window.toolbar)
        func button(_ label: String) throws -> NSButton {
            let view = try XCTUnwrap(toolbar.items.first { $0.label == label }?.view, label)
            return try XCTUnwrap(Self.descendants(view).compactMap { $0 as? NSButton }.first, "\(label) button")
        }
        func press(_ label: String) async throws {
            try button(label).performClick(nil)
            // Let the inspector's open/close finish before the next press.
            try await settle()
        }
        typealias State = (open: Bool, info: Bool)
        func assertState(_ expected: State, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(
                workspace.preview.showsOutline, expected.open, "\(context): inspector open", file: file, line: line)
            if expected.open {
                XCTAssertEqual(
                    workspace.inspectorInfo, expected.info, "\(context): Info segment", file: file, line: line)
            }
        }

        // The reported path: Info, then Outline switches instead of closing the panel.
        try await press("Show Document Info"); assertState((true, true), "Info from closed")
        try await press("Show Outline"); assertState((true, false), "Outline while Info is showing")
        try await press("Show Outline"); assertState((false, false), "Outline while Outline is showing")
        try await press("Show Outline"); assertState((true, false), "Outline from closed")
        try await press("Show Document Info"); assertState((true, true), "Info while Outline is showing")
        try await press("Show Document Info"); assertState((false, true), "Info while Info is showing")

        // `inspectorSegment` drives the toolbar's selected glyph and the View menu checkmarks.
        for (segment, info) in [("Show Outline", false), ("Show Document Info", true)] {
            try await press(segment)
            assertState((true, info), "\(segment) opens")
            XCTAssertEqual(workspace.inspectorSegment, info ? .info : .outline)
            // The in-inspector segmented control switches without closing the panel.
            workspace.inspectorInfo.toggle()
            try await settle()
            XCTAssertEqual(workspace.inspectorSegment, info ? .outline : .info, "\(segment): segmented control")
            workspace.inspectorInfo.toggle()
            try await press(segment)
            XCTAssertNil(workspace.inspectorSegment)
        }

        // Edit Tags… always opens Info and focuses the tags, and never closes the panel.
        for start in [nil, LibraryWorkspace.InspectorSegment.outline, .info] {
            if let start { workspace.toggleInspector(start) }
            try await settle()
            let focus = workspace.tagFocusRequest
            workspace.showInfo()
            try await settle()
            XCTAssertEqual(workspace.inspectorSegment, .info, "Edit Tags from \(String(describing: start))")
            XCTAssertEqual(workspace.tagFocusRequest, focus + 1)
            workspace.preview.showsOutline = false
        }
    }
}

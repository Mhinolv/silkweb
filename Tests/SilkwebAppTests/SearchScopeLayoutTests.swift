import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #222: the Search Library scope control and the results count stay inside the list column at every width, with
/// All Libraries offered and a long folder name selected.
final class SearchScopeLayoutTests: XCTestCase {
    private final class Frames {
        var values: [String: CGRect] = [:]
    }

    static let folder = "A Very Long Folder Name About Brewing Coffee At Home"

    @MainActor
    private func measured<Content: View>(_ content: Content, frames: Frames) -> some View {
        content.overlayPreferenceValue(ColumnLayoutAnchors.self) { anchors in
            GeometryReader { geometry in
                let values = anchors.mapValues { geometry[$0] }
                Color.clear
                    .onAppear { frames.values = values }
                    .onChange(of: values) { frames.values = values }
            }
            .allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    @MainActor
    private func settle(_ host: NSView) async throws {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor
    func testScopeControlAndCountFitTheColumnAtEveryWidth() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SearchScope-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(Self.folder), withIntermediateDirectories: true)
        try Data("# Kiwi\n\nA kiwi.\n".utf8).write(to: root.appendingPathComponent(Self.folder + "/Kiwi.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = disposableDefaults("SearchScopeLayout")
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        // Another open Library: the scope offers All Libraries too (#197).
        let other = LibraryWorkspace(defaults: defaults)
        workspace.search.otherLibraries = { [.init(name: "Other", root: root, search: other.search)] }
        let frames = Frames()
        let host = NSHostingView(
            rootView: measured(
                DocumentList(workspace: workspace).frame(maxWidth: .infinity, maxHeight: .infinity), frames: frames))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 560), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        workspace.session.selectedFolder = Self.folder
        try await settle(host)
        workspace.search.text = "kiwi"
        try await settle(host)
        XCTAssertEqual(workspace.search.folderScope, workspace.selectedFolder?.id, "a new search starts in the folder")

        for width: CGFloat in [240, 300, 480] {
            host.setFrameSize(NSSize(width: width, height: 560))
            try await settle(host)
            // No AppKit control (the old segmented picker) reaches past the column's edges.
            // (A list's idle scroller is parked outside its clip view.)
            for view in Self.descendants(host) where view is NSControl && !(view is NSScroller) {
                let frame = view.convert(view.bounds, to: host)
                XCTAssertGreaterThanOrEqual(
                    frame.minX, -0.5, "\(type(of: view)) clipped at the leading edge, \(width) pt")
                XCTAssertLessThanOrEqual(
                    frame.maxX, width + 0.5, "\(type(of: view)) clipped at the trailing edge, \(width) pt")
            }
            let scope = try XCTUnwrap(frames.values["search-scope"], "search-scope at \(width) pt")
            let count = try XCTUnwrap(frames.values["search-result-count"], "search-result-count at \(width) pt")
            XCTAssertGreaterThanOrEqual(scope.minX, 0, "\(width) pt")
            XCTAssertLessThanOrEqual(count.maxX, width, "the count is not clipped, \(width) pt")
            XCTAssertGreaterThan(count.width, 0)
            XCTAssertLessThanOrEqual(scope.maxX, count.minX, "the scope sits before the count, \(width) pt")
            XCTAssertEqual(scope.midY, count.midY, accuracy: 4, "one row, \(width) pt")
        }
        // A short scope hugs its title instead of stretching to the count.
        workspace.search.folderScope = nil
        try await settle(host)
        let scope = try XCTUnwrap(frames.values["search-scope"])
        XCTAssertLessThan(scope.width, 160, "All Documents keeps its own width")
        XCTAssertGreaterThan(scope.width, 40)
        XCTAssertFalse(window.isVisible)
    }
}

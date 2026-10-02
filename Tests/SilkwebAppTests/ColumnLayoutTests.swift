import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

final class ColumnLayoutTests: XCTestCase {
    private final class Frames {
        var values: [String: CGRect] = [:]
    }

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

    private func frame(_ identifier: String, in frames: Frames) throws -> CGRect {
        try XCTUnwrap(frames.values[identifier], identifier)
    }

    private func assertEmptyBodyIsCenteredBelowChrome(_ frames: Frames, chrome: CGRect) throws {
        let region = try frame("column-empty-region", in: frames)
        let body = try frame("column-empty-body", in: frames)
        XCTAssertGreaterThanOrEqual(region.minY, chrome.maxY)
        XCTAssertEqual(body.midY, region.midY - min(24, region.height / 10), accuracy: 2)
    }

    @MainActor
    private func settle(_ host: NSView) async throws {
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    @MainActor
    func testRealListSearchChromeAcrossEmptyPopulatedAndSearchStates() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try Data("# One".utf8).write(to: root.appendingPathComponent("One.md"))
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Silkweb.ColumnLayout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let frames = Frames()
        // Measure against the entire pane, not the intrinsic empty stack height.
        let host = NSHostingView(rootView: measured(DocumentList(workspace: workspace)
            .frame(maxWidth: .infinity, maxHeight: .infinity), frames: frames))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for size in [NSSize(width: 240, height: 300), NSSize(width: 300, height: 560), NSSize(width: 480, height: 900)] {
            host.setFrameSize(size)
            workspace.session.selectedFolder = ""
            try await settle(host)
            XCTAssertEqual(workspace.documents.count, 1)
            XCTAssertEqual(workspace.subtitle, "1 document")
            let populated = try frame("library-search", in: frames)
            XCTAssertEqual(populated.minY, 8, accuracy: 4)
            workspace.session.selectedFolder = "Empty"
            try await settle(host)
            XCTAssertTrue(workspace.documents.isEmpty)
            let empty = try frame("library-search", in: frames)
            XCTAssertEqual(empty.minY, populated.minY, accuracy: 4)
            XCTAssertEqual(empty.minY, 8, accuracy: 4)
            try assertEmptyBodyIsCenteredBelowChrome(frames, chrome: empty)
            workspace.setIncludeSubfolders(true)
            try await settle(host)
            XCTAssertEqual(try frame("library-search", in: frames).minY, populated.minY, accuracy: 4)
            workspace.search.text = "no-matches"
            await workspace.search.query(quick: false)
            try await settle(host)
            XCTAssertEqual(workspace.subtitle, "0 results")
            XCTAssertEqual(try frame("library-search", in: frames).minY, populated.minY, accuracy: 4)
            workspace.search.text = ""
            workspace.setIncludeSubfolders(false)
        }
        XCTAssertFalse(window.isVisible)
    }

    @MainActor
    func testRealOutlineTitleRemainsPinnedAcrossContentModesAndResize() async throws {
        _ = NSApplication.shared
        let suite = "Silkweb.OutlineLayout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = LibraryWorkspace(defaults: defaults)
        let frames = Frames()
        // Measure against the entire pane, not the intrinsic empty stack height.
        let host = NSHostingView(rootView: measured(InspectorView(workspace: workspace)
            .frame(maxWidth: .infinity, maxHeight: .infinity), frames: frames))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for size in [NSSize(width: 200, height: 300), NSSize(width: 240, height: 560), NSSize(width: 320, height: 900)] {
            host.setFrameSize(size)
            for mode in DocumentViewMode.allCases {
                workspace.preview.mode = mode
                workspace.preview.headings = MarkdownParser.parse("# Title\n## Child").headings
                try await settle(host)
                let populated = try frame("outline-title", in: frames)
                XCTAssertEqual(populated.minY, 12, accuracy: 4)
                workspace.preview.headings = MarkdownParser.parse("").headings
                try await settle(host)
                let empty = try frame("outline-title", in: frames)
                XCTAssertEqual(empty.minY, populated.minY, accuracy: 4)
                XCTAssertEqual(empty.minY, 12, accuracy: 4)
                try assertEmptyBodyIsCenteredBelowChrome(frames, chrome: empty)
            }
        }
        XCTAssertFalse(window.isVisible)
    }
}

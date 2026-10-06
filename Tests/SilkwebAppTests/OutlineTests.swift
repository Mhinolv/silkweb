import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

final class OutlineTests: XCTestCase {
    @MainActor
    func testCurrentHeadingAcrossCaretPositionsAndAllModes() throws {
        let defaults = disposableDefaults("Outline")
        let preview = PreviewCoordinator(defaults: defaults)
        let source = "Intro 😀\n# **Title**\nBody\n### Child\nMore\n###### End\n"
        preview.headings = MarkdownParser.parse(source).headings
        XCTAssertEqual(preview.headings.map(\.text), ["Title", "Child", "End"])
        for mode in DocumentViewMode.allCases {
            preview.mode = mode
            for visible in [nil] + preview.headings.map({ Optional($0.id) }) {
                preview.visibleHeading = visible
                for caret in 0...source.utf16.count {
                    let expected =
                        mode == .preview
                        ? visible : preview.headings.last(where: { $0.sourceRange.location <= caret })?.id
                    XCTAssertEqual(preview.currentHeading(caret: caret), expected, "\(mode), caret \(caret)")
                }
            }
        }
        preview.headings = []
        preview.visibleHeading = nil
        for mode in DocumentViewMode.allCases {
            preview.mode = mode
            XCTAssertNil(preview.currentHeading(caret: 0))
        }
    }

    @MainActor
    func testRealOutlineLifecycleContentChangesAndResize() async throws {
        _ = NSApplication.shared
        let defaults = disposableDefaults("OutlineLifecycle")
        let workspace = LibraryWorkspace(defaults: defaults)
        let source = (1...6).map { String(repeating: "#", count: $0) + " Heading \($0)" }.joined(separator: "\n")
        let headings = MarkdownParser.parse(source).headings
        let host = NSHostingView(rootView: InspectorView(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        for dark in [false, true] {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for content in [[], headings, Array(headings.dropFirst(2)), headings] {
                workspace.preview.headings = content
                for mode in DocumentViewMode.allCases {
                    workspace.preview.mode = mode
                    for heading in content {
                        workspace.editor.caretLocation = heading.sourceRange.location
                        workspace.preview.visibleHeading = heading.id
                        XCTAssertEqual(
                            workspace.preview.currentHeading(caret: workspace.editor.caretLocation), heading.id)
                        host.layoutSubtreeIfNeeded()
                    }
                    for width: CGFloat in [1, 200, 240, 320, 4096] {
                        host.setFrameSize(NSSize(width: width, height: 300))
                        host.layoutSubtreeIfNeeded()
                    }
                    await Task.yield()
                }
            }
        }
        XCTAssertFalse(window.isVisible)
    }
}

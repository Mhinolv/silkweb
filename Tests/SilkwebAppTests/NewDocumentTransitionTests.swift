import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

final class NewDocumentTransitionTests: XCTestCase {
    @MainActor
    private func backgroundPixels(_ editor: PlainMarkdownTextView) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 900, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        editor.drawBackground(in: NSRect(x: 0, y: 0, width: 900, height: 100))
        return Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    @MainActor
    func testNewDocumentKeepsEmptyEditorVisibleUntilSingleTabTransition() async throws {
        _ = NSApplication.shared
        for parent in [nil, "Writing"] as [String?] {
            for startsEmpty in [true, false] {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Writing"), withIntermediateDirectories: true)
                try Data().write(to: root.appendingPathComponent("Empty.md"))
                defer { try? FileManager.default.removeItem(at: root) }
                let defaults = try XCTUnwrap(UserDefaults(suiteName: "Silkweb.NewDocument." + UUID().uuidString))
                let workspace = LibraryWorkspace(defaults: defaults)
                workspace.root = root
                workspace.install(try await LibraryScanner.scan(root: root))
                if startsEmpty {
                    workspace.showDocument(root.appendingPathComponent("Empty.md"))
                    await workspace.waitForNavigation()
                }
                let oldID = workspace.activeTabID
                let host = NSHostingView(rootView: DocumentDetail(workspace: workspace))
                host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                                      styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.contentView = nil; window.close() }
                func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
                struct Frame: Equatable {
                    let tab: UUID?
                    let url: URL?
                    let installed: Bool
                    let placeholder: Bool
                }
                func frame() -> Frame {
                    host.layoutSubtreeIfNeeded()
                    host.displayIfNeeded()
                    let editor = workspace.preview.editor
                    let installed = editor.map { candidate in descendants(host).contains { $0 === candidate } } ?? false
                    return Frame(tab: workspace.activeTabID, url: editor?.session?.url, installed: installed,
                                 placeholder: installed && editor?.string.isEmpty == true && editor?.accessibilityPlaceholderValue() == "Start writing…")
                }
                for _ in 0..<10 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertEqual(frame().placeholder, startsEmpty)
                final class Frames { var values: [Frame] = [] }
                let sampled = Frames()
                sampled.values = [frame()]
                func record() {
                    let next = frame()
                    if sampled.values.last != next { sampled.values.append(next) }
                }
                // Sample every frame the window could show, including the asynchronous save/scan/open gaps: once per
                // main run-loop turn, after SwiftUI and Core Animation committed it (#63). A sleep-paced sampler could
                // wake between a model change and SwiftUI's update in the same turn and record a state never drawn.
                let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { _, _ in
                    MainActor.assumeIsolated { record() }
                }
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                defer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
                workspace.create(folder: false, parent: parent)
                try await waitUntil("the new document to finish creating", timeout: .seconds(10)) { !workspace.mutating }
                XCTAssertNil(workspace.mutationError)
                let newID = try XCTUnwrap(workspace.activeTabID)
                XCTAssertNotEqual(newID, oldID)
                let url = root.appendingPathComponent(parent == nil ? "Untitled.md" : "Writing/Untitled.md")
                XCTAssertEqual(workspace.editor.url, url)
                // Keep sampling while follow-up work (rename, focus) settles.
                try await Task.sleep(for: .milliseconds(300))
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                let frames = sampled.values
                let transitions = zip(frames, frames.dropFirst()).filter { $0.tab != $1.tab }
                XCTAssertEqual(transitions.count, 1, "Tab sequence: \(frames)")
                XCTAssertTrue(frames.allSatisfy {
                    if !startsEmpty && $0.tab == nil { return !$0.installed && !$0.placeholder }
                    return $0.installed && $0.placeholder
                }, "Placeholder/pane sequence: \(frames)")
                XCTAssertTrue(frames.filter { $0.tab == newID }.allSatisfy { $0.url == url })
                XCTAssertEqual(workspace.tabs.last?.isPreview, false)
                // The installed editor survives resize and mode/tab switches after creation.
                let newView = try XCTUnwrap(workspace.preview.editor)
                let steadyPixels = try backgroundPixels(newView)
                workspace.editor.loading = true
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertFalse(newView.isEditable, "Loading must still block input")
                XCTAssertEqual(try backgroundPixels(newView), steadyPixels, "Loading erased the placeholder")
                workspace.editor.readOnly = true
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertNil(newView.accessibilityPlaceholderValue())
                XCTAssertNotEqual(try backgroundPixels(newView), steadyPixels, "Read-only placeholder must be hidden")
                workspace.editor.readOnly = false
                workspace.editor.loading = false
                for mode in DocumentViewMode.allCases {
                    workspace.preview.mode = mode
                    for width: CGFloat in [1, 420, 900, 4096] {
                        host.setFrameSize(NSSize(width: width, height: 560))
                        host.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                workspace.preview.mode = .editor
                if let oldID {
                    workspace.activateTab(oldID)
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
                workspace.activateTab(newID)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                XCTAssertTrue(workspace.preview.editor === newView)
                XCTAssertTrue(frame().placeholder)
                XCTAssertFalse(window.isVisible)
                await workspace.didCloseWindow()
            }
        }
    }
}

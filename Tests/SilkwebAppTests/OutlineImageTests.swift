import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import SilkwebCore
@testable import Silkweb

final class OutlineImageTests: XCTestCase {
    @MainActor
    func testRealDetailImageOutlineNavigationResizeAndPersistence() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = disposableDefaults("OutlineImages")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "![Before](landscape.png)\n# Journey\n## Places\n![Portrait](portrait.png)\n### Detail\n![Transparent](transparent.png)\n## Other\n![Missing](missing.png)\n![Remote](https://example.invalid/image.png)\n"
        let document = root.appendingPathComponent("Document.md")
        let original = Data(source.utf8)
        try original.write(to: document)
        for (name, width, height) in [("landscape.png", 400, 240), ("portrait.png", 80, 240), ("transparent.png", 120, 80)] {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.systemBlue.cgColor); context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false; workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let opened = await workspace.openTab(try XCTUnwrap(workspace.snapshot?.documents.first), pinned: true)
        XCTAssertTrue(opened)
        workspace.preview.showsOutline = true
        let controller = LibrarySplitViewController(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        controller.view.layoutSubtreeIfNeeded()
        try await waitUntil("debounced outline items and attached editor") {
            controller.view.layoutSubtreeIfNeeded()
            return !workspace.preview.outlineItems.isEmpty && workspace.preview.editor != nil
        }
        controller.view.layoutSubtreeIfNeeded()
        let items = workspace.preview.outlineItems
        XCTAssertEqual(items.map(\.label), ["Before", "Journey", "Places", "Portrait", "Detail", "Transparent", "Other", "Missing", "Remote"])
        let images = items.filter { if case .image = $0.content { return true }; return false }
        XCTAssertEqual(images.count, 5)
        for (index, item) in images.enumerated() {
            guard case .image(let reference) = item.content else { continue }
            let loaded = await OutlineImageRow.load(reference, document: document, root: root, pixels: 64)
            if index < 3 {
                let bitmap = try XCTUnwrap(loaded.bitmap)
                XCTAssertLessThanOrEqual(max(bitmap.width, bitmap.height), 64)
            } else { XCTAssertNil(loaded.bitmap); XCTAssertEqual(loaded.symbol, index == 3 ? "exclamationmark.triangle" : "photo") }
        }
        // The offscreen host does not expose SwiftUI Button accessibility nodes.
        // Snapshot scenarios verify the rendered rows; exercise their production
        // navigation action directly against the editor in this real hierarchy.
        let editor = try XCTUnwrap(workspace.preview.editor)
        for mode in DocumentViewMode.allCases {
            workspace.preview.mode = mode
            workspace.preview.showsOutline = true
            for size in [NSSize(width: 1000, height: 500), NSSize(width: 1400, height: 900), NSSize(width: 1900, height: 1200)] {
                window.setContentSize(size); controller.view.layoutSubtreeIfNeeded()
                // WebKit cannot execute in this host. Verify the retained request
                // for the next preview load, alongside real editor navigation.
                let webView = workspace.preview.webView
                workspace.preview.webView = nil
                for item in images {
                    workspace.preview.navigate(item) // Same production action used by Button and Return.
                    XCTAssertEqual(editor.selectedRange().location, item.sourceRange.location)
                    if mode != .preview { XCTAssertEqual(workspace.preview.currentItem(caret: item.sourceRange.location), item.id) }
                    if mode != .editor { XCTAssertEqual(workspace.preview.pendingAnchor, item.id) }
                }
                workspace.preview.webView = webView
                await Task.yield()
            }
        }
        workspace.preview.mode = .editor
        for caret in 0...source.utf16.count {
            let image = images.first { NSLocationInRange(caret, $0.sourceRange) }
            XCTAssertEqual(workspace.preview.currentItem(caret: caret), image?.id ?? workspace.preview.currentHeading(caret: caret))
        }
        await workspace.editor.flush()
        XCTAssertEqual(try Data(contentsOf: document), original)
        XCTAssertFalse(window.isVisible)
    }

    func testTwoHundredThumbnailsReuseCacheAndInvalidate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("image.png")
        func write(_ width: Int) throws {
            let context = try XCTUnwrap(CGContext(data: nil, width: width, height: 100, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.systemBlue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: 100))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        try write(400)
        let firstResult = await ImageThumbnailCache.shared.load(file, pixels: 64)
        let first = try XCTUnwrap(firstResult)
        for _ in 0..<200 {
            let nextResult = await ImageThumbnailCache.shared.load(file, pixels: 64)
            let next = try XCTUnwrap(nextResult)
            XCTAssertTrue(first.bitmap === next.bitmap)
        }
        try write(100)
        let changedResult = await ImageThumbnailCache.shared.load(file, pixels: 64)
        let changed = try XCTUnwrap(changedResult)
        XCTAssertEqual(first.naturalSize.width, 400)
        XCTAssertGreaterThan(changed.bitmap.height, first.bitmap.height)
        XCTAssertEqual(changed.naturalSize.width, 100)
        let smallResult = await ImageThumbnailCache.shared.load(file, pixels: 32)
        let small = try XCTUnwrap(smallResult)
        XCTAssertLessThanOrEqual(max(small.bitmap.width, small.bitmap.height), 32)
    }
}

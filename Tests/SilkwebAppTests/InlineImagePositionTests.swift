import AppKit
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers
import XCTest
import SilkwebCore
@testable import Silkweb

final class InlineImagePositionTests: XCTestCase {
    /// Intercept the actual NSView mutations, including insertion at the default
    /// origin. Uses pre-existing APIs so this test can run unchanged before the fix.
    @MainActor
    func testHeadingEditsNeverExposeUnpositionedImages() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Silkweb.ImagePositions." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) { UserDefaults.standard.removeObject(forKey: key) }
        }
        let context = try XCTUnwrap(CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent("image.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = "# Heading\n\n![First](image.png)\n\n" + String(repeating: "A paragraph with words.\n\n", count: 1000)
            + "![Middle](image.png)\n\nMore words.\n\n![Last](image.png)\n"
        try Data(source.utf8).write(to: root.appendingPathComponent("Document.md"))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false; workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let opened = await workspace.openTab(try XCTUnwrap(workspace.snapshot?.documents.first), pinned: true)
        XCTAssertTrue(opened)
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: suite)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        struct Sample { let frame: NSRect; let hidden: Bool; let expectedY: CGFloat; let event: String }
        var samples: [Sample] = []
        func record(_ view: InlineImageView, event: String) {
            guard view.superview != nil, let editor = view.editor, let layout = editor.layoutManager else { return }
            let frame = view.frame, hidden = view.isHidden
            if hidden {
                samples.append(Sample(frame: frame, hidden: true, expectedY: 0, event: event))
                return
            }
            let source = editor.string as NSString
            let marker = source.range(of: "![\(view.content.reference.alt)]")
            guard marker.location != NSNotFound else { return }
            let range = source.lineRange(for: marker)
            let glyph = layout.glyphIndexForCharacter(at: NSMaxRange(range) - 1)
            let expected = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true).maxY + editor.textContainerOrigin.y + 6
            samples.append(Sample(frame: frame, hidden: hidden, expectedY: expected, event: event))
        }
        // Add overrides only to InlineImageView, restoring every implementation on exit.
        // No global NSView swizzle and no production-only instrumentation dependency.
        var restores: [(Method, IMP, IMP)] = []
        func hook(_ selector: Selector, block: Any) throws {
            let inherited = try XCTUnwrap(class_getInstanceMethod(InlineImageView.self, selector))
            let old = method_getImplementation(inherited)
            let replacement = imp_implementationWithBlock(block)
            class_addMethod(InlineImageView.self, selector, old, method_getTypeEncoding(inherited))
            let method = try XCTUnwrap(class_getInstanceMethod(InlineImageView.self, selector))
            method_setImplementation(method, replacement)
            restores.append((method, old, replacement))
        }
        defer { for (method, old, replacement) in restores { method_setImplementation(method, old); imp_removeBlock(replacement) } }
        let moveSelector = #selector(NSView.viewDidMoveToSuperview)
        let moveIMP = method_getImplementation(try XCTUnwrap(class_getInstanceMethod(InlineImageView.self, moveSelector)))
        try hook(moveSelector, block: { (view: InlineImageView) in
            unsafeBitCast(moveIMP, to: (@convention(c) (AnyObject, Selector) -> Void).self)(view, moveSelector)
            record(view, event: "added")
        } as @convention(block) (InlineImageView) -> Void)
        let hiddenSelector = #selector(setter: NSView.isHidden)
        let hiddenIMP = method_getImplementation(try XCTUnwrap(class_getInstanceMethod(InlineImageView.self, hiddenSelector)))
        try hook(hiddenSelector, block: { (view: InlineImageView, hidden: Bool) in
            unsafeBitCast(hiddenIMP, to: (@convention(c) (AnyObject, Selector, Bool) -> Void).self)(view, hiddenSelector, hidden)
            record(view, event: "visibility")
        } as @convention(block) (InlineImageView, Bool) -> Void)
        for selector in [#selector(NSView.setFrameOrigin(_:)), #selector(NSView.setFrameSize(_:))] {
            let original = method_getImplementation(try XCTUnwrap(class_getInstanceMethod(InlineImageView.self, selector)))
            try hook(selector, block: { (view: InlineImageView, value: NSPoint) in
                unsafeBitCast(original, to: (@convention(c) (AnyObject, Selector, NSPoint) -> Void).self)(view, selector, value)
                record(view, event: "frame")
            } as @convention(block) (InlineImageView, NSPoint) -> Void)
        }
        let frameSelector = #selector(setter: NSView.frame)
        let frameIMP = method_getImplementation(try XCTUnwrap(class_getInstanceMethod(InlineImageView.self, frameSelector)))
        try hook(frameSelector, block: { (view: InlineImageView, frame: NSRect) in
            unsafeBitCast(frameIMP, to: (@convention(c) (AnyObject, Selector, NSRect) -> Void).self)(view, frameSelector, frame)
            record(view, event: "frame rect")
        } as @convention(block) (InlineImageView, NSRect) -> Void)
        window.contentViewController = controller
        func settle() async throws {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(650))
            controller.view.layoutSubtreeIfNeeded()
        }
        try await settle()
        let editor = try XCTUnwrap(workspace.preview.editor)
        for hidden in [true, false, true, false] {
            if workspace.sidebarsHidden != hidden { workspace.toggleSidebars() }
            for width in [1000.0, 1800.0, 1400.0] {
                window.setContentSize(NSSize(width: width, height: 900))
                try await settle()
                let previous = editor.inlineImages.imageViews
                for text in ["x", "🙂", " longer heading", "\nnew line", ""] {
                    editor.insertText(text, replacementRange: NSRange(location: 2, length: text.isEmpty ? 1 : 0))
                    // The immediate path must neither recreate/decode images nor force
                    // positioning/full-document layout with obsolete paragraph offsets.
                    let unlaid = editor.layoutManager?.firstUnlaidCharacterIndex()
                    editor.inlineImages.positionViews()
                    XCTAssertEqual(editor.layoutManager?.firstUnlaidCharacterIndex(), unlaid, "positioning must not advance TextKit layout per keystroke")
                    XCTAssertTrue(zip(previous, editor.inlineImages.imageViews).allSatisfy { $0 === $1 })
                    XCTAssertTrue(editor.inlineImages.imageViews.allSatisfy(\.isHidden))
                }
                try await settle()
                XCTAssertEqual(editor.inlineImages.imageViews.count, 3)
                XCTAssertTrue(editor.inlineImages.imageViews.allSatisfy { !$0.isHidden })
            }
        }
        XCTAssertTrue(samples.contains { !$0.hidden })
        XCTAssertTrue(samples.contains { $0.event == "frame" })
        let invalid = samples.filter { !$0.hidden && abs($0.frame.minY - $0.expectedY) > 0.5 }
        XCTAssertTrue(invalid.isEmpty, "Visible overlays outside their source slot: \(invalid.prefix(8))")
        print("Inline image sweep: \(samples.count) mutations, \(invalid.count) visible slot violations; 60 rapid edits across 12 width/sidebar combinations")
        XCTAssertFalse(window.isVisible)
    }
}

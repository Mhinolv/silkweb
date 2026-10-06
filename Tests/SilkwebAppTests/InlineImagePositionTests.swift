import AppKit
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers
import XCTest
import SilkwebCore
@testable import Silkweb

final class InlineImagePositionTests: XCTestCase {
    /// An inline image behaves like a glyph: at every display pass it is visible and in
    /// its own slot, while typing anywhere, switching Split/Editor/Preview and toggling
    /// sidebars. Samples are taken in the editor's real draw callback (the frame the user
    /// sees) and on every visibility mutation, so hide/show blinks and stale frames both fail.
    @MainActor
    func testImagesStayVisibleInTheirSlotAtEveryDisplay() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = disposableDefaults("ImagePositions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        // Large enough that a wider column requests a sharper decode (Split -> Editor).
        let context = try XCTUnwrap(CGContext(data: nil, width: 1600, height: 400, bitsPerComponent: 8, bytesPerRow: 6400,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent("image.png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let source = "# Heading\n\nIntro words.\n\n![First](image.png)\n\nBetween first and middle.\n\n"
            + String(repeating: "A paragraph with words.\n\n", count: 1000)
            + "![Middle](image.png)\n\nMore words.\n\n![Last](image.png)\n\nClosing words.\n"
        try Data(source.utf8).write(to: root.appendingPathComponent("Document.md"))
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false; workspace.root = root
        workspace.preview.mode = .editor
        workspace.install(try await LibraryScanner.scan(root: root))
        let opened = await workspace.openTab(try XCTUnwrap(workspace.snapshot?.documents.first), pinned: true)
        XCTAssertTrue(opened)
        let controller = LibrarySplitViewController(workspace: workspace)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }

        struct Violation: CustomStringConvertible {
            let image: String; let phase: String; let hidden: Bool; let y: CGFloat; let expected: CGFloat
            var description: String { "\(image) [\(phase)] hidden=\(hidden) y=\(y) expected=\(expected)" }
        }
        var phase = "load"
        var violations: [Violation] = []
        var displaySamples = 0
        var checked: [String: Int] = [:]
        var shown: Set<ObjectIdentifier> = []
        var sampling = false
        /// Expected slot from already-computed TextKit geometry; nil when the line is
        /// not laid out or not inside the visible rect (nothing to see there).
        func expectedY(_ view: InlineImageView) -> CGFloat? {
            guard let editor = view.editor, let layout = editor.layoutManager else { return nil }
            let source = editor.string as NSString
            let marker = source.range(of: "![\(view.content.reference.alt)]")
            guard marker.location != NSNotFound else { return nil }
            let end = NSMaxRange(source.lineRange(for: marker)) - 1
            guard end < layout.firstUnlaidCharacterIndex() else { return nil }
            let glyph = layout.glyphIndexForCharacter(at: end)
            let line = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let y = line.maxY + editor.textContainerOrigin.y + 6
            let slot = NSRect(x: 0, y: line.minY + editor.textContainerOrigin.y, width: 1, height: y - line.minY + view.frame.height)
            return editor.visibleRect.intersects(slot) ? y : nil
        }
        func sampleDisplay(_ editor: PlainMarkdownTextView) {
            guard sampling, !editor.isHiddenOrHasHiddenAncestor, editor.window != nil else { return }
            displaySamples += 1
            for view in editor.inlineImages.imageViews where view.superview === editor {
                guard let expected = expectedY(view) else { continue }
                checked[String(phase.prefix(while: { $0 != " " })), default: 0] += 1
                if view.isHidden || abs(view.frame.minY - expected) > 1 {
                    violations.append(Violation(image: view.content.reference.alt, phase: phase, hidden: view.isHidden, y: view.frame.minY, expected: expected))
                }
            }
        }

        var restores: [(Method, IMP, IMP)] = []
        func hook(_ cls: AnyClass, _ selector: Selector, block: Any) throws -> IMP {
            let inherited = try XCTUnwrap(class_getInstanceMethod(cls, selector))
            let old = method_getImplementation(inherited)
            class_addMethod(cls, selector, old, method_getTypeEncoding(inherited))
            let method = try XCTUnwrap(class_getInstanceMethod(cls, selector))
            let current = method_getImplementation(method)
            let replacement = imp_implementationWithBlock(block)
            method_setImplementation(method, replacement)
            restores.append((method, current, replacement))
            return current
        }
        defer { for (method, old, replacement) in restores.reversed() { method_setImplementation(method, old); imp_removeBlock(replacement) } }
        let drawSelector = #selector(NSView.draw(_:))
        var drawIMP: IMP?
        drawIMP = try hook(PlainMarkdownTextView.self, drawSelector, block: { (editor: PlainMarkdownTextView, rect: NSRect) in
            sampleDisplay(editor)
            unsafeBitCast(drawIMP!, to: (@convention(c) (AnyObject, Selector, NSRect) -> Void).self)(editor, drawSelector, rect)
        } as @convention(block) (PlainMarkdownTextView, NSRect) -> Void)
        let hiddenSelector = #selector(setter: NSView.isHidden)
        var hiddenIMP: IMP?
        hiddenIMP = try hook(InlineImageView.self, hiddenSelector, block: { (view: InlineImageView, hidden: Bool) in
            unsafeBitCast(hiddenIMP!, to: (@convention(c) (AnyObject, Selector, Bool) -> Void).self)(view, hiddenSelector, hidden)
            // A previously shown image that hides again is a blink, wherever it is.
            if hidden, sampling, shown.contains(ObjectIdentifier(view)) {
                violations.append(Violation(image: view.content.reference.alt, phase: phase + " (hid)", hidden: true, y: view.frame.minY, expected: .nan))
            }
            if !hidden { shown.insert(ObjectIdentifier(view)) }
        } as @convention(block) (InlineImageView, Bool) -> Void)

        window.contentViewController = controller
        func display() { controller.view.layoutSubtreeIfNeeded(); window.displayIfNeeded() }
        func settle() async throws {
            display()
            try await Task.sleep(for: .milliseconds(700))
            display()
        }
        func panes() -> DocumentPanesController? {
            func find(_ controller: NSViewController) -> DocumentPanesController? {
                (controller as? DocumentPanesController) ?? controller.children.lazy.compactMap(find).first
            }
            return find(controller)
        }
        try await settle()
        let editor = try XCTUnwrap(workspace.preview.editor)
        // An offscreen NSTextView does not invalidate itself on edits as it does on screen;
        // dirty the visible rect so each sample is the frame the user would see.
        func redraw() { editor.setNeedsDisplay(editor.visibleRect); display() }
        window.setContentSize(NSSize(width: 1300, height: 900))
        try await settle()
        window.setContentSize(NSSize(width: 1400, height: 900))
        try await settle()
        XCTAssertGreaterThan(editor.visibleRect.height, 400, "the offscreen detail hierarchy must be laid out")
        XCTAssertEqual(editor.inlineImages.imageViews.count, 3)
        for view in editor.inlineImages.imageViews where !view.isHidden { shown.insert(ObjectIdentifier(view)) }
        sampling = true

        // (a) Typing in the heading, body text between images and far from any image.
        // Insert right after a phrase, so edits (and deleting the inserted text) keep it findable.
        func after(_ phrase: String, from fraction: Int = 0) -> () -> Int {
            {
                let source = editor.string as NSString
                let start = fraction == 0 ? 0 : source.length / fraction
                let found = source.range(of: phrase, options: [], range: NSRange(location: start, length: source.length - start))
                return found.location == NSNotFound ? 2 : NSMaxRange(found)
            }
        }
        let anchors: [(String, () -> Int)] = [
            ("heading", { 2 }),
            ("intro above first", after("Intro")),
            ("between first and middle", after("Between")),
            ("far body", after("A paragraph", from: 2)),
            ("between middle and last", after("More")),
            ("below last", after("Closing")),
        ]
        for hidden in [true, false] {
            if workspace.sidebarsHidden != hidden { workspace.toggleSidebars() }
            try await settle()
            let previous = editor.inlineImages.imageViews
            for (name, anchor) in anchors {
                editor.scrollRangeToVisible(NSRange(location: anchor(), length: 0))
                try await settle()
                for text in ["x", "🙂", " longer text", "\nnew line", "", "\n"] {
                    phase = "typing \(name) sidebarsHidden=\(hidden) \(text.debugDescription)"
                    let location = anchor()
                    editor.insertText(text, replacementRange: NSRange(location: location, length: text.isEmpty ? 1 : 0))
                    // The very next frame, before any queued work runs.
                    redraw()
                    // Immediate path stays cheap: no forced full-document layout.
                    let unlaid = editor.layoutManager?.firstUnlaidCharacterIndex()
                    editor.inlineImages.positionViews()
                    XCTAssertEqual(editor.layoutManager?.firstUnlaidCharacterIndex(), unlaid, "positioning must not advance TextKit layout per keystroke")
                    await Task.yield()
                    redraw()
                }
                // Return (list-aware newline command) and ⌫ shift every image below by a line.
                phase = "typing \(name) sidebarsHidden=\(hidden) return/backspace"
                editor.setSelectedRange(NSRange(location: anchor(), length: 0))
                editor.insertNewline(nil); redraw(); await Task.yield(); redraw()
                editor.deleteBackward(nil); redraw(); await Task.yield(); redraw()
                try await settle()
            }
            XCTAssertTrue(zip(previous, editor.inlineImages.imageViews).allSatisfy { $0 === $1 }, "edits must keep existing image views")
        }
        // Long-note guard: positioning reads cached TextKit geometry only (bounded by the
        // image count), so per-keystroke/per-display cost stays flat on a 1,000-paragraph note.
        let start = Date()
        for _ in 0..<1000 { editor.inlineImages.positionViews() }
        let perCall = Date().timeIntervalSince(start) / 1000
        XCTAssertLessThan(perCall, 0.001, "positionViews must stay sub-millisecond on a long note")
        print("positionViews on 1,000-paragraph note: \(String(format: "%.1f", perCall * 1_000_000)) µs per call")

        // (b) Split <-> Editor <-> Preview switches; (c) sidebars and window widths.
        editor.scrollRangeToVisible(NSRange(location: 0, length: 0))
        let modes: [DocumentViewMode] = [.split, .editor, .split, .preview, .editor, .split, .editor]
        for hidden in [true, false, true] {
            if workspace.sidebarsHidden != hidden {
                phase = "toggle sidebars hidden=\(hidden)"
                workspace.toggleSidebars(); redraw(); await Task.yield(); redraw()
                try await settle(); redraw()
            }
            for width in [1400.0, 1000.0, 1800.0] {
                phase = "width \(width) sidebarsHidden=\(hidden)"
                window.setContentSize(NSSize(width: width, height: 900)); redraw(); await Task.yield(); redraw()
                try await settle(); redraw()
                for mode in modes {
                    phase = "mode \(mode) width \(width) sidebarsHidden=\(hidden)"
                    workspace.preview.mode = mode
                    panes()?.updateMode()
                    redraw(); await Task.yield(); redraw()
                    try await Task.sleep(for: .milliseconds(30)); redraw()
                    // After the debounced re-decode at the new column width.
                    try await settle(); redraw()
                }
            }
        }
        sampling = false
        XCTAssertEqual(editor.inlineImages.imageViews.count, 3)
        XCTAssertGreaterThan(displaySamples, 100, "the editor's draw callback must be sampled")
        for kind in ["typing", "mode", "width"] { XCTAssertGreaterThan(checked[kind] ?? 0, 5, "visible images checked while \(kind)") }
        XCTAssertTrue(violations.isEmpty, "\(violations.count) hidden/misplaced image samples of \(displaySamples) displays: \(violations.prefix(10))")
        print("Inline image display sweep: \(displaySamples) editor draws, visible-image checks \(checked), \(violations.count) violations")
        XCTAssertFalse(window.isVisible)
    }
}

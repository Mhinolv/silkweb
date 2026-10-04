import AppKit
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers
import XCTest
import SilkwebCore
@testable import Silkweb

/// Counters fed by the Objective-C hooks below. Hooks only use pre-existing AppKit
/// selectors, so this file builds unchanged on the pre-1.66 tree.
@MainActor private final class ScrollWork {
    var editor: PlainMarkdownTextView?
    var recording = false
    var bitmapRasterizations = 0
    var imageDraws = 0
    var overlayMoves = 0
    var fullLayouts = 0
    var sizeToFits = 0
    var geometryWrites: [String: Int] = [:]
    static let shared = ScrollWork()
}

final class ScrollPerformanceTests: XCTestCase {
    /// silkweb-1.66: passive momentum scrolling of a long note with local inline images, in
    /// the real detail hierarchy with the Outline open, in Editor and Split. Every step is a
    /// clip-view bounds change plus the display of the newly exposed band (what AppKit does
    /// per frame on screen). Main-thread time per step must fit a 120 Hz frame (p95 ≤ 4 ms),
    /// and scrolling must not rasterize image bitmaps, move overlays, re-size or fully lay
    /// out the document, rewrite editor geometry or publish workspace state.
    @MainActor
    func testMomentumScrollStaysWithinFrameBudgetOnLongNoteWithImages() async throws {
        try await momentumScroll(focus: false, typewriter: false)
    }

    /// silkweb-1.27: the same budget and counters with Focus and/or Typewriter on.
    @MainActor
    func testMomentumScrollBudgetWithFocusMode() async throws {
        try await momentumScroll(focus: true, typewriter: false)
    }

    @MainActor
    func testMomentumScrollBudgetWithTypewriterMode() async throws {
        try await momentumScroll(focus: false, typewriter: true)
    }

    @MainActor
    func testMomentumScrollBudgetWithFocusAndTypewriterModes() async throws {
        try await momentumScroll(focus: true, typewriter: true)
    }

    @MainActor
    private func momentumScroll(focus: Bool, typewriter: Bool) async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Silkweb.ScrollPerformance." + UUID().uuidString
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) { UserDefaults.standard.removeObject(forKey: key) }
        }
        let imageCount = 20, paragraphs = 2_000
        for index in 0..<imageCount {
            let context = try XCTUnwrap(CGContext(data: nil, width: 1200, height: 700, bitsPerComponent: 8, bytesPerRow: 4800,
                                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor(hue: CGFloat(index) / CGFloat(imageCount), saturation: 0.6, brightness: 0.8, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 700))
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(root.appendingPathComponent("image\(index).png") as CFURL, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
        }
        var text = ""
        let every = paragraphs / imageCount
        for index in 0..<paragraphs {
            if index % 10 == 0 { text += "## Section \(index)\n\n" }
            text += "Paragraph \(index) with **bold**, `code`, Unicode café 日本語 and enough words that the line wraps across the column in both modes.\n\n"
            if index % every == every / 2 { text += "![Figure \(index / every)](image\(index / every).png)\n\n" }
        }
        try text.write(to: root.appendingPathComponent("Long.md"), atomically: true, encoding: .utf8)

        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.preview.showsOutline = true
        workspace.inspectorInfo = false
        workspace.install(try await LibraryScanner.scan(root: root))
        let opened = await workspace.openTab(try XCTUnwrap(workspace.snapshot?.documents.first { $0.relativePath == "Long.md" }), pinned: true)
        XCTAssertTrue(opened)
        let controller = LibrarySplitViewController(workspace: workspace, autosaveName: suite)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        window.setContentSize(NSSize(width: 1300, height: 900))
        window.setContentSize(NSSize(width: 1400, height: 900))
        workspace.setWritingModes(focus: focus, typewriter: typewriter)

        let work = ScrollWork.shared
        var restores: [(Method, IMP, IMP)] = []
        defer {
            for (method, old, replacement) in restores.reversed() { method_setImplementation(method, old); imp_removeBlock(replacement) }
            work.recording = false; work.editor = nil
        }
        /// Replaces `selector` on `cls` only (copying an inherited implementation down first).
        func hook(_ cls: AnyClass, _ selector: Selector, _ make: (IMP) -> Any) throws {
            let inherited = try XCTUnwrap(class_getInstanceMethod(cls, selector))
            class_addMethod(cls, selector, method_getImplementation(inherited), method_getTypeEncoding(inherited))
            let method = try XCTUnwrap(class_getInstanceMethod(cls, selector))
            let old = method_getImplementation(method)
            let replacement = imp_implementationWithBlock(make(old))
            method_setImplementation(method, replacement)
            restores.append((method, old, replacement))
        }
        func mine(_ object: AnyObject) -> Bool {
            MainActor.assumeIsolated {
                guard work.recording, let editor = work.editor else { return false }
                return object === editor || object === editor.textContainer || object === editor.layoutManager
                    || object === editor.enclosingScrollView || (object as? NSView)?.superview === editor
            }
        }
        func count(_ key: String) { MainActor.assumeIsolated { work.geometryWrites[key, default: 0] += 1 } }
        typealias RectIMP = @convention(c) (AnyObject, Selector, NSRect) -> Void
        typealias PointIMP = @convention(c) (AnyObject, Selector, NSPoint) -> Void
        typealias SizeIMP = @convention(c) (AnyObject, Selector, NSSize) -> Void
        typealias InsetsIMP = @convention(c) (AnyObject, Selector, NSEdgeInsets) -> Void
        typealias ObjectIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias VoidIMP = @convention(c) (AnyObject, Selector) -> Void
        let draw = #selector(NSView.draw(_:))
        try hook(InlineImageView.self, draw) { old in { (view: InlineImageView, rect: NSRect) in
            if mine(view) {
                MainActor.assumeIsolated {
                    work.imageDraws += 1
                    if view.content.bitmap != nil { work.bitmapRasterizations += 1 }
                }
            }
            unsafeBitCast(old, to: RectIMP.self)(view, draw, rect)
        } as @convention(block) (InlineImageView, NSRect) -> Void }
        let origin = #selector(NSView.setFrameOrigin(_:))
        try hook(InlineImageView.self, origin) { old in { (view: InlineImageView, point: NSPoint) in
            if mine(view), view.frame.origin != point { MainActor.assumeIsolated { work.overlayMoves += 1 } }
            unsafeBitCast(old, to: PointIMP.self)(view, origin, point)
        } as @convention(block) (InlineImageView, NSPoint) -> Void }
        let ensure = #selector(NSLayoutManager.ensureLayout(for:) as (NSLayoutManager) -> (NSTextContainer) -> Void)
        try hook(NSLayoutManager.self, ensure) { old in { (layout: NSLayoutManager, container: NSTextContainer) in
            if mine(layout) { MainActor.assumeIsolated { work.fullLayouts += 1 } }
            unsafeBitCast(old, to: ObjectIMP.self)(layout, ensure, container)
        } as @convention(block) (NSLayoutManager, NSTextContainer) -> Void }
        let fit = #selector(NSText.sizeToFit)
        try hook(PlainMarkdownTextView.self, fit) { old in { (view: PlainMarkdownTextView) in
            if mine(view) { MainActor.assumeIsolated { work.sizeToFits += 1 } }
            unsafeBitCast(old, to: VoidIMP.self)(view, fit)
        } as @convention(block) (PlainMarkdownTextView) -> Void }
        let frameSize = #selector(NSView.setFrameSize(_:))
        try hook(PlainMarkdownTextView.self, frameSize) { old in { (view: PlainMarkdownTextView, size: NSSize) in
            if mine(view), view.frame.size != size { count("editor frame") }
            unsafeBitCast(old, to: SizeIMP.self)(view, frameSize, size)
        } as @convention(block) (PlainMarkdownTextView, NSSize) -> Void }
        let inset = #selector(setter: NSTextView.textContainerInset)
        try hook(PlainMarkdownTextView.self, inset) { old in { (view: PlainMarkdownTextView, size: NSSize) in
            if mine(view) { count("textContainerInset") }
            unsafeBitCast(old, to: SizeIMP.self)(view, inset, size)
        } as @convention(block) (PlainMarkdownTextView, NSSize) -> Void }
        let minimum = #selector(setter: NSText.minSize)
        try hook(PlainMarkdownTextView.self, minimum) { old in { (view: PlainMarkdownTextView, size: NSSize) in
            if mine(view) { count("minSize") }
            unsafeBitCast(old, to: SizeIMP.self)(view, minimum, size)
        } as @convention(block) (PlainMarkdownTextView, NSSize) -> Void }
        let containerSize = #selector(setter: NSTextContainer.size)
        try hook(NSTextContainer.self, containerSize) { old in { (container: NSTextContainer, size: NSSize) in
            if mine(container) { count("containerSize") }
            unsafeBitCast(old, to: SizeIMP.self)(container, containerSize, size)
        } as @convention(block) (NSTextContainer, NSSize) -> Void }
        for selector in [#selector(setter: NSScrollView.contentInsets), #selector(setter: NSScrollView.scrollerInsets)] {
            try hook(EditorScrollView.self, selector) { old in { (scroll: EditorScrollView, insets: NSEdgeInsets) in
                if mine(scroll) { count(NSStringFromSelector(selector)) }
                unsafeBitCast(old, to: InsetsIMP.self)(scroll, selector, insets)
            } as @convention(block) (EditorScrollView, NSEdgeInsets) -> Void }
        }

        /// Everything the detail chrome and Inspector Outline observe while a note is open.
        var publishes = 0
        var observing = false
        func observeChrome() {
            withObservationTracking {
                let session = workspace.editor
                _ = (session.text, session.url, session.state, session.caretLocation, session.loading, session.readOnly,
                     session.banner, session.assetProgress, session.refusedNavigation)
                // silkweb-1.25: the status-bar counts publish only after edits or selection changes.
                _ = (session.statistics.document, session.statistics.selection)
                _ = (workspace.tabs, workspace.activeTabID, workspace.focusRequest, workspace.focusColumn, workspace.revision,
                     workspace.inspectorInfo, workspace.sidebarsHidden, workspace.snapshot?.documents.count, workspace.session.selectedDocuments)
                let preview = workspace.preview
                _ = (preview.mode, preview.showsOutline, preview.headings, preview.outlineItems, preview.renderedURL,
                     preview.currentItem(caret: session.caretLocation))
            } onChange: {
                Task { @MainActor in
                    guard observing else { return }
                    publishes += 1
                    observeChrome()
                }
            }
        }

        func settle() async throws {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(1_200))
            controller.view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        for mode in [DocumentViewMode.editor, .split] {
            workspace.preview.mode = mode
            try await settle()
            let editor = try XCTUnwrap(workspace.preview.editor)
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            XCTAssertGreaterThan(editor.visibleRect.height, 400, "the offscreen detail hierarchy must be laid out")
            XCTAssertEqual(editor.inlineImages.imageViews.count, imageCount)
            XCTAssertTrue(editor.inlineImages.imageViews.allSatisfy { $0.content.bitmap != nil }, "images decoded before scrolling")
            XCTAssertEqual(editor.writingModes.focus, focus)
            XCTAssertEqual(editor.writingModes.typewriter, typewriter)
            if typewriter { XCTAssertGreaterThan(scroll.contentInsets.bottom, 0) }
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle()
            work.editor = editor
            work.bitmapRasterizations = 0; work.imageDraws = 0; work.overlayMoves = 0
            work.fullLayouts = 0; work.sizeToFits = 0; work.geometryWrites = [:]
            publishes = 0
            observing = true
            observeChrome()
            let renders = workspace.preview.renderCount
            let counts = workspace.editor.statistics.refreshCount
            XCTAssertNotNil(workspace.editor.statistics.document, "counts computed off the main thread before scrolling")
            let frames = editor.inlineImages.imageViews.map(\.frame)
            var entered = Set<ObjectIdentifier>()
            var times: [Double] = [], wall: [Double] = []
            var faded: [String] = []
            let bottom = editor.frame.height - scroll.contentSize.height
            XCTAssertGreaterThan(bottom, 100_000, "a long note")
            /// One momentum frame: move the clip view, then draw only the newly exposed band.
            func step(to y: CGFloat) {
                let previous = scroll.contentView.bounds.minY
                let start = DispatchTime.now().uptimeNanoseconds
                let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                let visible = editor.visibleRect
                let delta = min(visible.height, abs(visible.minY - previous))
                editor.setNeedsDisplay(y > previous ? NSRect(x: visible.minX, y: visible.maxY - delta, width: visible.width, height: delta)
                                                    : NSRect(x: visible.minX, y: visible.minY, width: visible.width, height: delta))
                editor.displayIfNeeded()
                RunLoop.current.run(mode: .default, before: Date())
                times.append(Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpu) / 1e6)
                wall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
                for view in editor.inlineImages.imageViews where view.frame.intersects(visible) {
                    entered.insert(ObjectIdentifier(view))
                    // Focus Mode holds every image at dimmed text's opacity (1.27, 1.68).
                    let opacity = focus ? WritingModeController.dimmedOpacity : 1
                    if view.isHidden || abs(view.alphaValue - opacity) > 0.001 { faded.append(view.content.reference.alt) }
                }
            }
            // AppKit's one-time first-scroll setup (scroller, tracking areas) is not per-frame work.
            step(to: 10)
            times = []; wall = []
            work.recording = true
            var y: CGFloat = 10
            while y < bottom { y = min(bottom, y + 90); step(to: y) }
            for _ in 0..<300 { y = max(0, y - 45); step(to: y) }
            work.recording = false
            try await Task.sleep(for: .milliseconds(50))
            observing = false

            let sorted = times.sorted()
            let p95 = sorted[Int(Double(sorted.count) * 0.95)]
            let wallSorted = wall.sorted()
            let summary = "mode \(mode): \(times.count) steps, main-thread CPU p95 \(String(format: "%.3f", p95)) ms, max \(String(format: "%.3f", sorted.last ?? 0)) ms, "
                + "wall p95 \(String(format: "%.3f", wallSorted[Int(Double(wallSorted.count) * 0.95)])) ms, max \(String(format: "%.3f", wallSorted.last ?? 0)) ms, "
                + "bitmap rasterizations \(work.bitmapRasterizations), image draws \(work.imageDraws), overlay moves \(work.overlayMoves), "
                + "full layouts \(work.fullLayouts), sizeToFit \(work.sizeToFits), geometry \(work.geometryWrites), publishes \(publishes)"
            print("silkweb-1.66 scroll (focus \(focus), typewriter \(typewriter)): " + summary)
            XCTAssertGreaterThan(times.count, 300, "hundreds of scroll steps")
            XCTAssertEqual(entered.count, imageCount, "every image scrolled through the viewport")
            // CPU time of the main thread, so a loaded test machine descheduling the process
            // does not fail the frame budget; wall time is reported alongside.
            XCTAssertLessThanOrEqual(p95, TestEnvironment.frameBudget(4), "main-thread p95 per scroll step: " + summary)
            XCTAssertEqual(work.bitmapRasterizations, 0, "decoded images must not be rasterized on the main thread while scrolling: " + summary)
            XCTAssertEqual(work.overlayMoves, 0, "overlays move only when geometry changes: " + summary)
            XCTAssertEqual(work.fullLayouts, 0, "no full-document layout during scroll: " + summary)
            XCTAssertEqual(work.sizeToFits, 0, "no document re-sizing during scroll: " + summary)
            XCTAssertEqual(work.geometryWrites, [:], "layoutEditor must not rewrite geometry during scroll: " + summary)
            XCTAssertEqual(publishes, 0, "scrolling must not publish workspace/session state: " + summary)
            XCTAssertEqual(workspace.preview.renderCount, renders, "scrolling must not re-render the preview")
            XCTAssertEqual(workspace.editor.statistics.refreshCount, counts, "scrolling must not recount the document")
            XCTAssertEqual(faded, [], "already-decoded images scroll in opaque and visible")
            XCTAssertEqual(editor.inlineImages.imageViews.map(\.frame), frames, "overlays stay in their slots")
            // On screen the GPU composites the decoded bitmap; offscreen captures still draw it.
            let image = try XCTUnwrap(editor.inlineImages.imageViews.first)
            step(to: max(0, image.frame.minY - 100))
            XCTAssertTrue(image.layer?.contents as AnyObject? === image.content.bitmap, "bitmap is the layer contents")
            let capture = try XCTUnwrap(image.bitmapImageRepForCachingDisplay(in: image.bounds))
            image.cacheDisplay(in: image.bounds, to: capture)
            let center = try XCTUnwrap(capture.colorAt(x: capture.pixelsWide / 2, y: capture.pixelsHigh / 2)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(center.saturationComponent, 0.3, "cacheDisplay renders the image, not an empty slot")
        }
        XCTAssertFalse(window.isVisible)
    }
}

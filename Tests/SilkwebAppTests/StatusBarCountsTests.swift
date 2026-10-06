import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// silkweb-1.25: live counts in the status strip, save state (and the 1.27 chip) trail. #91: the path leads and the
/// counts sit on the bar's midline.
@MainActor
final class StatusBarCountsTests: XCTestCase {
    static func accessibilityTree(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? nil) ?? []
        return [element] + children.flatMap { accessibilityTree($0 as AnyObject) }
    }
    static func label(_ element: AnyObject) -> String? { element.accessibilityLabel?() ?? nil }
    static func value(_ element: AnyObject) -> String? {
        let selector = NSSelectorFromString("accessibilityValue")
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
    static func frame(_ element: AnyObject) -> NSRect { element.accessibilityFrame?() ?? .zero }
    static func element(_ label: String, in root: AnyObject) -> AnyObject? {
        accessibilityTree(root).first { Self.label($0) == label }
    }
    /// SwiftUI builds its accessibility tree only for an assistive client; flag the app the way
    /// VoiceOver does so offscreen hosts expose it. Turned off again after each test.
    static func exposeAccessibility(_ on: Bool) {
        _ = NSApplication.shared
        (NSApp as NSObject).perform(
            NSSelectorFromString("accessibilitySetValue:forAttribute:"),
            with: NSNumber(value: on), with: "AXEnhancedUserInterface")
    }

    private struct Library {
        let root: URL, defaults: UserDefaults, workspace: LibraryWorkspace
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func library(_ body: String) async throws -> Library {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebStatusCounts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: root.appendingPathComponent("Note.md"))
        let defaults = disposableDefaults("StatusCounts")
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        return Library(root: root, defaults: defaults, workspace: workspace)
    }

    /// The real window hierarchy: path leading, counts centred, “Saved” trailing, selection “of” counts, Focus chip
    /// between the counts and the save state.
    func testRealHierarchyPathLeadsCountsCentreSaveStateTrailsAndSelectionShowsOf() async throws {
        let body =
            "# Counting\n\nKyoto rewards **slowness**. 京都 ☕️\n\n"
            + String(repeating: "Another sentence with five words.\n\n", count: 40)
        let fixture = try await library(body)
        defer { fixture.cleanUp() }
        Self.exposeAccessibility(true)
        defer { Self.exposeAccessibility(false) }
        let workspace = fixture.workspace
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
        controller.sizingOptions = []
        window.contentViewController = controller // Never ordered on screen.
        defer { window.contentViewController = nil; window.close() }
        func settle(_ milliseconds: Int = 450) async throws {
            for _ in 0..<3 {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(milliseconds / 3))
            }
        }
        let document = try XCTUnwrap(workspace.snapshot?.documents.first)
        let opened = await workspace.openTab(document, pinned: true)
        XCTAssertTrue(opened)
        try await settle()
        let expected = DocumentStatistics.count(body)
        XCTAssertEqual(expected.words, 1 + 3 + 2 + 1 + 40 * 5)

        let root = try XCTUnwrap(window.contentView)
        func strip() throws -> (counts: AnyObject, save: AnyObject, chip: AnyObject?) {
            let counts = try XCTUnwrap(Self.element("Document statistics", in: root), "counts element")
            let save = try XCTUnwrap(Self.element("Save state", in: root), "save element")
            return (counts, save, Self.element("Writing modes", in: root))
        }
        func path() throws -> BreadcrumbView {
            try XCTUnwrap(Self.descendants(root).compactMap { $0 as? BreadcrumbView }.first, "status bar path")
        }
        func assertLayout(_ context: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let (counts, save, chip) = try strip()
            let countsFrame = Self.frame(counts), saveFrame = Self.frame(save)
            let editor = try XCTUnwrap(workspace.preview.editor?.enclosingScrollView)
            let pane = editor.window!.convertToScreen(editor.convert(editor.bounds, to: nil))
            let path = try path()
            let pathFrame = window.convertToScreen(path.convert(path.bounds, to: nil))
            XCTAssertGreaterThan(countsFrame.width, 20, context, file: file, line: line)
            // Path text 16 pt from the detail column's leading edge (its hover padding reaches into the 16 pt).
            XCTAssertEqual(
                pathFrame.minX + BreadcrumbView.padding, pane.minX + 16, accuracy: 1, context, file: file, line: line)
            XCTAssertLessThanOrEqual(pathFrame.maxX + 12, countsFrame.minX + 0.5, context, file: file, line: line)
            // Counts on the detail column's midline whenever the path leaves room; save state 16 pt from its end.
            let centredFits =
                pathFrame.maxX + 12 <= pane.midX - countsFrame.width / 2 + 0.5
                && pane.midX + countsFrame.width / 2 <= (chip.map { Self.frame($0).minX } ?? saveFrame.minX) - 12 + 0.5
            if pane.width >= 900 { XCTAssertTrue(centredFits, context, file: file, line: line) }
            if centredFits {
                XCTAssertEqual(
                    countsFrame.midX, pane.midX, accuracy: 2, "counts centred: \(context)", file: file, line: line)
            }
            XCTAssertLessThan(countsFrame.maxX, saveFrame.minX, context, file: file, line: line)
            XCTAssertLessThanOrEqual(saveFrame.maxX, pane.maxX - 12, context, file: file, line: line)
            XCTAssertLessThanOrEqual(
                countsFrame.maxY, pane.minY + 4, "strip sits under the editor: \(context)", file: file, line: line)
            if let chip {
                let chipFrame = Self.frame(chip)
                XCTAssertLessThanOrEqual(
                    countsFrame.maxX, chipFrame.minX + 4, "counts vs chip: \(context)", file: file, line: line)
                XCTAssertLessThanOrEqual(
                    chipFrame.maxX, saveFrame.minX + 4, "chip vs save: \(context)", file: file, line: line)
            }
        }

        var (counts, save, _) = try strip()
        XCTAssertEqual(Self.value(counts), DocumentStatisticsPresentation.accessibilityValue(document: expected))
        XCTAssertEqual(Self.value(save), "Saved")
        // A document at the library root: `Library › Note`, the title not a link, no count.
        let pathElement = try XCTUnwrap(Self.element("Path", in: root), "path element")
        XCTAssertEqual(Self.value(pathElement), fixture.root.lastPathComponent + " › Note")
        XCTAssertEqual(try path().crumbButtons.map(\.isLink), [true])
        XCTAssertEqual(try path().currentLabel.stringValue, "Note")
        // VoiceOver order: Path, Document statistics, Writing modes, Save state.
        workspace.setWritingModes(focus: true, typewriter: false)
        try await settle()
        let order = Self.accessibilityTree(root).compactMap(Self.label).filter {
            ["Path", "Document statistics", "Writing modes", "Save state"].contains($0)
        }
        XCTAssertEqual(order, ["Path", "Document statistics", "Writing modes", "Save state"])
        workspace.setWritingModes(focus: false, typewriter: false)
        try await settle()
        try assertLayout("document totals")

        // A non-empty selection shows “N of M”; collapsing it reverts after the debounce.
        let editor = try XCTUnwrap(workspace.preview.editor)
        let selected = (editor.string as NSString).range(of: "Kyoto rewards **slowness**.")
        func waitForCounts(_ value: String, _ description: String) async throws {
            try await waitUntil(description) {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                return Self.value(try strip().counts) == value
            }
        }
        editor.setSelectedRange(selected)
        let selection = DocumentStatistics(words: 3, characters: 23)
        try await waitForCounts(
            DocumentStatisticsPresentation.accessibilityValue(document: expected, selection: selection),
            "selection counts")
        try await settle()
        counts = try strip().counts
        XCTAssertTrue(Self.value(counts)?.hasPrefix("Selection: 3 of ") == true)
        try assertLayout("selection")

        // The Focus chip (1.27) sits between them without overlap, across a resize sweep.
        workspace.setWritingModes(focus: true, typewriter: true)
        for size in [
            NSSize(width: 1400, height: 900), NSSize(width: 1000, height: 700), NSSize(width: 1800, height: 1000),
        ] {
            window.setContentSize(size)
            try await settle(300)
            XCTAssertNotNil(try strip().chip, "chip visible at \(size)")
            try assertLayout("focus chip at \(size)")
        }
        workspace.setWritingModes(focus: false, typewriter: false)

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await waitForCounts(
            DocumentStatisticsPresentation.accessibilityValue(document: expected),
            "collapsed selection reverts to totals")

        // Typing updates the totals after the debounce, never synchronously.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" extra words", replacementRange: editor.selectedRange())
        XCTAssertEqual(workspace.editor.statistics.document, expected, "no count work on the keystroke itself")
        try await waitUntil("debounced totals after typing") {
            workspace.editor.statistics.document?.words == expected.words + 2
        }

        // Preview-only keeps document totals visible and ignores the editor selection.
        editor.setSelectedRange(selected)
        workspace.preview.mode = .preview
        try await settle()
        counts = try strip().counts
        XCTAssertEqual(
            Self.value(counts),
            DocumentStatisticsPresentation.accessibilityValue(document: workspace.editor.statistics.document!))
        workspace.preview.mode = .editor
        try await settle()

        // View ▸ Show Status Bar (⌘/) hides and restores the whole strip; the choice persists.
        workspace.preview.showsStatusBar = false
        try await settle(200)
        XCTAssertNil(Self.element("Document statistics", in: root))
        XCTAssertNil(Self.element("Save state", in: root))
        XCTAssertNil(Self.element("Path", in: root), "⌘/ off: no path anywhere")
        XCTAssertTrue(Self.descendants(root).compactMap { $0 as? BreadcrumbView }.isEmpty)
        XCTAssertFalse(workspace.menuState.value.showsStatusBar)
        XCTAssertEqual(fixture.defaults.object(forKey: "Silkweb.Detail.StatusBar") as? Bool, false)
        XCTAssertFalse(PreviewCoordinator(defaults: fixture.defaults).showsStatusBar)
        workspace.preview.showsStatusBar = true
        try await settle(200)
        (counts, save, _) = try strip()
        try assertLayout("restored")
        XCTAssertFalse(window.isVisible)
    }

    /// The production strip on its own across a width sweep, with and without the chip and a selection. #91: the
    /// counts hide last, once even truncated words would touch the trailing cluster.
    func testNarrowWidthsDropCharactersBeforeTouchingTrailingCluster() async throws {
        Self.exposeAccessibility(true)
        defer { Self.exposeAccessibility(false) }
        let defaults = disposableDefaults("StatusCountsSweep")
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
        let session = DocumentSession()
        session.text = String(repeating: "word ", count: 1_204)
        session.selection = NSRange(location: 0, length: 5 * 38)
        session.statistics.refreshNow()
        XCTAssertEqual(session.statistics.document?.words, 1_204)
        XCTAssertEqual(session.statistics.selection?.words, 38)
        let host = NSHostingView(
            rootView: DocumentStatusBar(session: session, readOnlyLibrary: false, workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 26), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        var widths: [String: CGFloat] = [:]
        for chip in [false, true] {
            workspace.setWritingModes(focus: chip, typewriter: chip)
            for width: CGFloat in [1200, 640, 420, 360, 330, 300, 270, 240, 200, 160, 1200] {
                window.setContentSize(NSSize(width: width, height: 26))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                let context = "chip \(chip) width \(width)"
                let save = try XCTUnwrap(Self.element("Save state", in: host), context)
                let saveFrame = Self.frame(save)
                if width >= 360 { XCTAssertNotNil(Self.element("Document statistics", in: host), context) }
                guard let counts = Self.element("Document statistics", in: host) else {
                    widths["\(chip)-\(Int(width))"] = 0
                    continue
                }
                let countsFrame = Self.frame(counts)
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                XCTAssertEqual(host.fittingSize.height, Spacing.statusBarHeight, accuracy: 0.5)
                // The save label never truncates or leaves the strip; counts give way first.
                XCTAssertGreaterThanOrEqual(
                    saveFrame.width + 0.5,
                    ceil(
                        ("Saved" as NSString).size(withAttributes: [
                            .font: NSFont.preferredFont(forTextStyle: .subheadline)
                        ]).width) - 2, context)
                XCTAssertLessThanOrEqual(saveFrame.maxX, bounds.maxX - 16 + 0.5, context)
                // No path for a bare session: the counts are centred while they fit, else stay clear of the edge.
                XCTAssertGreaterThanOrEqual(countsFrame.minX, bounds.minX + 16, context)
                if width >= 640 {
                    XCTAssertEqual(countsFrame.midX, bounds.midX, accuracy: 1, "centred: \(context)")
                }
                if let chipElement = Self.element("Writing modes", in: host) {
                    XCTAssertTrue(chip, context)
                    let chipFrame = Self.frame(chipElement)
                    XCTAssertLessThanOrEqual(countsFrame.maxX, chipFrame.minX + 4, context)
                    XCTAssertLessThanOrEqual(chipFrame.maxX, saveFrame.minX + 4, context)
                } else {
                    XCTAssertFalse(chip, context)
                    XCTAssertLessThanOrEqual(countsFrame.maxX, saveFrame.minX + 4, context)
                }
                widths["\(chip)-\(Int(width))"] = countsFrame.width
            }
        }
        // Wide strips show both segments; narrow ones drop the characters segment, then truncate.
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        func measured(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let full = DocumentStatisticsPresentation.label(
            document: session.statistics.document!, selection: session.statistics.selection)
        let words = DocumentStatisticsPresentation.label(
            document: session.statistics.document!, selection: session.statistics.selection, includesCharacters: false)
        XCTAssertEqual(widths["false-1200"]!, measured(full), accuracy: 12)
        XCTAssertEqual(widths["true-360"]!, measured(words), accuracy: 12, "words-only fallback")
        XCTAssertTrue(
            widths.contains { $0.key.hasPrefix("true-") && $0.value > 0 && $0.value < measured(words) - 4 },
            "tail truncation before hiding: \(widths)")
        XCTAssertEqual(widths["true-160"], 0, "the counts hide last")
        XCTAssertEqual(widths["false-1200"]!, widths["true-1200"]!, accuracy: 0.5)
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// #91, the narrow rules on the production strip with a real deep path: the path folds first, then the counts
    /// leave the midline, then drop characters, then hide. The path, counts, chip and save state never overlap.
    func testNarrowWidthsFoldThePathBeforeTheCountsMoveThenHideThem() async throws {
        Self.exposeAccessibility(true)
        defer { Self.exposeAccessibility(false) }
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebStatusPath-" + UUID().uuidString)
        let root = container.appendingPathComponent("Field Notes")
        defer { try? FileManager.default.removeItem(at: container) }
        let deep = "Vanlife/North American Road Trips/Pennsylvania and the Great Lakes/Lake Erie Shoreline"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(deep), withIntermediateDirectories: true)
        let document = deep + "/Getting In Shape.md"
        try Data(String(repeating: "word ", count: 1_204).utf8).write(to: root.appendingPathComponent(document))
        let workspace = LibraryWorkspace(defaults: disposableDefaults("StatusPathSweep"))
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.navigate(folder: deep, documents: [document], pinned: true)
        await workspace.waitForNavigation()
        let session = workspace.editor
        session.statistics.refreshNow()
        XCTAssertEqual(session.statistics.document?.words, 1_204)
        let host = NSHostingView(
            rootView: DocumentStatusBar(session: session, readOnlyLibrary: false, workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1800, height: 26), styleMask: [.titled], backing: .buffered,
            defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        func measured(_ text: String) -> CGFloat { ceil((text as NSString).size(withAttributes: [.font: font]).width) }
        let full = measured(DocumentStatisticsPresentation.label(document: session.statistics.document!))
        for chip in [false, true] {
            workspace.setWritingModes(focus: chip, typewriter: false)
            var previousPath = CGFloat.infinity
            for width: CGFloat in [1800, 1400, 1000, 800, 640, 520, 440, 380, 320, 260, 200] {
                window.setContentSize(NSSize(width: width, height: 26))
                for _ in 0..<2 {
                    host.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(30))
                }
                let context = "chip \(chip) width \(width)"
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                let path = try XCTUnwrap(Self.descendants(host).compactMap { $0 as? BreadcrumbView }.first, context)
                let pathFrame = window.convertToScreen(path.convert(path.bounds, to: nil))
                let fit = try XCTUnwrap(path.fit, context)
                let save = try XCTUnwrap(Self.element("Save state", in: host), context)
                let saveFrame = Self.frame(save)
                var trailingStart = saveFrame.minX
                if let chipElement = Self.element("Writing modes", in: host) {
                    trailingStart = min(trailingStart, Self.frame(chipElement).minX)
                }
                XCTAssertEqual(
                    Self.element("Path", in: host).flatMap(Self.value), workspace.breadcrumb.accessibilityValue)
                XCTAssertEqual(pathFrame.minX + BreadcrumbView.padding, bounds.minX + 16, accuracy: 0.5, context)
                let counts = Self.element("Document statistics", in: host)
                let countsShown = counts != nil
                // The path only narrows while the counts show; once they hide it may take their room.
                if countsShown {
                    XCTAssertLessThanOrEqual(pathFrame.width, previousPath + 0.5, "the path only narrows: \(context)")
                }
                previousPath = pathFrame.width
                XCTAssertLessThanOrEqual(saveFrame.maxX, bounds.maxX - 16 + 0.5, context)
                XCTAssertLessThanOrEqual(pathFrame.maxX, trailingStart, "path vs trailing: \(context)")
                let countsFrame = counts.map(Self.frame) ?? .zero
                if countsShown {
                    XCTAssertGreaterThanOrEqual(
                        countsFrame.minX, pathFrame.maxX + 12 - 0.5, "path vs counts: \(context)")
                    XCTAssertLessThanOrEqual(
                        countsFrame.maxX, trailingStart - 12 + 0.5, "counts vs trailing: \(context)")
                }
                // Wide: the whole path and the counts on the midline.
                if width == 1800 {
                    XCTAssertTrue(fit.collapsed.isEmpty, context)
                    XCTAssertEqual(pathFrame.width, path.idealWidth, accuracy: 0.5, context)
                }
                if width >= 1000 {
                    XCTAssertTrue(countsShown, context)
                    XCTAssertEqual(countsFrame.midX, bounds.midX, accuracy: 1, context)
                    XCTAssertEqual(countsFrame.width, full, accuracy: 8, context)
                }
                // The path folds while the full counts stay centred.
                if width == 1000 || width == 800 {
                    XCTAssertFalse(fit.collapsed.isEmpty, "folded before the counts move: \(context)")
                    XCTAssertEqual(countsFrame.midX, bounds.midX, accuracy: 1, context)
                }
                // At its folded minimum the path pushes the counts off the midline, 12 pt after it.
                if width == 380, !chip {
                    XCTAssertEqual(pathFrame.width, path.minimumWidth, accuracy: 0.5, context)
                    XCTAssertEqual(countsFrame.minX, pathFrame.maxX + 12, accuracy: 2, "off-centre: \(context)")
                    XCTAssertGreaterThan(countsFrame.midX, bounds.midX + 1, context)
                }
                // The title is middle-truncated, never dropped.
                XCTAssertFalse(path.currentLabel.isHidden, context)
                XCTAssertEqual(path.currentLabel.stringValue, "Getting In Shape")
                if width <= 200 { XCTAssertFalse(countsShown, "the counts hide last: \(context)") }
                if width == 320 {
                    XCTAssertTrue(countsShown, context)
                    XCTAssertLessThan(countsFrame.width, full - 8, "characters dropped or truncated: \(context)")
                }
            }
        }
    }

    /// Caret moves without a selection, and scrolling, never schedule count work.
    func testCaretMovesWithoutSelectionDoNotRecount() async throws {
        let session = DocumentSession()
        session.text = "One two three"
        let model = session.statistics
        XCTAssertEqual(model.document, DocumentStatistics(words: 3, characters: 13))
        let before = model.refreshCount
        for location in 0...13 { model.selectionDidChange(NSRange(location: location, length: 0)) }
        try await Task.sleep(for: DocumentStatisticsModel.debounce + .milliseconds(100))
        XCTAssertEqual(model.refreshCount, before)
        // The positive anchor (#56): one real selection change recounts exactly once, so the caret moves above
        // added nothing. Waits on the count instead of a fixed sleep a loaded CI runner can outlast.
        session.selection = NSRange(location: 4, length: 3)
        model.selectionDidChange(session.selection)
        try await waitUntil("selection counts") { model.selection == DocumentStatistics(words: 1, characters: 3) }
        XCTAssertEqual(model.refreshCount, before + 1, "caret moves without a selection must not recount")
        session.selection = NSRange(location: 4, length: 0)
        model.selectionDidChange(session.selection)
        try await waitUntil("collapsed selection recount") { model.refreshCount == before + 2 }
        XCTAssertNil(model.selection)
        // Large buffers count off the main thread and still publish.
        session.text = String(repeating: "word ", count: 20_000)
        try await waitUntil("background count of 20,000 words") { model.document?.words == 20_000 }
    }
}

import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

/// silkweb-1.25: live counts lead the status strip, save state (and the 1.27 chip) trail.
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
        (NSApp as NSObject).perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                    with: NSNumber(value: on), with: "AXEnhancedUserInterface")
    }

    private struct Library {
        let root: URL, suite: String, defaults: UserDefaults, workspace: LibraryWorkspace
        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func library(_ body: String) async throws -> Library {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebStatusCounts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: root.appendingPathComponent("Note.md"))
        let suite = "Silkweb.StatusCounts." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        return Library(root: root, suite: suite, defaults: defaults, workspace: workspace)
    }

    /// The real window hierarchy: counts leading, “Saved” trailing, selection “of” counts, Focus chip in between.
    func testRealHierarchyCountsLeadSaveStateTrailsAndSelectionShowsOf() async throws {
        let body = "# Counting\n\nKyoto rewards **slowness**. 京都 ☕️\n\n" + String(repeating: "Another sentence with five words.\n\n", count: 40)
        let fixture = try await library(body)
        defer { fixture.cleanUp() }
        Self.exposeAccessibility(true)
        defer { Self.exposeAccessibility(false) }
        let workspace = fixture.workspace
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
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
        func assertLayout(_ context: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let (counts, save, chip) = try strip()
            let countsFrame = Self.frame(counts), saveFrame = Self.frame(save)
            let editor = try XCTUnwrap(workspace.preview.editor?.enclosingScrollView)
            let pane = editor.window!.convertToScreen(editor.convert(editor.bounds, to: nil))
            XCTAssertGreaterThan(countsFrame.width, 20, context, file: file, line: line)
            // Leading: 16 pt from the detail column's leading edge; trailing: 16 pt from its end.
            XCTAssertEqual(countsFrame.minX, pane.minX + 16, accuracy: 4, context, file: file, line: line)
            XCTAssertLessThan(countsFrame.maxX, saveFrame.minX, context, file: file, line: line)
            XCTAssertLessThanOrEqual(saveFrame.maxX, pane.maxX - 12, context, file: file, line: line)
            XCTAssertLessThanOrEqual(countsFrame.maxY, pane.minY + 4, "strip sits under the editor: \(context)", file: file, line: line)
            if let chip {
                let chipFrame = Self.frame(chip)
                XCTAssertLessThanOrEqual(countsFrame.maxX, chipFrame.minX + 4, "counts vs chip: \(context)", file: file, line: line)
                XCTAssertLessThanOrEqual(chipFrame.maxX, saveFrame.minX + 4, "chip vs save: \(context)", file: file, line: line)
            }
        }

        var (counts, save, _) = try strip()
        XCTAssertEqual(Self.value(counts), DocumentStatisticsPresentation.accessibilityValue(document: expected))
        XCTAssertEqual(Self.value(save), "Saved")
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
        try await waitForCounts(DocumentStatisticsPresentation.accessibilityValue(document: expected, selection: selection), "selection counts")
        try await settle()
        counts = try strip().counts
        XCTAssertTrue(Self.value(counts)?.hasPrefix("Selection: 3 of ") == true)
        try assertLayout("selection")

        // The Focus chip (1.27) sits between them without overlap, across a resize sweep.
        workspace.setWritingModes(focus: true, typewriter: true)
        for size in [NSSize(width: 1400, height: 900), NSSize(width: 1000, height: 700), NSSize(width: 1800, height: 1000)] {
            window.setContentSize(size)
            try await settle(300)
            XCTAssertNotNil(try strip().chip, "chip visible at \(size)")
            try assertLayout("focus chip at \(size)")
        }
        workspace.setWritingModes(focus: false, typewriter: false)

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await waitForCounts(DocumentStatisticsPresentation.accessibilityValue(document: expected), "collapsed selection reverts to totals")

        // Typing updates the totals after the debounce, never synchronously.
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" extra words", replacementRange: editor.selectedRange())
        XCTAssertEqual(workspace.editor.statistics.document, expected, "no count work on the keystroke itself")
        try await waitUntil("debounced totals after typing") { workspace.editor.statistics.document?.words == expected.words + 2 }

        // Preview-only keeps document totals visible and ignores the editor selection.
        editor.setSelectedRange(selected)
        workspace.preview.mode = .preview
        try await settle()
        counts = try strip().counts
        XCTAssertEqual(Self.value(counts), DocumentStatisticsPresentation.accessibilityValue(document: workspace.editor.statistics.document!))
        workspace.preview.mode = .editor
        try await settle()

        // View ▸ Show Status Bar (⌘/) hides and restores the whole strip; the choice persists.
        workspace.preview.showsStatusBar = false
        try await settle(200)
        XCTAssertNil(Self.element("Document statistics", in: root))
        XCTAssertNil(Self.element("Save state", in: root))
        XCTAssertFalse(workspace.menuState.value.showsStatusBar)
        XCTAssertEqual(fixture.defaults.object(forKey: "Silkweb.Detail.StatusBar") as? Bool, false)
        XCTAssertFalse(PreviewCoordinator(defaults: fixture.defaults).showsStatusBar)
        workspace.preview.showsStatusBar = true
        try await settle(200)
        (counts, save, _) = try strip()
        try assertLayout("restored")
        XCTAssertFalse(window.isVisible)
    }

    /// The production strip on its own across a width sweep, with and without the chip and a selection.
    func testNarrowWidthsDropCharactersBeforeTouchingTrailingCluster() async throws {
        Self.exposeAccessibility(true)
        defer { Self.exposeAccessibility(false) }
        let suite = "Silkweb.StatusCountsSweep." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        let session = DocumentSession()
        session.text = String(repeating: "word ", count: 1_204)
        session.selection = NSRange(location: 0, length: 5 * 38)
        session.statistics.refreshNow()
        XCTAssertEqual(session.statistics.document?.words, 1_204)
        XCTAssertEqual(session.statistics.selection?.words, 38)
        let host = NSHostingView(rootView: DocumentStatusBar(session: session, readOnlyLibrary: false, workspace: workspace))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 26), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        var widths: [String: CGFloat] = [:]
        for chip in [false, true] {
            workspace.setWritingModes(focus: chip, typewriter: chip)
            for width: CGFloat in [1200, 640, 420, 360, 300, 240, 200, 160, 1200] {
                window.setContentSize(NSSize(width: width, height: 26))
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                host.layoutSubtreeIfNeeded()
                let context = "chip \(chip) width \(width)"
                let counts = try XCTUnwrap(Self.element("Document statistics", in: host), context)
                let save = try XCTUnwrap(Self.element("Save state", in: host), context)
                let countsFrame = Self.frame(counts), saveFrame = Self.frame(save)
                let bounds = window.convertToScreen(host.convert(host.bounds, to: nil))
                XCTAssertEqual(host.fittingSize.height, Spacing.statusBarHeight, accuracy: 0.5)
                // The save label never truncates or leaves the strip; counts give way first.
                XCTAssertGreaterThanOrEqual(saveFrame.width + 0.5, ceil(("Saved" as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .subheadline)]).width) - 2, context)
                XCTAssertLessThanOrEqual(saveFrame.maxX, bounds.maxX - 16 + 0.5, context)
                XCTAssertEqual(countsFrame.minX, bounds.minX + 16, accuracy: 0.5, context)
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
        let full = DocumentStatisticsPresentation.label(document: session.statistics.document!, selection: session.statistics.selection)
        let words = DocumentStatisticsPresentation.label(document: session.statistics.document!, selection: session.statistics.selection, includesCharacters: false)
        XCTAssertEqual(widths["false-1200"]!, measured(full), accuracy: 12)
        XCTAssertEqual(widths["true-360"]!, measured(words), accuracy: 12, "words-only fallback")
        XCTAssertLessThan(widths["true-160"]!, measured(words), "tail truncation as the last resort")
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

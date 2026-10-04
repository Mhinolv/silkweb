import AppKit
import SwiftUI
import XCTest
@testable import SilkwebCore
@testable import Silkweb

/// silkweb-1.24: the real Settings window and live apply to editors, preview CSS and colour tokens.
final class SettingsTests: XCTestCase {
    private var savedPreferences = WritingPreferences()
    private var savedAppearance: NSAppearance?
    private var suites: [String] = []

    @MainActor override func setUp() async throws {
        _ = NSApplication.shared
        savedPreferences = LivePreferences.shared.current
        savedAppearance = NSApp.appearance
        LivePreferences.shared.current = WritingPreferences()
    }

    @MainActor override func tearDown() async throws {
        LivePreferences.shared.current = savedPreferences
        EditorRegistry.apply(savedPreferences)
        NSApp.appearance = savedAppearance
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    }

    @MainActor private func makeSettings(live: Bool = true) throws -> WritingSettings {
        let suite = "Silkweb.Settings." + UUID().uuidString
        suites.append(suite)
        return WritingSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), live: live)
    }

    @MainActor private func makeEditor(_ source: String) throws -> (NSWindow, PlainMarkdownTextView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle())
        scroll.frame = window.contentView!.bounds
        window.contentView!.addSubview(scroll)
        let text = try XCTUnwrap(scroll.documentView as? PlainMarkdownTextView)
        text.string = source
        text.styler.reload()
        text.layoutEditor()
        return (window, text)
    }

    private static func srgb(_ color: NSColor, dark: Bool) -> Int {
        var resolved: NSColor?
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance { resolved = color.usingColorSpace(.sRGB) }
        guard let resolved else { return -1 }
        func channel(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        return channel(resolved.redComponent) << 16 | channel(resolved.greenComponent) << 8 | channel(resolved.blueComponent)
    }

    @MainActor
    func testSettingsWindowBuildsEveryTabWithItsControls() async throws {
        let settings = try makeSettings(live: false)
        let workspace = LibraryWorkspace(defaults: settings.defaults, columnAutosaveName: suites.last!)
        workspace.canSaveWindowSession = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebSettingsLibrary-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        workspace.root = root
        settings.preferences.colors.light.text = HexColor(0xBBBBBB)
        settings.editingDark = false
        for tab in SettingsTab.allCases {
            for dark in [false, true] {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 900), styleMask: [.titled, .closable], backing: .buffered, defer: true)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let host = NSHostingController(rootView: SettingsView(settings: settings, workspace: workspace, tab: tab))
                window.contentViewController = host
                host.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                host.view.layoutSubtreeIfNeeded()
                let views = Self.descendants(host.view)
                XCTAssertFalse(window.isVisible)
                switch tab {
                case .editor:
                    XCTAssertGreaterThanOrEqual(views.compactMap { $0 as? NSSlider }.count, 4, "Size, spacing, insets, width")
                    let sample = try XCTUnwrap(views.compactMap { $0 as? PlainMarkdownTextView }.first)
                    XCTAssertEqual(sample.string, EditorSample.text)
                    XCTAssertEqual(sample.accessibilityLabel(), "Editor sample text")
                    XCTAssertFalse(sample.isEditable)
                case .preview:
                    XCTAssertGreaterThanOrEqual(views.compactMap { $0 as? NSSlider }.count, 1)
                case .appearance:
                    XCTAssertGreaterThanOrEqual(views.compactMap { $0 as? NSColorWell }.count, 5, "Five colour wells")
                    // Coral marks only unsaved tabs now (1.65).
                    let coral = try XCTUnwrap(AppearanceSettingsTab.rows.first { $0.slot == .coral })
                    XCTAssertEqual(coral.title, "Unsaved dot")
                    XCTAssertEqual(coral.caption, "Dot on tabs with unsaved changes")
                    XCTAssertFalse(AppearanceSettingsTab.rows.contains { $0.title == "You are here" })
                case .library:
                    let path = try XCTUnwrap(views.compactMap { $0 as? NSPathControl }.first)
                    XCTAssertEqual(path.url?.standardizedFileURL, root.standardizedFileURL)
                    XCTAssertFalse(path.isEditable)
                }
                window.contentViewController = nil
                window.close()
            }
        }
        XCTAssertEqual(settings.editedColors.contrastWarning(dark: false).map { if case .text = $0 { true } else { false } }, true)
    }

    @MainActor
    func testEditorSettingsApplyLiveWithoutReplacingText() throws {
        let settings = try makeSettings()
        let source = "# Title\nBody line with words.\n\n![Missing](nowhere.png)\n"
        let (window, text) = try makeEditor(source)
        defer { window.close() }
        let storage = try XCTUnwrap(text.textStorage)
        text.setSelectedRange(NSRange(location: 3, length: 0))
        text.insertText("X", replacementRange: text.selectedRange())
        let edited = text.string
        let undo = try XCTUnwrap(text.undoManager)
        XCTAssertTrue(undo.canUndo)
        text.setSelectedRange(NSRange(location: 10, length: 4))

        for (family, size, spacing) in [("Serif", 20.0, 2.0), ("System", 10, 1.2), ("Monospaced", 32, 1.35), ("Missing Font Family", 15, 1.75), ("Menlo", 15, 1.6)] {
            settings.preferences.fontFamily = family
            settings.preferences.fontSize = size
            settings.preferences.lineHeight = spacing
            XCTAssertTrue(text.textStorage === storage, "Storage is never replaced")
            XCTAssertEqual(text.string, edited)
            XCTAssertEqual(text.selectedRange(), NSRange(location: 10, length: 4))
            XCTAssertTrue(undo.canUndo, "Undo survives a restyle")
            let font = try XCTUnwrap(storage.attribute(.font, at: 12, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.pointSize, size)
            XCTAssertEqual(text.style.bodyFont.pointSize, size)
            if family == "Missing Font Family" { XCTAssertEqual(font.fontName, "Menlo-Regular", "Unknown fonts fall back to Menlo") }
            let paragraph = try XCTUnwrap(storage.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle)
            XCTAssertEqual(paragraph.lineHeightMultiple, spacing)
        }
        for width in [480.0, 660, 1200] {
            for inset in [24.0, 48, 120] {
                settings.preferences.maximumWidth = width
                settings.preferences.horizontalInset = inset
                let viewport = try XCTUnwrap(text.enclosingScrollView).contentSize.width
                XCTAssertEqual(text.textContainer?.containerSize.width, max(1, min(width, viewport - 2 * inset)))
                XCTAssertGreaterThanOrEqual(text.textContainerInset.width, inset)
            }
        }
        settings.preferences.checksSpelling = false
        settings.preferences.smartPunctuation = true
        XCTAssertFalse(text.isContinuousSpellCheckingEnabled)
        XCTAssertTrue(text.isAutomaticQuoteSubstitutionEnabled)
        XCTAssertTrue(text.isAutomaticDashSubstitutionEnabled)
        settings.preferences.showsInlineImages = false
        XCTAssertFalse(text.inlineImages.enabled)
        XCTAssertTrue(text.inlineImages.imageViews.isEmpty)

        settings.preferences.highlightsCurrentLine = true
        text.setSelectedRange(NSRange(location: 3, length: 0))
        let band = try XCTUnwrap(text.currentLineBand())
        XCTAssertEqual(band.width, text.bounds.width)
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        XCTAssertNotNil(text.currentLineBand(), "End of document uses the extra line fragment")
        text.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertNil(text.currentLineBand(), "Hidden while text is selected")
        settings.preferences.highlightsCurrentLine = false
        text.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertNil(text.currentLineBand())

        for indent in WritingPreferences.Indent.allCases {
            settings.preferences.indent = indent
            text.isEditable = true
            text.setSelectedRange(NSRange(location: 9, length: 0))
            let before = text.string
            text.insertTab(nil)
            XCTAssertEqual(text.string, (before as NSString).replacingCharacters(in: NSRange(location: 9, length: 0), with: indent.text))
            text.undoManager?.undo()
        }

        settings.preferences.restoreEditorDefaults()
        XCTAssertEqual(text.style, EditorStyle(topInset: text.style.topInset, preferences: WritingPreferences()))
        XCTAssertTrue(text.inlineImages.enabled)
    }

    /// silkweb-1.76: list Tab/⇧Tab and Format › Shift Right/Left (⌘]/⌘[) use Indent with, live, one undo step each.
    @MainActor
    func testIndentSettingDrivesListShiftCommands() throws {
        let settings = try makeSettings()
        let (window, text) = try makeEditor("- a\n- b\n- c\n")
        defer { window.close() }
        text.isEditable = true
        // Offscreen there is no event loop to close groups; each command must group itself.
        let delegate = IndentUndoDelegate()
        text.delegate = delegate
        let undo = delegate.manager
        undo.groupsByEvent = false
        func caret(onLine line: Int) {
            let lines = text.string.components(separatedBy: "\n")
            let start = lines.prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 }
            text.setSelectedRange(NSRange(location: start + (lines[line] as NSString).length, length: 0))
        }
        for indent in [WritingPreferences.Indent.tab, .twoSpaces, .fourSpaces, .tab] {
            settings.preferences.indent = indent
            XCTAssertEqual(text.style.indent, indent, "Applies to the next keystroke without reopening")
            let unit = indent.text
            caret(onLine: 1)
            text.insertTab(nil)
            caret(onLine: 2)
            text.insertTab(nil)
            text.format(.indent)
            XCTAssertEqual(text.string, "- a\n\(unit)- b\n\(unit)\(unit)- c\n", indent.title)
            text.insertBacktab(nil)
            XCTAssertEqual(text.string, "- a\n\(unit)- b\n\(unit)- c\n", indent.title)
            text.format(.outdent)
            XCTAssertEqual(text.string, "- a\n\(unit)- b\n- c\n", indent.title)
            undo.undo()
            XCTAssertEqual(text.string, "- a\n\(unit)- b\n\(unit)- c\n", "⌘[ is one undo step")
            undo.undo()
            XCTAssertEqual(text.string, "- a\n\(unit)- b\n\(unit)\(unit)- c\n", "⇧Tab is one undo step")
            undo.undo()
            XCTAssertEqual(text.string, "- a\n\(unit)- b\n\(unit)- c\n", "⌘] is one undo step")
            undo.undo(); undo.undo()
            XCTAssertEqual(text.string, "- a\n- b\n- c\n")
        }
    }

    @MainActor
    func testColourWellsDriveTokensPerAppearance() throws {
        let settings = try makeSettings()
        let pane = Self.srgb(.silkwebPaneBackground, dark: false)
        XCTAssertEqual(pane, 0xFBFBFA)
        let revision = ColorRevision.shared.value
        settings.preferences.colors.light.surface = HexColor(0x102030)
        settings.preferences.colors.light.accent = HexColor(0xAA0000)
        settings.preferences.colors.light.text = HexColor(0x222222)
        settings.preferences.colors.light.headings = HexColor(0x004400)
        settings.preferences.colors.light.coral = HexColor(0x00AAFF)
        XCTAssertGreaterThan(ColorRevision.shared.value, revision)
        XCTAssertEqual(Self.srgb(.silkwebPaneBackground, dark: false), 0x102030)
        XCTAssertEqual(Self.srgb(.silkwebPaneBackground, dark: true), 0x1E1F21, "Dark keeps its own set")
        XCTAssertEqual(Self.srgb(.silkwebAccent, dark: false), 0xAA0000)
        XCTAssertEqual(Self.srgb(.silkwebAccent, dark: true), 0x7FC0A4)
        XCTAssertEqual(Self.srgb(.silkwebText, dark: false), 0x222222)
        XCTAssertEqual(Self.srgb(.editorHeading, dark: false), 0x004400)
        XCTAssertEqual(Self.srgb(.silkwebCoral, dark: false), 0x00AAFF)
        let set = settings.preferences.colors.light
        XCTAssertEqual(Self.srgb(.silkwebSelection, dark: false), set.selection(dark: false).rgb)
        XCTAssertEqual(Self.srgb(.silkwebSelectionInactive, dark: false), set.selectionInactive(dark: false).rgb)
        XCTAssertEqual(Self.srgb(.silkwebHairline, dark: false), set.hairline(dark: false).rgb)
        XCTAssertEqual(Self.srgb(.silkwebThread, dark: false), set.hairline(dark: false).rgb)
        XCTAssertEqual(Self.srgb(.silkwebHairline, dark: true), Self.srgb(.separatorColor, dark: true), "Default set keeps the system separator")

        // The editor's body text and headings use the slots without a restyle.
        let (window, text) = try makeEditor("# Heading\nBody")
        defer { window.close() }
        XCTAssertEqual(text.textStorage?.attribute(.foregroundColor, at: 10, effectiveRange: nil) as? NSColor, .silkwebText)
        XCTAssertEqual(text.textStorage?.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor, .editorHeading)

        settings.editingDark = false
        settings.restoreEditedColors()
        XCTAssertTrue(settings.preferences.colors.light.isDefault)
        XCTAssertEqual(Self.srgb(.silkwebPaneBackground, dark: false), 0xFBFBFA)
        XCTAssertEqual(Self.srgb(.silkwebAccent, dark: false), 0x3F7D64, "Sage is restored")
    }

    @MainActor
    func testAppearanceModeSetsNSAppAppearance() throws {
        let settings = try makeSettings()
        settings.preferences.appearance = .dark
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        settings.preferences.appearance = .light
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        settings.preferences.appearance = .system
        XCTAssertNil(NSApp.appearance)
        let snapshot = try makeSettings(live: false)
        snapshot.preferences.appearance = .dark
        XCTAssertNil(NSApp.appearance, "Non-live models never touch the app")
        XCTAssertEqual(LivePreferences.shared.current.appearance, .system)
    }

    @MainActor
    func testPreviewCSSVariablesAndRenderOptionsApplyLive() async throws {
        let settings = try makeSettings()
        let preview = PreviewCoordinator(defaults: settings.defaults)
        preview.mode = .preview
        let root = URL(fileURLWithPath: "/tmp/SilkwebSettingsPreview")
        let document = root.appendingPathComponent("Note.md")
        preview.schedule(text: "[TOC]\n\n# One\nfirst\nsecond\n", document: document, root: root)
        try await waitFor { preview.html.contains("<h1") }
        XCTAssertTrue(preview.html.contains("<style id=\"sw-settings\">"))
        XCTAssertTrue(preview.html.contains("--sw-font-size: 16px"))
        XCTAssertTrue(preview.html.contains("<nav class=\"sw-toc\""))
        XCTAssertFalse(preview.html.contains("first<br>"))

        settings.preferences.previewFontSize = 20
        settings.preferences.previewFont = .serif
        settings.preferences.colors.dark.surface = HexColor(0x010203)
        XCTAssertTrue(preview.html.contains("--sw-font-size: 20px"), "CSS-only changes patch the page without a re-parse")
        XCTAssertTrue(preview.html.contains("'New York'"))
        XCTAssertTrue(preview.html.contains("--sw-surface: #010203"))
        XCTAssertEqual(preview.html.components(separatedBy: "id=\"sw-settings\"").count, 2)

        settings.preferences.keepsLineBreaks = true
        settings.preferences.showsTableOfContents = false
        try await waitFor { preview.html.contains("first<br>") }
        XCTAssertFalse(preview.html.contains("<nav class=\"sw-toc\""))
        XCTAssertTrue(preview.html.contains("[TOC]"))
        XCTAssertTrue(preview.html.contains("--sw-font-size: 20px"))
    }

    @MainActor
    func testZoomIsTemporaryAndActualSizeRestoresSettingsSize() throws {
        let settings = try makeSettings()
        settings.preferences.fontSize = 15
        let workspace = LibraryWorkspace(defaults: settings.defaults, columnAutosaveName: suites.last!)
        workspace.canSaveWindowSession = false
        let (window, text) = try makeEditor("Body")
        defer { window.close() }
        text.configureAssetInsertion(session: DocumentSession(), workspace: workspace)
        let (otherWindow, other) = try makeEditor("Other window")
        defer { otherWindow.close() }

        for _ in 0..<3 { workspace.zoomEditor(by: 1) }
        XCTAssertEqual(text.style.bodyFont.pointSize, 18)
        XCTAssertEqual(other.style.bodyFont.pointSize, 15, "Zoom is per window")
        XCTAssertEqual(settings.preferences.fontSize, 15, "Zoom never moves the Settings size")
        for _ in 0..<40 { workspace.zoomEditor(by: 1) }
        XCTAssertEqual(text.style.bodyFont.pointSize, 32)
        for _ in 0..<40 { workspace.zoomEditor(by: -1) }
        XCTAssertEqual(text.style.bodyFont.pointSize, 10)
        workspace.zoomEditor(by: 2)
        settings.preferences.fontSize = 20
        XCTAssertEqual(text.style.bodyFont.pointSize, 20 + CGFloat(workspace.editorZoom))
        workspace.zoomEditor(by: nil)
        XCTAssertEqual(workspace.editorZoom, 0)
        XCTAssertEqual(text.style.bodyFont.pointSize, 20)
        XCTAssertEqual(LivePreferences.shared.current.fontSize, 20)
    }

    @MainActor
    func testChangesAreSavedAfterAPauseAndReloadFromDisk() async throws {
        let settings = try makeSettings()
        XCTAssertNil(settings.defaults.data(forKey: WritingPreferences.defaultsKey), "Opening Settings writes nothing")
        settings.preferences.maximumWidth = 900
        settings.preferences.colors.dark.accent = HexColor(0x123456)
        XCTAssertNil(settings.defaults.data(forKey: WritingPreferences.defaultsKey), "Saves are debounced")
        try await waitFor { settings.defaults.data(forKey: WritingPreferences.defaultsKey) != nil }
        let reloaded = WritingPreferences.load(from: settings.defaults)
        XCTAssertEqual(reloaded, settings.preferences)
        XCTAssertEqual(reloaded.colors.dark.accent, HexColor(0x123456))
        XCTAssertTrue(reloaded.colors.light.isDefault)
    }

    @MainActor private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 5) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

@MainActor private final class IndentUndoDelegate: NSObject, NSTextViewDelegate {
    let manager = UndoManager()
    func undoManager(for view: NSTextView) -> UndoManager? { manager }
}

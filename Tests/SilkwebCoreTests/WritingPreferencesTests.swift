import Foundation
import XCTest
@testable import SilkwebCore

final class WritingPreferencesTests: XCTestCase {
    private func decode(_ json: String) throws -> WritingPreferences {
        try JSONDecoder().decode(WritingPreferences.self, from: Data(json.utf8))
    }

    func testMissingKeysUseDocumentedDefaults() throws {
        for json in ["{}", "{\"version\":0,\"unknown\":true}", "{\"version\":99,\"colors\":null}"] {
            let value = try decode(json)
            XCTAssertEqual(value, WritingPreferences(), json)
            XCTAssertEqual(value.fontFamily, "Menlo")
            XCTAssertEqual(value.fontSize, 15)
            XCTAssertEqual(value.lineHeight, 1.6)
            XCTAssertEqual(value.horizontalInset, 48)
            XCTAssertEqual(value.maximumWidth, 660)
            XCTAssertEqual(value.indent, .fourSpaces)
            XCTAssertTrue(value.checksSpelling)
            XCTAssertFalse(value.smartPunctuation)
            XCTAssertTrue(value.showsInlineImages)
            XCTAssertFalse(value.highlightsCurrentLine)
            XCTAssertTrue(value.reopensSession)
            XCTAssertEqual(value.previewFont, .system)
            XCTAssertEqual(value.previewFontSize, 16)
            XCTAssertFalse(value.keepsLineBreaks)
            XCTAssertTrue(value.showsTableOfContents)
            XCTAssertEqual(value.appearance, .system)
            XCTAssertTrue(value.colors.light.isDefault)
            XCTAssertTrue(value.colors.dark.isDefault)
        }
    }

    /// Payloads saved by 1.47–1.65 (version 1, four keys) still load; 1.5 snaps to 1.6.
    func testFilesSavedBeforeSettingsStillLoad() throws {
        let legacy = try decode("{\"version\":1,\"fontFamily\":\"Helvetica\",\"fontSize\":21,\"lineHeight\":1.5,\"maximumWidth\":720}")
        XCTAssertEqual(legacy.fontFamily, "Helvetica")
        XCTAssertEqual(legacy.fontSize, 21)
        XCTAssertEqual(legacy.lineHeight, 1.6)
        XCTAssertEqual(legacy.maximumWidth, 720)
        var expected = WritingPreferences()
        expected.fontFamily = "Helvetica"; expected.fontSize = 21; expected.maximumWidth = 720
        XCTAssertEqual(legacy, expected)

        let suite = "SilkwebWritingPreferences-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(WritingPreferences.load(from: defaults), WritingPreferences())
        XCTAssertNil(defaults.data(forKey: WritingPreferences.defaultsKey), "Reading must not write")
        defaults.set(Data("{\"fontFamily\":\"Menlo\",\"fontSize\":18}".utf8), forKey: WritingPreferences.defaultsKey)
        XCTAssertEqual(WritingPreferences.load(from: defaults).fontSize, 18)
        defaults.set(Data("not json".utf8), forKey: WritingPreferences.defaultsKey)
        XCTAssertEqual(WritingPreferences.load(from: defaults), WritingPreferences())
    }

    func testOutOfRangeValuesClampAndCorruptValuesUseDefaults() throws {
        let sizes: [(Double, Double)] = [(0, 15), (-3, 15), (1, 10), (9.5, 10), (10, 10), (15, 15), (21.5, 21.5), (32, 32), (33, 32), (144, 32)]
        for (input, expected) in sizes {
            XCTAssertEqual(try decode("{\"fontSize\":\(input)}").fontSize, expected, "\(input)")
        }
        let insets: [(Double, Double)] = [(0, 48), (1, 24), (24, 24), (64, 64), (120, 120), (500, 120)]
        for (input, expected) in insets {
            XCTAssertEqual(try decode("{\"horizontalInset\":\(input)}").horizontalInset, expected, "\(input)")
        }
        let widths: [(Double, Double)] = [(0, 660), (-1, 660), (1, 480), (480, 480), (720, 720), (1200, 1200), (4096, 1200)]
        for (input, expected) in widths {
            XCTAssertEqual(try decode("{\"maximumWidth\":\(input)}").maximumWidth, expected, "\(input)")
        }
        let preview: [(Double, Double)] = [(0, 16), (2, 12), (12, 12), (24, 24), (99, 24)]
        for (input, expected) in preview {
            XCTAssertEqual(try decode("{\"previewFontSize\":\(input)}").previewFontSize, expected, "\(input)")
        }
        let spacing: [(Double, Double)] = [(-1, 1.6), (0, 1.6), (0.5, 1.2), (1.2, 1.2), (1.3, 1.35), (1.35, 1.35), (1.475, 1.6),
                                           (1.5, 1.6), (1.6, 1.6), (1.7, 1.75), (1.75, 1.75), (1.9, 2), (2, 2), (9, 2)]
        for (input, expected) in spacing {
            XCTAssertEqual(try decode("{\"lineHeight\":\(input)}").lineHeight, expected, "\(input)")
        }
        // Wrong types and unknown enum cases fall back per key, never failing the whole payload.
        let mixed = try decode("{\"fontFamily\":\"  \",\"fontSize\":\"big\",\"indent\":\"eight\",\"checksSpelling\":\"yes\",\"appearance\":\"sepia\",\"previewFont\":3,\"colors\":{\"light\":{\"accent\":\"#12\",\"text\":\"#112233\"},\"dark\":\"broken\"},\"smartPunctuation\":true}")
        XCTAssertEqual(mixed.fontFamily, "Menlo")
        XCTAssertEqual(mixed.fontSize, 15)
        XCTAssertEqual(mixed.indent, .fourSpaces)
        XCTAssertTrue(mixed.checksSpelling)
        XCTAssertEqual(mixed.appearance, .system)
        XCTAssertEqual(mixed.previewFont, .system)
        XCTAssertTrue(mixed.smartPunctuation)
        XCTAssertNil(mixed.colors.light.accent)
        XCTAssertEqual(mixed.colors.light.text, HexColor(0x112233))
        XCTAssertTrue(mixed.colors.dark.isDefault)
    }

    func testEveryOptionRoundTrips() throws {
        for family in ["Menlo", "Monospaced", "System", "Serif", "Helvetica", "future-font"] {
            for indent in WritingPreferences.Indent.allCases {
                for appearance in WritingPreferences.AppearanceMode.allCases {
                    for previewFont in WritingPreferences.PreviewFont.allCases {
                        for flag in [false, true] {
                            var value = WritingPreferences()
                            value.fontFamily = family; value.indent = indent; value.appearance = appearance
                            value.previewFont = previewFont; value.keepsLineBreaks = flag; value.showsTableOfContents = !flag
                            value.checksSpelling = flag; value.smartPunctuation = flag; value.showsInlineImages = !flag
                            value.highlightsCurrentLine = flag; value.reopensSession = !flag
                            value.fontSize = 32; value.lineHeight = 1.35; value.horizontalInset = 120; value.maximumWidth = 480
                            value.previewFontSize = 12
                            value.colors.light.accent = HexColor(0xABCDEF)
                            value.colors.dark.surface = HexColor(0x000000)
                            let data = try JSONEncoder().encode(value)
                            XCTAssertEqual(try JSONDecoder().decode(WritingPreferences.self, from: data), value)
                            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
                            XCTAssertEqual(object["version"] as? Int, 2)
                        }
                    }
                }
            }
        }
    }

    func testRestoreDefaultsResetsOnlyItsTab() {
        var value = WritingPreferences()
        value.fontFamily = "Serif"; value.fontSize = 20; value.lineHeight = 2; value.horizontalInset = 96; value.maximumWidth = 900
        value.indent = .tab; value.checksSpelling = false; value.smartPunctuation = true; value.showsInlineImages = false
        value.highlightsCurrentLine = true; value.reopensSession = false
        value.previewFont = .serif; value.previewFontSize = 20; value.keepsLineBreaks = true; value.showsTableOfContents = false
        value.appearance = .dark; value.colors.light.accent = HexColor(0x123456)
        XCTAssertFalse(value.editorIsDefault)
        XCTAssertFalse(value.previewIsDefault)

        var editor = value
        editor.restoreEditorDefaults()
        XCTAssertTrue(editor.editorIsDefault)
        XCTAssertEqual(editor.maximumWidth, 660)
        XCTAssertEqual(editor.fontFamily, "Menlo")
        XCTAssertEqual(editor.previewFont, .serif)
        XCTAssertEqual(editor.colors, value.colors)
        XCTAssertEqual(editor.appearance, .dark)

        var preview = value
        preview.restorePreviewDefaults()
        XCTAssertTrue(preview.previewIsDefault)
        XCTAssertEqual(preview.fontSize, 20)
        XCTAssertEqual(preview.colors, value.colors)

        var colors = value.colors
        colors.dark.coral = HexColor(0x00FF00)
        colors[dark: false] = ColorSet()
        XCTAssertTrue(colors.light.isDefault)
        XCTAssertEqual(colors.dark.coral, HexColor(0x00FF00), "Restoring one set keeps the other")
        XCTAssertEqual(ColorSet().resolved(.accent, dark: false), HexColor(0x3F7D64), "Sage is the default accent")
        XCTAssertEqual(ColorSet().resolved(.accent, dark: true), HexColor(0x7FC0A4))
    }

    func testContrastWarningsAndDerivedColours() {
        XCTAssertEqual(HexColor.contrast(HexColor(0), HexColor(0xFFFFFF)), 21, accuracy: 0.001)
        XCTAssertEqual(HexColor.contrast(HexColor(0x777777), HexColor(0x777777)), 1, accuracy: 0.001)
        for dark in [false, true] {
            XCTAssertNil(ColorSet().contrastWarning(dark: dark), "Defaults pass in \(dark ? "dark" : "light")")
        }
        var set = ColorSet()
        set.text = HexColor(0xAAAAAA)
        guard case .text(let ratio)? = set.contrastWarning(dark: false) else { return XCTFail("Expected a text warning") }
        XCTAssertLessThan(ratio, 4.5)
        XCTAssertEqual(set.contrastWarning(dark: false)?.message, "Text is hard to read on this surface (2.2:1). Aim for at least 4.5:1.")
        // Just under and at the 4.5:1 boundary on white.
        set = ColorSet(); set.surface = HexColor(0xFFFFFF)
        set.text = HexColor(0x777777)
        XCTAssertNotNil(set.contrastWarning(dark: false))
        set.text = HexColor(0x767676)
        XCTAssertNil(set.contrastWarning(dark: false))
        set.headings = HexColor(0xBBBBBB)
        guard case .headings(let heading)? = set.contrastWarning(dark: false) else { return XCTFail("Expected a headings warning") }
        XCTAssertLessThan(heading, 3)
        XCTAssertTrue(set.contrastWarning(dark: false)!.message.hasPrefix("Headings are hard to read"))
        // A dark set is tested against its own surface.
        set = ColorSet(); set.surface = HexColor(0xF0F0F0)
        XCTAssertNotNil(set.contrastWarning(dark: true))
        XCTAssertNil(set.contrastWarning(dark: false))

        let surface = HexColor(0xFFFFFF), accent = HexColor(0x000000)
        XCTAssertEqual(surface.mixed(with: accent, 0), surface)
        XCTAssertEqual(surface.mixed(with: accent, 1), accent)
        XCTAssertEqual(surface.mixed(with: accent, 0.5), HexColor(0x808080))
        var custom = ColorSet(); custom.surface = surface; custom.accent = accent; custom.text = accent
        XCTAssertEqual(custom.selection(dark: false), surface.mixed(with: accent, 0.14))
        XCTAssertEqual(custom.selection(dark: true), surface.mixed(with: accent, 0.22))
        XCTAssertEqual(custom.selectionInactive(dark: false), HexColor(0xF5F5F5))
        XCTAssertEqual(custom.hairline(dark: false), HexColor(0xE6E6E6))
    }

    func testHexColorsAndPreviewVariables() throws {
        XCTAssertEqual(HexColor(hex: "#3f7d64"), HexColor(0x3F7D64))
        XCTAssertEqual(HexColor(hex: "3F7D64")?.hex, "#3F7D64")
        for invalid in ["", "#", "#12345", "#1234567", "#GGGGGG", "red"] { XCTAssertNil(HexColor(hex: invalid), invalid) }
        XCTAssertEqual(String(data: try JSONEncoder().encode(HexColor(0x0A0B0C)), encoding: .utf8), "\"#0A0B0C\"")

        var value = WritingPreferences()
        XCTAssertTrue(value.previewCSS.contains("--sw-font-family: -apple-system; --sw-font-size: 16px;"))
        XCTAssertFalse(value.previewCSS.contains("@media"), "No colour variables until a colour is customised")
        value.previewFont = .serif; value.previewFontSize = 20
        value.colors.light.text = HexColor(0x111111)
        value.colors.dark.accent = HexColor(0x00FF88)
        let css = value.previewCSS
        XCTAssertTrue(css.contains("--sw-font-size: 20px"))
        XCTAssertTrue(css.contains("'New York'"))
        XCTAssertTrue(css.contains("@media (prefers-color-scheme: light) { :root { --sw-text: #111111; } }"))
        XCTAssertTrue(css.contains("@media (prefers-color-scheme: dark) { :root { --sw-accent: #00FF88; } }"))
    }

    func testTableOfContentsCanBeTurnedOff() {
        let source = "[TOC]\n\n# One\n\n## Two\n"
        XCTAssertTrue(HTMLRenderer.render(source).contains("sw-toc"))
        var options = HTMLRenderer.Options()
        options.showsTableOfContents = false
        let html = HTMLRenderer.render(source, options: options)
        XCTAssertFalse(html.contains("sw-toc"))
        XCTAssertTrue(html.contains("<p>[TOC]</p>"))
        XCTAssertTrue(html.contains("<h1"))
    }
}

import AppKit
import ImageIO
import SilkwebCore
import UniformTypeIdentifiers
import XCTest

@testable import Silkweb

/// #154: a pasted macOS screenshot (U+202F before AM/PM) loads inline, and the selected image's outline is
/// Silkweb chrome in the Accent from Settings, per appearance, never the system accent.
final class InlineImageAccentTests: XCTestCase {
    private var savedPreferences = WritingPreferences()
    private var savedAppearance: NSAppearance?

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
    }

    private static func srgb(_ color: CGColor?) -> Int {
        guard let color, let converted = NSColor(cgColor: color)?.usingColorSpace(.sRGB) else { return -1 }
        func channel(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        return channel(converted.redComponent) << 16 | channel(converted.greenComponent) << 8
            | channel(converted.blueComponent)
    }

    @MainActor
    func testScreenshotLoadsInlineAndSelectionOutlineUsesAccent() async throws {
        let settings = WritingSettings(defaults: disposableDefaults("InlineImageAccent"), live: true)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID().uuidString
        let media = root.appendingPathComponent("media/" + id)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 160,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.systemGreen.cgColor); context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let png = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                media.appendingPathComponent("Screenshot 2026-10-07 at 9.41.00\u{202F}AM.png") as CFURL,
                UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(png, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(png))
        // As pasted (percent-encoded) and as written by hand or another app (raw U+202F).
        let source =
            "See [Silkweb](https://example.com)\n"
            + "![Encoded](media/\(id)/Screenshot%202026-10-07%20at%209.41.00%E2%80%AFAM.png)\n"
            + "![Raw](media/\(id)/Screenshot%202026-10-07%20at%209.41.00\u{202F}AM.png)\nAfter\n"
        try Data(source.utf8).write(to: root.appendingPathComponent("Note.md"))
        let workspace = LibraryWorkspace(defaults: disposableDefaults("InlineImageAccentWorkspace"))
        workspace.canSaveWindowSession = false; workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let note = try XCTUnwrap(workspace.snapshot?.documents.first { $0.relativePath == "Note.md" })
        let opened = await workspace.openTab(note, pinned: true)
        XCTAssertTrue(opened)
        let controller = LibrarySplitViewController(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.appearance = NSAppearance(named: .aqua)
        defer { window.contentViewController = nil; window.close() }
        func settle() async throws {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(600))
            controller.view.layoutSubtreeIfNeeded()
        }
        try await settle()
        window.setContentSize(NSSize(width: 1400, height: 900)); workspace.preview.mode = .editor
        try await settle()
        let editor = try XCTUnwrap(workspace.preview.editor)
        let views = editor.subviews.compactMap { $0 as? InlineImageView }
        XCTAssertEqual(views.count, 2)
        for view in views {
            XCTAssertNil(view.content.message, "A screenshot that exists never shows a placeholder chip")
            XCTAssertNotNil(view.content.bitmap)
            XCTAssertEqual(view.frame.size, NSSize(width: 40, height: 20))
        }

        let line = (source as NSString).range(of: "![Encoded]")
        let length = (source as NSString).lineRange(for: line).length - 1
        editor.setSelectedRange(NSRange(location: line.location, length: length))
        let selected = try XCTUnwrap(views.first { $0.accessibilityLabel() == "Encoded" })
        XCTAssertEqual(selected.layer?.borderWidth, 2)
        XCTAssertEqual(views.first { $0 !== selected }?.layer?.borderWidth, 0)
        XCTAssertEqual(Self.srgb(selected.layer?.borderColor), 0x3F7D64, "Outline is the default Accent (Sage)")

        settings.preferences.colors.light.accent = HexColor(0xD9822B)
        settings.preferences.colors.dark.accent = HexColor(0xF0A050)
        XCTAssertEqual(Self.srgb(selected.layer?.borderColor), 0xD9822B, "A custom Accent recolours the outline live")
        window.appearance = NSAppearance(named: .darkAqua)
        try await settle()
        XCTAssertEqual(Self.srgb(selected.layer?.borderColor), 0xF0A050, "The outline resolves per appearance")
        XCTAssertEqual(selected.layer?.borderWidth, 2)
    }
}

import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

/// silkweb-1.56: every pane paints the one shared pane color, with no wallpaper vibrancy or `.bar` material.
final class PaneBackgroundTests: XCTestCase {
    @MainActor
    func testTokenResolvesToTextBackgroundInEveryAppearance() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var token: NSColor?, text: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                token = NSColor.silkwebPaneBackground.usingColorSpace(.sRGB)
                text = NSColor.textBackgroundColor.usingColorSpace(.sRGB)
            }
            XCTAssertEqual(token, text, name.rawValue)
        }
        XCTAssertEqual(NSColor.silkwebPaneBackground.colorNameComponent, "SilkwebPaneBackground")
    }

    @MainActor
    func testEveryPaneRendersTheSharedBackground() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebPanes-" + UUID().uuidString)
        let suite = "Silkweb.PaneBackground." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data("# Title\n\n## Section\n\nShort body.".utf8).write(to: root.appendingPathComponent("Note.md"))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let document = try XCTUnwrap(workspace.snapshot?.documents.first)
        let oldAppearance = NSApp.appearance
        defer {
            NSApp.appearance = oldAppearance
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: root)
        }

        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            NSApp.appearance = appearance
            // A fresh production window per appearance, never ordered on screen.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            defer { window.contentViewController = nil; window.close() }
            let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
            controller.sizingOptions = []
            window.contentViewController = controller
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
            func settle() async throws {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(250))
                controller.view.layoutSubtreeIfNeeded()
            }
            try await settle()
            // After the view's session restore, so the restored (empty) session cannot close it.
            let opened = await workspace.openTab(document, pinned: true)
            XCTAssertTrue(opened)
            workspace.preview.mode = .editor
            workspace.inspectorInfo = false
            workspace.preview.showsOutline = true
            try await settle()
            XCTAssertFalse(window.isVisible)

            let view = try XCTUnwrap(window.contentView)
            // Document loading and the inspector's presentation are asynchronous.
            let deadline = Date().addingTimeInterval(5)
            func ready() -> Bool {
                let views = Self.descendants(view)
                return views.contains { $0 is PlainMarkdownTextView }
                    && views.contains { $0 is NSTableView && !($0 is SidebarOutlineView) && !($0 is DocumentTableView) }
            }
            while Date() < deadline, !ready() { try await settle() }
            let all = Self.descendants(view)
            XCTAssertNotNil(workspace.editor.url, name.rawValue)
            XCTAssertTrue(ready(), "editor or Outline missing in \(name.rawValue); headings \(workspace.preview.headings.count)")
            let sidebar = try XCTUnwrap(all.compactMap { $0 as? SidebarOutlineView }.first?.enclosingScrollView)
            let list = try XCTUnwrap(all.compactMap { $0 as? DocumentTableView }.first?.enclosingScrollView)
            let tabBar = try XCTUnwrap(all.compactMap { $0 as? EditorTabBarView }.first)
            let editor = try XCTUnwrap(all.compactMap { $0 as? PlainMarkdownTextView }.first?.enclosingScrollView)
            // The Outline is SwiftUI's List: the right-most table that is not one of ours.
            let outline = try XCTUnwrap(all.compactMap { $0 as? NSTableView }
                .filter { !($0 is SidebarOutlineView) && !($0 is DocumentTableView) }
                .compactMap { $0.enclosingScrollView }
                .max { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX })
            XCTAssertGreaterThan(outline.convert(outline.bounds, to: view).minX, editor.convert(editor.bounds, to: view).minX,
                                 "Outline must be the inspector column")

            // The token as this window resolves it: an unordered dark window draws at its own
            // elevation, so a context-free resolution is not the reference.
            let swatch = TokenSwatch(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
            view.addSubview(swatch)
            defer { swatch.removeFromSuperview() }
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
            // cacheDisplay keeps transparent regions; the real window paints its background behind them.
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width, y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill(using: .destinationOver)
            }
            NSGraphicsContext.restoreGraphicsState()

            let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            var swatchCenter = swatch.convert(NSPoint(x: 2, y: 2), to: view)
            if !view.isFlipped { swatchCenter.y = view.bounds.height - swatchCenter.y }
            let token = try XCTUnwrap(bitmap.colorAt(x: Int(swatchCenter.x * scale), y: Int(swatchCenter.y * scale))?
                .usingColorSpace(bitmap.colorSpace))
            var backdrop: NSColor?
            appearance.performAsCurrentDrawingAppearance { backdrop = NSColor.windowBackgroundColor.usingColorSpace(bitmap.colorSpace) }
            if name == .aqua {
                XCTAssertEqual(token.redComponent, 1, accuracy: 0.01, "light pane color is white")
            } else {
                XCTAssertLessThan(token.redComponent, 0.25, "\(name.rawValue) pane color is the dark editor gray")
            }
            XCTAssertNotEqual(token, backdrop, "the pane color must differ from the window backdrop")
            let sidebarFrame = sidebar.convert(sidebar.bounds, to: view)
            // Sample ~8pt inside each pane, away from rows, text and controls.
            let samples: [(String, NSPoint)] = [
                ("sidebar", sidebar.convert(NSPoint(x: sidebar.bounds.maxX - 8, y: sidebar.bounds.midY), to: view)),
                // The strip above the folder outline ("LIBRARY"), right of its label.
                ("sidebar header", NSPoint(x: sidebarFrame.maxX - 8, y: view.isFlipped ? sidebarFrame.minY - 4 : sidebarFrame.maxY + 4)),
                ("document list", list.convert(NSPoint(x: list.bounds.maxX - 8, y: list.bounds.midY), to: view)),
                ("tab bar", tabBar.convert(NSPoint(x: tabBar.bounds.maxX - 60, y: tabBar.bounds.midY), to: view)),
                ("editor", editor.convert(NSPoint(x: editor.bounds.maxX - 24, y: editor.bounds.midY), to: view)),
                ("outline", outline.convert(NSPoint(x: outline.bounds.maxX - 8, y: outline.bounds.midY), to: view)),
            ]
            for (pane, sample) in samples {
                var point = sample
                if !view.isFlipped { point.y = view.bounds.height - point.y }
                let pixel = try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(bitmap.colorSpace),
                                          "\(pane) \(name.rawValue)")
                for (actual, wanted, channel) in [(pixel.redComponent, token.redComponent, "R"),
                                                  (pixel.greenComponent, token.greenComponent, "G"),
                                                  (pixel.blueComponent, token.blueComponent, "B")] {
                    XCTAssertEqual(actual * 255, wanted * 255, accuracy: 1.01,
                                   "\(pane) \(channel) in \(name.rawValue): \(pixel) vs \(token) at \(point)")
                }
            }
        }
    }

    private final class TokenSwatch: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.silkwebPaneBackground.setFill()
            bounds.fill()
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

/// silkweb-1.56: every pane paints the one shared pane color, with no wallpaper vibrancy or `.bar` material.
/// silkweb-1.62: the concepts surface (#FBFBFA / #1E1F21), a 32 pt tab strip with an ink underline,
/// a 26 pt status strip on the same surface, and capsule selection in the sidebar and list.
final class PaneBackgroundTests: XCTestCase {
    @MainActor
    func testTokenResolvesToConceptsSurfaceAndSystemTextBackgroundUnderIncreaseContrast() throws {
        let expected: [(NSAppearance.Name, NSColor)] = [
            (.aqua, SilkwebTokens.srgb(0xFBFBFA)), (.darkAqua, SilkwebTokens.srgb(0x1E1F21)),
        ]
        for (name, value) in expected {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var token: NSColor?, wanted: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                token = NSColor.silkwebPaneBackground.usingColorSpace(.sRGB)
                wanted = value.usingColorSpace(.sRGB)
            }
            XCTAssertEqual(token, wanted, name.rawValue)
        }
        // Increase Contrast cannot be simulated offscreen; the branch falls back to the system text background.
        for dark in [false, true] {
            XCTAssertEqual(SilkwebTokens.resolve(SilkwebTokens.pane, dark: dark, highContrast: true, fallback: .textBackgroundColor),
                           .textBackgroundColor)
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
            workspace.session.selectedDocuments = [document.relativePath]
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
            let inactive = TokenSwatch(frame: NSRect(x: 4, y: 0, width: 4, height: 4))
            inactive.color = .silkwebSelectionInactive
            view.addSubview(swatch)
            view.addSubview(inactive)
            defer { swatch.removeFromSuperview(); inactive.removeFromSuperview() }
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
                XCTAssertEqual(token.redComponent * 255, 0xFB, accuracy: 1.5, "light pane color is #FBFBFA")
                XCTAssertEqual(token.blueComponent * 255, 0xFA, accuracy: 1.5, "light pane color is #FBFBFA")
            } else {
                XCTAssertLessThan(token.redComponent, 0.25, "\(name.rawValue) pane color is the dark editor gray")
            }
            XCTAssertNotEqual(token, backdrop, "the pane color must differ from the window backdrop")
            let sidebarFrame = sidebar.convert(sidebar.bounds, to: view)
            func pixel(_ sample: NSPoint) throws -> NSColor {
                var point = sample
                if !view.isFlipped { point.y = view.bounds.height - point.y }
                return try XCTUnwrap(bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(bitmap.colorSpace))
            }
            func assertColor(_ actual: NSColor, _ wanted: NSColor, _ label: String) {
                for (a, w, channel) in [(actual.redComponent, wanted.redComponent, "R"), (actual.greenComponent, wanted.greenComponent, "G"),
                                        (actual.blueComponent, wanted.blueComponent, "B")] {
                    XCTAssertEqual(a * 255, w * 255, accuracy: 1.01, "\(label) \(channel) in \(name.rawValue): \(actual) vs \(wanted)")
                }
            }
            // R1 chrome: a 32 pt tab strip, and a 26 pt status strip under the editor on the pane surface.
            XCTAssertEqual(tabBar.frame.height, 32, accuracy: 0.5, "tab bar height in \(name.rawValue)")
            let editorFrame = editor.convert(editor.bounds, to: view)
            let bottom: CGFloat = view.isFlipped ? view.bounds.maxY : 0
            let below: (CGFloat) -> CGFloat = { view.isFlipped ? bottom - $0 : bottom + $0 }
            XCTAssertEqual(abs(below(0) - (view.isFlipped ? editorFrame.maxY : editorFrame.minY)), 26, accuracy: 1.5,
                           "status strip under the editor in \(name.rawValue)")
            // Mid-strip: the leading counts slot is empty and “Saved” sits at the trailing edge.
            assertColor(try pixel(NSPoint(x: editorFrame.midX, y: below(13))), token, "status bar")
            XCTAssertNotEqual(try pixel(NSPoint(x: editorFrame.midX, y: below(25.75))), token, "status hairline in \(name.rawValue)")
            // The active tab's 2 pt underline is ink (label colour), far from the pane colour.
            let active = try XCTUnwrap(tabBar.buttons.first { $0.tab.id == workspace.activeTabID })
            let ink = try pixel(active.convert(NSPoint(x: active.bounds.width - 30, y: active.isFlipped ? active.bounds.maxY - 1 : 1), to: view))
            XCTAssertGreaterThan(abs(ink.redComponent - token.redComponent), 0.4, "active tab underline in \(name.rawValue)")
            // An unordered window is never key: both capsules use the inactive fill, never the system accent.
            var inactiveCenter = inactive.convert(NSPoint(x: 2, y: 2), to: view)
            if !view.isFlipped { inactiveCenter.y = view.bounds.height - inactiveCenter.y }
            let inactiveToken = try XCTUnwrap(bitmap.colorAt(x: Int(inactiveCenter.x * scale), y: Int(inactiveCenter.y * scale))?
                .usingColorSpace(bitmap.colorSpace))
            func capsuleProbe(_ scroll: NSScrollView, fromTrailing: Bool) throws -> NSPoint {
                let table = try XCTUnwrap(scroll.documentView as? NSTableView)
                let row = try XCTUnwrap(table.selectedRowIndexes.first, "selection in \(name.rawValue)")
                let rowView = try XCTUnwrap(table.rowView(atRow: row, makeIfNecessary: false) as? CapsuleRowView)
                let capsule = rowView.capsuleRect
                XCTAssertEqual(rowView.convert(capsule, to: table).minX, 10, accuracy: 0.5)
                XCTAssertEqual(rowView.convert(capsule, to: table).maxX, table.bounds.width - 10, accuracy: 0.5)
                let top = rowView.isFlipped ? capsule.minY + 3 : capsule.maxY - 3
                return rowView.convert(NSPoint(x: fromTrailing ? capsule.maxX - 10 : capsule.minX + 8, y: top), to: view)
            }
            assertColor(try pixel(capsuleProbe(sidebar, fromTrailing: false)), inactiveToken, "sidebar capsule")
            assertColor(try pixel(capsuleProbe(list, fromTrailing: true)), inactiveToken, "document list capsule")
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
        var color = NSColor.silkwebPaneBackground
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            bounds.fill()
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}

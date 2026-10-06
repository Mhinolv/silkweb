import AppKit
import SilkwebCore
import SwiftUI
import XCTest

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
            XCTAssertEqual(
                SilkwebTokens.resolve(
                    SilkwebTokens.pane, dark: dark, highContrast: true, fallback: .textBackgroundColor),
                .textBackgroundColor)
        }
        XCTAssertEqual(NSColor.silkwebPaneBackground.colorNameComponent, "SilkwebPaneBackground")
    }

    @MainActor
    func testEveryPaneRendersTheSharedBackground() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebPanes-" + UUID().uuidString)
        let defaults = disposableDefaults("PaneBackground")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data("# Title\n\n## Section\n\nShort body.".utf8).write(to: root.appendingPathComponent("Note.md"))
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let document = try XCTUnwrap(workspace.snapshot?.documents.first)
        let oldAppearance = NSApp.appearance
        defer {
            NSApp.appearance = oldAppearance
            try? FileManager.default.removeItem(at: root)
        }

        for name in [NSAppearance.Name.aqua, .darkAqua, .accessibilityHighContrastDarkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            NSApp.appearance = appearance
            // A fresh production window per appearance, never ordered on screen.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
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
            XCTAssertTrue(
                ready(), "editor or Outline missing in \(name.rawValue); headings \(workspace.preview.headings.count)")
            let sidebar = try XCTUnwrap(all.compactMap { $0 as? SidebarOutlineView }.first?.enclosingScrollView)
            let list = try XCTUnwrap(all.compactMap { $0 as? DocumentTableView }.first?.enclosingScrollView)
            let tabBar = try XCTUnwrap(all.compactMap { $0 as? EditorTabBarView }.first)
            let editor = try XCTUnwrap(all.compactMap { $0 as? PlainMarkdownTextView }.first?.enclosingScrollView)
            // The Outline is SwiftUI's List: the right-most table that is not one of ours.
            let outline = try XCTUnwrap(
                all.compactMap { $0 as? NSTableView }
                    .filter { !($0 is SidebarOutlineView) && !($0 is DocumentTableView) }
                    .compactMap { $0.enclosingScrollView }
                    .max { $0.convert($0.bounds, to: view).minX < $1.convert($1.bounds, to: view).minX })
            XCTAssertGreaterThan(
                outline.convert(outline.bounds, to: view).minX, editor.convert(editor.bounds, to: view).minX,
                "Outline must be the inspector column")
            // 1.81: pin legacy scroll bars (System Settings with a mouse attached) so the result never depends
            // on the machine; content that fits must not paint an empty scroller track over a pane.
            for scroll in [sidebar, list, editor] { scroll.scrollerStyle = .legacy }
            try await settle()
            XCTAssertTrue(sidebar.verticalScroller?.isHidden ?? true, "sidebar scroller track in \(name.rawValue)")

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
            context.cgContext.scaleBy(
                x: CGFloat(bitmap.pixelsWide) / view.bounds.width, y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                view.bounds.fill(using: .destinationOver)
            }
            NSGraphicsContext.restoreGraphicsState()

            let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
            var swatchCenter = swatch.convert(NSPoint(x: 2, y: 2), to: view)
            if !view.isFlipped { swatchCenter.y = view.bounds.height - swatchCenter.y }
            let token = try XCTUnwrap(
                bitmap.colorAt(x: Int(swatchCenter.x * scale), y: Int(swatchCenter.y * scale))?
                    .usingColorSpace(bitmap.colorSpace))
            var backdrop: NSColor?
            appearance.performAsCurrentDrawingAppearance {
                backdrop = NSColor.windowBackgroundColor.usingColorSpace(bitmap.colorSpace)
            }
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
                return try XCTUnwrap(
                    bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(bitmap.colorSpace)
                )
            }
            func assertColor(_ actual: NSColor, _ wanted: NSColor, _ label: String) {
                for (a, w, channel) in [
                    (actual.redComponent, wanted.redComponent, "R"),
                    (actual.greenComponent, wanted.greenComponent, "G"),
                    (actual.blueComponent, wanted.blueComponent, "B"),
                ] {
                    XCTAssertEqual(
                        a * 255, w * 255, accuracy: 1.01,
                        "\(label) \(channel) in \(name.rawValue): \(actual) vs \(wanted)")
                }
            }
            // R1 chrome: a 32 pt tab strip, and a 26 pt status strip under the editor on the pane surface.
            XCTAssertEqual(tabBar.frame.height, 32, accuracy: 0.5, "tab bar height in \(name.rawValue)")
            let editorFrame = editor.convert(editor.bounds, to: view)
            let bottom: CGFloat = view.isFlipped ? view.bounds.maxY : 0
            let below: (CGFloat) -> CGFloat = { view.isFlipped ? bottom - $0 : bottom + $0 }
            XCTAssertEqual(
                abs(below(0) - (view.isFlipped ? editorFrame.maxY : editorFrame.minY)), 26, accuracy: 1.5,
                "status strip under the editor in \(name.rawValue)")
            // Between the centred counts and “Saved” at the trailing edge the strip is empty (#91).
            let emptyX = editorFrame.minX + editorFrame.width * 0.75
            assertColor(try pixel(NSPoint(x: emptyX, y: below(13))), token, "status bar")
            XCTAssertNotEqual(
                try pixel(NSPoint(x: editorFrame.midX, y: below(25.75))), token, "status hairline in \(name.rawValue)")
            // 1.65 folder tab: the active tab is open at the bottom onto the editor surface, with no underline.
            let active = try XCTUnwrap(tabBar.buttons.first { $0.tab.id == workspace.activeTabID })
            let open = try pixel(
                active.convert(
                    NSPoint(x: active.bounds.width - 30, y: active.isFlipped ? active.bounds.maxY - 0.25 : 0.25),
                    to: view))
            assertColor(open, token, "active tab joins the editor")
            // An unordered window is never key: both capsules use the inactive fill, never the system accent.
            var inactiveCenter = inactive.convert(NSPoint(x: 2, y: 2), to: view)
            if !view.isFlipped { inactiveCenter.y = view.bounds.height - inactiveCenter.y }
            let inactiveToken = try XCTUnwrap(
                bitmap.colorAt(x: Int(inactiveCenter.x * scale), y: Int(inactiveCenter.y * scale))?
                    .usingColorSpace(bitmap.colorSpace))
            func capsuleProbe(_ scroll: NSScrollView, fromTrailing: Bool) throws -> NSPoint {
                let table = try XCTUnwrap(scroll.documentView as? NSTableView)
                let row = try XCTUnwrap(table.selectedRowIndexes.first, "selection in \(name.rawValue)")
                let rowView = try XCTUnwrap(table.rowView(atRow: row, makeIfNecessary: false) as? CapsuleRowView)
                let capsule = rowView.capsuleRect
                XCTAssertEqual(rowView.convert(capsule, to: table).minX, 10, accuracy: 0.5)
                XCTAssertEqual(rowView.convert(capsule, to: table).maxX, table.bounds.width - 10, accuracy: 0.5)
                let top = rowView.isFlipped ? capsule.minY + 3 : capsule.maxY - 3
                return rowView.convert(
                    NSPoint(x: fromTrailing ? capsule.maxX - 10 : capsule.minX + 8, y: top), to: view)
            }
            assertColor(try pixel(capsuleProbe(sidebar, fromTrailing: false)), inactiveToken, "sidebar capsule")
            assertColor(try pixel(capsuleProbe(list, fromTrailing: true)), inactiveToken, "document list capsule")
            // Sample ~8pt inside each pane, away from rows, text and controls.
            let samples: [(String, NSPoint)] = [
                ("sidebar", sidebar.convert(NSPoint(x: sidebar.bounds.maxX - 8, y: sidebar.bounds.midY), to: view)),
                // The strip above the folder outline ("LIBRARY"), right of its label.
                (
                    "sidebar header",
                    NSPoint(x: sidebarFrame.maxX - 8, y: view.isFlipped ? sidebarFrame.minY - 4 : sidebarFrame.maxY + 4)
                ),
                ("document list", list.convert(NSPoint(x: list.bounds.maxX - 8, y: list.bounds.midY), to: view)),
                ("tab bar", tabBar.convert(NSPoint(x: tabBar.bounds.maxX - 60, y: tabBar.bounds.midY), to: view)),
                ("editor", editor.convert(NSPoint(x: editor.bounds.maxX - 24, y: editor.bounds.midY), to: view)),
                ("outline", outline.convert(NSPoint(x: outline.bounds.maxX - 8, y: outline.bounds.midY), to: view)),
            ]
            for (pane, sample) in samples {
                var point = sample
                if !view.isFlipped { point.y = view.bounds.height - point.y }
                let pixel = try XCTUnwrap(
                    bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(
                        bitmap.colorSpace),
                    "\(pane) \(name.rawValue)")
                for (actual, wanted, channel) in [
                    (pixel.redComponent, token.redComponent, "R"),
                    (pixel.greenComponent, token.greenComponent, "G"),
                    (pixel.blueComponent, token.blueComponent, "B"),
                ] {
                    XCTAssertEqual(
                        actual * 255, wanted * 255, accuracy: 1.01,
                        "\(pane) \(channel) in \(name.rawValue): \(pixel) vs \(token) at \(point)")
                }
            }
        }
    }

    /// silkweb-1.81: custom Settings colours saved in the test runner's real defaults domain must not reach
    /// tests. Loads preferences the way the app does at first use, then runs the pane-colour test.
    @MainActor
    func testCustomColoursInTheRealDomainDoNotReachThePanes() async throws {
        let real = UserDefaults.standard
        let key = WritingPreferences.defaultsKey
        let saved = real.data(forKey: key)
        let live = LivePreferences.shared.current
        defer {
            if let saved { real.set(saved, forKey: key) } else { real.removeObject(forKey: key) }
            LivePreferences.shared.current = live
        }
        var custom = WritingPreferences()
        custom.colors[dark: false].surface = HexColor(0x22AA44)
        custom.colors[dark: true].surface = HexColor(0x114422)
        custom.fontSize = 22
        custom.save(to: real)

        LivePreferences.shared.current = LivePreferences().current
        let settings = WritingSettings(live: false)
        XCTAssertFalse(settings.defaults === real, "tests must not use the real domain")
        XCTAssertEqual(settings.preferences, WritingPreferences())
        XCTAssertEqual(LivePreferences.shared.current, WritingPreferences())
        try testTokenResolvesToConceptsSurfaceAndSystemTextBackgroundUnderIncreaseContrast()
        try await testEveryPaneRendersTheSharedBackground()
    }

    /// silkweb-1.62 owner evidence: the titlebar/toolbar strip renders the pane token, not a lighter or
    /// grey toolbar material, with only a hairline between it and the panes. Samples the real window frame.
    @MainActor
    func testToolbarStripRendersThePaneSurface() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebToolbar-" + UUID().uuidString)
        let defaults = disposableDefaults("ToolbarSurface")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        try Data("# Title\n\nBody.".utf8).write(to: root.appendingPathComponent("Note.md"))
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let oldAppearance = NSApp.appearance
        defer {
            NSApp.appearance = oldAppearance
            try? FileManager.default.removeItem(at: root)
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            NSApp.appearance = appearance
            // The production window shape (titled, unified toolbar from SwiftUI), never ordered on screen.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = appearance
            window.backgroundColor = .windowBackgroundColor
            defer { window.contentViewController = nil; window.close() }
            let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
            controller.sizingOptions = []
            window.contentViewController = controller
            window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
            for _ in 0..<3 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(200))
            }
            XCTAssertFalse(window.isVisible)
            let content = try XCTUnwrap(window.contentView)
            let frameView = try XCTUnwrap(content.superview)
            frameView.layoutSubtreeIfNeeded()
            let swatch = TokenSwatch(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
            content.addSubview(swatch)
            defer { swatch.removeFromSuperview() }
            let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
            appearance.performAsCurrentDrawingAppearance { frameView.cacheDisplay(in: frameView.bounds, to: bitmap) }
            // Same backdrop the snapshot harness paints behind transparent regions.
            let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(
                x: CGFloat(bitmap.pixelsWide) / frameView.bounds.width,
                y: CGFloat(bitmap.pixelsHigh) / frameView.bounds.height)
            appearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                frameView.bounds.fill(using: .destinationOver)
            }
            NSGraphicsContext.restoreGraphicsState()
            let scale = CGFloat(bitmap.pixelsHigh) / frameView.bounds.height
            /// `top` is measured in points down from the window's top edge.
            func pixel(x: CGFloat, top: CGFloat) throws -> NSColor {
                try XCTUnwrap(
                    bitmap.colorAt(x: Int(x * scale), y: Int(top * scale))?.usingColorSpace(bitmap.colorSpace))
            }
            let contentFrame = content.convert(content.bounds, to: frameView)
            let titlebarHeight = frameView.isFlipped ? contentFrame.minY : frameView.bounds.height - contentFrame.maxY
            XCTAssertGreaterThan(titlebarHeight, 20, "window has a titlebar/toolbar strip in \(name.rawValue)")
            let swatchPoint = swatch.convert(NSPoint(x: 2, y: 2), to: frameView)
            let token = try pixel(
                x: swatchPoint.x, top: frameView.isFlipped ? swatchPoint.y : frameView.bounds.height - swatchPoint.y)
            // The editor surface just below the strip, as the reference the owner compared against.
            let editor = try pixel(x: frameView.bounds.maxX - 24, top: titlebarHeight + 120)
            func assertSurface(_ actual: NSColor, _ label: String) {
                for (a, w, channel) in [
                    (actual.redComponent, token.redComponent, "R"), (actual.greenComponent, token.greenComponent, "G"),
                    (actual.blueComponent, token.blueComponent, "B"),
                ] {
                    XCTAssertEqual(
                        a * 255, w * 255, accuracy: 1.01,
                        "\(label) \(channel) in \(name.rawValue): \(actual) vs \(token)")
                }
            }
            assertSurface(editor, "editor below toolbar")
            // Empty toolbar space: above the controls, and between the title and the trailing items.
            for (label, x, top) in [
                ("toolbar top-centre", frameView.bounds.midX, CGFloat(4)),
                ("toolbar top-trailing", frameView.bounds.maxX - 40, CGFloat(4)),
                ("toolbar centre", frameView.bounds.width * 0.62, titlebarHeight / 2),
                ("toolbar bottom", frameView.bounds.width * 0.62, titlebarHeight - 4),
            ] {
                assertSurface(try pixel(x: x, top: top), label)
            }
            // Exactly one divider between the strip and the panes: a hairline at the titlebar's bottom edge.
            let edge = (Int((titlebarHeight - 2) * scale)...Int((titlebarHeight + 1) * scale)).compactMap {
                bitmap.colorAt(x: Int(frameView.bounds.width * 0.62 * scale), y: $0)?.usingColorSpace(bitmap.colorSpace)
            }
            XCTAssertTrue(
                edge.contains { abs($0.redComponent - token.redComponent) * 255 > 4 },
                "titlebar hairline in \(name.rawValue): \(edge)")
        }
    }

    /// silkweb-1.67 owner report: while a library search is active the list column (field, scope, count,
    /// results or No Results) is the flat Surface, also with a custom 1.24 Surface, never wallpaper material.
    @MainActor
    func testSearchStateListColumnRendersTheSurface() async throws {
        _ = NSApplication.shared
        // A short root name: the scope picker shows it, and a long one widens the search chrome.
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebSearchPane-" + UUID().uuidString)
        let root = parent.appendingPathComponent("Library")
        let defaults = disposableDefaults("SearchPane")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
        for index in 1...3 {
            try Data("# Fog \(index)\n\nFog over the bay.".utf8).write(
                to: root.appendingPathComponent("Note \(index).md"))
        }
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let oldAppearance = NSApp.appearance
        let oldPreferences = LivePreferences.shared.current
        defer {
            NSApp.appearance = oldAppearance
            LivePreferences.shared.current = oldPreferences
            ColorRevision.shared.bump()
            try? FileManager.default.removeItem(at: parent)
        }

        for custom in [false, true] {
            var preferences = oldPreferences
            preferences.colors.light.surface = custom ? HexColor(0x2E6B3A) : nil
            preferences.colors.dark.surface = custom ? HexColor(0x163A22) : nil
            LivePreferences.shared.current = preferences
            ColorRevision.shared.bump()
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: name))
                NSApp.appearance = appearance
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                    styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = appearance
                defer { window.contentViewController = nil; window.close() }
                let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
                controller.sizingOptions = []
                window.contentViewController = controller
                window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
                let view = try XCTUnwrap(window.contentView)
                for query in ["fog", "silkweb-no-matches"] {
                    let label = "\(query) \(custom ? "custom" : "default") \(name.rawValue)"
                    workspace.search.text = query
                    await workspace.search.query(quick: false)
                    for _ in 0..<3 {
                        controller.view.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(200))
                    }
                    XCTAssertFalse(window.isVisible)
                    XCTAssertEqual(workspace.filteredSearchResults.isEmpty, query != "fog", label)
                    try assertSearchColumn(in: view, appearance: appearance, results: query == "fog", label: label)
                }
                workspace.search.text = ""
                workspace.search.results = []
            }
        }
    }

    /// silkweb-1.67 lifecycle: search with results → clear → search with no results, each across a resize
    /// sweep, in the real workspace view. The column stays on the Surface at every size.
    @MainActor
    func testSearchModeLifecycleKeepsTheSurfaceAcrossResizes() async throws {
        _ = NSApplication.shared
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebSearchLifecycle-" + UUID().uuidString)
        let root = parent.appendingPathComponent("Library")
        let defaults = disposableDefaults("SearchLifecycle")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 1...12 {
            try Data("# Fog \(index)\n\nFog over the bay.".utf8).write(
                to: root.appendingPathComponent("Note \(index).md"))
        }
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        let oldAppearance = NSApp.appearance
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        NSApp.appearance = appearance
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        defer {
            window.contentViewController = nil
            window.close()
            NSApp.appearance = oldAppearance
            try? FileManager.default.removeItem(at: parent)
        }
        let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
        controller.sizingOptions = []
        window.contentViewController = controller
        let view = try XCTUnwrap(window.contentView)
        func settle() async throws {
            for _ in 0..<2 {
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(150))
            }
        }
        func sweep(_ results: Bool, _ phase: String) async throws {
            for size in [
                NSSize(width: 1200, height: 800), NSSize(width: 900, height: 520), NSSize(width: 1500, height: 1000),
                NSSize(width: 1000, height: 400), NSSize(width: 1200, height: 800),
            ] {
                window.setContentSize(size)
                try await settle()
                try assertSearchColumn(in: view, appearance: appearance, results: results, label: "\(phase) \(size)")
            }
        }
        try await settle()

        workspace.search.text = "fog"
        await workspace.search.query(quick: false)
        try await settle()
        XCTAssertEqual(workspace.filteredSearchResults.count, 12)
        try await sweep(true, "results")

        workspace.search.text = ""
        workspace.search.results = []
        try await settle()
        let all = Self.descendants(view)
        let column = try XCTUnwrap(all.compactMap { $0 as? DocumentTableView }.first?.enclosingScrollView)
        let columnFrame = column.convert(column.bounds, to: view)
        XCTAssertFalse(
            all.compactMap { $0 as? NSTableView }
                .filter { !($0 is SidebarOutlineView) && !($0 is DocumentTableView) }
                .contains {
                    columnFrame.contains(NSPoint(x: $0.convert($0.bounds, to: view).midX, y: columnFrame.midY))
                },
            "results list removed after clearing")

        workspace.search.text = "silkweb-no-matches"
        await workspace.search.query(quick: false)
        try await settle()
        XCTAssertTrue(workspace.filteredSearchResults.isEmpty)
        try await sweep(false, "no results")
        workspace.search.text = ""
        workspace.search.results = []
    }

    /// Samples the list column's right gutter top to bottom and a row near its bottom edge against the token.
    @MainActor
    private func assertSearchColumn(in view: NSView, appearance: NSAppearance, results: Bool, label: String) throws {
        let swatch = TokenSwatch(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
        let inactive = TokenSwatch(frame: NSRect(x: 4, y: 0, width: 4, height: 4))
        inactive.color = .silkwebSelectionInactive
        view.addSubview(swatch)
        view.addSubview(inactive)
        defer { swatch.removeFromSuperview(); inactive.removeFromSuperview() }
        let all = Self.descendants(view)
        // The folder list stays in the hierarchy (hidden) under the search overlay; its split-view pane is the column.
        var column: NSView? = all.compactMap { $0 as? DocumentTableView }.first
        while let candidate = column, !(candidate.superview is NSSplitView) { column = candidate.superview }
        let pane = try XCTUnwrap(column, "list column pane: \(label)")
        let listFrame = pane.convert(pane.bounds, to: view).intersection(view.bounds)
        let resultTable = all.compactMap { $0 as? NSTableView }
            .filter { !($0 is SidebarOutlineView) && !($0 is DocumentTableView) }
            .first {
                $0.convert($0.bounds, to: view).midX > listFrame.minX
                    && $0.convert($0.bounds, to: view).midX < listFrame.maxX
            }
        XCTAssertEqual(resultTable != nil, results, "results list shown only with matches: \(label)")
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(
            x: CGFloat(bitmap.pixelsWide) / view.bounds.width, y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
        appearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            view.bounds.fill(using: .destinationOver)
        }
        NSGraphicsContext.restoreGraphicsState()
        let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
        func pixel(_ sample: NSPoint) throws -> NSColor {
            var point = sample
            if !view.isFlipped { point.y = view.bounds.height - point.y }
            return try XCTUnwrap(
                bitmap.colorAt(x: Int(point.x * scale), y: Int(point.y * scale))?.usingColorSpace(bitmap.colorSpace))
        }
        let token = try pixel(swatch.convert(NSPoint(x: 2, y: 2), to: view))
        let inactiveToken = try pixel(inactive.convert(NSPoint(x: 2, y: 2), to: view))
        // The injected custom Surfaces are greens; the defaults are near-neutral.
        let custom = LivePreferences.shared.colors(dark: appearance.name == .darkAqua).surface != nil
        XCTAssertEqual(
            token.greenComponent - max(token.redComponent, token.blueComponent) > 0.05, custom,
            "Surface swatch \(label): \(token)")
        var mismatches: [String] = []
        func off(_ actual: NSColor, _ wanted: NSColor) -> Bool {
            [
                (actual.redComponent, wanted.redComponent), (actual.greenComponent, wanted.greenComponent),
                (actual.blueComponent, wanted.blueComponent),
            ].contains { abs($0.0 - $0.1) * 255 > 1.01 }
        }
        // The selected result shows the inactive capsule (an unordered window is never key), inset like the
        // document list's, with Surface beside it. The row is skipped by the sweeps below.
        var skipped: [NSRect] = []
        if let resultTable {
            let row = try XCTUnwrap(resultTable.selectedRowIndexes.first, "first result selected: \(label)")
            XCTAssertEqual(
                resultTable.selectionHighlightStyle, .none, "no system highlight under the capsule: \(label)")
            let rect = resultTable.rect(ofRow: row)
            skipped.append(resultTable.convert(rect, to: view))
            XCTAssertEqual(rect.height, DocumentRow.height, "1.64 row height: \(label)")
            // Mid-row, clear of the rounded corners: the capsule edges sit ~10 pt from the table edges.
            let width = resultTable.bounds.width
            for (x, wanted, region) in [
                (Spacing.capsuleInset - 1.5, token, "outside capsule leading"),
                (Spacing.capsuleInset + 1.5, inactiveToken, "capsule leading edge"),
                (width - Spacing.capsuleInset - 2.5, inactiveToken, "capsule trailing edge"),
                (width - Spacing.capsuleInset + 1.5, token, "outside capsule trailing"),
            ] {
                let actual = try pixel(resultTable.convert(NSPoint(x: x, y: rect.midY), to: view))
                if off(actual, wanted) { mismatches.append("\(region): \(actual) vs \(wanted)") }
            }
        }
        func check(_ point: NSPoint, _ region: String) throws {
            guard !skipped.contains(where: { $0.insetBy(dx: 0, dy: -2).contains(point) }) else { return }
            let actual = try pixel(point)
            if off(actual, token) { mismatches.append("\(region) \(point): \(actual) vs \(token)") }
        }
        // Top to bottom just inside the column's trailing edge: field header, scope, count, rows, below the rows.
        // A legacy scroller (system-drawn) may take the trailing edge when results overflow; stay left of it.
        let clip = resultTable.flatMap { $0.enclosingScrollView?.contentView }.map { $0.convert($0.bounds, to: view) }
        let trailing = min(listFrame.maxX, clip?.maxX ?? listFrame.maxX) - 4
        let top = view.isFlipped ? view.bounds.minY + 3 : view.bounds.maxY - 3
        let bottom = view.isFlipped ? view.bounds.maxY - 3 : view.bounds.minY + 3
        for y in stride(from: min(top, bottom), through: max(top, bottom), by: 4) {
            let inList = clip.map { y >= $0.minY && y <= $0.maxY } ?? false
            try check(NSPoint(x: inList ? trailing : listFrame.maxX - 4, y: y), "gutter")
        }
        // Across the column near its bottom: below the last result row or the No Results body.
        // When results overflow the column, row text reaches the bottom; only the space past the rows counts.
        let rows = resultTable.flatMap { table in
            table.numberOfRows > 0
                ? table.convert(table.rect(ofRow: 0).union(table.rect(ofRow: table.numberOfRows - 1)), to: view) : nil
        }
        for x in stride(from: listFrame.minX + 8, through: trailing, by: 8) {
            let point = NSPoint(x: x, y: bottom + (view.isFlipped ? -8 : 8))
            if rows?.contains(point) != true { try check(point, "bottom") }
        }
        XCTAssertTrue(
            mismatches.isEmpty, "\(label): \(mismatches.count) off-Surface samples, e.g. \(mismatches.prefix(4))")
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

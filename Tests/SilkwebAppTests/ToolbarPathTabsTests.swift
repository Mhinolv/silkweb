import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// silkweb-1.65: the compact bar with its breadcrumb, and hairline folder tabs with a coral unsaved dot.
final class ToolbarPathTabsTests: XCTestCase {
    static let deep =
        "Vanlife/North American Road Trips/Pennsylvania and the Great Lakes/Lake Erie Shoreline Campgrounds/Presque Isle State Park"

    @MainActor private func library() async throws -> (LibraryWorkspace, URL) {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebPath-" + UUID().uuidString)
        let root = container.appendingPathComponent("Field Notes")
        for folder in ["Vanlife/East", Self.deep] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for (path, text) in [
            ("Vanlife/East/Settling In.md", "# Settling In\n\nBody."), ("Vanlife/Road.md", "# Road"),
            ("Other.md", "# Other"), (Self.deep + "/Settling In at the Campground.md", "# Campground"),
        ] {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        let workspace = LibraryWorkspace(defaults: disposableDefaults("PathTabs"))
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        return (workspace, container)
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private final class Swatch: NSView {
        var color = NSColor.clear
        override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
    }

    /// Walks the accessibility tree that VoiceOver sees (SwiftUI elements answer the informal protocol).
    @MainActor private static func accessibilityTree(_ element: AnyObject) -> [AnyObject] {
        let children = (element.accessibilityChildren?() ?? nil) ?? []
        return [element] + children.flatMap { accessibilityTree($0 as AnyObject) }
    }
    @MainActor private static func label(_ element: AnyObject) -> String? { element.accessibilityLabel?() ?? nil }
    @MainActor private static func value(_ element: AnyObject) -> String? {
        let selector = NSSelectorFromString("accessibilityValue")
        guard let object = element as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    /// The production window shape with a unified toolbar from SwiftUI, never ordered on screen.
    @MainActor
    func testCompactBarBreadcrumbNavigatesAndFollowsWindowButtons() async throws {
        _ = NSApplication.shared
        let (workspace, container) = try await library()
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.contentViewController = nil
            window.close()
            NSApp.appearance = oldAppearance
            try? FileManager.default.removeItem(at: container)
        }
        let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        func settle() async throws {
            for _ in 0..<4 {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(120))
            }
        }
        workspace.navigate(folder: "Vanlife/East", documents: ["Vanlife/East/Settling In.md"], pinned: true)
        await workspace.waitForNavigation()
        try await settle()
        XCTAssertFalse(window.isVisible)

        // One slim bar: compact style, at the window's frame, about 38 pt tall.
        XCTAssertEqual(window.toolbarStyle, .unifiedCompact)
        XCTAssertEqual(window.frame.height, 900)
        let barHeight = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(barHeight, 20)
        XCTAssertLessThanOrEqual(barHeight, 40)
        let toolbar = try XCTUnwrap(window.toolbar)
        func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        func placed() -> [NSView] {
            toolbar.items.compactMap(\.view).filter { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
        }
        XCTAssertEqual(placed().count, toolbar.items.count, "no item overflows into the » menu at 1400 pt")
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        func firstMinX() -> CGFloat { placed().map { frame($0).minX }.min() ?? .infinity }
        XCTAssertGreaterThan(firstMinX(), frame(zoom).maxX, "items follow the traffic lights")
        // The breadcrumb fills the middle, so the trailing items stay at the trailing edge.
        let info = try XCTUnwrap(toolbar.items.first { $0.label == "Show Document Info" }?.view)
        XCTAssertEqual(frame(info).maxX, window.frame.width - Spacing.small, accuracy: 3)

        // The breadcrumb: the open document's real folder, with the count as a suffix, for VoiceOver too.
        let crumbItem = try XCTUnwrap(
            toolbar.items.first { item in
                item.view.map { Self.descendants($0).contains { $0 is BreadcrumbView } } == true
            }?.view)
        let breadcrumb = try XCTUnwrap(Self.descendants(crumbItem).compactMap { $0 as? BreadcrumbView }.first)
        XCTAssertEqual(workspace.breadcrumb.crumbs.map(\.title), ["Field Notes", "Vanlife", "East"])
        func element(_ label: String) -> AnyObject? {
            Self.accessibilityTree(breadcrumb).first { Self.label($0) == label }
        }
        let group = try XCTUnwrap(element("Path"), "breadcrumb group")
        XCTAssertEqual(Self.value(group), "Field Notes › Vanlife › East › Settling In, 1 document")
        for name in ["Field Notes", "Vanlife", "East"] {
            let crumb = try XCTUnwrap(element("\(name), folder"), name)
            XCTAssertEqual(crumb.accessibilityHelp?() ?? nil, "Shows this folder", name)
        }
        XCTAssertNil(element("Settling In, folder"), "the last crumb is not a link")

        // Pressing an intermediate crumb is a sidebar click: scope, list and sidebar change; the tab stays open.
        let openURL = workspace.editor.url
        // VoiceOver's press; AppKit reports false for an unordered window but still sends the action.
        _ = try XCTUnwrap(element("Vanlife, folder")).accessibilityPerformPress?()
        await workspace.waitForNavigation()
        try await settle()
        XCTAssertEqual(workspace.session.selectedFolder, "Vanlife")
        XCTAssertNil(workspace.session.selectedTagID)
        XCTAssertEqual(workspace.documents.map(\.relativePath), ["Vanlife/Road.md"])
        XCTAssertEqual(workspace.editor.url, openURL)
        let outline = try XCTUnwrap(Self.descendants(controller.view).compactMap { $0 as? NSOutlineView }.first)
        let selected = try XCTUnwrap(outline.item(atRow: outline.selectedRow) as? FolderSidebar.Item)
        XCTAssertEqual(selected.folder?.relativePath, "Vanlife", "sidebar selection stays in sync")
        XCTAssertNotNil(Self.descendants(controller.view).first { $0 is EditorTabBarView })

        // A long path folds into `…` at the minimum window width; the document title stays, VoiceOver hears it all.
        window.setFrame(NSRect(x: 0, y: 0, width: 900, height: 900), display: false)
        workspace.navigate(
            folder: Self.deep, documents: [Self.deep + "/Settling In at the Campground.md"], pinned: true)
        await workspace.waitForNavigation()
        try await settle()
        let geometry = toolbar.items.map { item -> String in
            let view = item.view
            return
                "\(item.label): placed=\(view?.window != nil) frame=\(view.map(frame) ?? .zero) fitting=\(view?.fittingSize ?? .zero) priority=\(item.visibilityPriority.rawValue)"
        }.joined(separator: "\n")
        XCTAssertEqual(
            placed().count, toolbar.items.count,
            "no item overflows at the minimum width; breadcrumb width \(workspace.toolbarMetrics.breadcrumbWidth), window \(window.frame)\n\(geometry)"
        )
        let folders: [String] = ["Field Notes"] + Self.deep.split(separator: "/").map(String.init)
        let fullPath: String = (folders + ["Settling In at the Campground"]).joined(separator: " › ")
        XCTAssertEqual(element("Path").flatMap(Self.value), fullPath + ", 1 document")
        let more = try XCTUnwrap(
            Self.accessibilityTree(breadcrumb).first { Self.label($0)?.hasPrefix("More folders: ") == true })
        XCTAssertTrue(Self.label(more)?.contains("North American Road Trips") == true)
        let titles: [String?] = Self.accessibilityTree(breadcrumb).flatMap { [Self.label($0), Self.value($0)] }
        XCTAssertTrue(
            titles.contains("Settling In at the Campground"), "the document title is never dropped: \(titles)")
        let fit = try XCTUnwrap(breadcrumb.fit)
        XCTAssertFalse(fit.collapsed.isEmpty, "the long path folds")
        XCTAssertFalse(fit.showsCount, "the count is the first thing dropped")
        XCTAssertFalse(breadcrumb.currentLabel.isHidden)
        XCTAssertGreaterThanOrEqual(breadcrumb.currentLabel.frame.width, 80 - 2 * BreadcrumbView.padding)
        XCTAssertLessThanOrEqual(breadcrumb.currentLabel.frame.maxX, breadcrumb.bounds.maxX + 0.5)
        XCTAssertLessThanOrEqual(
            frame(crumbItem).maxX, frame(try XCTUnwrap(toolbar.items.first { $0.label == "View Mode" }?.view)).minX)

        // Without the window buttons the items move to the bar's leading inset, and back when they return.
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        try await settle()
        let shown = firstMinX()
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
        for _ in 0..<20 where firstMinX() > Spacing.small { try await settle() }
        XCTAssertLessThanOrEqual(firstMinX(), Spacing.small)
        XCTAssertEqual(placed().count, toolbar.items.count)
        XCTAssertEqual(frame(info).maxX, window.frame.width - Spacing.small, accuracy: 3)
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = false
        }
        for _ in 0..<20 where firstMinX() <= frame(zoom).maxX { try await settle() }
        XCTAssertEqual(firstMinX(), shown, accuracy: 0.5)
        XCTAssertGreaterThan(firstMinX(), frame(zoom).maxX)
    }

    @MainActor private func tabsFixture() async throws -> LibraryWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for name in ["A", "B", "C"] {
            try Data("# \(name)\n\nText.".utf8).write(to: root.appendingPathComponent(name + ".md"))
        }
        let workspace = LibraryWorkspace(defaults: disposableDefaults("FolderTabs"))
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        return workspace
    }

    /// Real detail column: the active tab opens into the editor, only the unsaved tab has the coral dot,
    /// and 1 → 2 → 1 tabs with a dirty toggle never moves the editor (1.50).
    @MainActor
    func testFolderTabsCoralDotAndStableEditorOrigin() async throws {
        _ = NSApplication.shared
        let workspace = try await tabsFixture()
        defer { try? FileManager.default.removeItem(at: workspace.root!) }
        let host = NSHostingView(rootView: DocumentDetail(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func settle() async throws {
            for _ in 0..<5 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        }
        func bar() throws -> EditorTabBarView {
            try XCTUnwrap(Self.descendants(host).compactMap { $0 as? EditorTabBarView }.first)
        }
        func editorFrame() throws -> NSRect {
            let editor = try XCTUnwrap(
                Self.descendants(host).compactMap { $0 as? PlainMarkdownTextView }.first {
                    $0.string == workspace.editor.text
                })
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            return scroll.convert(scroll.bounds, to: host)
        }
        func open(_ name: String, pinned: Bool) async {
            workspace.navigate(folder: "", documents: [name + ".md"], pinned: pinned)
            await workspace.waitForNavigation()
        }
        await open("A", pinned: true)
        try await settle()
        let single = try editorFrame()
        let barFrame = try bar().convert(try bar().bounds, to: host)
        XCTAssertEqual(barFrame.height, Spacing.tabBarHeight, accuracy: 1)
        await open("B", pinned: true)
        try await settle()
        workspace.editor.state = .dirty
        try await settle()
        XCTAssertEqual(try editorFrame().minY, single.minY, accuracy: 1)
        XCTAssertEqual(try editorFrame().maxY, single.maxY, accuracy: 1)
        XCTAssertEqual(try bar().convert(try bar().bounds, to: host), barFrame)

        let buttons = try bar().buttons
        XCTAssertEqual(buttons.count, 2)
        let (a, b) = (buttons[0], buttons[1])
        XCTAssertTrue(b.isActive)
        XCTAssertEqual(b.frame.height, EditorTabBarView.tabHeight)
        XCTAssertEqual(b.frame.minY, 0, "tabs sit on the strip's bottom edge under a 4 pt gap")
        XCTAssertEqual(b.accessibilityLabel(), "B, edited")
        XCTAssertEqual(a.accessibilityLabel(), "A")
        XCTAssertFalse(b.close.isHidden, "the active tab shows ×")
        XCTAssertTrue(a.close.isHidden)
        XCTAssertEqual(b.close.title, "×")
        let dot = try XCTUnwrap(b.dotRect)
        XCTAssertNil(a.dotRect)

        // Pixels: coral dot only on the unsaved tab; no hairline under the active tab; an outline on its top edge.
        let tabBar = try bar()
        let bitmap = try XCTUnwrap(tabBar.bitmapImageRepForCachingDisplay(in: tabBar.bounds))
        tabBar.cacheDisplay(in: tabBar.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / tabBar.bounds.width
        func pixel(_ point: NSPoint, in view: NSView) throws -> NSColor {
            let p = view.convert(point, to: tabBar)
            let y = Int((tabBar.bounds.height - p.y) * scale)
            return try XCTUnwrap(
                bitmap.colorAt(x: Int(p.x * scale), y: min(bitmap.pixelsHigh - 1, y))?.usingColorSpace(.sRGB))
        }
        // Reference colours rendered through the same window pipeline as the tab bar.
        func rendered(_ color: NSColor) throws -> NSColor {
            let swatch = Swatch(frame: NSRect(x: 0, y: 0, width: 4, height: 4))
            swatch.color = color
            host.addSubview(swatch)
            defer { swatch.removeFromSuperview() }
            let rep = try XCTUnwrap(swatch.bitmapImageRepForCachingDisplay(in: swatch.bounds))
            swatch.cacheDisplay(in: swatch.bounds, to: rep)
            return try XCTUnwrap(rep.colorAt(x: 1, y: 1)?.usingColorSpace(.sRGB))
        }
        let coral = try rendered(.silkwebCoral), pane = try rendered(.silkwebPaneBackground)
        func close(_ color: NSColor, _ wanted: NSColor, _ label: String) {
            for (x, y) in [
                (color.redComponent, wanted.redComponent), (color.greenComponent, wanted.greenComponent),
                (color.blueComponent, wanted.blueComponent),
            ] {
                XCTAssertEqual(x * 255, y * 255, accuracy: 4, "\(label): \(color) vs \(wanted)")
            }
        }
        close(try pixel(NSPoint(x: dot.midX, y: dot.midY), in: b), coral, "coral dot")
        close(try pixel(NSPoint(x: dot.midX, y: dot.midY), in: a), pane, "no dot on the saved tab")
        close(try pixel(NSPoint(x: b.bounds.midX, y: 0.25), in: b), pane, "open bottom under the active tab")
        XCTAssertGreaterThan(
            abs(try pixel(NSPoint(x: a.bounds.midX, y: 0.25), in: a).redComponent - pane.redComponent) * 255, 4,
            "hairline under inactive tabs")
        XCTAssertGreaterThan(
            abs(try pixel(NSPoint(x: b.bounds.midX, y: b.bounds.maxY - 0.25), in: b).redComponent - pane.redComponent)
                * 255, 4,
            "outline on the active tab's top edge")

        // 1.26: a preview tab keeps its italic title; saving clears the dot; closing back to one tab keeps the origin.
        await open("C", pinned: false)
        try await settle()
        let preview = try XCTUnwrap(try bar().buttons.first { $0.tab.isPreview })
        let title = try XCTUnwrap(Self.descendants(preview).compactMap { $0 as? NSTextField }.first)
        XCTAssertTrue(NSFontManager.shared.traits(of: title.font!).contains(.italicFontMask))
        XCTAssertEqual(preview.accessibilityLabel(), "C, preview")
        b.tab.editor.state = .clean
        try await settle()
        XCTAssertNil(b.dotRect)
        XCTAssertEqual(b.accessibilityLabel(), "B")
        for id in workspace.tabs.dropFirst().map(\.id) { _ = await workspace.closeTab(id) }
        try await settle()
        XCTAssertEqual(try bar().buttons.count, 1)
        XCTAssertEqual(try editorFrame(), single)
        XCTAssertFalse(window.isVisible)
    }
}

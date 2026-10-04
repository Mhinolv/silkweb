import AppKit
import SwiftUI
import XCTest
@testable import SilkwebCore
@testable import Silkweb

/// silkweb-1.65 attempt 2: the compact bar in a real titled, resizable window shaped like the one SwiftUI's
/// `Window` scene builds (full-size content, compact style before the toolbar exists), never ordered on screen.
/// The owner's GUI check of 5916514 found items over the traffic lights and the bar collapsing into » after a
/// document opened; the collapse reproduces whenever the Outline inspector is shown.
final class ToolbarRealWindowTests: XCTestCase {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let deep = "Travel/North American Road Trips/Pennsylvania and the Great Lakes/Lake Erie Shoreline Campgrounds/Presque Isle"
    static let document = deep + "/Settling In at Presque Isle State Park After a Long Week on the Road.md"
    /// Every control in the bar; none may overflow into the » menu at 900 pt or wider.
    static let controls = ["Hide Sidebars", "New Document", "Sort By", "Filter by Tag", "View Mode", "Show Outline", "Show Document Info"]
    /// AppKit's own gap after the zoom button is 10 pt; items must start at least this far past it.
    static let buttonSpacing: CGFloat = 8

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor private final class Harness {
        let window: NSWindow
        let workspace: LibraryWorkspace
        let cleanUp: () -> Void
        init(window: NSWindow, workspace: LibraryWorkspace, cleanUp: @escaping () -> Void) {
            self.window = window
            self.workspace = workspace
            self.cleanUp = cleanUp
        }
        var toolbar: NSToolbar { window.toolbar! }
        func frame(_ view: NSView) -> NSRect { view.convert(view.bounds, to: nil) }
        var placed: [NSToolbarItem] { toolbar.items.filter { $0.view?.window === window && $0.view?.isHiddenOrHasHiddenAncestor == false } }
        func view(_ label: String) -> NSView? {
            // The sidebar toggle reads Show Sidebars while they are hidden.
            let label = label == "Hide Sidebars" ? workspace.sidebarsTitle : label
            return toolbar.items.first { $0.label == label }?.view
        }
        var crumbItem: NSToolbarItem? {
            toolbar.items.first { item in item.view.map { ToolbarRealWindowTests.descendants($0).contains { $0 is BreadcrumbView } } == true }
        }
        var breadcrumb: BreadcrumbView? { crumbItem?.view.flatMap { ToolbarRealWindowTests.descendants($0).compactMap { $0 as? BreadcrumbView }.first } }
        var buttons: [NSButton] { [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) } }
        func settle() async throws {
            for _ in 0..<6 {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        func resize(_ width: CGFloat) async throws {
            window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: false)
            try await settle()
        }
        /// Every item's placement and frame, for failure messages.
        var geometry: String {
            toolbar.items.map { item in
                "\(item.label.isEmpty ? "breadcrumb" : item.label): placed=\(item.view?.window === window) frame=\(item.view.map(frame) ?? .zero)"
            }.joined(separator: "; ") + "; breadcrumbWidth=\(workspace.toolbarMetrics.breadcrumbWidth) window=\(window.frame.width)"
        }
    }

    /// A temp copy of `Test_Library` plus a deep folder holding a document with a long title.
    @MainActor private func makeHarness(width: CGFloat, outline: Bool) async throws -> Harness {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebRealWindow-" + UUID().uuidString)
        let root = container.appendingPathComponent("Field Notes")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.repository.appendingPathComponent("Test_Library"), to: root)
        try? FileManager.default.removeItem(at: root.appendingPathComponent(".silkweb"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(Self.deep), withIntermediateDirectories: true)
        try Data("# Settling In\n\nThe first night by the lake.\n".utf8).write(to: root.appendingPathComponent(Self.document))
        let suite = "Silkweb.RealWindow." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(outline, forKey: "Silkweb.Detail.Outline")
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        XCTAssertEqual(workspace.preview.showsOutline, outline)
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = SimulatedFullScreenWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
        controller.sizingOptions = []
        window.contentViewController = controller
        let harness = Harness(window: window, workspace: workspace) {
            window.contentViewController = nil
            window.close()
            NSApp.appearance = oldAppearance
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: container)
        }
        try await harness.resize(width)
        return harness
    }

    /// (a) no item touches a traffic light and the first starts past the zoom button; (b) the buttons are visible.
    @MainActor private func assertClearOfWindowButtons(_ h: Harness, _ context: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(h.window.toolbarStyle, .unifiedCompact, context, file: file, line: line)
        XCTAssertFalse(h.window.styleMask.contains(.fullScreen))
        let titlebar = NSRect(x: 0, y: h.window.contentLayoutRect.maxY, width: h.window.frame.width,
                              height: h.window.frame.height - h.window.contentLayoutRect.maxY)
        XCTAssertEqual(h.buttons.count, 3, context, file: file, line: line)
        for button in h.buttons {
            XCTAssertTrue(button.window === h.window, "\(context): window button in the window", file: file, line: line)
            XCTAssertFalse(button.isHiddenOrHasHiddenAncestor, "\(context): window button visible", file: file, line: line)
            XCTAssertEqual(button.alphaValue, 1, accuracy: 0.01, "\(context): window button opaque", file: file, line: line)
            XCTAssertTrue(titlebar.insetBy(dx: -0.5, dy: -0.5).contains(h.frame(button)),
                          "\(context): window button \(h.frame(button)) inside the titlebar \(titlebar)", file: file, line: line)
        }
        let zoom = try XCTUnwrap(h.window.standardWindowButton(.zoomButton))
        for item in h.placed {
            let frame = h.frame(item.view!)
            for button in h.buttons {
                // 0.5 pt of slack for subpixel rounding on 2x displays.
                XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(h.frame(button)),
                               "\(context): \(item.label) \(frame) overlaps a window button \(h.frame(button)) — \(h.geometry)", file: file, line: line)
            }
            XCTAssertGreaterThanOrEqual(frame.minX, h.frame(zoom).maxX + Self.buttonSpacing,
                                        "\(context): \(item.label) starts after the zoom button — \(h.geometry)", file: file, line: line)
        }
    }

    /// (c) nothing in the » menu: every control and the breadcrumb are placed, left to right in design order.
    @MainActor private func assertNothingOverflows(_ h: Harness, _ context: String, file: StaticString = #filePath, line: UInt = #line) throws {
        for label in Self.controls {
            let view = try XCTUnwrap(h.view(label), "\(context): \(label)", file: file, line: line)
            XCTAssertTrue(view.window === h.window, "\(context): \(label) overflowed into » — \(h.geometry)", file: file, line: line)
        }
        let crumb = try XCTUnwrap(h.crumbItem?.view, context, file: file, line: line)
        XCTAssertTrue(crumb.window === h.window, "\(context): breadcrumb overflowed into » — \(h.geometry)", file: file, line: line)
        guard h.placed.count == h.toolbar.items.count else { return }
        let order = ["Hide Sidebars", "New Document", "Sort By", "Filter by Tag"].compactMap { h.view($0) } + [crumb]
            + ["View Mode", "Show Outline", "Show Document Info"].compactMap { h.view($0) }
        for (left, right) in zip(order, order.dropFirst()) {
            XCTAssertLessThanOrEqual(h.frame(left).maxX, h.frame(right).minX + 0.5, "\(context): items overlap — \(h.geometry)", file: file, line: line)
        }
    }

    /// Before and after opening a long-titled document in a deep folder, at 1400 and 900 pt, with and without
    /// the Outline inspector: clear of the traffic lights, nothing in », and at 900 pt only the breadcrumb shortens.
    @MainActor
    func testRealWindowKeepsEveryItemBesideTheTrafficLightsBeforeAndAfterOpeningADocument() async throws {
        for outline in [false, true] {
            let h = try await makeHarness(width: 1400, outline: outline)
            defer { h.cleanUp() }
            XCTAssertFalse(h.window.isVisible)
            var widths: [CGFloat: CGFloat] = [:]
            for opened in [false, true] {
                if opened {
                    h.workspace.navigate(folder: Self.deep, documents: [Self.document], pinned: true)
                    await h.workspace.waitForNavigation()
                    XCTAssertNotNil(h.workspace.editor.url)
                }
                for width: CGFloat in [1400, 900] {
                    try await h.resize(width)
                    let context = "\(Int(width)) pt, outline \(outline), document open \(opened)"
                    try assertClearOfWindowButtons(h, context)
                    try assertNothingOverflows(h, context)
                    let crumb = try XCTUnwrap(h.crumbItem?.view)
                    widths[width] = h.frame(crumb).width
                    if opened, width == 900, let breadcrumb = h.breadcrumb, let fit = breadcrumb.fit {
                        // Only the breadcrumb gives way: its ancestors fold into `…`; the title stays.
                        XCTAssertFalse(fit.collapsed.isEmpty, context)
                        XCTAssertFalse(breadcrumb.currentLabel.isHidden, context)
                        XCTAssertLessThanOrEqual(breadcrumb.currentLabel.frame.maxX, breadcrumb.bounds.maxX + 0.5, context)
                    }
                }
                XCTAssertLessThan(widths[900] ?? 0, widths[1400] ?? 0, "the breadcrumb is what shrinks")
            }
            // Back to the default width, the row is whole again.
            try await h.resize(1400)
            try assertClearOfWindowButtons(h, "1400 pt again, outline \(outline)")
            try assertNothingOverflows(h, "1400 pt again, outline \(outline)")
        }
    }

    /// The bar adapts when the Outline inspector opens or closes without a window resize.
    @MainActor
    func testTogglingTheOutlineWithADocumentOpenKeepsTheRowWhole() async throws {
        let h = try await makeHarness(width: 1400, outline: false)
        defer { h.cleanUp() }
        h.workspace.navigate(folder: Self.deep, documents: [Self.document], pinned: true)
        await h.workspace.waitForNavigation()
        try await h.settle()
        for shown in [true, false, true] {
            h.workspace.preview.showsOutline = shown
            try await h.settle()
            try assertClearOfWindowButtons(h, "outline \(shown)")
            try assertNothingOverflows(h, "outline \(shown)")
        }
        // Hiding both sidebars moves the leading items up to the traffic lights, never under them.
        for width: CGFloat in [1400, 900] {
            try await h.resize(width)
            for hidden in [true, false] {
                h.workspace.setSidebarsHidden(hidden)
                try await h.settle()
                try assertClearOfWindowButtons(h, "\(Int(width)) pt, sidebars hidden \(hidden)")
                try assertNothingOverflows(h, "\(Int(width)) pt, sidebars hidden \(hidden)")
            }
        }
    }

    /// Only positive evidence moves items into the traffic-light area: no standard button shows. Full screen
    /// alone isn't evidence (attempt 3): its titlebar reveal shows the buttons while the window stays full screen.
    @MainActor
    func testWindowButtonsCountAsAbsentOnlyWhenNoneShows() {
        XCTAssertTrue(CompactToolbarController.windowButtonsAbsent(buttonsShown: [false, false, false]))
        XCTAssertTrue(CompactToolbarController.windowButtonsAbsent(buttonsShown: []))
        XCTAssertFalse(CompactToolbarController.windowButtonsAbsent(buttonsShown: [true, true, true]))
        XCTAssertFalse(CompactToolbarController.windowButtonsAbsent(buttonsShown: [false, false, true]))
        XCTAssertFalse(CompactToolbarController.windowButtonsAbsent(buttonsShown: [true, false, false]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let zoom = window.standardWindowButton(.zoomButton)
        XCTAssertTrue(CompactToolbarController.isShown(zoom))
        zoom?.alphaValue = 0
        XCTAssertFalse(CompactToolbarController.isShown(zoom), "faded out")
        zoom?.alphaValue = 1
        zoom?.superview?.isHidden = true
        XCTAssertFalse(CompactToolbarController.isShown(zoom), "titlebar hidden")
        zoom?.superview?.isHidden = false
        zoom?.isHidden = true
        XCTAssertFalse(CompactToolbarController.isShown(zoom), "hidden")
        XCTAssertFalse(CompactToolbarController.isShown(nil))
    }

    /// The toolbar stays visible in full screen: the window delegate drops `.autoHideToolbar`.
    @MainActor
    func testFullScreenKeepsTheToolbarVisible() {
        let coordinator = EditorWindowLifecycle.Coordinator(workspace: LibraryWorkspace())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let options = coordinator.window(window, willUseFullScreenPresentationOptions: [.fullScreen, .autoHideMenuBar, .autoHideToolbar])
        XCTAssertFalse(options.contains(.autoHideToolbar))
        XCTAssertTrue(options.contains(.fullScreen))
        XCTAssertTrue(options.contains(.autoHideMenuBar))
    }

    /// (d) Without the window buttons the leading items take the freed space, and move back beside them after.
    @MainActor
    func testHiddenWindowButtonsFreeTheLeadingSpaceAndRestoreIt() async throws {
        let h = try await makeHarness(width: 1400, outline: false)
        defer { h.cleanUp() }
        h.workspace.navigate(folder: Self.deep, documents: [Self.document], pinned: true)
        await h.workspace.waitForNavigation()
        try await h.settle()
        func firstMinX() -> CGFloat { h.placed.compactMap(\.view).map { h.frame($0).minX }.min() ?? .infinity }
        let shown = firstMinX()
        try assertClearOfWindowButtons(h, "before hiding")
        for button in h.buttons { button.isHidden = true }
        for _ in 0..<10 where firstMinX() > Spacing.small { try await h.settle() }
        XCTAssertLessThanOrEqual(firstMinX(), Spacing.small, h.geometry)
        try assertNothingOverflows(h, "buttons hidden")
        for button in h.buttons { button.isHidden = false }
        for _ in 0..<10 where firstMinX() != shown { try await h.settle() }
        XCTAssertEqual(firstMinX(), shown, accuracy: 0.5, h.geometry)
        try assertClearOfWindowButtons(h, "after showing")
        try assertNothingOverflows(h, "after showing")
        XCTAssertTrue(h.toolbar.isVisible)

        // Reduce Motion: the items jump into place in the same pass; otherwise they slide.
        let controller = h.workspace.toolbarMetrics.controller
        let reduceMotion = CompactToolbarController.reduceMotion
        defer { CompactToolbarController.reduceMotion = reduceMotion }
        CompactToolbarController.reduceMotion = { true }
        for button in h.buttons { button.isHidden = true }
        controller.update()
        XCTAssertEqual(controller.lastMoveAnimated, false)
        XCTAssertLessThanOrEqual(firstMinX(), Spacing.small, "placed at once: \(h.geometry)")
        for button in h.buttons { button.isHidden = false }
        controller.update()
        XCTAssertEqual(controller.lastMoveAnimated, false)
        XCTAssertEqual(firstMinX(), shown, accuracy: 0.5, "back at once: \(h.geometry)")
        try await h.settle()
        CompactToolbarController.reduceMotion = { false }
        for button in h.buttons { button.isHidden = true }
        controller.update()
        XCTAssertEqual(controller.lastMoveAnimated, true, "slides without Reduce Motion")
        for _ in 0..<10 where firstMinX() > Spacing.small { try await h.settle() }
        XCTAssertLessThanOrEqual(firstMinX(), Spacing.small, h.geometry)
        for button in h.buttons { button.isHidden = false }
        for _ in 0..<10 where abs(firstMinX() - shown) > 0.5 { try await h.settle() }
        XCTAssertEqual(firstMinX(), shown, accuracy: 0.5, h.geometry)
        try assertClearOfWindowButtons(h, "after the slide back")
    }

    /// No placed item touches a window button that is showing, whatever the window's full-screen state.
    @MainActor private func assertClearOfVisibleButtons(_ h: Harness, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        let visible = h.buttons.filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0.01 && $0.window != nil }
        XCTAssertEqual(visible.count, 3, "\(context): the revealed titlebar shows all three buttons", file: file, line: line)
        for item in h.placed {
            let frame = h.frame(item.view!)
            for button in visible {
                XCTAssertFalse(frame.insetBy(dx: 0.5, dy: 0.5).intersects(h.frame(button)),
                               "\(context): \(item.label) \(frame) overlaps a visible window button \(h.frame(button)) — \(h.geometry)",
                               file: file, line: line)
            }
        }
    }

    /// silkweb-1.65 attempt 3, the owner's repro on f85a28d: in full screen the items slide into the empty
    /// traffic-light area, then hovering at the top reveals the menu bar and macOS shows the titlebar WITH the
    /// buttons while the window stays full screen. Offscreen the window can't enter real full screen (AppKit
    /// traps when `.fullScreen` is set outside a transition), so the window reports the `.fullScreen` style mask
    /// and the test hides or shows the standard buttons as macOS does when it conceals or reveals the titlebar.
    @MainActor
    func testFullScreenTitlebarRevealNeverPutsItemsUnderTheWindowButtons() async throws {
        let h = try await makeHarness(width: 1400, outline: false)
        defer { h.cleanUp() }
        h.workspace.navigate(folder: Self.deep, documents: [Self.document], pinned: true)
        await h.workspace.waitForNavigation()
        try await h.settle()
        let shown = firstMinX(h)
        try assertClearOfWindowButtons(h, "before full screen")
        let window = try XCTUnwrap(h.window as? SimulatedFullScreenWindow)
        window.simulatesFullScreen = true
        h.workspace.toolbarMetrics.controller.scheduleUpdate()
        XCTAssertTrue(h.window.styleMask.contains(.fullScreen))
        // Full screen, titlebar revealed: the buttons are visible from the start.
        try await h.settle()
        assertClearOfVisibleButtons(h, "full screen, titlebar revealed")
        try assertNothingOverflows(h, "full screen, titlebar revealed")
        for round in 1...2 {
            try await concealAndReveal(h, round: round, shown: shown)
        }
        // The window leaves full screen with the row where it started.
        window.simulatesFullScreen = false
        h.workspace.toolbarMetrics.controller.scheduleUpdate()
        try await h.settle()
        try assertClearOfWindowButtons(h, "after full screen")
        try assertNothingOverflows(h, "after full screen")
    }

    /// Titlebar concealed (buttons hidden: items take the freed space), then the hover reveal (buttons shown:
    /// items move back beside them).
    @MainActor private func concealAndReveal(_ h: Harness, round: Int, shown: CGFloat) async throws {
        for button in h.buttons { button.isHidden = true }
        for _ in 0..<10 where firstMinX(h) > Spacing.small { try await h.settle() }
        XCTAssertLessThanOrEqual(firstMinX(h), Spacing.small, "round \(round), concealed: \(h.geometry)")
        try assertNothingOverflows(h, "round \(round), full screen, titlebar concealed")
        for button in h.buttons { button.isHidden = false }
        for _ in 0..<10 where abs(firstMinX(h) - shown) > 0.5 { try await h.settle() }
        assertClearOfVisibleButtons(h, "round \(round), full screen, titlebar revealed after hover")
        try assertNothingOverflows(h, "round \(round), full screen, titlebar revealed after hover")
        XCTAssertEqual(firstMinX(h), shown, accuracy: 0.5, "round \(round), revealed: \(h.geometry)")
    }

    @MainActor private func firstMinX(_ h: Harness) -> CGFloat {
        h.placed.compactMap(\.view).map { h.frame($0).minX }.min() ?? .infinity
    }
}

/// Reports the `.fullScreen` style mask while `simulatesFullScreen` is set, to AppKit and to Silkweb alike.
final class SimulatedFullScreenWindow: NSWindow {
    var simulatesFullScreen = false
    override var styleMask: NSWindow.StyleMask {
        get { simulatesFullScreen ? super.styleMask.union(.fullScreen) : super.styleMask }
        set { super.styleMask = newValue }
    }
}

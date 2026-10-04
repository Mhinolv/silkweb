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
        try FileManager.default.createDirectory(at: root.appendingPathComponent(Self.short), withIntermediateDirectories: true)
        try Data("# Notes\n".utf8).write(to: root.appendingPathComponent(Self.shortDocument))
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

    /// (d) Without the window buttons the row stays whole. In the library window AppKit starts the row after the
    /// sidebar column's section and never grows it into the freed space, so the items keep AppKit's placement
    /// rather than leave the trailing edge (#54); the slide itself is covered by the sectionless-window test.
    @MainActor
    func testHiddenWindowButtonsKeepTheRowWholeAfterTheSidebarSection() async throws {
        let h = try await makeHarness(width: 1400, outline: false)
        defer { h.cleanUp() }
        h.workspace.navigate(folder: Self.deep, documents: [Self.document], pinned: true)
        await h.workspace.waitForNavigation()
        try await h.settle()
        let shown = firstMinX(h)
        let shownGap = try trailingGap(h)
        let shownWidth = h.workspace.toolbarMetrics.breadcrumbWidth
        try assertClearOfWindowButtons(h, "before hiding")
        let controller = h.workspace.toolbarMetrics.controller
        let reduceMotion = CompactToolbarController.reduceMotion
        defer { CompactToolbarController.reduceMotion = reduceMotion }
        for reduced in [false, true] {
            CompactToolbarController.reduceMotion = { reduced }
            for button in h.buttons { button.isHidden = true }
            controller.update()
            try await h.settle()
            try await h.settle()
            let context = "buttons hidden, Reduce Motion \(reduced)"
            XCTAssertEqual(firstMinX(h), shown, accuracy: 0.5, "\(context): AppKit's placement kept — \(h.geometry)")
            XCTAssertEqual(try trailingGap(h), shownGap, accuracy: 0.5, "\(context): trailing items at the edge — \(h.geometry)")
            XCTAssertEqual(h.workspace.toolbarMetrics.breadcrumbWidth, shownWidth, accuracy: 0.5, "\(context) — \(h.geometry)")
            XCTAssertNil(controller.lastMoveAnimated, "\(context): nothing moved")
            try assertNothingOverflows(h, context)
            for button in h.buttons { button.isHidden = false }
            try await h.settle()
            XCTAssertEqual(firstMinX(h), shown, accuracy: 0.5, h.geometry)
            try assertClearOfWindowButtons(h, "after showing, Reduce Motion \(reduced)")
            try assertNothingOverflows(h, "after showing, Reduce Motion \(reduced)")
        }
        XCTAssertTrue(h.toolbar.isVisible)
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

    /// Titlebar concealed (buttons hidden: after the sidebar section the items keep AppKit's place and the
    /// trailing edge, #54), then the hover reveal (buttons shown: items beside them, never under).
    @MainActor private func concealAndReveal(_ h: Harness, round: Int, shown: CGFloat) async throws {
        let shownGap = try trailingGap(h)
        for button in h.buttons { button.isHidden = true }
        try await h.settle()
        try await h.settle()
        XCTAssertEqual(firstMinX(h), shown, accuracy: 0.5, "round \(round), concealed: \(h.geometry)")
        XCTAssertEqual(try trailingGap(h), shownGap, accuracy: 0.5, "round \(round), concealed: \(h.geometry)")
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

    /// #54, the owner's repro on 3aa32f2: in full screen with the titlebar concealed the leading items slid to
    /// the 12 pt inset, but the breadcrumb collapsed to `… › Syst…ions` and the trailing group sat right after
    /// it with the rest of the bar empty. The bar must look like the windowed one: the breadcrumb fills the room
    /// and the trailing group ends at the bar's edge, or at the titlebar area AppKit reserves over the Outline.
    @MainActor
    func testFullScreenConcealedTitlebarKeepsTheBreadcrumbWholeAndTheTrailingItemsAtTheEdge() async throws {
        for outline in [false, true] {
            let h = try await makeHarness(width: 1400, outline: outline)
            defer { h.cleanUp() }
            h.workspace.navigate(folder: Self.short, documents: [Self.shortDocument], pinned: true)
            await h.workspace.waitForNavigation()
            try await h.settle()
            let window = try XCTUnwrap(h.window as? SimulatedFullScreenWindow)
            for width: CGFloat in [1400, 1800, 900] {
                try await h.resize(width)
                for sidebarsHidden in [false, true] {
                    h.workspace.setSidebarsHidden(sidebarsHidden)
                    try await h.settle()
                    let windowed = try trailingGap(h)
                    // Enter full screen with the titlebar revealed, then conceal it as macOS does.
                    window.simulatesFullScreen = true
                    h.workspace.toolbarMetrics.controller.scheduleUpdate()
                    try await h.settle()
                    for button in h.buttons { button.isHidden = true }
                    try await h.settle()
                    try await h.settle()
                    let context = "\(Int(width)) pt, outline \(outline), sidebars hidden \(sidebarsHidden), full screen concealed"
                    try assertNothingOverflows(h, context)
                    let gap = try trailingGap(h)
                    XCTAssertLessThanOrEqual(gap, windowed + 1, "\(context): trailing items left the edge (windowed gap \(windowed)) — \(h.geometry)")
                    XCTAssertLessThanOrEqual(gap, CompactToolbarController.trailingInset + 12,
                                             "\(context): trailing items sit at the edge — \(h.geometry)")
                    if width >= 1400, let fit = h.breadcrumb?.fit {
                        XCTAssertTrue(fit.collapsed.isEmpty, "\(context): ancestors folded — \(h.geometry)")
                        XCTAssertTrue(fit.showsCount, "\(context): count dropped — \(h.geometry)")
                        if let breadcrumb = h.breadcrumb {
                            let full = BreadcrumbView.textWidth(breadcrumb.path.current, BreadcrumbView.currentFont) + 2 * BreadcrumbView.padding
                            XCTAssertGreaterThanOrEqual(CGFloat(fit.currentWidth), full - 0.5, "\(context): current crumb truncated — \(h.geometry)")
                        }
                    }
                    // Hover reveal: the buttons show again, nothing sits under them, the trailing group stays put.
                    for button in h.buttons { button.isHidden = false }
                    try await h.settle()
                    try await h.settle()
                    assertClearOfVisibleButtons(h, "\(context), revealed")
                    try assertNothingOverflows(h, "\(context), revealed")
                    XCTAssertLessThanOrEqual(try trailingGap(h), windowed + 1, "\(context), revealed — \(h.geometry)")
                    window.simulatesFullScreen = false
                    h.workspace.toolbarMetrics.controller.scheduleUpdate()
                    try await h.settle()
                }
            }
        }
    }

    static let short = "Engineering/System Applications"
    static let shortDocument = short + "/Notes.md"

    /// The compact bar's items in a toolbar of its own, in a window without a split view, so AppKit starts the
    /// row right after the traffic lights instead of after a sidebar section.
    @MainActor private final class SectionlessToolbar: NSObject, NSToolbarDelegate {
        static let leadingLabels = ["Hide Sidebars", "New Document", "Sort By", "Filter by Tag"]
        static let trailingLabels = ["View Mode", "Show Outline", "Show Document Info"]
        static let crumbIdentifier = NSToolbarItem.Identifier("breadcrumb")
        let workspace: LibraryWorkspace
        init(workspace: LibraryWorkspace) { self.workspace = workspace }
        var identifiers: [NSToolbarItem.Identifier] {
            Self.leadingLabels.map { NSToolbarItem.Identifier($0) } + [Self.crumbIdentifier] + Self.trailingLabels.map { NSToolbarItem.Identifier($0) }
        }
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { identifiers }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                     willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: identifier)
            if identifier == Self.crumbIdentifier {
                item.view = NSHostingView(rootView: ToolbarBreadcrumb(workspace: workspace))
            } else {
                item.label = identifier.rawValue
                item.view = NSButton(title: identifier.rawValue == "View Mode" ? "Editor  Split  Preview" : "•", target: nil, action: nil)
            }
            return item
        }
    }

    /// Without a section to grow past, AppKit gives the shifted row the freed room: the leading items slide to
    /// the 12 pt inset, the breadcrumb widens by as much, and the trailing items keep the edge (#54). They slide
    /// (0.2 s), or jump into place under Reduce Motion, and return beside the buttons when those show again.
    @MainActor
    func testWithoutASidebarSectionTheLeadingItemsSlideAndTheTrailingItemsKeepTheEdge() async throws {
        _ = NSApplication.shared
        let workspace = LibraryWorkspace()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.toolbar = nil; window.close() }
        window.toolbarStyle = .unifiedCompact
        // As `.toolbar(removing: .title)` does in the app: without the title the row starts at the leading side.
        window.titleVisibility = .hidden
        let delegate = SectionlessToolbar(workspace: workspace)
        let toolbar = NSToolbar(identifier: "Silkweb.SectionlessToolbar." + UUID().uuidString)
        toolbar.delegate = delegate
        window.toolbar = toolbar
        func settle() async throws {
            for _ in 0..<6 {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try await settle()
        let controller = workspace.toolbarMetrics.controller
        let buttons = [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window.standardWindowButton($0) }
        func frame(_ label: String) -> NSRect {
            guard let view = toolbar.items.first(where: { $0.label == label })?.view, view.window != nil else { return .null }
            return view.convert(view.bounds, to: nil)
        }
        func firstMinX() -> CGFloat { frame("Hide Sidebars").minX }
        func gap() -> CGFloat { window.frame.width - frame("Show Document Info").maxX }
        var geometry: String {
            toolbar.items.map { "\($0.label.isEmpty ? "breadcrumb" : $0.label): placed=\($0.view?.window != nil) frame=\($0.view.map { $0.convert($0.bounds, to: nil) } ?? .zero)" }
                .joined(separator: "; ") + "; breadcrumbWidth=\(workspace.toolbarMetrics.breadcrumbWidth) failed=\(controller.shiftGrowthFailed)"
        }
        func assertWhole(_ context: String, line: UInt = #line) {
            for item in toolbar.items {
                XCTAssertNotNil(item.view?.window, "\(context): \(item.label) overflowed into » — \(geometry)", line: line)
            }
            XCTAssertLessThanOrEqual(gap(), CompactToolbarController.trailingInset + 12, "\(context): trailing items at the edge — \(geometry)", line: line)
        }
        let shown = firstMinX()
        let shownWidth = workspace.toolbarMetrics.breadcrumbWidth
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        XCTAssertGreaterThan(shown, zoom.convert(zoom.bounds, to: nil).maxX, geometry)
        XCTAssertLessThan(shown, zoom.convert(zoom.bounds, to: nil).maxX + CompactToolbarController.sectionSlack,
                          "AppKit starts the row right after the traffic lights — \(geometry)")
        assertWhole("buttons shown")

        let reduceMotion = CompactToolbarController.reduceMotion
        defer { CompactToolbarController.reduceMotion = reduceMotion }
        for reduced in [false, true] {
            CompactToolbarController.reduceMotion = { reduced }
            for button in buttons { button.isHidden = true }
            controller.update()
            XCTAssertEqual(controller.lastMoveAnimated, !reduced, "slides unless Reduce Motion is on")
            if reduced { XCTAssertLessThanOrEqual(firstMinX(), Spacing.small + 0.5, "placed at once: \(geometry)") }
            try await settle()
            try await settle()
            let context = "buttons hidden, Reduce Motion \(reduced)"
            XCTAssertFalse(controller.shiftGrowthFailed, "\(context): AppKit gave the row the room — \(geometry)")
            XCTAssertLessThanOrEqual(firstMinX(), Spacing.small + 0.5, "\(context): items at the leading inset — \(geometry)")
            XCTAssertEqual(workspace.toolbarMetrics.breadcrumbWidth, shownWidth + shown - firstMinX(), accuracy: 2,
                           "\(context): the breadcrumb takes the freed room — \(geometry)")
            assertWhole(context)
            for button in buttons { button.isHidden = false }
            controller.update()
            XCTAssertEqual(controller.lastMoveAnimated, !reduced)
            try await settle()
            try await settle()
            XCTAssertEqual(firstMinX(), shown, accuracy: 0.5, "buttons shown again, Reduce Motion \(reduced): \(geometry)")
            XCTAssertEqual(workspace.toolbarMetrics.breadcrumbWidth, shownWidth, accuracy: 0.5, geometry)
            assertWhole("buttons shown again, Reduce Motion \(reduced)")
        }
    }

    /// The orchestrator's fallback (#54): when AppKit refuses the shifted row the freed width, the items return
    /// to AppKit's placement instead of shrinking the breadcrumb or leaving the trailing edge, and stay there
    /// while the buttons are hidden. Section prediction is off so the controller really tries.
    @MainActor
    func testRefusedShiftKeepsAppKitsPlacementAndTheTrailingEdge() async throws {
        let h = try await makeHarness(width: 1400, outline: false)
        defer { h.cleanUp() }
        h.workspace.navigate(folder: Self.short, documents: [Self.shortDocument], pinned: true)
        await h.workspace.waitForNavigation()
        try await h.settle()
        let predicts = CompactToolbarController.predictsSections
        defer { CompactToolbarController.predictsSections = predicts }
        CompactToolbarController.predictsSections = false
        let controller = h.workspace.toolbarMetrics.controller
        let shown = firstMinX(h)
        let shownGap = try trailingGap(h)
        let shownWidth = h.workspace.toolbarMetrics.breadcrumbWidth
        for button in h.buttons { button.isHidden = true }
        controller.update()
        XCTAssertNotNil(controller.lastMoveAnimated, "the controller tries the slide — \(h.geometry)")
        for _ in 0..<12 where !controller.shiftGrowthFailed || abs(firstMinX(h) - shown) > 0.5 { try await h.settle() }
        try await h.settle()
        XCTAssertTrue(controller.shiftGrowthFailed, "AppKit refuses the row after the sidebar section — \(h.geometry)")
        XCTAssertEqual(firstMinX(h), shown, accuracy: 0.5, "back at AppKit's placement — \(h.geometry)")
        XCTAssertEqual(try trailingGap(h), shownGap, accuracy: 0.5, "trailing items at the edge — \(h.geometry)")
        XCTAssertEqual(h.workspace.toolbarMetrics.breadcrumbWidth, shownWidth, accuracy: 0.5, h.geometry)
        try assertNothingOverflows(h, "refused shift")
        // No retry while the buttons stay hidden; the next reveal clears the refusal.
        controller.update()
        XCTAssertEqual(firstMinX(h), shown, accuracy: 0.5, "no second attempt — \(h.geometry)")
        try await h.settle()
        XCTAssertTrue(controller.shiftGrowthFailed)
        XCTAssertEqual(firstMinX(h), shown, accuracy: 0.5, h.geometry)
        for button in h.buttons { button.isHidden = false }
        try await h.settle()
        XCTAssertFalse(controller.shiftGrowthFailed)
        try assertClearOfWindowButtons(h, "after the reveal")
        try assertNothingOverflows(h, "after the reveal")
    }

    @MainActor
    func testOnlyARowAfterASidebarSectionKeepsItsPlace() {
        let section = NSRect(x: 178, y: 0, width: 5, height: 38)
        XCTAssertTrue(CompactToolbarController.rowFollowsSection(naturalLeading: 185, regions: [section], buttonsEnd: 66))
        XCTAssertTrue(CompactToolbarController.rowFollowsSection(naturalLeading: 185, regions: [], buttonsEnd: 66), "sidebar column, no divider view")
        XCTAssertTrue(CompactToolbarController.rowFollowsSection(naturalLeading: 185, regions: [section], buttonsEnd: nil))
        XCTAssertFalse(CompactToolbarController.rowFollowsSection(naturalLeading: 76, regions: [], buttonsEnd: 66), "right after the traffic lights")
        XCTAssertFalse(CompactToolbarController.rowFollowsSection(naturalLeading: 185, regions: [], buttonsEnd: nil))
        let inspector = NSRect(x: 1000, y: 0, width: 400, height: 38)
        XCTAssertFalse(CompactToolbarController.rowFollowsSection(naturalLeading: 76, regions: [inspector], buttonsEnd: 66), "the inspector's area is trailing")
    }

    /// From the last trailing item to the end of the row: the bar's edge, or the reserved inspector titlebar area.
    @MainActor private func trailingGap(_ h: Harness) throws -> CGFloat {
        let info = try XCTUnwrap(h.view("Show Document Info"))
        let bar = try XCTUnwrap(info.superview?.superview?.superview)
        let infoFrame = info.convert(info.bounds, to: bar)
        var limit = bar.bounds.maxX
        for region in CompactToolbarController.reservedRegions(in: bar) where region.minX >= infoFrame.maxX - 1 {
            limit = min(limit, region.minX)
        }
        return limit - infoFrame.maxX
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

import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #238: opening a document from another Library makes that Library current. The compact bar must look as it does
/// after a same-Library tab switch, and the editor column must show the document (or a loading state) at once.
@MainActor
final class CrossLibrarySwitchTests: XCTestCase {
    static let controls = [
        "Hide Sidebars", "New Document", "Sort By", "Filter by Tag", "View Mode", "Show Outline", "Show Document Info",
    ]

    private var cleanUps: [@MainActor () async -> Void] = []
    private var temporary: URL!

    override func setUp() async throws {
        try await super.setUp()
        _ = NSApplication.shared
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebCrossLibrary-" + UUID().uuidString)
    }

    override func tearDown() async throws {
        for cleanUp in cleanUps.reversed() { await cleanUp() }
        cleanUps = []
        try? FileManager.default.removeItem(at: temporary)
        try await super.tearDown()
    }

    /// A Library with `Notes/<name>.md` for each document.
    private func library(_ name: String, _ documents: [String]) throws -> URL {
        let root = temporary.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        for document in documents {
            try Data("# \(document)\n\nA note from \(name).\n".utf8).write(
                to: root.appendingPathComponent("Notes/\(document).md"))
        }
        return root.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func registry(outline: Bool) -> LibraryWindowRegistry {
        let defaults = disposableDefaults("CrossLibrary")
        defaults.set(outline, forKey: "Silkweb.Detail.Outline")
        let recovery = temporary.appendingPathComponent(".recovery")
        let registry = LibraryWindowRegistry(defaults: defaults) {
            let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: nil)
            workspace.canSaveWindowSession = false
            workspace.recoveryDirectory = recovery
            return workspace
        }
        registry.presentAlert = { _, _ in
            XCTFail("unexpected alert"); return false
        }
        return registry
    }

    /// The real library window, shaped like the `Window` scene's (compact bar, full-size content), never shown.
    private func window(_ registry: LibraryWindowRegistry, width: CGFloat) -> NSWindow {
        let oldAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        let window = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let controller = NSHostingController(rootView: LibraryWindow(registry: registry))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: width, height: 900), display: false)
        cleanUps.append { @MainActor in
            for workspace in registry.workspaces { await workspace.releaseLibrary() }
            window.contentViewController = nil
            window.close()
            NSApp.appearance = oldAppearance
        }
        return window
    }

    private func settle(_ window: NSWindow, _ rounds: Int = 3) async throws {
        for _ in 0..<rounds {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Alpha (`Notes/Apple.md`) and Beta (`Notes/Banana.md`), each with its document open unless `betaOpens` is
    /// off; Beta is current.
    private func twoLibraries(outline: Bool, width: CGFloat = 1400, betaOpens: Bool = true) async throws -> (
        LibraryWindowRegistry, NSWindow, LibraryWorkspace, LibraryWorkspace
    ) {
        let registry = registry(outline: outline)
        let window = window(registry, width: width)
        var opened: [LibraryWorkspace] = []
        for (name, document) in [("Alpha", "Apple"), ("Beta", "Banana")] {
            let added = await registry.add(try library(name, [document]))
            let workspace = try XCTUnwrap(added)
            try await settle(window)
            if name == "Alpha" || betaOpens {
                workspace.navigate(folder: "Notes", documents: ["Notes/\(document).md"])
                await workspace.waitForNavigation()
            }
            await workspace.search.waitForIndex()
            opened.append(workspace)
        }
        try await settle(window)
        return (registry, window, opened[0], opened[1])
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func item(_ window: NSWindow, _ label: String, _ workspace: LibraryWorkspace) -> NSToolbarItem? {
        let label = label == "Hide Sidebars" ? workspace.sidebarsTitle : label
        return window.toolbar?.items.first { $0.label == label }
    }

    private func geometry(_ window: NSWindow) -> String {
        (window.toolbar?.items ?? []).map { item in
            let frame = item.view.map { $0.convert($0.bounds, to: nil) } ?? .zero
            return "\(item.label.isEmpty ? "gap" : item.label): placed=\(item.view?.window === window) frame=\(frame)"
        }.joined(separator: "; ")
    }

    /// From the Info glyph to the bar's edge, or to the inspector's titlebar area while the Outline shows.
    private func trailingGap(_ window: NSWindow, _ workspace: LibraryWorkspace) throws -> CGFloat {
        let info = try XCTUnwrap(item(window, "Show Document Info", workspace)?.view)
        let bar = try XCTUnwrap(info.superview?.superview?.superview)
        let frame = info.convert(info.bounds, to: bar)
        var limit = bar.bounds.maxX
        for region in CompactToolbarController.reservedRegions(in: bar) where region.minX >= frame.maxX - 1 {
            limit = min(limit, region.minX)
        }
        return limit - frame.maxX
    }

    /// Every control placed (none in »), and the view group at the trailing edge.
    private func toolbarIsWhole(_ window: NSWindow, _ workspace: LibraryWorkspace) -> Bool {
        let placed = Self.controls.allSatisfy { item(window, $0, workspace)?.view?.window === window }
        guard placed, let gap = try? trailingGap(window, workspace) else { return false }
        return gap >= 0 && gap <= CompactToolbarController.rowEndInset + 12
    }

    // MARK: Toolbar

    /// The owner's report: after the other Library became current, the view group sat over the editor and the
    /// leading controls were missing, and it stayed that way. Each workspace sized its own gap, and the bar's gap
    /// view kept measuring for the first Library only.
    func testSwitchingCurrentLibraryKeepsTheWholeCompactBar() async throws {
        for outline in [false, true] {
            for width: CGFloat in [1400, 900] {
                let (registry, window, a, b) = try await twoLibraries(outline: outline, width: width)
                let context = "\(Int(width)) pt, outline \(outline)"
                XCTAssertTrue(registry.current === b)
                for (target, name) in [(a, "Alpha"), (b, "Beta"), (a, "Alpha again")] {
                    let entry = try XCTUnwrap(registry.stripTabs.first { $0.workspace === target })
                    let start = ContinuousClock.now
                    registry.activate(entry)
                    XCTAssertTrue(registry.current === target)
                    var whole = false
                    while ContinuousClock.now - start < .milliseconds(500) {
                        window.contentView?.superview?.layoutSubtreeIfNeeded()
                        if toolbarIsWhole(window, target) { whole = true; break }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                    XCTAssertTrue(
                        whole,
                        "\(context), \(name) current: every control placed and the view group at the trailing edge "
                            + "within 500 ms (trailing gap \((try? trailingGap(window, target)) ?? -1)) — "
                            + geometry(window))
                    // Nothing reflows later either: no resize or sidebar toggle is needed to restore it.
                    try await settle(window)
                    XCTAssertTrue(toolbarIsWhole(window, target), "\(context), \(name) settled — \(geometry(window))")
                }
                for cleanUp in cleanUps.reversed() { await cleanUp() }
                cleanUps = []
            }
        }
    }

    // MARK: Content

    /// A loaded tab from another Library shows its text in the same frame budget as a same-Library switch (#150).
    func testAnotherLibrarysTabShowsItsTextWithin150Milliseconds() async throws {
        let (registry, window, a, b) = try await twoLibraries(outline: false)
        for target in [a, b, a] {
            let entry = try XCTUnwrap(registry.stripTabs.first { $0.workspace === target })
            let start = ContinuousClock.now
            registry.activate(entry)
            var shown = false
            while ContinuousClock.now - start < .milliseconds(150) {
                window.contentView?.superview?.layoutSubtreeIfNeeded()
                if let view = target.preview.editor, view.window === window, !view.isHiddenOrHasHiddenAncestor,
                    view.string == target.editor.text, !view.string.isEmpty
                {
                    shown = true
                    break
                }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(shown, "\(target.root?.lastPathComponent ?? "?"): the tab's text within 150 ms")
        }
    }

    /// The owner's case: the other Library hadn't been used yet. A Quick Open (All Libraries) into a Library that is
    /// still loading waits for it, shows the loading state meanwhile, and opens on its own once it is ready. Before
    /// #238 `navigate` returned early and the open was lost, leaving an empty editor.
    func testQuickOpenIntoALibraryThatIsStillLoadingOpensOnceItIsReady() async throws {
        let (registry, window, a, b) = try await twoLibraries(outline: false, betaOpens: false)
        registry.focus(a)
        try await settle(window)
        a.search.toggleQuickOpen()
        a.search.quickText = "Banana"
        a.search.quickAllLibraries = true
        await a.search.query(quick: true, debounce: false)
        let banana = try XCTUnwrap(a.search.quickResults.first)
        b.loading = true
        await a.openSearchSelection(banana.id, quick: true)
        XCTAssertTrue(registry.current === b)
        XCTAssertFalse(a.search.showsQuickOpen)
        XCTAssertNil(b.editor.url, "nothing opens while Beta loads")
        XCTAssertEqual(b.pendingSelection?.reveals, true, "the open is queued, not dropped")
        let start = ContinuousClock.now
        b.loading = false
        try await waitUntil("Banana opens once Beta is ready", timeout: .milliseconds(500)) {
            b.editor.url?.lastPathComponent == "Banana.md"
        }
        await b.waitForNavigation()
        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500))
        XCTAssertEqual(b.session.selectedDocuments, ["Notes/Banana.md"])
        XCTAssertFalse(b.openingDocument)
    }

    /// While a document without a tab loads, the empty editor column says so; the flag clears when it lands.
    func testOpeningADocumentWithoutATabFlagsTheEditorColumnUntilItLands() async throws {
        let (registry, window, _, b) = try await twoLibraries(outline: false, betaOpens: false)
        XCTAssertTrue(registry.current === b)
        XCTAssertNil(b.editor.url)
        b.navigate(folder: "Notes", documents: ["Notes/Banana.md"])
        XCTAssertTrue(b.openingDocument, "the empty column shows the open is on its way")
        await b.waitForNavigation()
        XCTAssertFalse(b.openingDocument)
        XCTAssertEqual(b.editor.url?.lastPathComponent, "Banana.md")
        // Switching to an open tab loads nothing: no placeholder.
        b.navigate(folder: "Notes", documents: ["Notes/Banana.md"])
        XCTAssertFalse(b.openingDocument)
        await b.waitForNavigation()
        _ = window
    }

    /// Preview mode: the editor column is rebuilt for the Library that becomes current, with a new web view. Its
    /// first load of a note the old web view had finished still gets the usual spinner instead of a silent blank.
    func testANewPreviewWebViewShowsTheSpinnerForANoteTheOldOneHadFinished() async throws {
        let preview = PreviewCoordinator(defaults: disposableDefaults("CrossLibraryPreview"))
        preview.mode = .preview
        let note = temporary.appendingPathComponent("Note.md")
        preview.didFinish(document: note)
        preview.beginLoading(document: note)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(preview.isLoading, "the same web view already shows it")
        preview.webViewReplaced()
        preview.beginLoading(document: note)
        try await waitUntil("the spinner for the new web view's first load") { preview.isLoading }
        preview.didFinish(document: note)
        XCTAssertFalse(preview.isLoading)
    }
}

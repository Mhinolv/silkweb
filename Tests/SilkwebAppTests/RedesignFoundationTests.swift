import AppKit
import QuartzCore
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// silkweb-1.62 (Redesign R1): one surface, capsule selection, spacing scale, 660 pt measure, status strip.
final class RedesignFoundationTests: XCTestCase {
    private static let appearances: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
    ]

    private func resolved(_ color: NSColor, _ name: NSAppearance.Name) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: name))
        var value: NSColor?
        appearance.performAsCurrentDrawingAppearance { value = color.usingColorSpace(.sRGB) }
        return try XCTUnwrap(value)
    }

    @MainActor
    func testEveryTokenResolvesPerAppearance() throws {
        let tokens: [(NSColor, SilkwebTokens.Palette, NSColor?)] = [
            (.silkwebPaneBackground, SilkwebTokens.pane, .textBackgroundColor),
            (.silkwebAccent, SilkwebTokens.accent, nil),
            (.silkwebSelection, SilkwebTokens.selection, nil),
            (.silkwebSelectionInactive, SilkwebTokens.selectionInactive, .unemphasizedSelectedContentBackgroundColor),
            (.silkwebCoral, SilkwebTokens.coral, nil),
            (.silkwebThread, SilkwebTokens.thread, nil),
        ]
        XCTAssertEqual(SilkwebTokens.accent.light, 0x3F7D64)
        XCTAssertEqual(SilkwebTokens.accent.dark, 0x7FC0A4)
        XCTAssertEqual(SilkwebTokens.coral.light, 0xCC6544)
        for (color, palette, fallback) in tokens {
            // Offscreen, a named Increase Contrast appearance resolves like its plain sibling (system colours
            // included), so the dynamic colour is checked in light and dark and every branch through `resolve`.
            XCTAssertEqual(
                try resolved(color, .aqua), try resolved(SilkwebTokens.srgb(palette.light), .aqua),
                color.colorNameComponent)
            XCTAssertEqual(
                try resolved(color, .darkAqua), try resolved(SilkwebTokens.srgb(palette.dark), .darkAqua),
                color.colorNameComponent)
            for name in Self.appearances {
                let dark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
                let highContrast = name == .accessibilityHighContrastAqua || name == .accessibilityHighContrastDarkAqua
                let expected: NSColor
                switch (dark, highContrast) {
                case (false, false): expected = SilkwebTokens.srgb(palette.light)
                case (true, false): expected = SilkwebTokens.srgb(palette.dark)
                case (false, true): expected = palette.highContrastLight.map(SilkwebTokens.srgb) ?? fallback!
                case (true, true): expected = palette.highContrastDark.map(SilkwebTokens.srgb) ?? fallback!
                }
                let actual = SilkwebTokens.resolve(palette, dark: dark, highContrast: highContrast, fallback: fallback)
                XCTAssertEqual(
                    try resolved(actual, name), try resolved(expected, name),
                    "\(color.colorNameComponent) in \(name.rawValue)")
            }
        }
    }

    @MainActor
    func testCapsuleStyleEveryBranch() {
        for isKey in [false, true] {
            for isFocused in [false, true] {
                for contrast in [false, true] {
                    let style = CapsuleStyle.fill(isKey: isKey, isFocused: isFocused, contrast: contrast)
                    let active = isKey && isFocused
                    XCTAssertEqual(
                        style.fill, active ? .silkwebSelection : .silkwebSelectionInactive,
                        "\(isKey) \(isFocused) \(contrast)")
                    XCTAssertEqual(style.stroke, active && contrast ? .silkwebAccent : nil)
                    XCTAssertEqual(style.tintsAccessories, active)
                }
            }
        }
    }

    func testSpacingScale() {
        XCTAssertEqual(
            [
                Spacing.xxSmall, Spacing.xSmall, Spacing.small, Spacing.medium, Spacing.large,
                Spacing.xLarge, Spacing.xxLarge, Spacing.page,
            ], [4, 8, 12, 16, 20, 24, 32, 48])
        XCTAssertEqual(Spacing.sidebarRowHeight, 28)
        XCTAssertEqual(Spacing.editorHorizontalInset, 48)
        XCTAssertEqual(Spacing.tabBarHeight, 32)
        XCTAssertEqual(Spacing.statusBarHeight, 26)
        XCTAssertEqual(WritingPreferences().maximumWidth, 660)
        XCTAssertEqual(EditorStyle(preferences: WritingPreferences()).horizontalInset, 48)
    }

    func testStatusBarSaveLabels() {
        typealias Label = DocumentStatusBar.SaveLabel
        let failure = DocumentSaveState.failed(
            error: DocumentSaveFailure(error: CocoaError(.fileWriteOutOfSpace), url: URL(fileURLWithPath: "/tmp/x.md")),
            attempt: 1)
        let cases: [(DocumentSaveState, Bool, Label)] = [
            (.clean, false, .saved), (.dirty, false, .edited), (.saving, false, .edited),
            (failure, false, .notSaved), (.conflict(diskRevision: nil), false, .notSaved),
        ]
        for (state, readOnly, label) in cases {
            XCTAssertEqual(Label(state: state, readOnly: readOnly), label)
            XCTAssertEqual(Label(state: state, readOnly: true), .readOnly)
        }
        XCTAssertEqual(
            [Label.saved, .edited, .notSaved, .readOnly].map(\.rawValue), ["Saved", "Edited", "Not Saved", "Read-only"])
    }

    @MainActor
    func testPreviewUsesSurfaceAndSageButExportsStayPortable() async throws {
        let defaults = disposableDefaults("RedesignPreview")
        let preview = PreviewCoordinator(defaults: defaults)
        preview.mode = .preview
        preview.schedule(text: "# Title\n\n[link](https://example.com)", document: nil, root: nil)
        let deadline = Date().addingTimeInterval(3)
        while preview.html.isEmpty && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(preview.html.contains(SilkwebTokens.previewCSS))
        XCTAssertTrue(preview.html.contains("--sw-surface: #FBFBFA"))
        XCTAssertTrue(preview.html.contains("--sw-accent: #7FC0A4"))
        XCTAssertTrue(preview.html.contains("max-width: 660px"))
        XCTAssertTrue(preview.html.contains("padding: 16px 48px 80px"))
        // Export and print never pick up the on-screen surface.
        XCTAssertFalse(PreviewCoordinator.stylesheet.contains("--sw-surface"))
        XCTAssertFalse(PrintCoordinator.stylesheet.contains("--sw-surface"))
    }

    @MainActor
    func testFocusedCapsuleTintsSidebarAccessories() {
        let cell = SidebarFolderCell()
        let image = NSImageView()
        cell.addSubview(image)
        cell.imageView = image
        cell.configureCluster(unreadable: true, renaming: false)
        XCTAssertEqual(cell.countBadge.textColor, .secondaryLabelColor)
        XCTAssertEqual(image.contentTintColor, .secondaryLabelColor)
        cell.capsuleFocused = true
        XCTAssertEqual(cell.countBadge.textColor, .silkwebAccent)
        XCTAssertEqual(cell.lockBadge.contentTintColor, .silkwebAccent)
        XCTAssertEqual(image.contentTintColor, .silkwebAccent)
        cell.capsuleFocused = false
        XCTAssertEqual(cell.countBadge.textColor, .secondaryLabelColor)
        // The row view never hands cells the emphasized (white-on-accent) style.
        let row = CapsuleRowView(cornerRadius: 6)
        row.isSelected = true
        row.isEmphasized = true
        XCTAssertEqual(row.interiorBackgroundStyle, .normal)
    }

    // MARK: Real hierarchy

    private struct Fixture {
        let root: URL
        let workspace: LibraryWorkspace
        let defaults: UserDefaults
        func cleanUp() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @MainActor
    private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebRedesign-" + UUID().uuidString)
        let defaults = disposableDefaults("Redesign")
        for path in ["Coffee/Brewing Guides", "Travels/Japan"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let body =
            "# Pour-Over\n\n## Grind\n\nMedium-fine.\n\n## Bloom\n\n"
            + String(repeating: "Pour slowly in circles. ", count: 80)
        try Data(body.utf8).write(to: root.appendingPathComponent("Coffee/Brewing Guides/Pour-Over.md"))
        try Data("# Cold Brew\n\nSteep overnight.".utf8).write(
            to: root.appendingPathComponent("Coffee/Brewing Guides/Cold Brew.md"))
        try Data("# Kyoto\n\nTemples.".utf8).write(to: root.appendingPathComponent("Travels/Japan/Kyoto.md"))
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        return Fixture(root: root, workspace: workspace, defaults: defaults)
    }

    @MainActor
    private func settle(_ controller: NSViewController) async throws {
        for _ in 0..<6 {
            (controller as? LibrarySplitViewController)?.updateRequests()
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }

    @MainActor
    func testOffscreenLifecycleKeepsCapsulesSuffixesTabsAndMeasure() async throws {
        let fixture = try await makeFixture()
        defer { fixture.cleanUp() }
        let workspace = fixture.workspace
        let snapshot = try XCTUnwrap(workspace.snapshot)
        let pour = try XCTUnwrap(snapshot.documents.first { $0.name == "Pour-Over.md" })
        let cold = try XCTUnwrap(snapshot.documents.first { $0.name == "Cold Brew.md" })
        workspace.session.selectedFolder = "Coffee/Brewing Guides"
        workspace.session.expandedFolders = ["", "Coffee"]
        let controller = LibrarySplitViewController(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller // Never ordered on screen.
        defer { window.contentViewController = nil; window.close() }
        try await settle(controller)
        let openedCold = await workspace.openTab(cold, pinned: true)
        let openedPour = await workspace.openTab(pour, pinned: true)
        XCTAssertTrue(openedCold && openedPour)
        workspace.session.selectedDocuments = [pour.relativePath]
        try await settle(controller)

        let sizes: [NSSize] = [
            NSSize(width: 1200, height: 560), NSSize(width: 1400, height: 780),
            NSSize(width: 1600, height: 1000), NSSize(width: 1200, height: 560),
        ]
        for (mode, outline) in [
            (DocumentViewMode.editor, false), (.split, false), (.preview, true), (.editor, true), (.split, true),
        ] {
            workspace.preview.mode = mode
            workspace.inspectorInfo = false
            workspace.preview.showsOutline = outline
            for size in sizes {
                window.setContentSize(size)
                try await settle(controller)
                let context = "\(mode) outline \(outline) at \(size)"
                let views = Self.descendants(controller.view)

                // Sidebar: 28 pt rows, a 6 pt capsule 10 pt from the column edges, and the 1.49 inline suffix intact.
                let sidebar = try XCTUnwrap(views.compactMap { $0 as? SidebarOutlineView }.first)
                XCTAssertEqual(sidebar.rowHeight, 28)
                let folderRow = sidebar.selectedRow
                let item = try XCTUnwrap(sidebar.item(atRow: folderRow) as? FolderSidebar.Item, context)
                XCTAssertEqual(item.folder?.relativePath, "Coffee/Brewing Guides", context)
                let folderRowView = try XCTUnwrap(
                    sidebar.rowView(atRow: folderRow, makeIfNecessary: false) as? CapsuleRowView, context)
                XCTAssertEqual(folderRowView.cornerRadius, 6)
                let folderCapsule = folderRowView.convert(folderRowView.capsuleRect, to: sidebar)
                XCTAssertEqual(folderCapsule.minX, 10, accuracy: 0.5, context)
                XCTAssertEqual(folderCapsule.maxX, sidebar.bounds.width - 10, accuracy: 0.5, context)
                let cell = try XCTUnwrap(
                    sidebar.view(atColumn: 0, row: folderRow, makeIfNecessary: false) as? SidebarFolderCell, context)
                let text = try XCTUnwrap(cell.textField)
                let titleRect = text.alignmentRect(forFrame: text.frame)
                let countRect = cell.countBadge.alignmentRect(forFrame: cell.countBadge.frame)
                XCTAssertEqual(cell.countBadge.stringValue, " (2)", context)
                XCTAssertFalse(cell.countBadge.isHidden)
                XCTAssertEqual(countRect.minX, titleRect.maxX, accuracy: 0.5, context)
                XCTAssertGreaterThanOrEqual(countRect.width + 0.5, cell.countBadge.intrinsicContentSize.width, context)
                XCTAssertLessThanOrEqual(cell.convert(countRect, to: sidebar).maxX, folderCapsule.maxX, context)
                XCTAssertEqual(
                    cell.countBadge.textColor, .secondaryLabelColor, "unfocused capsule keeps the secondary suffix")

                // Document list: an 8 pt capsule with the same 10 pt inset.
                let list = try XCTUnwrap(views.compactMap { $0 as? DocumentTableView }.first, context)
                let listRow = try XCTUnwrap(list.selectedRowIndexes.first, context)
                let listRowView = try XCTUnwrap(
                    list.rowView(atRow: listRow, makeIfNecessary: false) as? CapsuleRowView, context)
                XCTAssertEqual(listRowView.cornerRadius, 8)
                let listCapsule = listRowView.convert(listRowView.capsuleRect, to: list)
                XCTAssertEqual(listCapsule.minX, 10, accuracy: 0.5, context)
                XCTAssertEqual(listCapsule.maxX, list.bounds.width - 10, accuracy: 0.5, context)

                // Tabs: a 32 pt strip of 28 pt folder tabs (1.65); × on hover and on the active tab only.
                let tabBar = try XCTUnwrap(views.compactMap { $0 as? EditorTabBarView }.first, context)
                XCTAssertEqual(tabBar.frame.height, 32, accuracy: 0.5, context)
                XCTAssertEqual(tabBar.buttons.count, 2)
                for button in tabBar.buttons {
                    XCTAssertEqual(button.frame.height, 28, accuracy: 0.5, context)
                    XCTAssertEqual(button.close.isHidden, !button.isActive, context)
                }

                if outline {
                    let tables = views.compactMap { $0 as? NSTableView }.filter {
                        !($0 is SidebarOutlineView) && !($0 is DocumentTableView)
                    }
                    XCTAssertFalse(tables.isEmpty, "Outline shown: \(context)")
                }
                guard mode != .preview else { continue }
                // Editor: a ≤660 pt column centered in its pane (the whole detail in Editor mode); Menlo 15 unchanged.
                let editor = try XCTUnwrap(workspace.preview.editor, context)
                let scroll = try XCTUnwrap(editor.enclosingScrollView)
                let container = try XCTUnwrap(editor.textContainer)
                let viewport = scroll.contentSize.width
                XCTAssertEqual(container.containerSize.width, max(1, min(660, viewport - 96)), accuracy: 0.5, context)
                XCTAssertLessThanOrEqual(container.containerSize.width, 660)
                let column = editor.convert(
                    NSRect(x: editor.textContainerOrigin.x, y: 0, width: container.containerSize.width, height: 1),
                    to: nil)
                let pane = scroll.convert(scroll.bounds, to: nil)
                XCTAssertEqual(column.midX, pane.minX + viewport / 2, accuracy: 8, context)
                if mode == .editor {
                    let detail = controller.splitView.arrangedSubviews[1]
                    let detailFrame = detail.convert(detail.bounds, to: nil)
                    let inspector = outline ? detailFrame.maxX - pane.maxX : 0
                    XCTAssertEqual(
                        column.midX, detailFrame.minX + (detailFrame.width - inspector) / 2, accuracy: 8, context)
                    // The status strip sits under the editor, at the bottom of the detail column.
                    XCTAssertEqual(pane.minY - detailFrame.minY, 26, accuracy: 1.5, context)
                }
                XCTAssertEqual(editor.font?.fontName, "Menlo-Regular")
                XCTAssertEqual(editor.font?.pointSize, 15)
            }
        }
        XCTAssertFalse(window.isVisible)
    }

    /// 1,000 folders expanded in the sidebar and 10,000 rows in the list scroll within a 16 ms frame budget.
    @MainActor
    func testLargeLibraryScrollStaysWithinFrameBudget() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebRedesignPerf-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scanned = try await LibraryScanner.scan(root: root)
        let rootFolder = try XCTUnwrap(scanned.folders.first)
        var folders = [rootFolder]
        for parent in 0..<100 {
            let parentFolder = LibraryFolder(
                id: UUID(), parentID: rootFolder.id, relativePath: "Folder \(parent)", name: "Folder \(parent)")
            folders.append(parentFolder)
            for child in 0..<9 {
                folders.append(
                    LibraryFolder(
                        id: UUID(), parentID: parentFolder.id, relativePath: "Folder \(parent)/Child \(child)",
                        name: "Child \(child)"))
            }
        }
        let documents = (0..<10_000).map {
            LibraryDocument(id: UUID(), folderID: rootFolder.id, relativePath: "Note \($0).md", name: "Note \($0).md")
        }
        let snapshot = LibrarySnapshot(
            rootURL: root, folders: folders, documents: documents,
            presentation: LibraryPresentation(folders: folders, documents: documents), metadata: scanned.metadata,
            recoveredMetadataURL: nil, isReadOnly: false)
        let defaults = disposableDefaults("RedesignPerf")
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.session.selectedFolder = ""
        workspace.session.expandedFolders = Set(folders.map(\.relativePath))
        workspace.install(snapshot)
        let controller = LibrarySplitViewController(workspace: workspace)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { window.contentViewController = nil; window.close() }
        try await settle(controller)
        let views = Self.descendants(controller.view)
        let sidebar = try XCTUnwrap(views.compactMap { $0 as? SidebarOutlineView }.first)
        let list = try XCTUnwrap(views.compactMap { $0 as? DocumentTableView }.first)
        XCTAssertGreaterThanOrEqual(sidebar.numberOfRows, 1_001)
        XCTAssertEqual(list.numberOfRows, 10_000)

        for (table, step) in [(sidebar as NSTableView, CGFloat(84)), (list as NSTableView, CGFloat(144))] {
            let scroll = try XCTUnwrap(table.enclosingScrollView)
            // An unordered window never tiles on its own; size the table to its rows first.
            table.tile()
            scroll.layoutSubtreeIfNeeded()
            let contentHeight = table.rect(ofRow: table.numberOfRows - 1).maxY
            XCTAssertGreaterThan(
                contentHeight, scroll.contentSize.height + 120 * step / 2, "\(type(of: table)) must scroll")
            var samples: [Double] = []
            var offset: CGFloat = 0
            for _ in 0..<120 {
                offset = min(offset + step, max(0, contentHeight - scroll.contentSize.height))
                let start = CACurrentMediaTime()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scroll.reflectScrolledClipView(scroll.contentView)
                scroll.layoutSubtreeIfNeeded()
                samples.append((CACurrentMediaTime() - start) * 1000)
            }
            samples.sort()
            let p95 = samples[Int(Double(samples.count - 1) * 0.95)]
            print(
                "R1 scroll benchmark \(type(of: table)): p95 \(String(format: "%.2f", p95)) ms, max \(String(format: "%.2f", samples.last!)) ms"
            )
            XCTAssertLessThan(p95, TestEnvironment.frameBudget(16), "\(type(of: table)) scroll p95")
            // The clip view, not `visibleRect`: an unordered window reports no visible area.
            XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0, "\(type(of: table)) scrolled")
        }
    }
}

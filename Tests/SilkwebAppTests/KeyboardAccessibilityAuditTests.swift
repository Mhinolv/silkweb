import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

/// silkweb-1.25: §6 shortcut map, focus-dependent enablement, context-menu wording and the §7
/// accessibility audit, checked against the shipped hierarchy.
@MainActor
final class KeyboardAccessibilityAuditTests: XCTestCase {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    // MARK: §6 shortcut map

    /// The §6 table as a string table: command → shortcut. Standard Edit, Spelling, Toolbar and
    /// Full Screen items come from AppKit/SwiftUI and are not declared in Silkweb's sources.
    static let shortcutMap: [(command: String, shortcut: String)] = [
        ("New Document", "⌘N"), ("New Folder", "⇧⌘N"), ("New Library…", "⌥⌘N"),
        ("Open Folder in Place…", "⌘O"), ("Quick Open…", "⇧⌘O"), ("Open in New Tab", "⌘T"),
        ("Import Folder Copy…", "⇧⌘I"), ("Close Tab", "⌘W"), ("Close Window", "⇧⌘W"), ("Save", "⌘S"),
        ("Move To…", "⌃⌘M"), ("Reveal in Finder", "⌥⌘R"), ("Move to Trash", "⌘⌫"),
        ("Export ▸ HTML…", "⇧⌘E"), ("Export ▸ PDF…", "⌥⌘P"), ("Page Setup…", "⇧⌘P"), ("Print…", "⌘P"),
        ("Undo", "⌘Z"), ("Redo", "⇧⌘Z"), ("Paste and Match Style", "⌥⇧⌘V"),
        ("Find…", "⌘F"), ("Find and Replace…", "⌥⌘F"), ("Find Next", "⌘G"), ("Find Previous", "⇧⌘G"),
        ("Use Selection for Find", "⌘E"), ("Jump to Selection", "⌘J"), ("Search Library…", "⇧⌘F"),
        ("Bold", "⌘B"), ("Italic", "⌘I"), ("Strikethrough", "⇧⌘X"), ("Inline Code", "⌃⌘C"),
        ("Link", "⌘K"), ("Image…", "⌃⌘I"),
        ("Heading 1", "⌃⌘1"), ("Heading 2", "⌃⌘2"), ("Heading 3", "⌃⌘3"), ("Heading 4", "⌃⌘4"),
        ("Heading 5", "⌃⌘5"), ("Heading 6", "⌃⌘6"), ("Body Text", "⌃⌘0"),
        ("Quote", "⌘'"), ("Bulleted List", "⌥⌘U"), ("Numbered List", "⌥⌘O"), ("Task List", "⌥⌘X"),
        ("Code Block", "⌃⇧⌘C"), ("Shift Right", "⌘]"), ("Shift Left", "⌘["), ("Insert Table…", "⌃⌘T"),
        ("Editor ↔ Preview", "⌘R"), ("Split Editor and Preview", "⌘4"), ("Show Outline", "⌘7"),
        ("Show Document Info", "⌘8"), ("Hide/Show Sidebars", "⌃⌘S"), ("Show Status Bar", "⌘/"),
        ("Sort By ▸ Name", "⌃⌥⌘1"), ("Sort By ▸ Date Modified", "⌃⌥⌘2"), ("Sort By ▸ Date Created", "⌃⌥⌘3"),
        ("Focus Mode", "⌃⇧⌘F"), ("Typewriter Mode", "⌃⇧⌘T"),
        ("Bigger", "⌘+"), ("Smaller", "⌘−"), ("Actual Size", "⌘0"),
        ("Go ▸ Folders", "⌥⌘1"), ("Go ▸ Documents", "⌥⌘2"), ("Go ▸ Editor", "⌥⌘3"),
        ("Show Next Tab", "⇧⌘]"), ("Show Previous Tab", "⇧⌘["), ("Close Other Tabs", "⌥⌘W"),
    ]

    static func glyphs(key: String, modifiers: Set<String>) -> String {
        let order: [(String, String)] = [("control", "⌃"), ("option", "⌥"), ("shift", "⇧"), ("command", "⌘")]
        let keyGlyph = ["delete": "⌫", "-": "−"][key] ?? key.uppercased()
        return order.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyGlyph
    }

    /// Every `.keyboardShortcut("k", modifiers: …)` and `KeyboardShortcut("k", …)` in the app sources.
    static func declaredShortcuts() throws -> [String] {
        let sources = repository.appendingPathComponent("Sources/Silkweb")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        let pattern = try NSRegularExpression(pattern: #"[kK]eyboardShortcut\((?:"([^"]+)"|\.(delete))(?:,\s*modifiers:\s*(\[[^\]]*\]|\.[a-z]+))?\)"#)
        var result: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let ns = text as NSString
                let key = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : ns.substring(with: match.range(at: 2))
                var modifiers: Set<String> = ["command"]
                if match.range(at: 3).location != NSNotFound {
                    let list = ns.substring(with: match.range(at: 3))
                    modifiers = Set(["control", "option", "shift", "command"].filter { list.contains("." + $0) })
                }
                result.append(glyphs(key: key, modifiers: modifiers))
            }
        }
        // Table-driven items: Format (1.12) and Sort By (1.9).
        for item in FormatItem.groups.flatMap({ $0 }) {
            var modifiers: Set<String> = []
            if item.modifiers.contains(.control) { modifiers.insert("control") }
            if item.modifiers.contains(.option) { modifiers.insert("option") }
            if item.modifiers.contains(.shift) { modifiers.insert("shift") }
            if item.modifiers.contains(.command) { modifiers.insert("command") }
            result.append(glyphs(key: item.key, modifiers: modifiers))
        }
        result += ["⌃⌥⌘1", "⌃⌥⌘2", "⌃⌥⌘3"]
        return result
    }

    func testShortcutMapMatchesDesignSystemAndSources() throws {
        let doc = try String(contentsOf: Self.repository.appendingPathComponent("docs/design-system.md"), encoding: .utf8)
        let section = try XCTUnwrap(doc.components(separatedBy: "## 6. Keyboard shortcut map").last?.components(separatedBy: "## 7.").first)
        let mapped = Self.shortcutMap.map(\.shortcut)
        // No duplicate bindings in the map.
        XCTAssertEqual(Set(mapped).count, mapped.count, "duplicate shortcut in the §6 string table")
        let declared = try Self.declaredShortcuts()
        // Silkweb declares ⌘Z/⇧⌘Z itself (library undo); standard Edit items are documented as “standard”.
        let documentedAsStandard: Set<String> = ["⌘Z", "⇧⌘Z"]
        for (command, shortcut) in Self.shortcutMap {
            XCTAssertTrue(declared.contains(shortcut), "\(command) \(shortcut) is in §6 but not declared")
            if !documentedAsStandard.contains(shortcut) {
                // Range rows (⌃⌘1…⌃⌘6) cover the individual headings.
                let documented = section.contains(shortcut) || (command.hasPrefix("Heading ") && section.contains("⌃⌘1…⌃⌘6"))
                XCTAssertTrue(documented, "\(command) \(shortcut) is declared but missing from design-system §6")
            }
        }
        // Nothing undocumented, and each binding is declared once (the Format context menu reuses FormatItem).
        var counts: [String: Int] = [:]
        for shortcut in declared { counts[shortcut, default: 0] += 1 }
        for (shortcut, count) in counts {
            XCTAssertTrue(mapped.contains(shortcut), "\(shortcut) is declared but not in the §6 map")
            XCTAssertEqual(count, 1, "\(shortcut) is bound \(count) times")
        }
        // Deliberately unassigned keys stay free.
        for free in ["⌘1", "⌘2", "⌘3", "⌘5", "⌘6", "⌘9", "⌘U", "⌃⌘Q"] {
            XCTAssertFalse(declared.contains(free), "\(free) must stay unassigned")
        }
    }

    // MARK: Focus rules

    private struct Library {
        let root: URL, suite: String, defaults: UserDefaults, workspace: LibraryWorkspace
        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func library() async throws -> Library {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebAudit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Coffee/Brewing"), withIntermediateDirectories: true)
        try Data("# Pour-Over\n\n## Grind\n\nMedium-fine.\n\n![Kettle](kettle.png)\n".utf8).write(to: root.appendingPathComponent("Coffee/Brewing/Pour-Over.md"))
        try Data("# Cold Brew\n\nSteep overnight.".utf8).write(to: root.appendingPathComponent("Coffee/Brewing/Cold Brew.md"))
        try Data("# Kyoto\n\nTemples.".utf8).write(to: root.appendingPathComponent("Coffee/Kyoto.md"))
        let suite = "Silkweb.Audit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        return Library(root: root, suite: suite, defaults: defaults, workspace: workspace)
    }

    private func window(_ root: some View) -> (NSWindow, NSHostingController<AnyView>) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sizingOptions = []
        window.contentViewController = controller // Never ordered on screen.
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        return (window, controller)
    }

    private func settle(_ window: NSWindow, _ rounds: Int = 4) async throws {
        for _ in 0..<rounds {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    /// Format needs an editable editor; Find needs a visible editor; Rename/Move/Trash need a
    /// sidebar or list selection; Export/Print need a document. Disabled items stay in the menu.
    func testCommandEnablementFollowsFocusRules() async throws {
        let fixture = try await library()
        defer { fixture.cleanUp() }
        let workspace = fixture.workspace
        let (window, _) = window(LibraryWorkspaceView(workspace: workspace))
        defer { window.contentViewController = nil; window.close() }
        try await settle(window)

        // Nothing selected: document commands are off.
        workspace.session.selectedFolder = "Coffee/Brewing"
        workspace.session.selectedDocuments = []
        workspace.focusColumn = 1
        workspace.menuState.refresh()
        var state = workspace.menuState.value
        XCTAssertFalse(state.canRename); XCTAssertFalse(state.canMove); XCTAssertFalse(state.canTrash)
        XCTAssertFalse(state.canExport); XCTAssertFalse(state.canPrint); XCTAssertFalse(state.canFind)
        XCTAssertFalse(FormattingTarget.shared.enabled)

        // A list selection enables Rename, Move To…, Trash and Export; Find follows the open editor.
        let pour = try XCTUnwrap(workspace.snapshot?.documents.first { $0.name == "Pour-Over.md" })
        workspace.selectDocuments([pour.relativePath])
        await workspace.waitForNavigation()
        try await settle(window)
        workspace.focusColumn = 1
        workspace.menuState.refresh()
        state = workspace.menuState.value
        XCTAssertTrue(state.canRename); XCTAssertTrue(state.canMove); XCTAssertTrue(state.canTrash)
        XCTAssertTrue(state.canExport); XCTAssertTrue(state.canPrint); XCTAssertTrue(state.canFind)
        XCTAssertEqual(state.trashTitle, "Move “Pour-Over” to Trash")

        // Editor focus: Format turns on, Trash turns off (⌘⌫ deletes text there).
        let editor = try XCTUnwrap(workspace.preview.editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        workspace.focusColumn = 2
        try await settle(window, 2)
        workspace.menuState.refresh()
        XCTAssertTrue(FormattingTarget.shared.enabled)
        XCTAssertFalse(workspace.menuState.value.canTrash)
        XCTAssertFalse(workspace.menuState.value.canRename)
        XCTAssertFalse(workspace.menuState.value.canMove)
        XCTAssertTrue(workspace.menuState.value.canFind)
        // Leaving the editor disables Format again.
        let list = try XCTUnwrap(Self.descendants(window.contentView!).compactMap { $0 as? DocumentTableView }.first)
        XCTAssertTrue(window.makeFirstResponder(list))
        XCTAssertFalse(FormattingTarget.shared.enabled)

        // Preview-only: Find is off (no editor), Export still works.
        workspace.preview.mode = .preview
        try await settle(window, 2)
        workspace.menuState.refresh()
        XCTAssertFalse(workspace.menuState.value.canFind)
        XCTAssertTrue(workspace.menuState.value.canExport)
        workspace.preview.mode = .editor
        XCTAssertFalse(window.isVisible)
    }

    // MARK: Context menus

    func testContextMenusMatchMenuBarWordingAndExportOffersPDF() async throws {
        let fixture = try await library()
        defer { fixture.cleanUp() }
        let workspace = fixture.workspace
        workspace.session.selectedFolder = "Coffee/Brewing"
        let (window, _) = window(LibraryWorkspaceView(workspace: workspace))
        defer { window.contentViewController = nil; window.close() }
        try await settle(window)
        let path = "Coffee/Brewing/Pour-Over.md"
        workspace.selectDocuments([path])
        await workspace.waitForNavigation()
        try await settle(window)
        let table = try XCTUnwrap(Self.descendants(window.contentView!).compactMap { $0 as? DocumentTableView }.first)
        let coordinator = try XCTUnwrap(table.coordinator)
        let menu = coordinator.menu(path: path)
        XCTAssertEqual(menu.items.map(\.title), ["Open in New Tab", "", "Rename…", "Move To…", "Reveal in Finder", "Export", "", "Tags", "Move to Trash"])
        let export = try XCTUnwrap(menu.items.first { $0.title == "Export" }?.submenu)
        // Same titles and order as File ▸ Export; no key equivalents in the context menu.
        XCTAssertEqual(export.items.map(\.title), ["HTML…", "PDF…"])
        XCTAssertTrue(export.items.allSatisfy { $0.keyEquivalent.isEmpty })
        let pdf = export.items[1]
        XCTAssertTrue(pdf.isEnabled)
        XCTAssertEqual(pdf.action, #selector(DocumentTable.Coordinator.exportPDF(_:)))
        XCTAssertTrue(pdf.target === coordinator)
        XCTAssertEqual(pdf.representedObject as? String, path)
        // Enablement follows HTML (and File ▸ Export): off for a multi-selection.
        workspace.session.selectedDocuments = [path, "Coffee/Brewing/Cold Brew.md"]
        let multi = try XCTUnwrap(coordinator.menu(path: path).items.first { $0.title == "Export" }?.submenu)
        XCTAssertFalse(multi.items[0].isEnabled)
        XCTAssertFalse(multi.items[1].isEnabled)
        workspace.session.selectedDocuments = [path]
        XCTAssertFalse(window.isVisible)
    }

    // MARK: Insert Table preview (1.14 follow-up)

    func testInsertTablePreviewSitsTopLeftWhenItFits() async throws {
        StatusBarCountsTests.exposeAccessibility(true)
        defer { StatusBarCountsTests.exposeAccessibility(false) }
        for options in [TableOptions(columns: 1, rows: 1), TableOptions(columns: 2, rows: 1), TableOptions(columns: 20, rows: 100)] {
            let form = TableInsertForm(options: options)
            let host = NSHostingView(rootView: TableInsertSheet(form: form, cancel: {}, insert: { _ in }))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.contentView = nil; window.close() }
            window.setContentSize(host.fittingSize)
            for _ in 0..<3 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(40)) }
            let tree = StatusBarCountsTests.accessibilityTree(host)
            let box = try XCTUnwrap(tree.first { StatusBarCountsTests.label($0) == "Table source preview" }, "\(options)")
            let text = try XCTUnwrap(tree.first { $0.accessibilityIdentifier?() == "tableSourcePreviewText" }, "\(options)")
            let boxFrame = StatusBarCountsTests.frame(box), textFrame = StatusBarCountsTests.frame(text)
            let context = "\(options) box \(boxFrame) text \(textFrame)"
            XCTAssertGreaterThan(textFrame.width, 10, context)
            // Top-leading within ±2 pt of the visible box (AppKit screen coordinates: top = maxY).
            XCTAssertEqual(textFrame.minX, boxFrame.minX, accuracy: 2, context)
            XCTAssertEqual(textFrame.maxY, boxFrame.maxY, accuracy: 2, context)
            XCTAssertLessThanOrEqual(boxFrame.height, 80.5, context)
        }
    }

    // MARK: §7 accessibility audit

    private static let controlRoles: Set<NSAccessibility.Role> = [
        .button, .checkBox, .radioButton, .popUpButton, .menuButton, .disclosureTriangle,
        .slider, .incrementor, .comboBox, .textField, .colorWell,
    ]

    /// Walks the tree VoiceOver sees from the window, including the toolbar.
    static func walk(_ window: NSWindow, _ visit: (AnyObject, NSAccessibility.Role) -> Void) {
        var seen = Set<ObjectIdentifier>()
        func recurse(_ element: AnyObject, depth: Int) {
            guard depth < 60, seen.insert(ObjectIdentifier(element)).inserted else { return }
            if let role = element.accessibilityRole?() ?? nil { visit(element, role) }
            for child in (element.accessibilityChildren?() ?? nil) ?? [] { recurse(child as AnyObject, depth: depth + 1) }
        }
        recurse(window, depth: 0)
        if let frame = window.contentView?.superview { recurse(frame, depth: 0) }
    }

    static func unlabeledControls(in window: NSWindow) -> [String] {
        var missing: [String] = []
        // Window chrome (close/minimize/zoom/full screen) belongs to AppKit.
        let chrome: Set<NSAccessibility.Subrole> = [.closeButton, .minimizeButton, .zoomButton, .fullScreenButton, .toolbarButton]
        walk(window) { element, role in
            guard controlRoles.contains(role) else { return }
            // VoiceOver also reads a linked title element (a Form row's label).
            let titleElement: AnyObject? = (element.accessibilityTitleUIElement?() ?? nil).map { $0 as AnyObject }
            let names: [String?] = [element.accessibilityLabel?() ?? nil, element.accessibilityTitle?() ?? nil,
                                    titleElement.flatMap { $0.accessibilityLabel?() ?? nil },
                                    titleElement.flatMap { StatusBarCountsTests.value($0) }]
            let name = names.compactMap { $0 }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let subrole = element.accessibilitySubrole?() ?? nil
            if name == nil, !(subrole.map(chrome.contains) ?? false) {
                missing.append("\(role.rawValue) \(type(of: element)) id=\(element.accessibilityIdentifier?() ?? "") help=\((element.accessibilityHelp?() ?? nil) ?? "")")
            }
        }
        return missing
    }

    static func controlCount(in window: NSWindow) -> Int {
        var count = 0
        walk(window) { _, role in if controlRoles.contains(role) { count += 1 } }
        return count
    }

    /// Toolbar, sidebar, list, tab bar, inspector (Outline and Info) and status bar in the shipped
    /// window, plus every Settings tab: every control has a non-empty accessible name.
    func testEveryShippedControlHasAnAccessibilityLabel() async throws {
        let fixture = try await library()
        defer { fixture.cleanUp() }
        StatusBarCountsTests.exposeAccessibility(true)
        defer { StatusBarCountsTests.exposeAccessibility(false) }
        let workspace = fixture.workspace
        workspace.session.selectedFolder = "Coffee/Brewing"
        workspace.session.expandedFolders = ["", "Coffee"]
        let (window, _) = window(LibraryWorkspaceView(workspace: workspace))
        defer { window.contentViewController = nil; window.close() }
        try await settle(window)
        for name in ["Pour-Over.md", "Cold Brew.md"] {
            let document = try XCTUnwrap(workspace.snapshot?.documents.first { $0.name == name })
            let opened = await workspace.openTab(document, pinned: true)
            XCTAssertTrue(opened)
        }
        workspace.setWritingModes(focus: true, typewriter: false)
        workspace.editor.state = .dirty
        var visited: [String] = []
        for (mode, outline, info) in [(DocumentViewMode.editor, true, false), (.split, true, true), (.preview, false, false), (.editor, true, true)] {
            workspace.preview.mode = mode
            workspace.preview.showsOutline = outline
            workspace.inspectorInfo = info
            try await settle(window)
            let missing = Self.unlabeledControls(in: window)
            XCTAssertEqual(missing, [], "\(mode) outline \(outline) info \(info)")
            visited.append("\(mode): \(Self.controlCount(in: window)) controls")
        }
        // The walk reaches the toolbar, sidebar, list, tabs and inspector (not an empty tree).
        let tree = StatusBarCountsTests.accessibilityTree(window.contentView!)
        for label in ["Document tabs", "Folders", "Document statistics", "Save state", "Writing modes"] {
            XCTAssertNotNil(tree.first { StatusBarCountsTests.label($0) == label }, "\(label) reachable; \(visited)")
        }
        XCTAssertGreaterThan(Self.controlCount(in: window), 8, "\(visited)")
        workspace.editor.state = .clean
        workspace.setWritingModes(focus: false, typewriter: false)

        // Settings (1.24): every tab.
        let settings = WritingSettings(defaults: fixture.defaults, live: false)
        for tab in SettingsTab.allCases {
            let (settingsWindow, _) = self.window(SettingsView(settings: settings, workspace: workspace, tab: tab))
            defer { settingsWindow.contentViewController = nil; settingsWindow.close() }
            try await settle(settingsWindow, 3)
            XCTAssertEqual(Self.unlabeledControls(in: settingsWindow), [], "Settings \(tab)")
            XCTAssertGreaterThan(Self.controlCount(in: settingsWindow), 0, "Settings \(tab)")
        }
        XCTAssertFalse(window.isVisible)
    }
}

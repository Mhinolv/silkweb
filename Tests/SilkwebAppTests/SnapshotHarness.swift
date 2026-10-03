import AppKit
import SwiftUI
import WebKit
@testable import SilkwebCore
@testable import Silkweb

/// QA infrastructure only: scenarios configure production state, never draw substitute UI.
@MainActor
struct SnapshotScenario {
    let name: String
    var folder: String? = nil
    var document: String? = nil
    var mode: DocumentViewMode = .editor
    var tagState: String? = nil
    var outline = false
    var sidebarsHidden = false
    var caretHeading: String? = nil
    var caretImage: String? = nil
    var rename = false
    var quickQuery: String? = nil
    var searchQuery: String? = nil
    var tabs: [String] = []
    var selectedDocuments: Set<String>? = nil
    var scrollToEnd = false
    var legacyScroller = false
    var resizeSidebar = false
    /// Final sidebar width after the resize sweep.
    var sidebarWidth: CGFloat? = nil
    /// Folders expanded in addition to the default set.
    var expanded: Set<String> = []
    var mediaMigration: String? = nil
    var tableInsert: String? = nil
    var exportWarning = false
    var printWarning = false
    var pdfProgress = false
    var focusOutline = false
    /// Draw the editor caret (normally hidden in captures) right after this source text.
    var visibleCaret: String? = nil
    var previewScrollState: String? = nil
    var createDocument = false
    var editImageHeading = false

    static let pourOver = "Coffee/Brewing Guides/Pour-Over in Five Steps.md"
    static let image = "Snapshot Fixtures/Image Fixture.md"
    static let initial: [SnapshotScenario] = [
        .init(name: "library-overview"),
        .init(name: "export-missing-images", exportWarning: true),
        .init(name: "print-missing-images", printWarning: true),
        .init(name: "pdf-export-progress", pdfProgress: true),
        .init(name: "tags-sidebar-collapsed", tagState: "collapsed"),
        .init(name: "tags-sidebar-expanded", tagState: "expanded"),
        .init(name: "tags-sidebar-empty", tagState: "zero"),
        .init(name: "tags-info-many", document: pourOver, tagState: "many"),
        .init(name: "tags-info", document: pourOver, tagState: "info"),
        .init(name: "tags-info-choose", tagState: "choose", selectedDocuments: [pourOver, image]),
        .init(name: "tags-info-empty", tagState: "empty"),
        .init(name: "tags-multi-selection", tagState: "multi", selectedDocuments: [pourOver, image]),
        .init(name: "tags-selected", tagState: "selected"),
        .init(name: "tags-rename", tagState: "rename"),
        .init(name: "tags-filter", folder: "Coffee/Brewing Guides", tagState: "filter"),
        .init(name: "tags-filter-empty", folder: "Snapshot Fixtures/Empty Folder", tagState: "filter"),
        .init(name: "tags-search", folder: "Coffee/Brewing Guides", tagState: "filter", searchQuery: "coffee"),
        .init(name: "sidebars-collapsed", document: pourOver, sidebarsHidden: true),
        .init(name: "table-insert-default", tableInsert: "default"),
        .init(name: "table-insert-maximum", tableInsert: "maximum"),
        .init(name: "table-insert-invalid", tableInsert: "invalid"),
        .init(name: "table-insert-left", tableInsert: "left"),
        .init(name: "table-insert-right", tableInsert: "right"),
        .init(name: "media-migration-progress", document: image, mediaMigration: "progress"),
        .init(name: "media-migration-failure", document: image, mediaMigration: "failure"),
        .init(name: "sidebar-resized", folder: "Coffee", resizeSidebar: true),
        // silkweb-1.63: thread guides and the coral node at both sidebar width limits.
        .init(name: "sidebar-resized-180", folder: "Coffee", resizeSidebar: true, sidebarWidth: 180),
        .init(name: "sidebar-resized-320", folder: "Coffee", resizeSidebar: true, sidebarWidth: 320),
        .init(name: "redesign-thread-sidebar", folder: "Vanlife", tagState: "expanded", expanded: ["Travel", "Travel/Japan"]),
        .init(name: "sidebar-folder-rename", folder: "Coffee", rename: true),
        .init(name: "folder-selected", folder: "Coffee/Brewing Guides"),
        // silkweb-1.62: one surface, hairlines, capsules, underline tab, status strip with “Saved” trailing.
        .init(name: "redesign-one-surface", folder: "Coffee/Brewing Guides", document: pourOver, outline: true,
              tabs: [pourOver, "Coffee/Why I Switched to Light Roasts.md"]),
        .init(name: "empty-folder", folder: "Snapshot Fixtures/Empty Folder"),
        .init(name: "outline-empty", document: "Snapshot Fixtures/Empty Document.md", outline: true),
        .init(name: "search-empty", searchQuery: "silkweb-no-matches-fixture"),
        .init(name: "editor-document", document: "Snapshot Fixtures/Editor Typography.md", tabs: ["Snapshot Fixtures/Editor Typography.md"], visibleCaret: "Body:"),
        .init(name: "tabs-multi-selection", tabs: [pourOver], selectedDocuments: [pourOver, image]),
        .init(name: "editor-long-scrolled-end", document: "Snapshot Fixtures/Long Document.md", tabs: [pourOver, "Snapshot Fixtures/Long Document.md"], scrollToEnd: true, legacyScroller: true),
        .init(name: "editor-image", document: image),
        .init(name: "editor-image-heading-edited", document: "Snapshot Fixtures/Image Heading Edits.md", editImageHeading: true),
        .init(name: "editor-image-heading-edited-wide", document: "Snapshot Fixtures/Image Heading Edits.md", sidebarsHidden: true, editImageHeading: true),
        .init(name: "editor-image-placeholders", document: "Snapshot Fixtures/Image States.md"),
        .init(name: "preview-headings", document: "Snapshot Fixtures/Preview Headings.md", mode: .preview),
        .init(name: "preview-mode", document: pourOver, mode: .preview),
        .init(name: "split-mode", document: pourOver, mode: .split),
        .init(name: "split-scroll-update", document: "Snapshot Fixtures/Scroll Preview.md", mode: .split, previewScrollState: "update"),
        .init(name: "split-scroll-entry", document: "Snapshot Fixtures/Scroll Preview.md", mode: .split, outline: true, previewScrollState: "entry"),
        .init(name: "inspector-outline", document: pourOver, outline: true),
        .init(name: "outline-images-split", document: "Snapshot Fixtures/Outline Images.md", mode: .split, outline: true, caretImage: "![Portrait]"),
        .init(name: "outline-images-only", document: "Snapshot Fixtures/Images Only.md", outline: true),
        .init(name: "outline-image-states", document: "Snapshot Fixtures/Image States.md", outline: true),
        .init(name: "outline-images", document: "Snapshot Fixtures/Outline Images.md", outline: true, caretImage: "![Portrait]"),
        // Outline focused with the second image row selected. The unordered host window is never
        // key, so the List draws its non-key selection; the accent fill needs a key window.
        .init(name: "outline-images-focused", document: "Snapshot Fixtures/Outline Images.md", outline: true, caretImage: "![Portrait]", focusOutline: true),
        .init(name: "outline-hierarchy", document: "Snapshot Fixtures/Outline Hierarchy.md", outline: true, caretHeading: "Grind size"),
        .init(name: "rename-active", document: pourOver, rename: true),
        .init(name: "quick-open", quickQuery: "brew"),
        .init(name: "search-results", searchQuery: "coffee"),
        .init(name: "empty-document", document: "Snapshot Fixtures/Empty Document.md"),
        .init(name: "new-document", folder: "", document: "Snapshot Fixtures/Empty Document.md", createDocument: true),
        .init(name: "new-document-in-folder", folder: "Snapshot Fixtures/Empty Folder", document: "Snapshot Fixtures/Empty Document.md", createDocument: true),
        .init(name: "read-only-banner", document: "Snapshot Fixtures/Read Only.md"),
        .init(name: "tabs-open", document: image, tabs: [pourOver, image, "Snapshot Fixtures/Empty Document.md"]),
    ]
}

struct SnapshotManifest: Codable {
    var version = 1
    var pointWidth: Int
    var pointHeight: Int
    var captures: [Capture] = []

    struct Capture: Codable {
        var scenario: String
        var appearance: String
        var status: String
        var file: String?
        var pixelWidth: Int?
        var pixelHeight: Int?
        var backingScale: Double?
        var windowTitle: String?
        var details: [String] = []
    }
}

private enum SnapshotFailure: Error {
    case timeout(String)
    case error(String)
}

@MainActor
private final class SnapshotResult<Value> {
    var value: Result<Value, Error>?
}

@MainActor
final class SnapshotHarness {
    static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let size: NSSize
    let timeout: TimeInterval
    private let environment: [String: String]
    var webKitUnavailable: Bool {
        Self.isWebKitUnavailable(environment: environment, activationPolicy: NSApp.activationPolicy().rawValue)
    }

    static func isWebKitUnavailable(environment: [String: String], activationPolicy: Int) -> Bool {
        // LaunchServices denial identifies unregistered sandbox hosts even when the
        // runner supplies no vendor-specific environment marker. Check after requesting
        // prohibited activation, before waiting for any WebKit navigation.
        environment["SILKWEB_SNAPSHOT_NO_WEBKIT"] == "1" ||
            environment["CODEX_SANDBOX"] != nil || activationPolicy == -1
    }
    var activationIsSafe: Bool {
        NSApp.activationPolicy() == .prohibited || (webKitUnavailable && NSApp.activationPolicy().rawValue == -1)
    }

    init(size: NSSize = NSSize(width: 1400, height: 900), timeout: TimeInterval = 12,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.size = size
        self.timeout = timeout
        self.environment = environment
    }

    func run(output: URL, names: [String] = []) async throws -> SnapshotManifest {
        let output = output.standardizedFileURL.resolvingSymlinksInPath()
        let ownerLibrary = Self.repository.appendingPathComponent("Test_Library").resolvingSymlinksInPath().path
        guard output.path != ownerLibrary, !output.path.hasPrefix(ownerLibrary + "/") else {
            throw SnapshotFailure.error("Snapshot output must be outside Test_Library")
        }
        guard size.width >= 900, size.height >= 560, size.width <= 4096, size.height <= 2160 else {
            throw SnapshotFailure.error("Snapshot size must be between 900×560 and 4096×2160 points")
        }
        let app = NSApplication.shared
        // XCTest already starts as prohibited; AppKit may return false for a no-op change.
        _ = app.setActivationPolicy(.prohibited)
        // Without LaunchServices access, AppKit reports -1 (unregistered) in seatbelt.
        // The command-line XCTest host has no Dock registration in that environment.
        guard activationIsSafe else { throw SnapshotFailure.error("Cannot prohibit application activation") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var manifest = SnapshotManifest(pointWidth: Int(size.width), pointHeight: Int(size.height))
        let requested = names.isEmpty ? SnapshotScenario.initial.map(\.name) : names
        for name in requested {
            for dark in [false, true] {
                let appearance = dark ? "dark" : "light"
                let capture: SnapshotManifest.Capture
                if let scenario = SnapshotScenario.initial.first(where: { $0.name == name }) {
                    capture = await render(scenario, dark: dark, output: output)
                } else {
                    capture = .init(scenario: name, appearance: appearance, status: "error: Unknown scenario")
                }
                manifest.captures.append(capture)
                // Write incrementally so even an interrupted batch leaves useful diagnostics.
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(manifest).write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
            }
        }
        return manifest
    }

    private func wait(_ stage: String, until ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready() {
            guard Date() < deadline else { throw SnapshotFailure.timeout(stage) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func bounded<Value>(_ stage: String, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let result = SnapshotResult<Value>()
        let task = Task { do { result.value = .success(try await operation()) } catch { result.value = .failure(error) } }
        defer { task.cancel() }
        try await wait(stage) { result.value != nil }
        return try result.value!.get()
    }

    private func makeFixture(at root: URL) throws {
        try FileManager.default.copyItem(at: Self.repository.appendingPathComponent("Test_Library"), to: root)
        // Ignore owner navigation/tab state in the COPY, including any recovery metadata.
        for name in [".silkweb"] {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
        }
        for name in ["A very long folder name that truncates before its count", "Private folder with a very long unreadable name"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // The thread scenario selects Vanlife; supply it in the copy when the owner library has none.
        let vanlife = root.appendingPathComponent("Vanlife")
        if !FileManager.default.fileExists(atPath: vanlife.path) {
            try FileManager.default.createDirectory(at: vanlife, withIntermediateDirectories: true)
            try Data("# Road Notes\n".utf8).write(to: vanlife.appendingPathComponent("Road Notes.md"), options: .atomic)
        }
        let fixtures = root.appendingPathComponent("Snapshot Fixtures")
        try FileManager.default.createDirectory(at: fixtures, withIntermediateDirectories: true)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 240,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for y in 0..<240 {
            for x in 0..<400 {
                bitmap.setColor(NSColor(calibratedRed: CGFloat(x) / 400, green: CGFloat(y) / 240, blue: 0.65, alpha: 1), atX: x, y: y)
            }
        }
        try bitmap.representation(using: .png, properties: [:])!.write(to: fixtures.appendingPathComponent("fixture.png"), options: .atomic)
        for (name, width, height) in [("portrait.png", 80, 240), ("transparent.png", 120, 80)] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for y in 0..<height { for x in 0..<width {
                rep.setColor(NSColor(calibratedRed: 0.2, green: 0.6, blue: 0.8, alpha: name == "transparent.png" && x < width / 2 ? 0 : 1), atX: x, y: y)
            } }
            try rep.representation(using: .png, properties: [:])!.write(to: fixtures.appendingPathComponent(name))
        }
        try Data("![Landscape](fixture.png)\n![Remote](https://example.invalid/image.png)\n".utf8).write(to: fixtures.appendingPathComponent("Images Only.md"))
        let outlineImages = "![Landscape](fixture.png)\n# Journey\n## Places\n![Portrait](portrait.png)\n### Detail\n![Transparent](transparent.png)\n## Other\n![Missing](missing.png)\n![Remote](https://example.invalid/image.png)\n"
        try Data(outlineImages.utf8).write(to: fixtures.appendingPathComponent("Outline Images.md"))
        let scrollPreview = "# Scroll stability\n\n![Local fixture](fixture.png)\n\n" + (0..<100).map { "## Section \($0)\n\nA paragraph with **emphasis**.\n\n" }.joined()
        try Data(scrollPreview.utf8).write(to: fixtures.appendingPathComponent("Scroll Preview.md"), options: .atomic)
        let headingImages = "# Journey\n\n![Landscape](fixture.png)\n\n" + String(repeating: "A paragraph between the images.\n\n", count: 40) + "![Portrait](portrait.png)\n\n![Transparent](transparent.png)\n"
        try Data(headingImages.utf8).write(to: fixtures.appendingPathComponent("Image Heading Edits.md"))
        let imageText = "# Image Fixture\n\n![Local fixture](fixture.png)\n\n![Remote fixture](https://example.invalid/snapshot.png)\n"
        try Data(imageText.utf8).write(to: fixtures.appendingPathComponent("Image Fixture.md"), options: .atomic)
        try Data("not an image".utf8).write(to: fixtures.appendingPathComponent("unreadable.png"))
        let imageStates = "# Image states\n\n![Remote](https://example.invalid/snapshot.png)\n\n![Missing](missing.png)\n\n![Outside](../../outside.png)\n\n![Unreadable](unreadable.png)\n"
        try Data(imageStates.utf8).write(to: fixtures.appendingPathComponent("Image States.md"), options: .atomic)
        let typography = "# Heading one\n\n## Heading two\n\n### Heading three\n\n#### Heading four\n\n##### Heading five\n\n###### Heading six\n\nBody: café, 日本語, 👩🏽‍💻. **Strong**, *emphasis*, ~~strike~~ and `code`.\n\n> A quote\n\n- [ ] A task with [a link](https://example.invalid)\n\n```swift\nlet source = true\n```\n"
        try Data(typography.utf8).write(to: fixtures.appendingPathComponent("Editor Typography.md"), options: .atomic)
        let previewHeadings = """
        # Settling In
        ###### Jamestown, PA

        Body text at the default preview size.

        ## Heading two
        ### Heading three
        #### Heading four
        ##### Heading five
        ###### Heading six

        A final paragraph beneath the complete heading scale.
        """
        try Data(previewHeadings.utf8).write(to: fixtures.appendingPathComponent("Preview Headings.md"), options: .atomic)
        let hierarchy = """
        # Pour-Over in Five Steps

        ## Equipment and a deliberately long heading ending with the essential tools

        ### Grind size

        Adjust the grind before brewing.

        #### Water temperature

        ##### Notes

        ###### Footnote

        ## Technique

        # Another brew

        # Settling In
        ###### Jamestown Campground, PA
        ![IMG_0412](portrait.png)
        ### Building A Home
        ###### Lake Erie
        ![IMG_0533](fixture.png)
        """
        try Data(hierarchy.utf8).write(to: fixtures.appendingPathComponent("Outline Hierarchy.md"), options: .atomic)
        try Data(LongEditorFixture.document.utf8).write(to: fixtures.appendingPathComponent("Long Document.md"), options: .atomic)
        try FileManager.default.createDirectory(at: fixtures.appendingPathComponent("Empty Folder"), withIntermediateDirectories: true)
        try Data().write(to: fixtures.appendingPathComponent("Empty Document.md"), options: .atomic)
        // Exercise the app's real invalid-UTF8 read-only banner without permission tricks.
        try Data(Array("# Read Only\n\nThis fixture opens read-only.\n".utf8) + [0xFF]).write(to: fixtures.appendingPathComponent("Read Only.md"), options: .atomic)
    }

    private func configure(_ scenario: SnapshotScenario, workspace: LibraryWorkspace) async throws {
        guard let snapshot = workspace.snapshot else { throw SnapshotFailure.error("Library did not scan") }
        workspace.session = LibrarySession()
        workspace.session.expandedFolders = Set(["", "Coffee", "Coffee/Brewing Guides", "Snapshot Fixtures"]).union(scenario.expanded)
        workspace.session.selectedFolder = scenario.folder
        if let folder = scenario.folder, !snapshot.folders.contains(where: { $0.relativePath == folder }) {
            throw SnapshotFailure.error("Missing fixture folder: \(folder)")
        }
        let paths = scenario.tabs.isEmpty ? scenario.document.map({ [$0] }) ?? [] : scenario.tabs
        for path in paths {
            guard let document = snapshot.documents.first(where: { $0.relativePath == path }) else {
                throw SnapshotFailure.error("Missing fixture document: \(path)")
            }
            guard await workspace.openTab(document, pinned: true) else { throw SnapshotFailure.error("Cannot open \(path)") }
        }
        if let path = scenario.document, let tab = workspace.tabs.first(where: { $0.editor.url?.path.hasSuffix("/" + path) == true }) {
            workspace.activateTab(tab.id, syncSelection: false)
            workspace.session.selectedDocuments = [path]
            if scenario.folder == nil { workspace.session.selectedFolder = (path as NSString).deletingLastPathComponent }
        }
        if let selected = scenario.selectedDocuments {
            workspace.selectDocuments(selected)
            await workspace.waitForNavigation()
            // Exercise the existing multi-selection placeholder with tabs retained.
            workspace.activeTabID = nil
        }
        if let migration = scenario.mediaMigration {
            workspace.mediaBannerVisible = true
            workspace.mediaDirectoryName = "media"
            if migration == "progress" { workspace.mediaProgress = ("media", 12, 40) }
            else { workspace.mediaFailures = [.init(name: "kettle.png", reason: "The file is locked.")] }
        }
        if scenario.createDocument {
            workspace.create(folder: false, parent: scenario.folder)
            for _ in 0..<500 {
                if !workspace.mutating { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !workspace.mutating, workspace.mutationError == nil else {
                throw SnapshotFailure.error("New document did not finish")
            }
        }
        workspace.preview.mode = scenario.mode
        workspace.preview.showsOutline = scenario.outline
        if let state = scenario.tagState, let snapshot = workspace.snapshot {
            let ids = Set(snapshot.documents.filter { [SnapshotScenario.pourOver, SnapshotScenario.image].contains($0.relativePath) }.map(\.id))
            let names = state == "many" ? (1...20).map { "research topic \($0)" } : ["research", "draft"]
            let choosePaths = [SnapshotScenario.pourOver, SnapshotScenario.image]
            _ = try await TagStore.update(root: snapshot.rootURL) { metadata in
                if state == "zero" { return metadata.tags.reduce(metadata) { TagEditor.delete($1.id, metadata: $0) } }
                if state == "info" {
                    let allNames = ["coffee", "draft", "kyoto", "notes", "research", "travel", "archive", "writing"]
                    let otherIDs = Set(snapshot.documents.map(\.id)).subtracting(ids)
                    var result = TagEditor.edit(allNames, documents: otherIDs, metadata: metadata)
                    result = TagEditor.edit(["coffee", "research"], documents: ids, metadata: result)
                    result.tagRecency = ["coffee", "draft", "kyoto", "notes", "research", "travel"].compactMap { TagEditor.existing($0, in: result.tags)?.id }
                    return result
                }
                if state == "choose" {
                    let allNames = ["Coffee brewing experiments", "Drafts awaiting another review", "Field notes from Kyoto", "Long distance travel planning", "Research and reference reading", "Writing small useful tools"]
                    let a = snapshot.metadata.IDsByPath[choosePaths[0]]!, b = snapshot.metadata.IDsByPath[choosePaths[1]]!
                    let otherIDs = Set(snapshot.documents.map(\.id)).subtracting([a, b])
                    var result = TagEditor.edit(allNames, documents: otherIDs, metadata: metadata)
                    result = TagEditor.edit([allNames[0], allNames[1]], documents: [a], metadata: result)
                    return TagEditor.edit([allNames[0]], documents: [b], metadata: result)
                }
                return TagEditor.edit(names, documents: ids, metadata: metadata)
            }
            workspace.tagsExpanded = state != "collapsed"
            workspace.install(try await LibraryScanner.scan(root: snapshot.rootURL))
            if state == "rename", let tag = workspace.tags.first { workspace.tagRenameID = tag.id; workspace.tagRenameName = tag.name }
            if state == "filter" { workspace.tagFilters = Set(workspace.tags.map(\.id)) }
            if state == "selected", let id = workspace.tags.first?.id { workspace.session.selectedTagID = id; workspace.session.selectedFolder = nil }
            if ["info", "empty", "multi", "many", "choose"].contains(state) { workspace.inspectorInfo = true; workspace.preview.showsOutline = true }
        }
        if let query = scenario.quickQuery { workspace.search.toggleQuickOpen(); workspace.search.quickText = query }
        if let query = scenario.searchQuery { workspace.search.text = query }
    }

    private func render(_ scenario: SnapshotScenario, dark: Bool, output: URL) async -> SnapshotManifest.Capture {
        var capture = SnapshotManifest.Capture(scenario: scenario.name, appearance: dark ? "dark" : "light", status: "ok")
        if NSApp.activationPolicy().rawValue == -1 {
            capture.details.append("Sandbox denies LaunchServices registration (activation policy -1); prohibited was requested; XCTest has no Dock registration.")
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebSnapshot-" + UUID().uuidString)
        let root = temporary.appendingPathComponent("Silkweb Snapshot Library")
        let suite = "Silkweb.Snapshots." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.canSaveWindowSession = false
        let oldAppearance = NSApp.appearance
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        NSApp.appearance = appearance
        // Native window chrome and production content, never entered into the window list.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = appearance
        window.backgroundColor = .windowBackgroundColor
        var host: NSHostingController<AnyView>?
        defer {
            window.contentViewController = nil
            window.close()
            NSApp.appearance = oldAppearance
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: temporary)
        }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            try makeFixture(at: root)
            workspace.root = root
            workspace.recoveryDirectory = root.appendingPathComponent("Snapshot Recovery")
            let snapshot = try await bounded("library scan") { try await LibraryScanner.scan(root: root) }
            if scenario.resizeSidebar {
                var folders = snapshot.folders
                if let index = folders.firstIndex(where: { $0.name == "Private folder with a very long unreadable name" }) {
                    // Deterministic scan-time permission fixture without changing filesystem permissions.
                    folders[index].isUnreadable = true
                }
                workspace.install(LibrarySnapshot(rootURL: snapshot.rootURL, folders: folders, documents: snapshot.documents,
                    presentation: LibraryPresentation(folders: folders, documents: snapshot.documents), metadata: snapshot.metadata,
                    recoveredMetadataURL: snapshot.recoveredMetadataURL, isReadOnly: snapshot.isReadOnly))
            } else { workspace.install(snapshot) }
            try await bounded("scenario configuration") { try await self.configure(scenario, workspace: workspace) }
            let content: AnyView
            if scenario.exportWarning || scenario.printWarning {
                let result = HTMLExport.prepare(markdown: (1...8).map { "![Image \($0)](missing-\($0).png)" }.joined(separator: "\n\n"),
                    title: "Document", documentURL: snapshot.rootURL.appendingPathComponent("Document.md"), libraryRoot: snapshot.rootURL, stylesheet: "")
                content = AnyView(ExportAlertSnapshot(alert: ExportCommands.missingImageAlert(result, printing: scenario.printWarning)))
            } else if scenario.pdfProgress {
                // Host the production progress sheet itself; never present or order a sheet window.
                content = AnyView(PDFProgressSheet(progress: PDFProgress(message: "Exporting “Pour-Over in Five Steps” as PDF…") {})
                    .background(Color(nsColor: .windowBackgroundColor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity))
            } else if let state = scenario.tableInsert {
                let form = TableInsertForm(options: state == "maximum" ? TableOptions(columns: 20, rows: 100, alignment: .center) : TableOptions())
                if state == "invalid" { form.columns = "abc" }
                if state == "left" { form.alignment = .left; form.columns = "1"; form.rows = "1" }
                if state == "right" { form.alignment = .right }
                // Host the production sheet itself; never present or order a sheet window.
                content = AnyView(TableInsertSheet(form: form, cancel: {}, insert: { _ in })
                    .background(Color(nsColor: .windowBackgroundColor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity))
            } else { content = AnyView(LibraryWorkspaceView(workspace: workspace)) }
            let controller = NSHostingController(rootView: AnyView(content
                .environment(\.colorScheme, dark ? .dark : .light)))
            controller.sizingOptions = []
            host = controller
            window.contentViewController = controller
            window.setFrame(NSRect(origin: .zero, size: size), display: false)
            controller.view.frame = window.contentView!.bounds
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            // Use the production controller and explicit standard column widths, avoiding owner autosaves.
            if let columns = Self.descendants(controller.view).compactMap({ ($0 as? NSSplitView)?.delegate as? LibrarySplitViewController }).first {
                columns.splitView.autosaveName = nil
                columns.navigationController.splitView.autosaveName = nil
                columns.splitView.setPosition(220 + columns.navigationController.splitView.dividerThickness + 300, ofDividerAt: 0)
                controller.view.layoutSubtreeIfNeeded()
                columns.navigationController.splitView.setPosition(220, ofDividerAt: 0)
                if scenario.resizeSidebar {
                    for width: CGFloat in [180, 320, 200, 260] + (scenario.sidebarWidth.map { [$0] } ?? []) {
                        columns.navigationController.splitView.setPosition(width, ofDividerAt: 0)
                        controller.view.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
            }
            if scenario.sidebarsHidden {
                workspace.setSidebarsHidden(true)
                controller.view.layoutSubtreeIfNeeded()
                try await wait("sidebars collapse") { workspace.librarySplitController?.navigationItem.isCollapsed == true }
            }
            if scenario.rename {
                guard let path = scenario.document ?? scenario.folder else { throw SnapshotFailure.error("Rename scenario needs an item") }
                workspace.beginRename(LibraryRename(path: path, isFolder: scenario.document == nil))
                try await wait("inline rename") { workspace.rename != nil && Self.descendants(controller.view).contains { $0 is RenameNameField } }
            }
            if scenario.quickQuery != nil || scenario.searchQuery != nil {
                try await bounded("search index") { await workspace.search.waitForIndex() }
                try await bounded("search query") { await workspace.search.query(quick: scenario.quickQuery != nil) }
                if let error = workspace.search.error { throw SnapshotFailure.error(error) }
            }
            if scenario.document != nil, scenario.mode != .preview {
                try await wait("editor content") {
                    Self.descendants(controller.view).compactMap { $0 as? PlainMarkdownTextView }.contains { $0.string == workspace.editor.text }
                }
                if scenario.outline {
                    let expected = MarkdownParser.parse(workspace.editor.text).headings
                    try await wait("outline parsing") { workspace.preview.headings == expected }
                }
            }
            if scenario.editImageHeading, let editor = workspace.preview.editor {
                let heading = (editor.string as NSString).range(of: "# Journey")
                guard heading.location != NSNotFound else { throw SnapshotFailure.error("Missing image fixture heading") }
                editor.insertText(" edited", replacementRange: NSRange(location: NSMaxRange(heading), length: 0))
                try await Task.sleep(for: .milliseconds(650))
            }
            if let marker = scenario.caretImage, let editor = workspace.preview.editor {
                let range = (editor.string as NSString).range(of: marker)
                editor.setSelectedRange(NSRange(location: range.location, length: 0))
                workspace.editor.caretLocation = range.location
                try await Task.sleep(for: .milliseconds(400))
            }
            if let text = scenario.caretHeading {
                guard let heading = workspace.preview.headings.first(where: { $0.text == text }),
                      let editor = workspace.preview.editor else { throw SnapshotFailure.error("Missing caret heading") }
                editor.setSelectedRange(NSRange(location: heading.sourceRange.location, length: 0))
                workspace.editor.caretLocation = heading.sourceRange.location
            }
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
            if scenario.focusOutline {
                // Focusing the List selects the current (caret) row, as Tab or a click would.
                let count = workspace.preview.outlineItems.count
                guard let table = Self.descendants(controller.view).compactMap({ $0 as? NSTableView })
                    .first(where: { !($0 is DocumentTableView) && [count, count + 1].contains($0.numberOfRows) }) else {
                    throw SnapshotFailure.error("Missing outline list")
                }
                window.makeFirstResponder(table)
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
            }
            if scenario.outline {
                for split in Self.descendants(controller.view).compactMap({ $0 as? NSSplitView }) {
                    let panes = split.arrangedSubviews
                    if panes.count == 2, panes[0].frame.width > 600, (200...320).contains(panes[1].frame.width) {
                        split.setPosition(split.bounds.width - split.dividerThickness - 240, ofDividerAt: 0)
                    }
                }
                controller.view.layoutSubtreeIfNeeded()
            }
            if scenario.legacyScroller, let scroll = workspace.preview.editor?.enclosingScrollView {
                scroll.scrollerStyle = .legacy
                scroll.autohidesScrollers = false
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
            }
            if scenario.scrollToEnd, let editor = workspace.preview.editor {
                editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
                editor.scrollToEndOfDocument(nil)
                editor.scrollRangeToVisible(editor.selectedRange())
            }
            if scenario.mode != .editor {
                if webKitUnavailable {
                    capture.status = "unavailable in this environment"
                    capture.details.append("WebKit capture is disabled by the environment or unavailable in this unregistered host; PNG contains the real native panes only.")
                } else {
                    try await wait("preview didFinish") {
                        guard let web = workspace.preview.webView,
                              let delegate = web.navigationDelegate as? PreviewView.Coordinator else { return false }
                        return delegate.completedPage != nil || delegate.navigationError != nil || workspace.preview.error != nil
                    }
                    if let error = workspace.preview.error { throw SnapshotFailure.error(error) }
                    if let error = (workspace.preview.webView?.navigationDelegate as? PreviewView.Coordinator)?.navigationError {
                        throw SnapshotFailure.error(error.localizedDescription)
                    }
                    if let state = scenario.previewScrollState, let web = workspace.preview.webView,
                       let delegate = web.navigationDelegate as? PreviewView.Coordinator {
                        try await wait("resting preview") { !delegate.restoring }
                        _ = try await web.callAsyncJavaScript("scrollTo(0, Math.floor((document.documentElement.scrollHeight - innerHeight) / 2) + 17);", arguments: [:], in: nil, contentWorld: .defaultClient)
                        try await Task.sleep(for: .milliseconds(350))
                        if state == "entry" {
                            workspace.preview.mode = .editor
                            try await Task.sleep(for: .milliseconds(350))
                        }
                        workspace.editor.text = workspace.editor.text.replacingOccurrences(of: "Scroll stability", with: "Scroll stability updated")
                        if state == "entry" { workspace.preview.mode = .split }
                        try await wait("preview update at resting position") {
                            workspace.preview.html.contains("Scroll stability updated") && delegate.lastHTML == workspace.preview.html && !delegate.restoring
                        }
                        try await Task.sleep(for: .milliseconds(350))
                    }
                    if let marker = scenario.caretImage, let web = workspace.preview.webView {
                        try await wait("preview image anchors") { (web.navigationDelegate as? PreviewView.Coordinator)?.restoring == false }
                        let location = (workspace.editor.text as NSString).range(of: marker).location
                        guard let item = workspace.preview.outlineItems.first(where: { $0.sourceRange.location == location }) else {
                            throw SnapshotFailure.error("Missing outline image navigation target")
                        }
                        workspace.preview.navigate(item)
                        // Await the actual WebKit scroll; outside-sandbox QA exercises
                        // the same production navigation used by an outline row click.
                        let deadline = Date().addingTimeInterval(3)
                        var visible = false
                        repeat {
                            let result: Any? = try await bounded("preview image navigation") {
                                try await web.callAsyncJavaScript("const image = document.getElementById(anchor); if (!image) return false; const rect = image.getBoundingClientRect(); return rect.top >= -1 && rect.top < innerHeight;",
                                    arguments: ["anchor": item.id], in: nil, contentWorld: .defaultClient)
                            }
                            visible = result as? Bool == true
                            if !visible { try await Task.sleep(for: .milliseconds(50)) }
                        } while !visible && Date() < deadline
                        guard visible else { throw SnapshotFailure.error("Outline click did not reveal preview image") }
                    }
                }
            }
        } catch { record(error, in: &capture) }

        if let host {
            do {
                host.view.layoutSubtreeIfNeeded()
                guard let view = window.contentView?.superview else { throw SnapshotFailure.error("Window frame view is missing") }
                view.layoutSubtreeIfNeeded()
                // Hide ordinary editor carets; preserve the rename field's selected base name.
                for editor in Self.descendants(view).compactMap({ $0 as? PlainMarkdownTextView }) where scenario.visibleCaret == nil {
                    editor.insertionPointColor = .clear
                }
                if (scenario.name == "empty-document" || scenario.createDocument), let editor = workspace.preview.editor { window.makeFirstResponder(editor) }
                window.title = workspace.editor.url == nil ? workspace.folderName : workspace.editor.name
                window.subtitle = workspace.subtitle
                capture.windowTitle = window.title
                guard !window.isVisible, activationIsSafe else { throw SnapshotFailure.error("Offscreen invariant violated") }
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SnapshotFailure.error("Cannot allocate window bitmap") }
                appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
                // AppKit paints no caret in a window that is not key, and an offscreen window
                // never is. Paint the production caret rect (textHeightInsertionRect) in the
                // production insertionPointColor instead; EditorCaretTests cover the
                // drawInsertionPoint path itself.
                if let marker = scenario.visibleCaret, let editor = workspace.preview.editor {
                    let found = (editor.string as NSString).range(of: marker)
                    guard found.location != NSNotFound else { throw SnapshotFailure.error("Missing caret text") }
                    editor.setSelectedRange(NSRange(location: NSMaxRange(found), length: 0))
                    let caret = editor.textHeightInsertionRect(for: editor.lineFragmentCaretRect(at: NSMaxRange(found)))
                    var caretRect = editor.convert(caret, to: view)
                    // Bitmap rows run top-down.
                    if !view.isFlipped { caretRect.origin.y = view.bounds.height - caretRect.maxY }
                    let scale = CGFloat(bitmap.pixelsHigh) / view.bounds.height
                    var color: NSColor?
                    appearance.performAsCurrentDrawingAppearance { color = editor.insertionPointColor.usingColorSpace(.genericRGB) }
                    guard let color else { throw SnapshotFailure.error("Cannot resolve caret color") }
                    // NSBitmapImageRep.setColor ignores this cached-display rep, so write RGBA bytes.
                    guard let pixels = bitmap.bitmapData, bitmap.bitsPerPixel == 32, !bitmap.isPlanar else { throw SnapshotFailure.error("Unexpected bitmap layout") }
                    let channels = [color.redComponent, color.greenComponent, color.blueComponent, 1].map { UInt8(($0 * 255).rounded()) }
                    for y in Int((caretRect.minY * scale).rounded())..<Int((caretRect.maxY * scale).rounded()) {
                        for x in Int((caretRect.minX * scale).rounded())..<Int((caretRect.maxX * scale).rounded()) {
                            for (offset, value) in channels.enumerated() { pixels[y * bitmap.bytesPerRow + x * 4 + offset] = value }
                        }
                    }
                    let sample = (x: Int(caretRect.midX * scale), y: Int(caretRect.midY * scale))
                    if bitmap.colorAt(x: sample.x, y: sample.y) != color {
                        throw SnapshotFailure.error("Editor caret was not drawn at \(caretRect)")
                    }
                }
                // cacheDisplay preserves transparent SwiftUI/material regions; provide the
                // same semantic backdrop as the real window, behind the captured pixels.
                guard let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap) else { throw SnapshotFailure.error("Cannot create bitmap context") }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = bitmapContext
                bitmapContext.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                                                y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
                appearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSRect(origin: .zero, size: view.bounds.size).fill(using: .destinationOver)
                }
                NSGraphicsContext.restoreGraphicsState()
                if scenario.mode != .editor, capture.status == "ok", let web = workspace.preview.webView {
                    do {
                        let content = try await bounded("preview DOM") {
                            try await web.callAsyncJavaScript("while (Array.from(document.images).some(i => !i.complete)) { await new Promise(resolve => setTimeout(resolve, 25)); } return {text: document.body.innerText.trim(), dark: matchMedia('(prefers-color-scheme: dark)').matches, imagesReady: Array.from(document.images).every(i => i.naturalWidth > 0)};",
                                arguments: [:], in: nil, contentWorld: .defaultClient) as? [String: Any]
                        }
                        guard let content, let text = content["text"] as? String, !text.isEmpty else { throw SnapshotFailure.error("Rendered preview is blank") }
                        guard content["dark"] as? Bool == dark else { throw SnapshotFailure.error("WebKit appearance does not match window") }
                        if content["imagesReady"] as? Bool != true { throw SnapshotFailure.error("Preview images are not ready") }
                        let configuration = WKSnapshotConfiguration()
                        configuration.rect = web.bounds
                        configuration.afterScreenUpdates = false
                        let image = try await bounded("WebKit takeSnapshot") { try await web.takeSnapshot(configuration: configuration) }
                        var rect = view.convert(web.bounds, from: web)
                        if view.isFlipped { rect.origin.y = view.bounds.height - rect.maxY }
                        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { throw SnapshotFailure.error("Cannot composite WebKit bitmap") }
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = context
                        context.cgContext.scaleBy(x: CGFloat(bitmap.pixelsWide) / view.bounds.width,
                                                  y: CGFloat(bitmap.pixelsHigh) / view.bounds.height)
                        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: false,
                                   hints: [.interpolation: NSImageInterpolation.high])
                        NSGraphicsContext.restoreGraphicsState()
                    } catch { record(error, in: &capture) }
                }
                let file = scenario.name + "-" + capture.appearance + ".png"
                guard let png = bitmap.representation(using: .png, properties: [:]) else { throw SnapshotFailure.error("Cannot encode PNG") }
                try png.write(to: output.appendingPathComponent(file), options: .atomic)
                capture.file = file
                capture.pixelWidth = bitmap.pixelsWide
                capture.pixelHeight = bitmap.pixelsHigh
                capture.backingScale = Double(window.backingScaleFactor)
            } catch { record(error, in: &capture) }
        }
        // Stop observation/save work before deleting the disposable library.
        window.contentViewController = nil
        host = nil
        workspace.search.reset()
        await workspace.saveSessionNow()
        await workspace.didCloseWindow()
        return capture
    }

    private func record(_ error: Error, in capture: inout SnapshotManifest.Capture) {
        switch error {
        case SnapshotFailure.timeout(let stage): capture.status = "timeout"; capture.details.append("Timed out waiting for \(stage)")
        case SnapshotFailure.error(let message): capture.status = "error: " + message; capture.details.append(message)
        default: capture.status = "error: " + error.localizedDescription; capture.details.append(error.localizedDescription)
        }
    }

    static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

/// Captures the production NSAlert hierarchy without presenting its window.
@MainActor private struct ExportAlertSnapshot: NSViewRepresentable {
    let alert: NSAlert
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        alert.layout()
        if let content = alert.window.contentView {
            content.removeFromSuperview()
            content.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(content)
            NSLayoutConstraint.activate([
                content.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                content.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                content.widthAnchor.constraint(equalToConstant: content.frame.width),
                content.heightAnchor.constraint(equalToConstant: content.frame.height)
            ])
        }
        return container
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

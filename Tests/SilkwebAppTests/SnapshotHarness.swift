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
    var outline = false
    var caretHeading: String? = nil
    var rename = false
    var quickQuery: String? = nil
    var searchQuery: String? = nil
    var tabs: [String] = []
    var scrollToEnd = false
    var legacyScroller = false
    var resizeSidebar = false

    static let pourOver = "Coffee/Brewing Guides/Pour-Over in Five Steps.md"
    static let image = "Snapshot Fixtures/Image Fixture.md"
    static let initial: [SnapshotScenario] = [
        .init(name: "library-overview"),
        .init(name: "sidebar-resized", folder: "Coffee", resizeSidebar: true),
        .init(name: "sidebar-folder-rename", folder: "Coffee", rename: true),
        .init(name: "folder-selected", folder: "Coffee/Brewing Guides"),
        .init(name: "empty-folder", folder: "Snapshot Fixtures/Empty Folder"),
        .init(name: "outline-empty", document: "Snapshot Fixtures/Empty Document.md", outline: true),
        .init(name: "search-empty", searchQuery: "silkweb-no-matches-fixture"),
        .init(name: "editor-document", document: "Snapshot Fixtures/Editor Typography.md"),
        .init(name: "editor-long-scrolled-end", document: "Snapshot Fixtures/Long Document.md", tabs: [pourOver, "Snapshot Fixtures/Long Document.md"], scrollToEnd: true, legacyScroller: true),
        .init(name: "editor-image", document: image),
        .init(name: "preview-headings", document: "Snapshot Fixtures/Preview Headings.md", mode: .preview),
        .init(name: "preview-mode", document: pourOver, mode: .preview),
        .init(name: "split-mode", document: pourOver, mode: .split),
        .init(name: "inspector-outline", document: pourOver, outline: true),
        .init(name: "outline-hierarchy", document: "Snapshot Fixtures/Outline Hierarchy.md", outline: true, caretHeading: "Grind size"),
        .init(name: "rename-active", document: pourOver, rename: true),
        .init(name: "quick-open", quickQuery: "brew"),
        .init(name: "search-results", searchQuery: "coffee"),
        .init(name: "empty-document", document: "Snapshot Fixtures/Empty Document.md"),
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
        let imageText = "# Image Fixture\n\n![Local fixture](fixture.png)\n\n![Remote fixture](https://example.invalid/snapshot.png)\n"
        try Data(imageText.utf8).write(to: fixtures.appendingPathComponent("Image Fixture.md"), options: .atomic)
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
        workspace.session.expandedFolders = ["", "Coffee", "Coffee/Brewing Guides", "Snapshot Fixtures"]
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
        workspace.preview.mode = scenario.mode
        workspace.preview.showsOutline = scenario.outline
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
            let controller = NSHostingController(rootView: AnyView(LibraryWorkspaceView(workspace: workspace)
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
                    for width: CGFloat in [180, 320, 200, 260] {
                        columns.navigationController.splitView.setPosition(width, ofDividerAt: 0)
                        controller.view.layoutSubtreeIfNeeded()
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
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
            if let text = scenario.caretHeading {
                guard let heading = workspace.preview.headings.first(where: { $0.text == text }),
                      let editor = workspace.preview.editor else { throw SnapshotFailure.error("Missing caret heading") }
                editor.setSelectedRange(NSRange(location: heading.sourceRange.location, length: 0))
                workspace.editor.caretLocation = heading.sourceRange.location
            }
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(300))
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
                }
            }
        } catch { record(error, in: &capture) }

        if let host {
            do {
                host.view.layoutSubtreeIfNeeded()
                guard let view = window.contentView?.superview else { throw SnapshotFailure.error("Window frame view is missing") }
                view.layoutSubtreeIfNeeded()
                // Hide ordinary editor carets; preserve the rename field's selected base name.
                for editor in Self.descendants(view).compactMap({ $0 as? PlainMarkdownTextView }) {
                    editor.insertionPointColor = .clear
                }
                if scenario.name == "empty-document", let editor = workspace.preview.editor { window.makeFirstResponder(editor) }
                window.title = workspace.editor.url == nil ? workspace.folderName : workspace.editor.name
                window.subtitle = workspace.subtitle
                capture.windowTitle = window.title
                guard !window.isVisible, activationIsSafe else { throw SnapshotFailure.error("Offscreen invariant violated") }
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw SnapshotFailure.error("Cannot allocate window bitmap") }
                appearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: bitmap) }
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

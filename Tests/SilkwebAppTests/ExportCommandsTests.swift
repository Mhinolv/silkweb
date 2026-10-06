import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

final class ExportCommandsTests: XCTestCase {
    @MainActor func testFlushAvailabilityAndRealContextMenu() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Note.md")
        try Data("Old".utf8).write(to: file)
        let workspace = LibraryWorkspace(defaults: disposableDefaults("ExportCommands"))
        XCTAssertFalse(workspace.canExport)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedDocuments = ["Note.md"]
        await workspace.editor.configure(root: root, recoveryDirectory: root.appendingPathComponent("recovery"))
        _ = await workspace.editor.open(file, readOnly: false)
        workspace.editor.edit("# Latest & <text>")
        let result = try await workspace.prepareHTMLExport()
        XCTAssertTrue(try XCTUnwrap(result).html.contains("Latest &amp;"))
        XCTAssertTrue(try XCTUnwrap(result).html.contains("&lt;text&gt;"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# Latest & <text>")
        XCTAssertTrue(workspace.canExport)
        let host = NSHostingView(
            rootView: DocumentTable(workspace: workspace, documents: workspace.documents, dateReference: Date()))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        for mode in DocumentViewMode.allCases {
            // The document table hosts only native rows; mode switches exercise command availability.
            workspace.preview.mode = mode
            for width: CGFloat in [900, 1400, 1000] {
                host.setFrameSize(NSSize(width: width, height: 900)); host.layoutSubtreeIfNeeded()
                let table = try XCTUnwrap(descendants(host).compactMap { $0 as? DocumentTableView }.first)
                let menu = try XCTUnwrap(table.coordinator?.menu(path: "Note.md"))
                let html = try XCTUnwrap(menu.items.first { $0.title == "Export" }?.submenu?.items.first)
                XCTAssertEqual(html.title, "HTML…")
                XCTAssertTrue(html.isEnabled)
                workspace.session.selectedDocuments = ["Note.md", "Other.md"]
                XCTAssertFalse(workspace.canExport)
                XCTAssertFalse(
                    table.coordinator!.menu(path: "Note.md").items.first { $0.title == "Export" }!.submenu!.items[0]
                        .isEnabled)
                workspace.session.selectedDocuments = ["Note.md"]
            }
        }
        workspace.editor.recovered = true
        do { _ = try await workspace.prepareHTMLExport(); XCTFail("Recovery must be resolved before export") } catch {
            XCTAssertTrue(error.localizedDescription.contains("saved"))
        }
        await workspace.didCloseWindow()
    }

    /// #101: HTML export, PDF export and Print (`printOutput`) follow the Preview line-break and
    /// [TOC] settings; only the stylesheet differs between them.
    @MainActor func testExportAndPrintFollowPreviewRenderingSettings() async throws {
        _ = NSApplication.shared
        let live = LivePreferences.shared.current
        defer { LivePreferences.shared.current = live }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Poem.md")
        try Data("Old".utf8).write(to: file)
        let workspace = LibraryWorkspace(defaults: disposableDefaults("ExportCommands"))
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedDocuments = ["Poem.md"]
        await workspace.editor.configure(root: root, recoveryDirectory: root.appendingPathComponent("recovery"))
        _ = await workspace.editor.open(file, readOnly: false)
        workspace.editor.edit("[TOC]\n\n# One\nfirst\nsecond\nhard\\\nbreak\n\n```\n[TOC]\n```\n")
        for keepsLineBreaks in [false, true] {
            for showsTableOfContents in [false, true] {
                LivePreferences.shared.current.keepsLineBreaks = keepsLineBreaks
                LivePreferences.shared.current.showsTableOfContents = showsTableOfContents
                for printOutput in [false, true] {
                    let label = "lineBreaks \(keepsLineBreaks), TOC \(showsTableOfContents), print \(printOutput)"
                    let prepared = try await workspace.prepareHTMLExport(printOutput: printOutput)
                    let html = try XCTUnwrap(prepared).html
                    let body = try XCTUnwrap(html.components(separatedBy: "<body>").last)
                    XCTAssertEqual(body.contains("first<br>"), keepsLineBreaks, label)
                    XCTAssertEqual(body.contains("first\nsecond"), !keepsLineBreaks, label)
                    XCTAssertTrue(body.contains("hard<br>"), "Backslash breaks are kept either way: \(label)")
                    XCTAssertEqual(body.contains("<nav class=\"sw-toc\""), showsTableOfContents, label)
                    XCTAssertEqual(body.contains("<p>[TOC]</p>"), !showsTableOfContents, label)
                    XCTAssertTrue(body.contains("<code>[TOC]"), "[TOC] in a code block stays code: \(label)")
                    XCTAssertEqual(html.contains("@page { margin: 0; }"), printOutput, label)
                    XCTAssertEqual(html.contains("prefers-color-scheme: dark"), !printOutput, label)
                }
            }
        }
        await workspace.didCloseWindow()
    }

    @MainActor func testNativeAlertAndStylesheet() {
        let root = URL(fileURLWithPath: "/nonexistent-export-fixture")
        let result = HTMLExport.prepare(
            markdown: (1...8).map { "![alt](missing-\($0).png)" }.joined(separator: "\n\n"), title: "Note",
            documentURL: root.appendingPathComponent("Note.md"), libraryRoot: root,
            stylesheet: PreviewCoordinator.stylesheet)
        let alert = ExportCommands.missingImageAlert(result)
        alert.layout()
        XCTAssertEqual(alert.messageText, "8 images couldn’t be found.")
        XCTAssertTrue(alert.informativeText.contains("and 3 more"))
        XCTAssertEqual(alert.buttons.map(\.title), ["Export Anyway", "Cancel"])
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        XCTAssertNotNil(alert.window.contentView)
        XCTAssertFalse(result.html.contains("-apple-system-label"))
        XCTAssertTrue(result.html.contains("BlinkMacSystemFont"))
        XCTAssertTrue(result.html.contains("Menlo, Consolas"))
    }
}

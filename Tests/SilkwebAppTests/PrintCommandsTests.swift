import AppKit
import WebKit
import XCTest
import SilkwebCore
@testable import Silkweb

final class PrintCommandsTests: XCTestCase {
    /// Compiles the production rules without loading a page or starting a print job.
    /// Unlike the PDF smoke test, this regression must also run in the sandbox.
    @MainActor func testOfflinePrintRulesCompile() async throws {
        let identifier = "Silkweb.OfflinePrint.Test.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WKContentRuleListStore(url: root)!
        let rules = try await store.compileContentRuleList(
            forIdentifier: identifier, encodedContentRuleList: PrintCoordinator.offlineRules)
        XCTAssertNotNil(rules)
        try await store.removeContentRuleList(forIdentifier: identifier)
    }

    @MainActor func testAvailabilityAndPrintPreflight() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let workspace = LibraryWorkspace(defaults: defaults)
        XCTAssertFalse(workspace.canPrint)
        let file = root.appendingPathComponent("Print.md")
        try Data("Old".utf8).write(to: file)
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        workspace.session.selectedDocuments = ["Print.md"]
        XCTAssertFalse(workspace.canPrint, "A list selection alone is not an open document")
        await workspace.editor.configure(root: root, recoveryDirectory: root.appendingPathComponent("recovery"))
        _ = await workspace.editor.open(file, readOnly: false)
        workspace.editor.edit("# Current\n\n- [x] Saved\n\n![Missing](absent.png)")
        for mode in DocumentViewMode.allCases {
            workspace.preview.mode = mode
            XCTAssertTrue(workspace.canPrint)
            workspace.session.selectedDocuments = ["Print.md", "Other.md"]
            XCTAssertFalse(workspace.canPrint)
            workspace.session.selectedDocuments = ["Print.md"]
        }
        workspace.exporting = true
        XCTAssertFalse(workspace.canPrint)
        workspace.exporting = false
        let prepared = try await workspace.prepareHTMLExport(printOutput: true)
        let result = try XCTUnwrap(prepared)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), workspace.editor.text)
        XCTAssertTrue(result.html.contains("☑ Saved"))
        XCTAssertTrue(result.html.contains("@page { margin: 18mm 16mm; }"))
        XCTAssertFalse(result.html.contains("prefers-color-scheme: dark"))
        let alert = ExportCommands.missingImageAlert(result, printing: true)
        alert.layout()
        XCTAssertNotNil(alert.window.contentView)
        XCTAssertEqual(alert.buttons.map(\.title), ["Print Anyway", "Cancel"])
        XCTAssertTrue(alert.informativeText.contains("printed document"))
        XCTAssertEqual(alert.buttons[1].keyEquivalent, "\u{1b}")
        await workspace.didCloseWindow()
    }

    @MainActor func testPrintInfoAndStylesheet() {
        let info = PrintCoordinator.defaultPrintInfo()
        XCTAssertEqual(info.topMargin, 18 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(info.leftMargin, 16 * 72 / 25.4, accuracy: 0.01)
        XCTAssertEqual(info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] as? Bool, true)
        for rule in ["white-space: pre-wrap", "word-break: break-word", "break-after: avoid", "table-layout: fixed", "table-header-group", "pre.sw-short-code", "color-scheme: light"] {
            XCTAssertTrue(PrintCoordinator.stylesheet.contains(rule), rule)
        }
    }

    @MainActor func testNativePDFSavePanel() throws {
        _ = NSApplication.shared
        guard !SnapshotHarness.isWebKitUnavailable(environment: ProcessInfo.processInfo.environment, activationPolicy: NSApp.activationPolicy().rawValue) else {
            throw XCTSkip("The native save panel requires an outside-sandbox connection to its XPC service")
        }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        defaults.set("/tmp/print-folder", forKey: ExportCommands.directoryKey)
        let panel = ExportCommands.savePanel(name: "Title", defaults: defaults, pdf: true)
        XCTAssertEqual(panel.allowedContentTypes, [.pdf])
        XCTAssertEqual(panel.nameFieldStringValue, "Title.pdf")
        XCTAssertEqual(panel.prompt, "Export")
        XCTAssertEqual(panel.directoryURL?.path, "/tmp/print-folder")
    }

    @MainActor func testPrintJobDeadlineAndLateCompletion() async throws {
        let job = PrintJob()
        var cancelled = false
        let start = Date()
        do {
            _ = try await job.wait(timeoutInterval: 0.02, cancel: { cancelled = true }, start: {})
            XCTFail("A print job that never completes must time out")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertTrue(cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        job.finish(.success(true)) // A delayed AppKit callback must not resume twice.
    }

    @MainActor func testPrintJobSuccessAndCancellationCancelDeadline() async throws {
        for success in [false, true] {
            let job = PrintJob()
            var cancelled = false
            let result = try await job.wait(timeoutInterval: 0.01, cancel: { cancelled = true }) {
                job.finish(.success(success))
            }
            XCTAssertEqual(result, success)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertFalse(cancelled)
        }
    }

    /// Runs only in the registered offscreen QA host: WebKit cannot render in the agent sandbox.
    @MainActor func testRealWebHierarchyAndMultipagePDF() async throws {
        _ = NSApplication.shared
        guard !SnapshotHarness.isWebKitUnavailable(environment: ProcessInfo.processInfo.environment, activationPolicy: NSApp.activationPolicy().rawValue) else {
            throw XCTSkip("WebKit PDF pagination requires the outside-sandbox QA host")
        }
        // An async expectation alone cannot fail a regression that blocks the main
        // run loop. A worker deadline terminates this test host rather than leaving
        // QA with another indefinitely spinning xctest process.
        let watchdog = DispatchWorkItem {
            fatalError("Offscreen PDF smoke exceeded its 90-second process deadline")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90, execute: watchdog)
        defer { watchdog.cancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jZJkAAAAASUVORK5CYII=")!
        try data.write(to: root.appendingPathComponent("image.png"))
        let renderer = PrintCoordinator()
        defer { renderer.hostWindow.close() }
        let host = try XCTUnwrap(renderer.hostWindow.contentView)
        XCTAssertTrue(renderer.web.window === renderer.hostWindow)
        XCTAssertFalse(renderer.hostWindow.isVisible)
        for (index, markdown) in ["", "# Small\n\nBody", "# Long\n\n" + String(repeating: "Paragraph text.\n\n", count: 300) + "| Wide | Table |\n| --- | --- |\n| \(String(repeating: "wide", count: 200)) | text |\n\n```\n\(String(repeating: "code\n", count: 50))```\n\n![Image](image.png)"].enumerated() {
            let result = HTMLExport.prepare(markdown: markdown, title: "Smoke", documentURL: root.appendingPathComponent("note.md"), libraryRoot: root, stylesheet: PrintCoordinator.stylesheet, printOutput: true)
            try await renderer.load(html: result.html)
            for width: CGFloat in [320, 720, 1400] {
                host.setFrameSize(NSSize(width: width, height: 900))
                renderer.web.setFrameSize(host.frame.size)
                host.layoutSubtreeIfNeeded()
            }
            let destination = root.appendingPathComponent("smoke-\(index).pdf")
            let operation = renderer.operation(info: PrintCoordinator.defaultPrintInfo(), title: "Smoke", destination: destination)
            XCTAssertFalse(operation.showsPrintPanel)
            XCTAssertEqual(operation.jobTitle, "Smoke")
            XCTAssertFalse(operation.canSpawnSeparateThread, "WebKit pagination must stay on its main thread")
            let succeeded = try await renderer.run(operation, timeoutInterval: 15, showsProgressPanel: false)
            XCTAssertTrue(succeeded)
            let pdf = try Data(contentsOf: destination)
            XCTAssertTrue(pdf.starts(with: Data("%PDF-".utf8)))
            let document = try XCTUnwrap(CGPDFDocument(destination as CFURL))
            XCTAssertGreaterThanOrEqual(document.numberOfPages, index == 2 ? 2 : 1)
        }
    }
}

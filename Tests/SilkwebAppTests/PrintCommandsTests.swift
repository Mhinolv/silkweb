import AppKit
import WebKit
import PDFKit
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
        XCTAssertTrue(result.html.contains("@page { margin: 0; }"))
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

    @MainActor func testPDFExportDeadlineAndLateCompletion() async throws {
        let job = PDFExportJob()
        var cancelled = false
        let start = Date()
        do {
            _ = try await job.wait(timeoutInterval: 0.02, cancel: { cancelled = true }) {
                // Simulates a delayed WebKit callback even after cancellation.
                try? await Task.sleep(for: .milliseconds(100))
                return Data("late".utf8)
            }
            XCTFail("An export that never completes must time out")
        } catch {
            XCTAssertEqual(error as? PDFExportError, .timedOut)
            XCTAssertTrue(error.localizedDescription.contains("took too long"))
        }
        XCTAssertTrue(cancelled)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        try await Task.sleep(for: .milliseconds(30))
        let data = try await PDFExportJob().wait(timeoutInterval: 1, cancel: { XCTFail("Completed export cancelled") }) {
            Data("done".utf8)
        }
        XCTAssertEqual(data, Data("done".utf8))
    }

    func testPDFPageAssembly() throws {
        for count in [1, 2, 50] {
            let source = NSMutableData()
            var strip = CGRect(x: 0, y: 0, width: 200 * count, height: 300)
            let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: source)!, mediaBox: &strip, nil))
            context.beginPDFPage(nil)
            for index in 0..<count {
                context.setFillColor(gray: CGFloat(index + 1) / CGFloat(count + 1), alpha: 1)
                context.fill(CGRect(x: 200 * index, y: 0, width: 200, height: 300))
            }
            context.endPDFPage()
            context.closePDF()
            let data = try PrintCoordinator.paginate(source as Data, count: count,
                paper: CGSize(width: 240, height: 360), content: CGSize(width: 200, height: 300),
                left: 20, bottom: 30, title: "Assembly")
            let pdf = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(pdf.pageCount, count)
            XCTAssertEqual(pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Assembly")
            for index in 0..<count {
                let page = try XCTUnwrap(pdf.page(at: index))
                XCTAssertEqual(page.bounds(for: .mediaBox), CGRect(x: 0, y: 0, width: 240, height: 360))
                // Different columns must reach different output pages, with white
                // margins. A duplicated first slice or double margin fails here.
                let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: 240 * 360)
                defer { pixels.deallocate() }
                let bitmap = try XCTUnwrap(CGContext(data: pixels, width: 240, height: 360,
                    bitsPerComponent: 8, bytesPerRow: 240, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue))
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: 240, height: 360))
                page.draw(with: .mediaBox, to: bitmap)
                let expected = Double(index + 1) / Double(count + 1) * 255
                XCTAssertEqual(Double(pixels[180 * 240 + 120]), expected, accuracy: 2)
                XCTAssertEqual(pixels[5 * 240 + 5], 255)
                XCTAssertNotEqual(pixels[31 * 240 + 21], 255)
            }
        }
        XCTAssertThrowsError(try PrintCoordinator.paginate(Data(), count: 1,
            paper: CGSize(width: 240, height: 360), content: CGSize(width: 200, height: 300),
            left: 20, bottom: 30, title: "Invalid"))
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
            fatalError("Offscreen PDF smoke exceeded its 20-second process deadline")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer { watchdog.cancel() }
        let start = Date()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 128, bitsPerPixel: 32)!
        for offset in stride(from: 0, to: 32 * 128, by: 4) {
            image.bitmapData![offset] = 255
            image.bitmapData![offset + 1] = 0
            image.bitmapData![offset + 2] = 0
            image.bitmapData![offset + 3] = 255
        }
        try XCTUnwrap(image.representation(using: .png, properties: [:]))
            .write(to: root.appendingPathComponent("image.png"))
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
            let pdf = try await renderer.exportPDF(html: result.html,
                                                   info: PrintCoordinator.defaultPrintInfo(),
                                                   title: "Smoke", timeoutInterval: 5)
            XCTAssertTrue(pdf.starts(with: Data("%PDF-".utf8)))
            let document = try XCTUnwrap(PDFDocument(data: pdf))
            if index == 2 { XCTAssertGreaterThan(document.pageCount, 1) }
            else { XCTAssertEqual(document.pageCount, 1) }
            XCTAssertEqual(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, "Smoke")
            XCTAssertFalse(renderer.hostWindow.isVisible)
            let bounds = try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox)
            let paper = PrintCoordinator.defaultPrintInfo().paperSize
            XCTAssertEqual(bounds.width, paper.width, accuracy: 0.01)
            XCTAssertEqual(bounds.height, paper.height, accuracy: 0.01)
            if index == 2 {
                let text = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined()
                XCTAssertTrue(text.contains("Table"))
                XCTAssertTrue(text.contains("code"))
                let imageState = try await renderer.javascript(
                    "return document.images.length === 1 && document.images[0].complete && document.images[0].naturalWidth > 0;")
                XCTAssertEqual(imageState as? Bool, true)
                // The only red pixels in this fixture come from its local image;
                // checking the actual last PDF page proves it survived capture.
                let pixelWidth = Int(paper.width.rounded(.up))
                let pixelHeight = Int(paper.height.rounded(.up))
                let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelWidth * pixelHeight * 4)
                defer { pixels.deallocate() }
                let bitmap = try XCTUnwrap(CGContext(data: pixels, width: pixelWidth, height: pixelHeight,
                    bitsPerComponent: 8, bytesPerRow: pixelWidth * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
                bitmap.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
                try XCTUnwrap(document.page(at: document.pageCount - 1)).draw(with: .mediaBox, to: bitmap)
                XCTAssertTrue(stride(from: 0, to: pixelWidth * pixelHeight * 4, by: 4).contains {
                    pixels[$0] > 220 && pixels[$0 + 1] < 50 && pixels[$0 + 2] < 50
                }, "The exported local image must appear in the PDF")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }
}

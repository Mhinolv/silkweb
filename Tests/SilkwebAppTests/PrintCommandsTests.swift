import AppKit
import WebKit
import PDFKit
import SwiftUI
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
        let defaults = disposableDefaults("PrintCommands")
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
        let defaults = disposableDefaults("PrintCommands")
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

    /// The render ignores cancellation and returns only when the test releases it, like a WebKit
    /// callback arriving after the deadline: only the deadline can end the wait, and the late
    /// result neither resumes the job a second time nor stops the renderer again.
    @MainActor func testPDFExportDeadlineAndLateCompletion() async throws {
        let job = PDFExportJob()
        var cancels = 0
        var release: CheckedContinuation<Void, Never>?
        var returned = false
        do {
            _ = try await job.wait(timeoutInterval: 0.02, cancel: { cancels += 1 }) { @MainActor in
                await withCheckedContinuation { release = $0 }
                returned = true
                return Data("late".utf8)
            }
            XCTFail("An export that never completes must time out")
        } catch {
            XCTAssertEqual(error as? PDFExportError, .timedOut)
            XCTAssertTrue(error.localizedDescription.contains("took too long"))
        }
        XCTAssertEqual(cancels, 1)
        while release == nil { await Task.yield() }
        release?.resume()
        // The render's job finishes on the main actor in the same turn it returns.
        while !returned { await Task.yield() }
        await Task.yield()
        XCTAssertEqual(cancels, 1)
        let data = try await PDFExportJob().wait(timeoutInterval: 60, cancel: { XCTFail("Completed export cancelled") }) {
            Data("done".utf8)
        }
        XCTAssertEqual(data, Data("done".utf8))
    }

    /// #61 (CI flake): on a busy runner the render can return after the deadline but before the
    /// deadline task gets the main actor. The deadline is final, so that late render must still
    /// time out. Blocking the main actor past a 20 ms deadline reproduces the ordering exactly.
    @MainActor func testPDFExportRenderReturningAfterDeadlineTimesOut() async throws {
        var cancels = 0
        do {
            let data = try await PDFExportJob().wait(timeoutInterval: 0.02, cancel: { cancels += 1 }) { @MainActor in
                let busy = ContinuousClock.now + .milliseconds(100)
                while ContinuousClock.now < busy {}
                return Data("late".utf8)
            }
            XCTFail("A render that returned after the deadline was published: \(String(decoding: data, as: UTF8.self))")
        } catch {
            XCTAssertEqual(error as? PDFExportError, .timedOut, "\(error)")
        }
        XCTAssertEqual(cancels, 1)
    }

    /// #61: Cancel can arrive in the same turn the render returns (its stop is queued behind the
    /// render's result). The user asked to stop, so no data is returned and nothing is written.
    @MainActor func testPDFExportCancelRacingCompletionDiscardsData() async throws {
        final class Box { var task: Task<Data, Error>? }
        let box = Box()
        var cancels = 0
        box.task = Task { @MainActor in
            try await PDFExportJob().wait(timeoutInterval: 60, cancel: { cancels += 1 }) { @MainActor in
                box.task?.cancel()
                return Data("late".utf8)
            }
        }
        do {
            let data = try await XCTUnwrap(box.task).value
            XCTFail("A cancelled export returned data: \(String(decoding: data, as: UTF8.self))")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        await Task.yield()
        XCTAssertEqual(cancels, 1)
    }

    /// The progress sheet's Cancel cancels the awaiting task: rendering stops at once with
    /// CancellationError (no alert, nothing written) and a late render cannot complete it.
    /// The render returns only when released, so the outcome cannot depend on timing.
    @MainActor func testPDFExportCancellationAndProgressSheet() async throws {
        var stopped = false
        var started = false
        var release: CheckedContinuation<Void, Never>?
        let render = Task { @MainActor in
            try await PDFExportJob().wait(timeoutInterval: 60, cancel: { stopped = true }) { @MainActor in
                started = true
                await withCheckedContinuation { release = $0 }
                return Data("late".utf8)
            }
        }
        while !started { await Task.yield() }
        render.cancel()
        do {
            _ = try await render.value
            XCTFail("A cancelled export must not produce data")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(stopped)
        release?.resume()
        XCTAssertEqual(PDFExportError.timedOut.localizedDescription,
                       "The document took too long to render. Try again, or export a shorter document.")

        var cancelled = false
        let host = NSHostingView(rootView: PDFProgressSheet(progress: PDFProgress(message: "Exporting “Plan” as PDF…") { cancelled = true }))
        for width: CGFloat in [200, 380, 800] {
            host.setFrameSize(NSSize(width: width, height: 120))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(host.fittingSize.width, 380, accuracy: 1)
        PDFProgressSheet(progress: PDFProgress(message: "") { cancelled = true }).progress.cancel()
        XCTAssertTrue(cancelled)
    }

    func testPDFPageAssembly() throws {
        for count in [1, 2, 50] {
            // One WebKit capture per page, in CSS pixels (4/3 of the physical content size).
            let captures = try (0..<count).map { index -> Data in
                let source = NSMutableData()
                var page = CGRect(x: 0, y: 0, width: 200 * 4 / 3, height: 400)
                let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: source)!, mediaBox: &page, nil))
                context.beginPDFPage(nil)
                context.setFillColor(gray: CGFloat(index + 1) / CGFloat(count + 1), alpha: 1)
                context.fill(page)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Slice \(index + 1)",
                    attributes: [.font: NSFont.systemFont(ofSize: 12)]))
                context.textPosition = CGPoint(x: 10, y: 10)
                CTLineDraw(line, context)
                context.endPDFPage()
                context.closePDF()
                return source as Data
            }
            let data = try PrintCoordinator.assemble(captures, paper: CGSize(width: 240, height: 360),
                content: CGRect(x: 20, y: 30, width: 200, height: 300), title: "Assembly")
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
                // Each page's text layer holds only its own capture.
                XCTAssertEqual(page.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Slice \(index + 1)")
            }
        }
        XCTAssertThrowsError(try PrintCoordinator.assemble([Data()], paper: CGSize(width: 240, height: 360),
            content: CGRect(x: 20, y: 30, width: 200, height: 300), title: "Invalid"))
        XCTAssertThrowsError(try PrintCoordinator.assemble([], paper: CGSize(width: 240, height: 360),
            content: CGRect(x: 20, y: 30, width: 200, height: 300), title: "Empty"))
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

    /// Owner regression (Vanlife/Settling In.md): two large camera JPEGs, page slicing and ⌘P.
    /// Every paragraph starts with a unique token (w0001…), so a leaked neighbour slice shows up
    /// as a token on two pages or as a truncated token. The images are dark noisy blue and green
    /// so painted pixels, and slivers of a neighbouring page at the content edge, are detectable.
    @MainActor func testRealWebLargeImagesSliceCleanTextAndPrintToPDF() async throws {
        _ = NSApplication.shared
        guard !SnapshotHarness.isWebKitUnavailable(environment: ProcessInfo.processInfo.environment, activationPolicy: NSApp.activationPolicy().rawValue) else {
            throw XCTSkip("WebKit PDF pagination requires the outside-sandbox QA host")
        }
        // A hung native print loop cannot fail through XCTest; terminate the host instead.
        let watchdog = DispatchWorkItem {
            fatalError("Large-image PDF/print smoke exceeded its 45-second process deadline")
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 45, execute: watchdog)
        defer { watchdog.cancel() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let id = UUID().uuidString
        let media = root.appendingPathComponent("media/\(id)")
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Vanlife"), withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        // Camera-sized like the owner's photos; the first sits at the top of page 1, as in the report.
        try Self.noisyJPEG(width: 4032, height: 3024, base: (10, 20, 120)).write(to: media.appendingPathComponent("IMG_4050.JPG"))
        try Self.noisyJPEG(width: 4032, height: 3024, base: (10, 110, 20)).write(to: media.appendingPathComponent("IMG_4027.JPG"))
        let tokens = (1...120).map { String(format: "w%04d", $0) }
        var markdown = "# Settling In\n ##### Jamestown Campground\n![First](../media/\(id)/IMG_4050.JPG)\n\n"
        for (index, token) in tokens.enumerated() {
            markdown += token + String(repeating: " settling into the van one day at a time then moving on", count: 2) + ".\n\n"
            if index == 9 { markdown += "### Building A Home\n###### Lake Erie\n![Second](../media/\(id)/IMG_4027.JPG)\n\n" }
        }
        let result = HTMLExport.prepare(markdown: markdown, title: "Settling In",
            documentURL: root.appendingPathComponent("Vanlife/Settling In.md"), libraryRoot: root,
            stylesheet: PrintCoordinator.stylesheet, printOutput: true)
        XCTAssertTrue(result.missingAssets.isEmpty)
        let renderer = PrintCoordinator()
        defer { renderer.hostWindow.close() }
        let info = PrintCoordinator.defaultPrintInfo()
        let paper = info.paperSize
        let pdf = try await renderer.exportPDF(html: result.html, info: info, title: "Settling In", timeoutInterval: 15)
        let document = try XCTUnwrap(PDFDocument(data: pdf))
        XCTAssertGreaterThan(document.pageCount, 2)

        // 1. Text layer: every token on exactly one page, pages in reading order, no fragments.
        var owner: [String: Int] = [:]
        for index in 0..<document.pageCount {
            let text = try XCTUnwrap(document.page(at: index)?.string)
            let found = Self.matches(#"w\d{4}"#, in: text)
            for token in found {
                XCTAssertNil(owner[token], "\(token) leaked onto page \(index + 1) from page \((owner[token] ?? 0) + 1)")
                owner[token] = owner[token] ?? index
            }
            XCTAssertEqual(Self.matches(#"w\d{1,3}(?!\d)"#, in: text), [], "Truncated token fragments on page \(index + 1)")
            if index > 0, let first = found.first, let previous = owner.filter({ $0.value == index - 1 }).keys.max() {
                XCTAssertLessThan(previous, first, "Page \(index + 1) is out of reading order")
            }
        }
        XCTAssertEqual(Set(owner.keys), Set(tokens), "Every paragraph must appear in the PDF text")

        // 2. Both images painted; 3. no 1-px dark columns at, or anything in, the margins.
        var blue = 0, green = 0
        for index in 0..<document.pageCount {
            let page = try XCTUnwrap(document.page(at: index))
            let raster = try Self.rasterize(page, paper: paper, scale: 2)
            for offset in stride(from: 0, to: raster.pixels.count, by: 4) {
                let (r, g, b) = (Int(raster.pixels[offset]), Int(raster.pixels[offset + 1]), Int(raster.pixels[offset + 2]))
                if b > 80, b > r + 50, b > g + 40 { blue += 1 }
                if g > 70, g > r + 40, g > b + 40 { green += 1 }
            }
            let content = CGRect(x: info.leftMargin * 2, y: info.topMargin * 2,
                                 width: (paper.width - info.leftMargin - info.rightMargin) * 2,
                                 height: (paper.height - info.topMargin - info.bottomMargin) * 2)
            XCTAssertEqual(Self.inkOutside(content.insetBy(dx: -2, dy: -2), raster), 0, "Ink in the margins of page \(index + 1)")
            let run = Self.longestEdgeLine(content, raster)
            XCTAssertLessThan(run, 40, "A thin dark line \(run) px tall at a content edge of page \(index + 1)")
        }
        // Each image covers ~600,000 px at this scale; a blank reserved box covers none.
        XCTAssertGreaterThan(blue, 100_000, "First large JPEG must be painted in the exported PDF")
        XCTAssertGreaterThan(green, 100_000, "Second large JPEG must be painted in the exported PDF")
        // Edge slivers come from neighbouring content hidden behind a page clip: CoreGraphics
        // antialiases it away, but other renderers (Preview zoom, printers) show 1-px lines.
        // Independent of any rasterizer: only the pages showing the two photos may contain images.
        let pagesWithImages = (0..<document.pageCount).filter {
            Self.imageCount(document.page(at: $0)?.pageRef?.dictionary) > 0
        }
        XCTAssertLessThanOrEqual(pagesWithImages.count, 2, "Pages \(pagesWithImages.map { $0 + 1 }) embed image content; hidden off-page content shows as edge lines")

        // 4. ⌘P path: the print operation saved to a PDF (no panels) holds the same pages.
        let output = root.appendingPathComponent("Printed.pdf")
        let operation = try renderer.operation(info: info, title: "Settling In")
        let saving = operation.printInfo
        saving.jobDisposition = .save
        saving.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        operation.printInfo = saving
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let printed = try await PrintJob.run(operation, window: renderer.hostWindow, timeoutInterval: 15) {}
        XCTAssertTrue(printed)
        let printedDocument = try XCTUnwrap(PDFDocument(url: output), "Print to PDF wrote no document")
        XCTAssertEqual(printedDocument.pageCount, document.pageCount)
        let printedText = (0..<printedDocument.pageCount).compactMap { printedDocument.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertEqual(Set(Self.matches(#"w\d{4}"#, in: printedText)), Set(tokens), "Printed PDF is missing document text")
        var printedImage = 0
        for index in 0..<printedDocument.pageCount {
            let raster = try Self.rasterize(try XCTUnwrap(printedDocument.page(at: index)), paper: paper, scale: 1)
            printedImage += stride(from: 0, to: raster.pixels.count, by: 4).filter {
                Int(raster.pixels[$0 + 2]) > Int(raster.pixels[$0]) + 50
            }.count
        }
        XCTAssertGreaterThan(printedImage, 20_000, "Printed PDF must contain the images")
        // Same pages in the same place: printed content matches the export pixel for pixel
        // inside the content area (header and footer live in the margins).
        for index in 0..<min(document.pageCount, printedDocument.pageCount) {
            let exported = try Self.rasterize(try XCTUnwrap(document.page(at: index)), paper: paper, scale: 1)
            let printedPage = try Self.rasterize(try XCTUnwrap(printedDocument.page(at: index)), paper: paper, scale: 1)
            var different = 0, total = 0
            for y in Int(info.topMargin)..<Int(paper.height - info.bottomMargin) {
                for x in Int(info.leftMargin)..<Int(paper.width - info.rightMargin) {
                    let offset = (y * exported.width + x) * 4
                    total += 1
                    if (0..<3).contains(where: { abs(Int(exported.pixels[offset + $0]) - Int(printedPage.pixels[offset + $0])) > 40 }) { different += 1 }
                }
            }
            XCTAssertLessThan(Double(different) / Double(total), 0.01, "Printed page \(index + 1) differs from the export")
        }
    }

    /// Prints pre-rendered pages through the real NSPrintOperation machinery (no WebKit, so
    /// this also runs in the agent sandbox): page count, text, margins and paper are 1:1.
    @MainActor func testPrintedPagesOperationSavesEveryPage() async throws {
        _ = NSApplication.shared
        let source = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = try XCTUnwrap(CGContext(consumer: CGDataConsumer(data: source)!, mediaBox: &box, nil))
        for index in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: 220, height: 100))
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Printed page \(index + 1)",
                attributes: [.font: NSFont.systemFont(ofSize: 14)]))
            context.textPosition = CGPoint(x: 40, y: 300)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        let info = NSPrintInfo()
        info.paperSize = box.size
        info.topMargin = 30
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = true
        let operation = try PrintCoordinator.printOperation(pages: source as Data, info: info, title: "Pages")
        XCTAssertFalse(operation.printPanel.options.contains(.showsPaperSize), "Pagination is fixed by Page Setup")
        XCTAssertTrue(operation.printPanel.options.contains(.showsPreview))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("Pages.pdf")
        let saving = operation.printInfo
        saving.jobDisposition = .save
        saving.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = output
        operation.printInfo = saving
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let completed = try await PrintJob.run(operation, window: window, timeoutInterval: 10) {}
        XCTAssertTrue(completed)
        let printed = try XCTUnwrap(PDFDocument(url: output))
        XCTAssertEqual(printed.pageCount, 3)
        for index in 0..<3 {
            let page = try XCTUnwrap(printed.page(at: index))
            XCTAssertEqual(page.bounds(for: .mediaBox).size, box.size)
            let text = page.string ?? ""
            XCTAssertTrue(text.contains("Printed page \(index + 1)"), text)
            XCTAssertTrue(text.contains("Pages"), "Header shows the title: \(text)")
            XCTAssertTrue(text.contains("\(index + 1) of 3"), "Footer shows the page number: \(text)")
            // The blue block keeps its position: printed pages carry no second margin.
            let raster = try Self.rasterize(page, paper: box.size, scale: 1)
            // Block spans x 40…260, y 40…140 (PDF space); sample just inside and outside its corner.
            func pixel(_ x: Int, _ y: Int) -> (UInt8, UInt8) {
                let offset = ((400 - y) * 300 + x) * 4
                return (raster.pixels[offset], raster.pixels[offset + 2])
            }
            for (x, y) in [(150, 90), (43, 43), (257, 137)] {
                XCTAssertLessThan(pixel(x, y).0, 60, "(\(x), \(y)) on page \(index + 1)")
                XCTAssertGreaterThan(pixel(x, y).1, 180, "(\(x), \(y)) on page \(index + 1)")
            }
            for (x, y) in [(36, 90), (264, 90), (150, 144), (150, 36)] {
                XCTAssertEqual(pixel(x, y).0, 255, "Printed page shifted: (\(x), \(y)) on page \(index + 1)")
            }
        }
    }

    /// Image XObjects reachable from a page (or form) resource dictionary, through nested forms.
    static func imageCount(_ owner: CGPDFDictionaryRef?, depth: Int = 0) -> Int {
        var resources: CGPDFDictionaryRef?
        var objects: CGPDFDictionaryRef?
        guard depth < 8, let owner, CGPDFDictionaryGetDictionary(owner, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "XObject", &objects), let objects else { return 0 }
        var count = 0
        CGPDFDictionaryApplyBlock(objects, { _, object, _ in
            var stream: CGPDFStreamRef?
            var subtype: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream,
                  let dictionary = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return true }
            switch String(cString: subtype) {
            case "Image": count += 1
            case "Form": count += imageCount(dictionary, depth: depth + 1)
            default: break
            }
            return true
        }, nil)
        return count
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    /// A photo-sized JPEG of dark noise around `base`, so it compresses like a camera image.
    static func noisyJPEG(width: Int, height: Int, base: (Int, Int, Int)) throws -> Data {
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 3, bitsPerPixel: 24))
        let bytes = try XCTUnwrap(image.bitmapData)
        var seed: UInt32 = 0x9E37_79B9
        for offset in stride(from: 0, to: width * height * 3, by: 3) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Int(seed >> 27) // 0…31
            bytes[offset] = UInt8(min(255, base.0 + noise))
            bytes[offset + 1] = UInt8(min(255, base.1 + noise))
            bytes[offset + 2] = UInt8(min(255, base.2 + noise))
        }
        return try XCTUnwrap(image.representation(using: .jpeg, properties: [.compressionFactor: 0.9]))
    }

    /// RGBA pixels, top row first, of `page` drawn on white.
    static func rasterize(_ page: PDFPage, paper: CGSize, scale: CGFloat) throws -> (pixels: [UInt8], width: Int, height: Int) {
        let width = Int((paper.width * scale).rounded(.up)), height = Int((paper.height * scale).rounded(.up))
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let bitmap = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            bitmap.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: bitmap)
        }
        return (pixels, width, height)
    }

    /// Count of non-white pixels outside `rect` (top-left pixel coordinates).
    static func inkOutside(_ rect: CGRect, _ raster: (pixels: [UInt8], width: Int, height: Int)) -> Int {
        var count = 0
        for y in 0..<raster.height {
            for x in 0..<raster.width where !rect.contains(CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)) {
                let offset = (y * raster.width + x) * 4
                if raster.pixels[offset..<offset + 3].contains(where: { $0 < 245 }) { count += 1 }
            }
        }
        return count
    }

    /// Longest vertical run of dark pixels in the outermost content columns whose neighbour
    /// six pixels inward is white: a sliver of an adjacent page, not this page's own image.
    static func longestEdgeLine(_ content: CGRect, _ raster: (pixels: [UInt8], width: Int, height: Int)) -> Int {
        func dark(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * raster.width + x) * 4
            return raster.pixels[offset..<offset + 3].contains { $0 < 200 }
        }
        func white(_ x: Int, _ y: Int) -> Bool {
            let offset = (y * raster.width + x) * 4
            return raster.pixels[offset..<offset + 3].allSatisfy { $0 > 245 }
        }
        let left = Int(content.minX.rounded(.down)), right = Int(content.maxX.rounded(.up))
        let columns = (left - 1...left + 2).map { ($0, $0 + 6) } + (right - 3...right).map { ($0, $0 - 6) }
        var longest = 0
        for (x, inward) in columns where x >= 0 && x < raster.width && inward >= 0 && inward < raster.width {
            var run = 0
            for y in Int(content.minY)..<min(raster.height, Int(content.maxY.rounded(.up))) {
                run = dark(x, y) && white(inward, y) ? run + 1 : 0
                longest = max(longest, run)
            }
        }
        return longest
    }

    /// silkweb-1.79: a delay that elapses just as rendering finishes must not open a sheet
    /// that nothing closes. The delay ignores cancellation, like a sleep that already returned.
    @MainActor func testDelayedProgressNeverAppearsAfterRenderFinished() async throws {
        let workspace = LibraryWorkspace(defaults: disposableDefaults("PrintCommands"))
        var release: CheckedContinuation<Void, Never>?
        var delayFinished = false
        let value = try await workspace.withDelayedProgress("Fast", delay: {
            await withCheckedContinuation { release = $0 }
            delayFinished = true
        }, cancel: {}) {
            while release == nil { await Task.yield() }
            return 7
        }
        XCTAssertEqual(value, 7)
        XCTAssertNil(workspace.pdfProgress)
        release?.resume()
        for _ in 0..<200 where !delayFinished { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(delayFinished)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(workspace.pdfProgress, "the progress sheet appeared after rendering finished and would never close")
    }

    /// A slow render shows the sheet, whose Cancel reaches the render; any outcome closes it.
    @MainActor func testDelayedProgressShowsWhileRunningAndClosesOnEveryOutcome() async throws {
        let workspace = LibraryWorkspace(defaults: disposableDefaults("PrintCommands"))
        var cancelled = false
        let value = try await workspace.withDelayedProgress("Slow", delay: {}, cancel: { cancelled = true }) {
            for _ in 0..<200 where workspace.pdfProgress == nil { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(workspace.pdfProgress?.message, "Slow")
            workspace.pdfProgress?.cancel()
            return "done"
        }
        XCTAssertEqual(value, "done")
        XCTAssertTrue(cancelled)
        XCTAssertNil(workspace.pdfProgress)
        for error in [CancellationError() as Error, CocoaError(.fileWriteUnknown)] {
            do {
                _ = try await workspace.withDelayedProgress("Failing", delay: {}, cancel: {}) { () async throws -> Int in
                    for _ in 0..<200 where workspace.pdfProgress == nil { try await Task.sleep(for: .milliseconds(5)) }
                    XCTAssertNotNil(workspace.pdfProgress)
                    throw error
                }
                XCTFail("expected an error")
            } catch {}
            XCTAssertNil(workspace.pdfProgress)
        }
        // A fast render never shows the sheet, not even briefly.
        _ = try await workspace.withDelayedProgress("Instant", cancel: {}) { 1 }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(workspace.pdfProgress)
    }
}

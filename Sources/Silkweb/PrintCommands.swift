import AppKit
import SilkwebCore
import SwiftUI

struct PrintCommands: Commands {
    let workspace: LibraryWorkspace
    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { workspace.pageSetup() }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!workspace.menuState.value.canPrint)
            Button("Print…") { workspace.printDocument() }
                .keyboardShortcut("p").disabled(!workspace.menuState.value.canPrint)
        }
    }
}

extension LibraryWorkspace {
    var canPrint: Bool { canExport && editor.url != nil }

    func pageSetup() {
        guard canPrint else { return }
        exporting = true
        defer { exporting = false }
        NSPageLayout().runModal(with: printInfo)
    }

    /// Export ▸ PDF… from a document row (silkweb-1.25): opens that document if needed, then runs
    /// the same export as File ▸ Export ▸ PDF….
    func exportPDF(path: String) {
        guard canExport, let root else { return }
        let target = root.appendingPathComponent(path).standardizedFileURL
        if editor.url?.standardizedFileURL == target { printDocument(exportPDF: true); return }
        selectDocuments([path])
        Task {
            await waitForNavigation()
            guard editor.url?.standardizedFileURL == target else { return }
            printDocument(exportPDF: true)
        }
    }

    func printDocument(exportPDF: Bool = false) {
        guard canPrint else { return }
        exporting = true
        Task {
            defer { exporting = false }
            let name = editor.name
            do {
                guard let result = try await prepareHTMLExport(printOutput: true) else { return }
                if !result.missingAssets.isEmpty,
                    ExportCommands.missingImageAlert(result, printing: !exportPDF).runModal() != .alertFirstButtonReturn
                {
                    return
                }
                var destination: URL?
                if exportPDF {
                    let panel = ExportCommands.savePanel(name: name, defaults: preview.defaults, pdf: true)
                    // The native panel confirms replacement before we write anything.
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    destination = url
                }
                let window = NSApp.keyWindow
                let renderer = PrintCoordinator()
                defer { renderer.hostWindow.close() }
                // Print renders the same pages as Export ▸ PDF, then prints them 1:1.
                let info = printInfo
                let render = Task {
                    try await renderer.exportPDF(
                        html: result.html, info: info, title: name,
                        timeoutInterval: exportPDF ? 15 : 60)
                }
                let message = exportPDF ? "Exporting “\(name)” as PDF…" : "Preparing “\(name)” for printing…"
                let data = try await withDelayedProgress(message, cancel: { render.cancel() }) {
                    try await withTaskCancellationHandler {
                        try await render.value
                    } onCancel: {
                        render.cancel()
                    }
                }
                if let destination {
                    try await Task.detached(priority: .userInitiated) {
                        try data.write(to: destination, options: .atomic)
                    }.value
                    preview.defaults.set(
                        destination.deletingLastPathComponent().path, forKey: ExportCommands.directoryKey)
                } else {
                    guard let window else { throw CocoaError(.userCancelled) }
                    _ = try await renderer.print(info: info, title: name, window: window)
                }
            } catch is CancellationError {
                // Cancelled from the progress sheet: nothing was written.
            } catch {
                mutationFailure(
                    error,
                    title: exportPDF ? "“\(name)” couldn’t be exported as PDF." : "“\(name)” couldn’t be printed.")
            }
        }
    }

    /// Runs `operation`, showing the progress sheet only while it is still running after `delay`.
    /// The sheet closes when it finishes, fails or is cancelled, and never appears afterwards.
    func withDelayedProgress<T>(
        _ message: String,
        delay: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(1)) },
        cancel: @escaping () -> Void,
        operation: () async throws -> T
    ) async throws -> T {
        let shown = Task { @MainActor in
            try await delay()
            // The delay may elapse just as the operation finishes; its continuation can then run after the cleanup below.
            try Task.checkCancellation()
            pdfProgress = PDFProgress(message: message, cancel: cancel)
        }
        defer { shown.cancel(); pdfProgress = nil }
        return try await operation()
    }
}

/// Shown only when rendering takes longer than a second; Cancel stops the render.
struct PDFProgress: Identifiable {
    let id = UUID()
    let message: String
    let cancel: () -> Void
}

struct PDFProgressSheet: View {
    let progress: PDFProgress
    var body: some View {
        VStack(alignment: .trailing, spacing: 16) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(progress.message)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Cancel", action: progress.cancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
        .frame(width: 380)
    }
}

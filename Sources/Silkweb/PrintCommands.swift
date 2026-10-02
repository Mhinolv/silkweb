import AppKit
import SwiftUI
import SilkwebCore

struct PrintCommands: Commands {
    let workspace: LibraryWorkspace
    var body: some Commands {
        CommandGroup(replacing: .printItem) {
            Button("Page Setup…") { workspace.pageSetup() }
                .keyboardShortcut("p", modifiers: [.command, .shift]).disabled(!workspace.canPrint)
            Button("Print…") { workspace.printDocument() }
                .keyboardShortcut("p").disabled(!workspace.canPrint)
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

    func printDocument(exportPDF: Bool = false) {
        guard canPrint else { return }
        exporting = true
        Task {
            defer { exporting = false }
            let name = editor.name
            do {
                guard let result = try await prepareHTMLExport(printOutput: true) else { return }
                if !result.missingAssets.isEmpty,
                   ExportCommands.missingImageAlert(result, printing: !exportPDF).runModal() != .alertFirstButtonReturn { return }
                var destination: URL?
                if exportPDF {
                    let panel = ExportCommands.savePanel(name: name, defaults: preview.defaults, pdf: true)
                    // The native panel confirms replacement before we write anything.
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    destination = url
                }
                let renderer = PrintCoordinator()
                try await renderer.load(html: result.html)
                // Print into a staging file so a failed print job cannot damage an existing PDF.
                let staging = destination.map { $0.deletingLastPathComponent().appendingPathComponent(".silkweb-print-" + UUID().uuidString + ".pdf") }
                defer { if let staging { try? FileManager.default.removeItem(at: staging) } }
                let operation = renderer.operation(info: printInfo, title: name, destination: staging)
                let succeeded = operation.run()
                if let destination {
                    guard succeeded, let staging else { throw CocoaError(.fileWriteUnknown) }
                    try await Task.detached(priority: .userInitiated) {
                        let data = try Data(contentsOf: staging)
                        guard data.starts(with: Data("%PDF-".utf8)) else { throw CocoaError(.fileWriteUnknown) }
                        try data.write(to: destination, options: .atomic)
                    }.value
                    preview.defaults.set(destination.deletingLastPathComponent().path, forKey: ExportCommands.directoryKey)
                }
            } catch {
                mutationFailure(error, title: exportPDF ? "“\(name)” couldn’t be exported as PDF." : "“\(name)” couldn’t be printed.")
            }
        }
    }
}

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
                defer { renderer.hostWindow.close() }
                if let destination {
                    let data = try await renderer.exportPDF(html: result.html, info: printInfo, title: name)
                    try await Task.detached(priority: .userInitiated) {
                        try data.write(to: destination, options: .atomic)
                    }.value
                    preview.defaults.set(destination.deletingLastPathComponent().path, forKey: ExportCommands.directoryKey)
                } else {
                    guard let window = NSApp.keyWindow else { throw CocoaError(.userCancelled) }
                    try await renderer.load(html: result.html)
                    _ = try await renderer.print(info: printInfo, title: name, window: window)
                }
            } catch {
                mutationFailure(error, title: exportPDF ? "“\(name)” couldn’t be exported as PDF." : "“\(name)” couldn’t be printed.")
            }
        }
    }
}

import AppKit
import SilkwebCore
import SwiftUI
import UniformTypeIdentifiers

struct ExportMenu: View {
    let workspace: LibraryWorkspace
    let state: MenuCommandValues
    var body: some View {
        Menu("Export") {
            Button("HTML…") { workspace.exportHTML() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("PDF…") { workspace.printDocument(exportPDF: true) }
                .keyboardShortcut("p", modifiers: [.command, .option]).disabled(!state.canPrint)
        }.disabled(!state.canExport)
    }
}

@MainActor enum ExportCommands {
    static let directoryKey = "Silkweb.Export.Directory"

    static func missingImageAlert(_ result: HTMLExport.Result, printing: Bool = false) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = result.warningTitle
        alert.informativeText =
            printing
            ? result.warningDetail.replacingOccurrences(of: "The exported file", with: "The printed document")
            : result.warningDetail
        alert.addButton(withTitle: printing ? "Print Anyway" : "Export Anyway")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    static func savePanel(name: String, defaults: UserDefaults, pdf: Bool = false) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = pdf ? [.pdf] : [.html]
        panel.nameFieldStringValue = name + (pdf ? ".pdf" : ".html")
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.directoryURL =
            defaults.string(forKey: directoryKey).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        return panel
    }
}

extension LibraryWorkspace {
    var canExport: Bool {
        root != nil && !loading && !mutating && !exporting && !editor.loading
            && session.selectedDocuments.count <= 1 && (selectedDocument != nil || editor.url != nil)
    }

    /// Capture the flushed buffer before any destination or warning panel is presented.
    func prepareHTMLExport(path: String? = nil, printOutput: Bool = false) async throws -> HTMLExport.Result? {
        await waitForNavigation()
        guard !loading, !mutating, !editor.loading, session.selectedDocuments.count <= 1, let root else { return nil }
        let destination =
            path.map { root.appendingPathComponent($0) }
            ?? (printOutput
                ? editor.url : selectedDocument.map { root.appendingPathComponent($0.relativePath) } ?? editor.url)
        guard let destination else { return nil }
        let buffer = allEditors.first { $0.url == destination }
        if let buffer, !(await buffer.flush()) {
            throw CocoaError(
                .fileWriteUnknown,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The document couldn’t be saved. Resolve its save warning before exporting."
                ])
        }
        let text = buffer?.text
        let language = Locale.preferredLanguages.first ?? "en"
        // Same rendering settings as Preview (#101); only the stylesheet differs.
        let preferences = LivePreferences.shared.current
        return try await Task.detached(priority: .userInitiated) {
            let markdown = try text ?? String(contentsOf: destination, encoding: .utf8)
            return HTMLExport.prepare(
                markdown: markdown, title: destination.deletingPathExtension().lastPathComponent,
                documentURL: destination, libraryRoot: root,
                stylesheet: printOutput ? PrintCoordinator.stylesheet : PreviewCoordinator.stylesheet,
                language: language,
                lineBreaks: preferences.keepsLineBreaks ? .preserve : .standard,
                showsTableOfContents: preferences.showsTableOfContents,
                printOutput: printOutput)
        }.value
    }

    func exportHTML(path: String? = nil) {
        guard canExport else { return }
        exporting = true
        Task {
            defer { exporting = false }
            let name =
                path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
                ?? selectedDocument.map { ($0.name as NSString).deletingPathExtension } ?? editor.name
            do {
                guard let result = try await prepareHTMLExport(path: path) else { return }
                if !result.missingAssets.isEmpty,
                    ExportCommands.missingImageAlert(result).runModal() != .alertFirstButtonReturn
                {
                    return
                }
                let panel = ExportCommands.savePanel(name: name, defaults: preview.defaults)
                // NSSavePanel owns the explicit confirmation before replacing an existing file.
                guard panel.runModal() == .OK, let destination = panel.url else { return }
                try await Task.detached(priority: .userInitiated) { try result.write(to: destination) }.value
                preview.defaults.set(destination.deletingLastPathComponent().path, forKey: ExportCommands.directoryKey)
            } catch { mutationFailure(error, title: "“\(name)” couldn’t be exported.") }
        }
    }
}

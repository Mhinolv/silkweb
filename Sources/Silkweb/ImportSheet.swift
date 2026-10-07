import AppKit
import SilkwebCore
import SwiftUI

struct ImportRequest: Identifiable {
    let id = UUID()
    let source: URL
    let destination: String
}

@MainActor @Observable
final class ImportReview {
    var plan: ImportPlan?
    var reviewing = false
    var copying = false
    var copied = 0
    var total = 0
    var message: String?
    var errorTitle = ""
    var stopped = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var worker: Task<Void, Never>?

    func cancel() { worker?.cancel() }
    func review(_ request: ImportRequest, root: URL, destination: String) {
        worker?.cancel()
        let generation = UUID()
        self.generation = generation
        plan = nil; reviewing = false; message = nil; stopped = false
        worker = Task {
            let delayed = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled && self.generation == generation {
                    reviewing = true; announce("Import review started.")
                }
            }
            defer {
                delayed.cancel()
                if self.generation == generation {
                    if reviewing { announce("Import review ended.") }
                    reviewing = false
                }
            }
            let scan = Task.detached {
                try FolderImporter.plan(source: request.source, library: root, destination: destination)
            }
            do {
                let value = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: {
                    scan.cancel()
                }
                guard !Task.isCancelled && self.generation == generation else { return }
                plan = value
            } catch {
                if !Task.isCancelled && self.generation == generation {
                    if error is FolderImportError {
                        errorTitle = error.localizedDescription; message = "Choose another folder to import."
                    } else {
                        errorTitle = "Silkweb can’t read “\(request.source.lastPathComponent)”.";
                        message = error.localizedDescription
                    }
                }
            }
        }
    }
    func start(_ workspace: LibraryWorkspace) {
        guard let plan, workspace.canMutate,
            workspace.root?.standardizedFileURL.resolvingSymlinksInPath() == plan.library
        else { return }
        workspace.mutating = true
        copying = true; total = plan.documentCount
        announce("Import started.")
        worker = Task {
            var published = false
            defer { copying = false; workspace.mutating = false }
            let copy = Task.detached {
                try FolderImporter.copy(plan) { [weak self] count, total in
                    Task { @MainActor in
                        self?.copied = count; self?.total = total
                    }
                }
            }
            do {
                let path = try await withTaskCancellationHandler {
                    try await copy.value
                } onCancel: {
                    copy.cancel()
                }
                published = true
                // Once published, finish the library refresh even if Stop arrived at the commit boundary.
                try await Task { @MainActor in try await workspace.refresh(LibraryChangeSet(changes: [])) }.value
                var ancestor = plan.destination
                while !ancestor.isEmpty {
                    workspace.session.expandedFolders.insert(ancestor)
                    ancestor = (ancestor as NSString).deletingLastPathComponent
                }
                workspace.session.expandedFolders.insert("")
                workspace.session.selectedFolder = path
                workspace.session.selectedDocuments = []
                workspace.importRequest = nil
                announce("Import completed.")
            } catch is CancellationError {
                stopped = true; message = "Import stopped. Nothing was added to your library."
                announce("Import stopped.")
            } catch {
                errorTitle = "The import couldn’t be completed."
                message = error.localizedDescription
                // A refresh failure after publication must not claim the copy was rolled back.
                if !published {
                    message! += "\nNothing was added to your library."
                } else {
                    message! += "\nThe copied folder is on disk. Reopen the library to refresh it."
                }
                announce("Import ended.")
            }
        }
    }
    private func announce(_ text: String) {
        if let view = NSApp.keyWindow?.contentView {
            NSAccessibility.post(
                element: view, notification: .announcementRequested,
                userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
}

struct ImportSheet: View {
    @Bindable var workspace: LibraryWorkspace
    let request: ImportRequest
    @State private var review = ImportReview()
    @State private var destination = ""
    @State private var choosingDestination = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import “\(request.source.lastPathComponent)”").font(.headline)
            if review.copying {
                Text("Copying \(review.copied) of \(review.total) documents…")
                ProgressView(value: Double(review.copied), total: Double(max(1, review.total)))
            } else if let message = review.message {
                if !review.stopped { Text(review.errorTitle).font(.headline) }
                Text(message)
            } else if let plan = review.plan {
                HStack {
                    Text("Copy into:")
                    Label(
                        destination.isEmpty
                            ? (workspace.root?.lastPathComponent ?? "Library")
                            : destination.replacingOccurrences(of: "/", with: " › "), systemImage: "folder")
                    Spacer()
                    Button("Change…") { choosingDestination = true }
                }
                if plan.documentCount == 0 {
                    Text("No Markdown documents found").font(.headline)
                    Text("“\(request.source.lastPathComponent)” doesn’t contain any .md or .markdown files.")
                } else {
                    Text(plan.summary)
                }
                if plan.folderName != request.source.lastPathComponent {
                    Text(
                        plan.folderNameCollision
                            ? "“\(request.source.lastPathComponent)” already exists here, so the copy will be named “\(plan.folderName)”."
                            : "The copy will be named “\(plan.folderName)” to avoid an existing or invalid folder name."
                    ).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        report("Will be renamed", rows: plan.renamed)
                        report("Won’t be copied", rows: plan.skipped)
                        report("Links outside the folder", rows: plan.outsideLinks)
                        if !plan.outsideLinks.isEmpty {
                            Text("These files won’t be copied. The links stay as written.").font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else if review.reviewing {
                Text("Reviewing “\(request.source.lastPathComponent)”…")
                ProgressView()
            }
            Spacer()
            HStack {
                Spacer()
                if review.copying {
                    Button("Stop") { review.cancel() }
                } else if review.message != nil {
                    Button(review.stopped ? "Done" : "Cancel") { close() }.keyboardShortcut(.cancelAction)
                } else {
                    Button("Cancel") { close() }.keyboardShortcut(.cancelAction)
                    if review.plan == nil || (review.plan?.documentCount ?? 0) > 0 {
                        Button("Import") { review.start(workspace) }.keyboardShortcut(.defaultAction)
                            .disabled(review.plan == nil)
                    }
                }
            }
        }
        .padding(20).frame(width: 540, height: 560)
        .interactiveDismissDisabled(review.copying)
        .sheet(isPresented: $choosingDestination) {
            MovePicker(
                workspace: workspace, request: MoveRequest(paths: []),
                importChoice: { path in
                    choosingDestination = false
                    if let path, let root = workspace.root {
                        destination = path
                        review.review(request, root: root, destination: path)
                    }
                })
        }
        .task {
            destination = request.destination
            if let root = workspace.root { review.review(request, root: root, destination: destination) }
        }
        .onDisappear { review.cancel() }
    }
    private func close() { review.cancel(); workspace.importRequest = nil }
    private func report(_ title: String, rows: [String]) -> some View {
        DisclosureGroup("\(title) (\(rows.count))") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(rows.prefix(200).enumerated()), id: \.offset) { _, row in
                    Text(row).font(.caption).textSelection(.enabled)
                }
                if rows.count > 200 { Text("and \(rows.count - 200) more").font(.caption) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityLabel("\(title), \(rows.count) items")
    }
}

extension LibraryWorkspace {
    func chooseImportFolder() {
        guard canMutate else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message =
            "Choose a folder of Markdown files to copy into your library. The original folder won’t be changed."
        panel.begin { [weak self] response in
            guard let self, response == .OK, let source = panel.url, self.canMutate else { return }
            self.importRequest = ImportRequest(source: source, destination: self.targetFolder)
        }
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SilkwebCore

extension UTType {
    static let silkwebMove = UTType(exportedAs: "com.silkweb.internal-move")
}

struct MoveRequest: Identifiable {
    let id = UUID()
    let paths: [String]
}

struct MovePicker: View {
    @Bindable var workspace: LibraryWorkspace
    let request: MoveRequest
    var importChoice: ((String?) -> Void)? = nil
    @State private var filter = ""
    @State private var destination: String?
    @State private var expanded: Set<String> = [""]
    @State private var renamingPath: String?
    @State private var folderName = "Untitled Folder"
    @State private var error: String?
    @FocusState private var filterFocused: Bool
    @FocusState private var renameFocused: Bool

    private var folders: [LibraryFolder] { workspace.snapshot?.folders ?? [] }
    private var title: String {
        if importChoice != nil { return "Import Into…" }
        guard request.paths.count == 1 else { return "Move \(request.paths.count) Items To…" }
        let path = request.paths[0]
        let filename = (path as NSString).lastPathComponent
        let name = folders.contains(where: { $0.relativePath == path }) ? filename : (filename as NSString).deletingPathExtension
        return "Move “\(name)” To…"
    }
    private func valid(_ path: String) -> Bool { importChoice != nil || MoveSelection.permits(request.paths, destination: path) }
    private var visible: [LibraryFolder] {
        if !filter.isEmpty { return folders.filter { $0.name.localizedStandardContains(filter) || $0.relativePath.localizedStandardContains(filter) } }
        let byParent = Dictionary(grouping: folders, by: \.parentID)
        func children(_ parent: UUID?) -> [LibraryFolder] {
            (byParent[parent] ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.flatMap {
                [$0] + (expanded.contains($0.relativePath) ? children($0.id) : [])
            }
        }
        return children(nil)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField("Filter folders", text: $filter).focused($filterFocused)
            List(selection: $destination) {
                if filter.isEmpty, !workspace.recentMoveFolders.isEmpty {
                    Section("Recent") {
                        ForEach(workspace.recentMoveFolders.compactMap { path in folders.first { $0.relativePath == path } }) { row($0) }
                    }
                }
                Section("Library") { ForEach(visible) { row($0) } }
            }
            .onKeyPress(.rightArrow) { if let destination { expanded.insert(destination) }; return .handled }
            .onKeyPress(.leftArrow) { if let destination { expanded.remove(destination) }; return .handled }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Button("New Folder…") { createFolder() }.disabled(destination == nil || !workspace.canMutate)
                Spacer()
                Button("Cancel") { if let importChoice { importChoice(nil) } else { workspace.moveRequest = nil } }.keyboardShortcut(.cancelAction)
                Button(importChoice == nil ? "Move" : "Choose") {
                    guard let destination, valid(destination) else { return }
                    if let importChoice { importChoice(destination) }
                    else {
                        workspace.moveRequest = nil
                        workspace.move(request.paths, to: destination)
                    }
                }.keyboardShortcut(.defaultAction).disabled(renamingPath != nil || (destination.map { !valid($0) } ?? true))
            }
        }.padding(20).frame(width: 440, height: 480)
        .task { filterFocused = true }
    }
    private func createFolder() {
        guard let parent = destination, let root = workspace.root else { return }
        workspace.mutating = true
        Task {
            defer { workspace.mutating = false }
            do {
                let engine = try LibraryMutations(root: root)
                let name = try await engine.uniqueName(base: "Untitled Folder", in: parent)
                let changes = try await engine.createFolder(named: name, in: parent)
                try await workspace.refresh(changes)
                guard let path = changes.changes.first?.newPath else { return }
                workspace.libraryUndo.append(.newFolder(path))
                expanded.insert(parent)
                filter = ""
                destination = path
                renamingPath = path
                folderName = name
                renameFocused = true
            } catch { self.error = error.localizedDescription }
        }
    }
    private func renameFolder() {
        guard let path = renamingPath, let root = workspace.root, workspace.canMutate else { return }
        workspace.mutating = true
        Task {
            defer { workspace.mutating = false }
            do {
                let engine = try LibraryMutations(root: root)
                let changes = try await engine.rename(path, to: folderName)
                try await workspace.refresh(changes)
                destination = changes.changes.first?.newPath ?? path
                if let newPath = changes.changes.first?.newPath {
                    workspace.libraryUndo.append(.rename(LibraryRename(path: newPath, isFolder: true), (path as NSString).lastPathComponent))
                }
                renamingPath = nil
                error = nil
            } catch { self.error = error.localizedDescription; renameFocused = true }
        }
    }
    private func highlightedName(_ name: String) -> AttributedString {
        var value = AttributedString(name)
        if !filter.isEmpty, let range = value.range(of: filter, options: [.caseInsensitive, .diacriticInsensitive]) {
            value[range].foregroundColor = .accentColor
            value[range].font = .body.bold()
        }
        return value
    }
    private func row(_ folder: LibraryFolder) -> some View {
        HStack {
            if filter.isEmpty {
                Button {
                    if expanded.contains(folder.relativePath) { expanded.remove(folder.relativePath) }
                    else { expanded.insert(folder.relativePath) }
                } label: { Image(systemName: expanded.contains(folder.relativePath) ? "chevron.down" : "chevron.right").font(.caption) }
                    .buttonStyle(.plain).accessibilityLabel("Expand or collapse \(folder.name)")
            }
            VStack(alignment: .leading) {
                if renamingPath == folder.relativePath {
                    TextField("Folder name", text: $folderName).focused($renameFocused)
                        .onSubmit { renameFolder() }
                        .onExitCommand { renamingPath = nil }
                } else {
                    Label { Text(highlightedName(folder.name)) } icon: { Image(systemName: "folder") }
                }
                if !valid(folder.relativePath) {
                    Text(request.paths.contains { ($0 as NSString).deletingLastPathComponent == folder.relativePath } ? "Current location" : "Unavailable destination").font(.caption).foregroundStyle(.secondary)
                } else if !filter.isEmpty {
                    Text(folder.relativePath.replacingOccurrences(of: "/", with: " › ")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, filter.isEmpty ? CGFloat(folder.relativePath.split(separator: "/").count) * 12 : 0)
        .tag(folder.relativePath).disabled(!valid(folder.relativePath) || folder.isUnreadable)
        .accessibilityLabel("\(folder.name), folder, \(folder.relativePath.isEmpty ? "library root" : folder.relativePath)")
    }
}

extension LibraryWorkspace {
    var movePaths: [String] {
        focusColumn == 0 ? selectedItem.map { [$0.path] } ?? [] : Array(session.selectedDocuments).sorted()
    }
    func requestMove(_ paths: [String]? = nil) {
        guard canMutate else { return }
        let paths = MoveSelection.topLevel(paths ?? movePaths)
        guard !paths.isEmpty, !paths.contains("") else { return }
        moveRequest = MoveRequest(paths: paths)
    }

    func documentDragPaths(_ path: String) -> [String] {
        session.selectedDocuments.contains(path) ? Array(session.selectedDocuments).sorted() : [path]
    }
    func dragProvider(_ paths: [String]) -> NSItemProvider {
        let provider = NSItemProvider()
        guard canMutate else { return provider }
        let payload = try! JSONEncoder().encode(InternalMove(library: dragIdentity, ids: paths.compactMap { snapshot?.metadata.IDsByPath[$0] }))
        provider.registerDataRepresentation(forTypeIdentifier: UTType.silkwebMove.identifier, visibility: .ownProcess) { completion in
            completion(payload, nil); return nil
        }
        return provider
    }
    func pathsForDrag(_ data: Data) -> [String]? {
        guard let payload = try? JSONDecoder().decode(InternalMove.self, from: data), payload.library == dragIdentity,
              !payload.ids.isEmpty else { return nil }
        let paths = payload.ids.compactMap { itemPathsByID[$0] }
        return paths.count == payload.ids.count ? MoveSelection.topLevel(paths) : nil
    }
    func move(_ paths: [String], to destination: String) {
        guard canMutate, MoveSelection.permits(paths, destination: destination), let root else { return }
        mutating = true
        Task {
            await waitForNavigation()
            editor.loading = true
            defer { editor.loading = false; mutating = false }
            guard await editor.flush() else { return }
            let oldURL = editor.url
            let position = (editor.selection, editor.scroll)
            do {
                let engine = try LibraryMutations(root: root)
                var plan = try await preflightMove(engine, paths: paths, destination: destination)
                if !plan.collisions.isEmpty {
                    plan = try await preflightMove(engine, paths: paths, destination: destination, keepBoth: true)
                    var applyToAll = false
                    for path in plan.collisions where !applyToAll {
                        guard let change = plan.changes.changes.first(where: { $0.oldPath == path }) else { continue }
                        let name = (path as NSString).lastPathComponent
                        let newName = (change.newPath as NSString).lastPathComponent
                        let folderName = destination.isEmpty ? root.lastPathComponent : (destination as NSString).lastPathComponent
                        let alert = NSAlert()
                        alert.messageText = "An item named “\(name)” already exists in “\(folderName)”."
                        alert.informativeText = "You can keep both by naming the moved item “\(newName)”, or stop the move."
                        alert.addButton(withTitle: "Keep Both"); alert.addButton(withTitle: "Stop")
                        alert.showsSuppressionButton = plan.collisions.count > 1
                        alert.suppressionButton?.title = "Apply to All"
                        guard await moveAlert(alert) else { return }
                        applyToAll = alert.suppressionButton?.state == .on
                    }
                }
                if !plan.unsupportedLinks.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "Some links might stop working"
                    alert.informativeText = "Silkweb can’t update these links automatically. They’ll stay as written."
                    let view = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 140))
                    let text = NSTextView(frame: view.bounds)
                    text.isEditable = false
                    text.string = plan.unsupportedLinks.map { "\($0.document) › \($0.syntax)" }.joined(separator: "\n")
                    view.documentView = text; view.hasVerticalScroller = true
                    alert.accessoryView = view
                    alert.addButton(withTitle: "Move Anyway"); alert.addButton(withTitle: "Cancel")
                    guard await moveAlert(alert) else { return }
                }
                guard await editor.open(nil, readOnly: false) else { return }
                let changes = try await commitMove(plan, using: engine)
                libraryUndo.append(.move(plan.reversed))
                if let movedFolder = changes.changes.first(where: \.isFolder) { session.selectedFolder = movedFolder.newPath }
                session.expandedFolders.insert(destination)
                recentMoveFolders.removeAll { $0 == destination }; recentMoveFolders.insert(destination, at: 0)
                recentMoveFolders = Array(recentMoveFolders.prefix(3))
                if let oldURL {
                    let oldPath = String(oldURL.path.dropFirst(root.path.count + 1))
                    _ = await editor.open(root.appendingPathComponent(changes.remapping(oldPath)), readOnly: false)
                    (editor.selection, editor.scroll) = position
                }
            } catch {
                if editor.url == nil { _ = await editor.open(oldURL, readOnly: false); (editor.selection, editor.scroll) = position }
                mutationFailure(error, title: "The items couldn’t be moved.")
                if let failure = error as? LibraryMutationError, case .rollbackFailed = failure {
                    // The recovery suggestion identifies the preserved items.
                } else { mutationError = (mutationError ?? "") + "\nNothing was changed." }
            }
        }
    }
    func commitMove(_ plan: MovePlan, using engine: LibraryMutations) async throws -> LibraryChangeSet {
        let changes = try await engine.executeMove(plan)
        do { try await refresh(changes) }
        catch {
            let failure = error
            do {
                let reversed = try await engine.executeMove(plan.reversed)
                try await refresh(reversed)
            } catch {
                throw LibraryMutationError.rollbackFailed(original: failure.localizedDescription, current: error.localizedDescription)
            }
            throw failure
        }
        return changes
    }

    private func preflightMove(_ engine: LibraryMutations, paths: [String], destination: String, keepBoth: Bool = false) async throws -> MovePlan {
        let window = NSApp.keyWindow
        let progress = makeMoveProgressPanel()
        let delayed = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            if let window { window.beginSheet(progress, completionHandler: { _ in }) }
        }
        defer {
            delayed.cancel()
            if progress.sheetParent != nil { window?.endSheet(progress) }
            progress.orderOut(nil)
        }
        return try await engine.planMove(paths, toFolder: destination, keepBoth: keepBoth)
    }

    private func moveAlert(_ alert: NSAlert) async -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0 == .alertFirstButtonReturn) }
        }
    }
}

struct InternalMove: Codable {
    let library: UUID
    let ids: [UUID]
}

@MainActor
func makeMoveProgressPanel() -> NSPanel {
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
    panel.title = "Preparing Move"
    let spinner = NSProgressIndicator()
    spinner.style = .spinning; spinner.startAnimation(nil)
    let label = NSTextField(labelWithString: "Checking items and links…")
    let stack = NSStackView(views: [spinner, label])
    stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
    panel.contentView?.addSubview(stack)
    if let content = panel.contentView {
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: content.centerXAnchor), stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
    }
    return panel
}

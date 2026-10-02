import AppKit
import SwiftUI
import SilkwebCore

extension LibraryWorkspace {
    var canEditTags: Bool { snapshot != nil && snapshot?.isReadOnly == false && !loading && (!mutating || tagEditing) }
    var tagDocumentIDs: Set<UUID> {
        Set(session.selectedDocuments.compactMap { snapshot?.metadata.IDsByPath[$0] })
    }
    var commonTagNames: [String] {
        guard let snapshot else { return [] }
        let common = TagEditor.commonTags(documents: tagDocumentIDs, metadata: snapshot.metadata)
        return tags.filter { common.contains($0.id) }.map(\.name)
    }
    var effectiveTagFilters: Set<UUID> { tagFilters.union(session.selectedTagID.map { [$0] } ?? []) }
    func selectTag(_ id: UUID) {
        tagFilters = []
        selectFolder(nil)
        Task { await waitForNavigation(); session.selectedTagID = id; persistSession() }
    }
    func showInfo() { inspectorInfo = true; preview.showsOutline = true; tagFocusRequest += 1 }
    func editTags(_ names: [String]) {
        let ids = tagDocumentIDs
        guard let metadata = snapshot?.metadata,
              TagEditor.edit(names, documents: ids, metadata: metadata) != metadata else { return }
        let removing = commonTagNames.contains { old in
            !names.contains { $0.compare(old, options: .caseInsensitive) == .orderedSame }
        }
        changeTags(title: removing ? "Undo Remove Tag" : "Undo Add Tag") { TagEditor.edit(names, documents: ids, metadata: $0) }
    }
    func toggleTag(_ tag: LibraryTag, paths: Set<String>) {
        guard let snapshot else { return }
        let ids = Set(paths.compactMap { snapshot.metadata.IDsByPath[$0] })
        let common = TagEditor.commonTags(documents: ids, metadata: snapshot.metadata)
        let names = tags.filter { common.contains($0.id) && $0.id != tag.id }.map(\.name)
        changeTags(title: common.contains(tag.id) ? "Undo Remove Tag" : "Undo Add Tag") {
            TagEditor.edit(common.contains(tag.id) ? names : names + [tag.name], documents: ids, metadata: $0)
        }
    }
    func changeTags(title: String, transform: @escaping @Sendable (LibraryMetadata) -> LibraryMetadata) {
        guard canEditTags, let snapshot else { return }
        let previousTask = tagEditTask
        pendingTagEdits += 1
        mutating = true
        tagEditing = true
        tagEditTask = Task {
            await previousTask?.value
            defer {
                pendingTagEdits -= 1
                if pendingTagEdits == 0 { mutating = false; tagEditing = false; tagEditTask = nil }
            }
            do {
                let previous = self.snapshot?.metadata ?? snapshot.metadata
                _ = try await TagStore.update(root: snapshot.rootURL, transform: transform)
                let scanned = try await LibraryScanner.scan(root: snapshot.rootURL, previousSnapshot: snapshot)
                install(scanned)
                if previous.tags != scanned.metadata.tags || previous.tagsByDocument != scanned.metadata.tagsByDocument {
                    libraryUndo.append(.tags(previous, title))
                }
                tagFilters.formIntersection(Set(scanned.metadata.tags.map(\.id)))
                revision += 1
                persistSession()
            } catch { mutationFailure(error) }
        }
    }
    func renameTag(_ tag: LibraryTag, to name: String) {
        guard let normalized = TagEditor.normalize(name) else { NSSound.beep(); return }
        if let existing = TagEditor.existing(normalized, in: tags), existing.id != tag.id {
            let alert = NSAlert()
            alert.messageText = "A tag named “\(existing.name)” already exists."
            alert.informativeText = "Merge “\(tag.name)” into “\(existing.name)”? Documents with either tag will have “\(existing.name)”."
            alert.addButton(withTitle: "Merge"); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        changeTags(title: "Undo Rename Tag") { TagEditor.rename(tag.id, to: normalized, metadata: $0) }
    }
    func deleteTag(_ tag: LibraryTag) {
        let count = tagCounts[tag.id] ?? 0
        let alert = NSAlert()
        alert.messageText = "Delete the tag “\(tag.name)”?"
        alert.informativeText = "It will be removed from \(count) documents. The documents themselves won’t change."
        alert.addButton(withTitle: "Delete Tag"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        changeTags(title: "Undo Delete Tag") { TagEditor.delete(tag.id, metadata: $0) }
    }
    var filteredSearchResults: [SearchResult] {
        guard let snapshot else { return search.results }
        guard !effectiveTagFilters.isEmpty || search.folderScope != nil else { return search.results }
        let documents = snapshot.presentation.documentsByID
        return search.results.filter { result in
            guard let document = documents[result.id] else { return false }
            // Folder search always includes descendants; the toggle only scopes the plain list.
            return TagEditor.matches(document, folder: search.folderScope == nil ? nil : selectedFolder,
                                     includeSubfolders: true, tags: effectiveTagFilters, metadata: snapshot.metadata)
        }
    }
}

struct TagSidebar: View {
    @Bindable var workspace: LibraryWorkspace
    @State private var renameError: String?
    @FocusState private var renameFocused: Bool
    private func commitRename(_ tag: LibraryTag) {
        guard TagEditor.normalize(workspace.tagRenameName) != nil else {
            renameError = "Use 1–64 characters without commas."
            NSSound.beep()
            return
        }
        workspace.renameTag(tag, to: workspace.tagRenameName)
        workspace.tagRenameID = nil
        renameError = nil
    }
    var body: some View {
        if !workspace.tags.isEmpty {
            Text("TAGS").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(workspace.tags) { tag in
                        HStack(spacing: 6) {
                            Image(systemName: "tag").foregroundStyle(.secondary)
                            if workspace.tagRenameID == tag.id {
                                TextField(tag.name, text: $workspace.tagRenameName).focused($renameFocused)
                                    .onSubmit { commitRename(tag) }
                                    .onExitCommand { workspace.tagRenameID = nil; renameError = nil }
                                    .onChange(of: renameFocused) { if !renameFocused, workspace.tagRenameID == tag.id { commitRename(tag) } }
                                    .popover(isPresented: Binding(get: { renameError != nil && workspace.tagRenameID == tag.id }, set: { if !$0 { renameError = nil } }), arrowEdge: .bottom) {
                                        Text(renameError ?? "").foregroundStyle(.red).padding(12)
                                    }
                            } else {
                                Button { workspace.selectTag(tag.id) } label: {
                                    HStack(spacing: 0) {
                                        Text(tag.name).lineLimit(1)
                                        Text(" (\(workspace.tagCounts[tag.id] ?? 0))")
                                            .foregroundStyle(.secondary).monospacedDigit().fixedSize()
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16).frame(height: 24)
                        .background(workspace.session.selectedTagID == tag.id ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor) : .clear)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(tag.name), tag, \(workspace.tagCounts[tag.id] ?? 0) documents")
                        .contextMenu {
                            Button("Rename Tag…") { workspace.tagRenameName = tag.name; workspace.tagRenameID = tag.id; renameFocused = true }.disabled(!workspace.canMutate)
                            Button("Delete Tag…", role: .destructive) { workspace.deleteTag(tag) }.disabled(!workspace.canMutate)
                        }
                    }
                }
            }.frame(maxHeight: 180)
        }
    }
}

struct TagFilterBar: View {
    let workspace: LibraryWorkspace
    var body: some View {
        if !workspace.tagFilters.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    Text("Tagged:")
                    ForEach(workspace.tags.filter { workspace.tagFilters.contains($0.id) }) { tag in
                        Button { workspace.tagFilters.remove(tag.id) } label: { Text(tag.name + " ×") }
                            .accessibilityLabel("Remove filter \(tag.name)")
                    }
                    Button("Clear") { workspace.tagFilters = [] }
                }.font(.caption).padding(.horizontal, 8)
            }.frame(height: 28).background(.bar)
        }
    }
}

struct DocumentInfo: View {
    let workspace: LibraryWorkspace
    var body: some View {
        if workspace.tagDocumentIDs.isEmpty {
            ContentUnavailableView("No Document Selected", systemImage: "doc.text")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Tags").font(.headline)
                    TagTokenField(names: workspace.commonTagNames, suggestions: workspace.tags.map(\.name),
                                  focusRequest: workspace.tagFocusRequest, enabled: workspace.canEditTags, onChange: workspace.editTags)
                        .frame(minHeight: 28)
                    Text("Tags are saved in this library’s Silkweb index, not in the document file.")
                        .font(.caption).foregroundStyle(.tertiary)
                    if let document = workspace.selectedDocument {
                        Text("Location").font(.headline)
                        let parent = (document.relativePath as NSString).deletingLastPathComponent
                        Button(parent.isEmpty ? "Library" : parent.replacingOccurrences(of: "/", with: " › ")) { workspace.reveal(document.relativePath) }
                            .buttonStyle(.link)
                        if let date = document.created { Text("Created").font(.headline); Text(date.formatted()).font(.caption) }
                        if let date = document.modified { Text("Modified").font(.headline); Text(date.formatted()).font(.caption) }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct TagTokenField: NSViewRepresentable {
    let names: [String]
    let suggestions: [String]
    let focusRequest: Int
    let enabled: Bool
    let onChange: ([String]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }
    func makeNSView(context: Context) -> NSTokenField {
        let field = TagInputField()
        field.placeholderString = "Add tags"
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",\t\n")
        field.completionDelay = 0.1
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.setAccessibilityLabel("Tags")
        return field
    }
    func updateNSView(_ field: NSTokenField, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.suggestions = suggestions
        // Preserve uncommitted input when unrelated workspace state updates the bridge.
        if context.coordinator.presentedNames != names {
            if (field.objectValue as? [String] ?? []) != names { field.objectValue = names }
            context.coordinator.presentedNames = names
        }
        field.isEnabled = enabled
        if let field = field as? TagInputField {
            field.requestedFocus = focusRequest
            field.focusIfNeeded()
        }
    }
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var onChange: ([String]) -> Void
        var suggestions: [String] = []
        var presentedNames: [String]?
        private var validating = false
        init(onChange: @escaping ([String]) -> Void) { self.onChange = onChange }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let backwards = selector == #selector(NSResponder.deleteBackward(_:))
            let forwards = selector == #selector(NSResponder.deleteForward(_:))
            if (backwards || forwards), Self.isTokenDeletion(textView, backwards: backwards) {
                DispatchQueue.main.async { [weak self, weak control] in
                    guard let self, let field = control as? NSTokenField else { return }
                    self.validateAndCommit(field)
                }
            }
            return false
        }
        static func isTokenDeletion(_ textView: NSTextView, backwards: Bool) -> Bool {
            let text = textView.string as NSString
            var range = textView.selectedRange()
            guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return false }
            if range.length == 0 {
                if backwards {
                    guard range.location > 0 else { return false }
                    range = NSRange(location: range.location - 1, length: 1)
                } else {
                    guard range.location < text.length else { return false }
                    range.length = 1
                }
            }
            return text.substring(with: range).contains("\u{FFFC}")
        }
        private func validateAndCommit(_ field: NSTokenField) {
            validating = true
            field.validateEditing()
            validating = false
            commit(field)
        }
        @objc func commit(_ field: NSTokenField) { onChange(field.objectValue as? [String] ?? []) }
        func controlTextDidEndEditing(_ notification: Notification) {
            if let field = notification.object as? NSTokenField { commit(field) }
        }
        func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
            guard !substring.isEmpty else { return [] }
            return suggestions.filter { $0.range(of: substring, options: [.caseInsensitive, .anchored]) != nil }
        }
        func tokenField(_ tokenField: NSTokenField, shouldAdd tokens: [Any], at index: Int) -> [Any] {
            let normalized = tokens.compactMap { ($0 as? String).flatMap(TagEditor.normalize) }.map { name in
                suggestions.first { $0.compare(name, options: .caseInsensitive) == .orderedSame } ?? name
            }
            if !normalized.isEmpty, !validating {
                DispatchQueue.main.async { [weak self, weak tokenField] in
                    guard let self, let tokenField else { return }
                    self.validateAndCommit(tokenField)
                }
            }
            return normalized
        }
    }
}

/// Requests issued before SwiftUI attaches the field are fulfilled once it has a window.
final class TagInputField: NSTokenField {
    var requestedFocus = 0
    private(set) var fulfilledFocus = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusIfNeeded()
    }
    func focusIfNeeded() {
        guard requestedFocus > fulfilledFocus, let window else { return }
        fulfilledFocus = requestedFocus
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.window === window else { return }
            window?.makeFirstResponder(self)
        }
    }
}

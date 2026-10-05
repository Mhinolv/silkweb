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
        navigate(folder: nil, documents: [], tag: id, changesScope: true)
    }
    func tagState(_ tag: LibraryTag) -> NSControl.StateValue {
        guard let metadata = snapshot?.metadata else { return .off }
        let ids = tagDocumentIDs
        let count = ids.filter { metadata.tagsByDocument[$0.uuidString]?.contains(tag.id) == true }.count
        return count == 0 ? .off : count == ids.count ? .on : .mixed
    }
    /// Outline and Info are two segments of one Inspector; `preview.showsOutline` opens the panel.
    enum InspectorSegment { case outline, info }
    /// The segment on screen, or nil while the Inspector is closed.
    var inspectorSegment: InspectorSegment? { preview.showsOutline ? (inspectorInfo ? .info : .outline) : nil }
    /// Toolbar and ⌘7/⌘8 (#69): open or switch to `segment`, or close the panel when it is already showing.
    func toggleInspector(_ segment: InspectorSegment) {
        if inspectorSegment == segment { preview.showsOutline = false }
        else if segment == .info { showInfo() }
        else { inspectorInfo = false; preview.showsOutline = true }
    }
    /// Opens Info with the tag field focused; never closes the panel (Edit Tags…).
    func showInfo() { inspectorInfo = true; preview.showsOutline = true; tagFocusRequest += 1 }
    func editTags(_ names: [String]) {
        let ids = tagDocumentIDs
        guard let metadata = snapshot?.metadata else { return }
        let updated = TagEditor.edit(names, documents: ids, metadata: metadata)
        guard updated != metadata else { return }
        let oldIDs = TagEditor.commonTags(documents: ids, metadata: metadata)
        let newIDs = TagEditor.commonTags(documents: ids, metadata: updated)
        let removed = oldIDs.subtracting(newIDs), added = newIDs.subtracting(oldIDs)
        let changes = removed.isEmpty ? added : removed
        let changedNames = (metadata.tags + updated.tags).filter { changes.contains($0.id) }.reduce(into: [UUID: String]()) { $0[$1.id] = $1.name }
        let verb = removed.isEmpty ? "Add" : "Remove"
        let title = changedNames.count == 1 ? "Undo \(verb) Tag “\(changedNames.values.first!)”" : "Undo \(verb) Tags"
        changeTags(title: title) { TagEditor.edit(names, documents: ids, metadata: $0) }
    }
    /// Tags on any selected document: true when every selected document has the tag (#72 chips).
    var appliedTagStates: [UUID: Bool] {
        guard let snapshot else { return [:] }
        return TagEditor.appliedTags(documents: tagDocumentIDs, metadata: snapshot.metadata)
    }
    /// Typed, completed and suggested tags. Never removes a tag, even while an earlier edit is still queued.
    func addTags(_ input: [String]) {
        let names = input.compactMap(TagEditor.normalize)
        let ids = tagDocumentIDs
        guard let metadata = snapshot?.metadata, !names.isEmpty,
              TagEditor.add(names, documents: ids, metadata: metadata) != metadata else { return }
        let first = TagEditor.existing(names[0], in: tags)?.name ?? names[0]
        changeTags(title: Set(names.map { $0.lowercased() }).count == 1 ? "Undo Add Tag “\(first)”" : "Undo Add Tags") {
            TagEditor.add(names, documents: ids, metadata: $0)
        }
    }
    /// A chip's ×, ⌫ in the empty field: removes the tag from every selected document, mixed or not.
    func removeTag(_ id: UUID) {
        let ids = tagDocumentIDs
        guard let metadata = snapshot?.metadata, let tag = tags.first(where: { $0.id == id }),
              TagEditor.remove(id, documents: ids, metadata: metadata) != metadata else { return }
        changeTags(title: "Undo Remove Tag “\(tag.name)”") { TagEditor.remove(id, documents: ids, metadata: $0) }
    }
    func toggleTag(_ tag: LibraryTag, paths: Set<String>) {
        guard let snapshot else { return }
        let ids = Set(paths.compactMap { snapshot.metadata.IDsByPath[$0] })
        let common = TagEditor.commonTags(documents: ids, metadata: snapshot.metadata)
        let names = tags.filter { common.contains($0.id) && $0.id != tag.id }.map(\.name)
        changeTags(title: "Undo \(common.contains(tag.id) ? "Remove" : "Add") Tag “\(tag.name)”") {
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
                }.font(.caption).padding(.horizontal, Spacing.small)
            }.frame(height: 28).paneStrip(hairline: .bottom)
        }
    }
}


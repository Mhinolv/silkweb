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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Tags").font(.headline)
                        TagTokenField(names: workspace.commonTagNames, suggestions: workspace.tags.map(\.name),
                                      focusRequest: workspace.tagFocusRequest, enabled: workspace.canEditTags, onChange: workspace.editTags)
                            .frame(minHeight: 28)
                        if !workspace.recentTags.isEmpty {
                            Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 4)
                            RecentTagFlow {
                                ForEach(workspace.recentTags) { tag in
                                    RecentTagPill(tag: tag, state: workspace.tagState(tag), enabled: workspace.canEditTags) {
                                        workspace.toggleTag(tag, paths: workspace.session.selectedDocuments)
                                    }
                                }
                            }
                            .accessibilityElement(children: .contain).accessibilityLabel("Recent tags")
                        }
                        Text("Saved in Silkweb’s index, not in the file.")
                            .font(.caption).foregroundStyle(.tertiary)
                    }
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
    func makeNSView(context: Context) -> TagTokenContainer {
        let container = TagTokenContainer()
        let field = container.field
        field.placeholderString = "Add tags"
        field.tokenizingCharacterSet = CharacterSet(charactersIn: ",\t\n")
        // A controlled nonactivating completion list commits mouse and keyboard identically.
        field.completionDelay = .greatestFiniteMagnitude
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.commit(_:))
        field.setAccessibilityLabel("Tags")
        return container
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TagTokenContainer, context: Context) -> CGSize? {
        let proposedWidth = proposal.width ?? 216
        let width = proposedWidth.isFinite ? proposedWidth : 216
        return CGSize(width: width, height: nsView.measuredHeight(width: width))
    }
    func updateNSView(_ container: TagTokenContainer, context: Context) {
        let field = container.field
        context.coordinator.onChange = onChange
        context.coordinator.suggestions = suggestions
        // Preserve uncommitted input when unrelated workspace state updates the bridge.
        if context.coordinator.presentedNames != names {
            if (field.objectValue as? [String] ?? []) != names { field.objectValue = names }
            context.coordinator.presentedNames = names
        }
        container.needsLayout = true
        field.isEnabled = enabled
        field.requestedFocus = focusRequest
        field.focusIfNeeded()
    }
    final class Coordinator: NSObject, NSTokenFieldDelegate {
        var onChange: ([String]) -> Void
        var suggestions: [String] = []
        var presentedNames: [String]?
        private var validating = false
        init(onChange: @escaping ([String]) -> Void) { self.onChange = onChange }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if let field = control as? TagInputField, field.handleCompletionCommand(selector) { return true }
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
        @objc func commit(_ field: NSTokenField) {
            (field as? TagInputField)?.contentChanged()
            onChange(field.objectValue as? [String] ?? [])
        }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? TagInputField {
                field.contentChanged()
                if let editor = field.currentEditor() as? NSTextView {
                    let prefix = editor.string.components(separatedBy: "\u{FFFC}").last?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    field.showCompletions(suggestions.filter { !$0.isEmpty && !prefix.isEmpty && $0.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil })
                }
            }
        }
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

private final class WrappingTagCell: NSTokenFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect { rect }
}

/// The bezel belongs to the viewport so it never scrolls away with the tokens.
final class TagTokenContainer: NSView {
    let field = TagInputField()
    let scroll = NSScrollView()
    private var visibleHeight: CGFloat = 28
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.cell = WrappingTagCell(textCell: "")
        field.tokenStyle = .rounded
        field.font = .systemFont(ofSize: 13)
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.cell?.usesSingleLineMode = false
        field.cell?.lineBreakMode = .byWordWrapping
        scroll.borderType = .bezelBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .legacy
        scroll.drawsBackground = false
        scroll.documentView = field
        addSubview(scroll)
        focusRingType = .exterior
        field.container = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func measuredHeight(width: CGFloat) -> CGFloat {
        let height = contentHeight(width: width)
        return min(108, 28 + ceil(max(0, height - 28) / 20) * 20)
    }
    private func contentHeight(width: CGFloat) -> CGFloat {
        guard width > 4, let cell = field.cell else { return 28 }
        // Native token-cell measurement includes wrapping and token attachment widths.
        var measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: width - 4, height: 10_000)).height + 4
        if measured > 108 {
            let scrollerWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
            measured = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: max(1, width - 4 - scrollerWidth), height: 10_000)).height + 4
        }
        if let editor = field.currentEditor() as? NSTextView, let manager = editor.layoutManager, let container = editor.textContainer {
            manager.ensureLayout(for: container)
            return max(28, measured, manager.usedRect(for: container).height + 4)
        }
        return max(28, measured)
    }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: visibleHeight) }
    override func layout() {
        super.layout()
        let height = contentHeight(width: bounds.width)
        let next = min(108, 28 + ceil(max(0, height - 28) / 20) * 20)
        if visibleHeight != next {
            visibleHeight = next
            invalidateIntrinsicContentSize()
        }
        scroll.frame = bounds
        field.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: max(scroll.contentSize.height, height - 4))
        // Adding/removing the vertical scroller changes the clip width during tiling.
        scroll.tile()
        field.setFrameSize(NSSize(width: scroll.contentSize.width, height: field.frame.height))
        if let editor = field.currentEditor() as? NSTextView {
            editor.isHorizontallyResizable = false
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.containerSize.width = field.bounds.width
        }
    }
    func contentChanged() {
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let editor = field.currentEditor() as? NSTextView {
            editor.scrollRangeToVisible(editor.selectedRange())
        } else {
            field.scrollToVisible(NSRect(x: 0, y: max(0, field.bounds.height - 20), width: 1, height: 20))
        }
        needsDisplay = true
        noteFocusRingMaskChanged()
    }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        if field.currentEditor() != nil { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }
    }
}

/// Requests issued before SwiftUI attaches the field are fulfilled once it has a window.
final class TagInputField: NSTokenField {
    weak var container: TagTokenContainer?
    var completionRows: [NSButton] = []
    var completionIndex = 0
    let completionPanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    override var objectValue: Any? { didSet { contentChanged() } }
    func contentChanged() { container?.contentChanged() }
    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        if let editor = currentEditor() as? NSTextView { editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0)) }
        contentChanged()
    }
    override func textDidEndEditing(_ notification: Notification) {
        dismissCompletions()
        super.textDidEndEditing(notification)
        contentChanged()
    }
    var requestedFocus = 0
    private(set) var fulfilledFocus = 0
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { dismissCompletions() }
        focusIfNeeded()
    }
    func focusIfNeeded() {
        guard requestedFocus > fulfilledFocus, let window else { return }
        fulfilledFocus = requestedFocus
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.window === window else { return }
            window?.makeFirstResponder(self)
            if let editor = self.currentEditor() as? NSTextView {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }
    }
}

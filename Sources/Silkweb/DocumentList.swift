import AppKit
import SwiftUI
import SilkwebCore

struct DocumentList: View {
    @Bindable var workspace: LibraryWorkspace
    var makeDragProvider: (([String]) -> NSItemProvider)? = nil
    @State private var dateReference = Date()
    var body: some View {
        SearchView(workspace: workspace, search: workspace.search) {
            PinnedColumn {
                TagFilterBar(workspace: workspace)
                if workspace.includesSubfolders {
                    HStack {
                        Text("Including subfolders · \(CountPresentation.label(workspace.documents.count, unit: .document))")
                        Spacer()
                        Button("Show Only This Folder") { workspace.setIncludeSubfolders(false) }.buttonStyle(.borderless)
                    }
                    .font(.caption).monospacedDigit().padding(.horizontal, Spacing.small).frame(height: 28).paneStrip(hairline: .bottom)
                    .accessibilityElement(children: .contain).accessibilityLabel("Including subfolders")
                }
            } content: {
                if workspace.snapshot?.folders.first(where: { $0.relativePath == workspace.session.selectedFolder })?.isUnreadable == true {
                    ColumnEmptyState {
                        ContentUnavailableView("Folder Unavailable", systemImage: "lock",
                                           description: Text("You don't have permission to view this folder."))
                    }
                } else if workspace.documents.isEmpty && !workspace.effectiveTagFilters.isEmpty {
                    ColumnEmptyState {
                        ContentUnavailableView {
                            Label("No Matching Documents", systemImage: "tag")
                        } description: {
                            Text("No documents in “\(workspace.folderName)” have all of these tags.")
                        } actions: {
                            Button("Clear Filters") { workspace.tagFilters = []; workspace.session.selectedTagID = nil }
                        }
                    }
                } else if workspace.documents.isEmpty {
                    ColumnEmptyState {
                        ContentUnavailableView {
                            Label(workspace.snapshot?.documents.isEmpty == true ? "No Documents Yet" : "No Documents", systemImage: "doc.text")
                        } description: {
                            Text(workspace.snapshot?.documents.isEmpty == true ? "Create a document or folder to get started." : "This folder is empty.")
                        } actions: {
                            Button("New Document") { workspace.create(folder: false) }.disabled(!workspace.canMutate)
                            if workspace.snapshot?.documents.isEmpty == true {
                                Button("New Folder") { workspace.create(folder: true) }.disabled(!workspace.canMutate)
                            }
                        }
                    }
                } else {
                    DocumentTable(workspace: workspace, documents: workspace.documents,
                                  dateReference: dateReference, makeDragProvider: makeDragProvider)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in dateReference = Date() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in dateReference = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in dateReference = Date() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in dateReference = Date() }
    }
}

/// Direction A list row (silkweb-1.64): title, `date · location`, two-line excerpt at a fixed 96 pt.
struct DocumentRow: View {
    /// 12 + 17 + 3 + 15 + 3 + 34 + 12: 11 pt padding inside the capsule plus its 1 pt inset on each edge.
    static let height: CGFloat = 96
    /// 12 pt inside the capsule, which sits `Spacing.capsuleInset` from the table edges.
    static let horizontalPadding: CGFloat = Spacing.capsuleInset + 12
    /// Brings the 12 pt excerpt to a 17 pt line height.
    static let excerptLineSpacing = max(0, 17 - NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 12)))

    let document: LibraryDocument
    let root: URL
    let workspace: LibraryWorkspace
    let dateReference: Date
    let pointerState: DocumentRowPointerState
    /// Shown only when the list spans folders; a single-folder scope already names its folder.
    var location: String? = nil
    @Environment(\.locale) private var locale
    @State private var summary: DocumentSummary?
    private var title: String { URL(fileURLWithPath: document.name).deletingPathExtension().lastPathComponent }
    private var sortsByCreated: Bool { workspace.listPreference.key == .created }
    private var date: Date? { sortsByCreated ? document.created : document.modified }
    private var dateText: String? {
        date.map { (sortsByCreated ? "Created " : "") + DocumentRowPresentation.dateLabel($0, now: dateReference, locale: locale) }
    }
    private var excerpt: String { summary?.excerpt ?? "" }
    private var isEmpty: Bool { summary.map { $0.excerpt == "No additional text" } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let item = workspace.rename, item.path == document.relativePath, !item.isFolder {
                // The 24 pt field overhangs the 17 pt title line so the other lines stay put.
                InlineRenameField(item: item, workspace: workspace).frame(height: 24).frame(height: 17)
            } else {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(height: 17)
            }
            HStack(spacing: 0) {
                if let dateText { Text(dateText).fixedSize().layoutPriority(1) }
                if let location {
                    if dateText != nil { Text(" · ").foregroundStyle(.tertiary).fixedSize().layoutPriority(1) }
                    Text(location).truncationMode(.head)
                }
            }
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1).frame(height: 15)
            Text(excerpt)
                .font(.system(size: 12)).lineSpacing(Self.excerptLineSpacing)
                .foregroundStyle(isEmpty ? .tertiary : .secondary)
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 12)
        .contentShape([.interaction, .dragPreview], Rectangle())
        .overlay(DocumentRowClickObserver(path: document.relativePath, workspace: workspace, pointerState: pointerState))
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: workspace.rename?.path == document.relativePath ? .contain : .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
        .task(id: DocumentSummaryIdentity(path: document.relativePath, modified: document.modified)) {
            summary = nil
            summary = await DocumentSummary.load(document: document, root: root)
        }
    }

    /// “modified 10:18 AM, in Vanlife. First sentence.”
    var accessibilityValue: String {
        var parts: [String] = []
        if let date {
            parts.append((sortsByCreated ? "created " : "modified ") + DocumentRowPresentation.dateLabel(date, now: dateReference, locale: locale))
        }
        if let location { parts.append("in " + location) }
        var value = parts.joined(separator: ", ")
        if let summary, !isEmpty {
            let sentence = summary.excerpt.prefix { !".!?。".contains($0) }
            value += (value.isEmpty ? "" : ". ") + sentence
        }
        return value
    }
}

private struct DocumentSummaryIdentity: Hashable {
    let path: String
    let modified: Date?
}

struct DocumentDetail: View {
    let workspace: LibraryWorkspace
    @State private var isNarrow = true
    var body: some View {
        VStack(spacing: 0) {
            if !workspace.tabs.isEmpty { EditorTabBar(workspace: workspace).frame(height: Spacing.tabBarHeight) }
            MediaMigrationBanner(workspace: workspace)
            if workspace.snapshot?.isReadOnly == true {
                Label("This library is read-only. Documents can be viewed, but changes can’t be saved.", systemImage: "lock")
                    .font(.callout).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .padding(.horizontal, 12).paneStrip(hairline: .bottom)
            }
            EditorBanner(session: workspace.editor, workspace: workspace)
            AssetErrorBanner(session: workspace.editor)
            if workspace.editor.url != nil {
                DocumentPanes(workspace: workspace)
                if let progress = workspace.editor.assetProgress {
                    HStack { Text(progress); Spacer() }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
                        .frame(height: 24).paneStrip(hairline: .top)
                }
                if workspace.preview.showsStatusBar {
                    DocumentStatusBar(session: workspace.editor, readOnlyLibrary: workspace.snapshot?.isReadOnly == true, workspace: workspace)
                }
            } else if workspace.session.selectedDocuments.count > 1 {
                ContentUnavailableView("\(workspace.session.selectedDocuments.count) Documents Selected", systemImage: "doc.on.doc")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No Document Selected", systemImage: "doc.text", description: Text("Select a document in the list."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.silkwebPaneBackground.ignoresSafeArea())
        .inspector(isPresented: Binding(get: { workspace.preview.showsOutline }, set: { workspace.preview.showsOutline = $0 })) {
            InspectorView(workspace: workspace).inspectorColumnWidth(min: 200, ideal: 240, max: 320)
        }
        .onChange(of: workspace.editor.text, initial: true) { render() }
        .onChange(of: workspace.editor.url) { render() }
        .onGeometryChange(for: Bool.self) { $0.size.width < 600 } action: { narrow in
            isNarrow = narrow
            if narrow, workspace.preview.mode == .split { workspace.preview.showsOutline = false }
        }
        .onChange(of: workspace.preview.showsOutline) { render() }
        .onChange(of: workspace.root) { render() }
        .onChange(of: workspace.preview.mode) {
            render()
            if isNarrow, workspace.preview.mode == .split { workspace.preview.showsOutline = false }
        }
    }

    private func render() {
        workspace.preview.schedule(text: workspace.editor.text, document: workspace.editor.url, root: workspace.root)
    }
}

/// Writing metrics lead (1.25 fills `statusCounts`); save state trails. Pane surface and one hairline only.
struct DocumentStatusBar: View {
    let session: DocumentSession
    let readOnlyLibrary: Bool
    /// Supplies the Focus/Typewriter chip (1.27).
    var workspace: LibraryWorkspace? = nil

    enum SaveLabel: String {
        case saved = "Saved", edited = "Edited", notSaved = "Not Saved", readOnly = "Read-only"

        init(state: DocumentSaveState, readOnly: Bool) {
            if readOnly { self = .readOnly; return }
            switch state {
            case .clean: self = .saved
            case .dirty, .saving: self = .edited
            // The editor banner explains the failure or conflict.
            case .failed, .conflict: self = .notSaved
            }
        }
    }

    var label: SaveLabel { SaveLabel(state: session.state, readOnly: readOnlyLibrary || session.readOnly) }

    var body: some View {
        HStack(spacing: 0) {
            DocumentStatusCounts(statistics: session.statistics,
                                 showsSelection: workspace?.preview.mode != .preview)
            Spacer(minLength: 8)
            Group {
                if let workspace {
                    WritingModesChip(workspace: workspace).padding(.trailing, 12 - 6)
                }
                Text(label.rawValue)
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(label == .notSaved ? AnyShapeStyle(Color.silkwebCoral) : AnyShapeStyle(.secondary))
                    .fixedSize()
                    .accessibilityLabel("Save state")
                    .accessibilityValue(label.rawValue)
                    .accessibilityIdentifier("statusSaveState")
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, Spacing.medium)
        .frame(height: Spacing.statusBarHeight)
        .paneStrip(hairline: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Status")
        // Saved ⇄ Edited follows typing; announce only failures and their recovery.
        .onChange(of: label) { old, new in
            guard new == .notSaved || old == .notSaved else { return }
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: new.rawValue, .priority: NSAccessibilityPriorityLevel.low.rawValue])
        }
    }
}

/// Leading status-bar counts (silkweb-1.25): `1,204 words · 6,830 characters`, or the selection
/// against the totals. Narrow strips drop the characters segment, then truncate. No animation.
struct DocumentStatusCounts: View {
    let statistics: DocumentStatisticsModel
    /// Preview-only shows document totals only.
    var showsSelection = true

    var body: some View {
        let document = statistics.document
        let selection = showsSelection ? statistics.selection : nil
        let full = document.map { DocumentStatisticsPresentation.label(document: $0, selection: selection) } ?? ""
        let words = document.map { DocumentStatisticsPresentation.label(document: $0, selection: selection, includesCharacters: false) } ?? ""
        ViewThatFits(in: .horizontal) {
            Text(full).fixedSize()
            Text(words).fixedSize()
            Text(words).truncationMode(.tail)
        }
        .lineLimit(1)
        .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel("Document statistics")
        .accessibilityValue(document.map { DocumentStatisticsPresentation.accessibilityValue(document: $0, selection: selection) } ?? "")
        .accessibilityIdentifier("statusCounts")
    }
}

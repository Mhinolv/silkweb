import SilkwebCore
import SwiftUI

struct SearchView<Content: View>: View {
    let workspace: LibraryWorkspace
    @Bindable var search: LibrarySearch
    @FocusState private var fieldFocused: Bool
    @FocusState private var resultsFocused: Bool
    @State private var selected: UUID?
    @ViewBuilder var content: () -> Content

    var body: some View {
        #if DEBUG
            let _ = { search.resultsBodyCount += 1 }()
        #endif
        let results = workspace.filteredSearchResults
        return PinnedColumn {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search Library", text: $search.text)
                    .textFieldStyle(.plain).focused($fieldFocused)
                    .accessibilityLabel("Search Library")
                    .accessibilityIdentifier("library-search")
                    .columnLayoutAnchor("library-search")
                    .onSubmit { openSelected() }
                    .onKeyPress(.downArrow) {
                        selected = selected ?? results.first?.id
                        resultsFocused = true
                        return .handled
                    }
                if !search.text.isEmpty {
                    Button {
                        search.text = ""; search.results = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).help("Clear Search").accessibilityLabel("Clear Search")
                }
            }.padding(.horizontal, Spacing.small).padding(.vertical, 10)
        } content: {
            ZStack(alignment: .top) {
                content()
                    .opacity(search.text.isEmpty ? 1 : 0)
                    .allowsHitTesting(search.text.isEmpty)
                    .accessibilityHidden(!search.text.isEmpty)
                if !search.text.isEmpty {
                    PinnedColumn {
                        TagFilterBar(workspace: workspace)
                        Picker("Search Scope", selection: $search.folderScope) {
                            Text("All Documents").tag(nil as UUID?)
                            if let folder = workspace.selectedFolder {
                                Text("“\(folder.name)”").tag(Optional(folder.id))
                            }
                        }.pickerStyle(.segmented).padding(.horizontal, 8).padding(.bottom, 8)
                        HStack(spacing: 4) {
                            if search.isSearching { ProgressView().controlSize(.small) }
                            Text(LibrarySearch.resultCount(results.count))
                        }
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(
                            maxWidth: .infinity, alignment: .leading
                        ).padding(.horizontal, 8)
                    } content: {
                        VStack(spacing: 0) {
                            if results.isEmpty && !search.hasPendingQuery {
                                ColumnEmptyState {
                                    VStack(spacing: 8) {
                                        ContentUnavailableView.search(text: search.text)
                                        if search.folderScope != nil {
                                            Button("Search All Documents") { search.folderScope = nil }
                                        }
                                    }
                                }
                            } else {
                                List(results, selection: $selected) { result in
                                    Button {
                                        selected = result.id
                                        let query = search.text
                                        Task { await workspace.openSearchResult(result, findText: query) }
                                    } label: {
                                        SearchResultRow(result: result, query: search.resultText)
                                            .padding(.horizontal, 12)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background {
                                                if selected == result.id {
                                                    SearchResultCapsule(focused: resultsFocused)
                                                }
                                            }
                                            .padding(.horizontal, Spacing.capsuleInset - SearchResultCapsule.cellInset)
                                            .padding(.vertical, 1)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .tag(result.id)
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .background(SelectionHighlightSuppressor())
                                }
                                .listStyle(.plain)
                                // The flat Surface (1.67): no list material behind or below the rows.
                                .scrollContentBackground(.hidden)
                                .background(Color.silkwebPaneBackground)
                                .focused($resultsFocused)
                                .onKeyPress(.return) {
                                    openSelected(); return .handled
                                }
                            }
                            if let note = search.error ?? search.indexingNote {
                                Text(note).font(.caption).foregroundStyle(.secondary).padding(8).frame(
                                    maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(Color.silkwebPaneBackground)
                }
            }
        }
        .onChange(of: search.focusRequest) { fieldFocused = true }
        .onChange(of: search.text) { old, new in
            if old.isEmpty, !new.isEmpty { search.folderScope = workspace.selectedFolder?.id }
            selected = nil
            if new.isEmpty { search.results = [] }
        }
        .onChange(of: workspace.session.selectedFolder) { search.folderScope = workspace.selectedFolder?.id }
        .onChange(of: results) { selected = SearchNavigation.selection(selected, in: results) }
        .onChange(of: search.resultText) { selected = results.first?.id }
        .onExitCommand {
            search.text = ""; search.results = []
        }
        .task(id: SearchRequestIdentity(text: search.text, scope: search.folderScope, revision: search.revision)) {
            if !search.text.isEmpty { await search.query(quick: false) }
        }
    }

    private func openSelected() {
        Task { [selected] in await workspace.openSearchSelection(selected, quick: false) }
    }
}

struct SearchRequestIdentity: Hashable {
    let text: String
    var scope: UUID? = nil
    let revision: Int
}

/// Same metrics as `DocumentRow` (silkweb-1.64); the excerpt is the match context.
struct SearchResultRow: View {
    let result: SearchResult
    let query: String
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(
                SearchPresentation.highlight(
                    result.displayName, query: query, font: .system(size: 13, weight: .semibold))
            )
            .font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(height: 17)
            HStack(spacing: 0) {
                if let modified = result.modified {
                    Text(DocumentRowPresentation.dateLabel(modified, locale: locale)).fixedSize().layoutPriority(1)
                    Text(" · ").foregroundStyle(.tertiary).fixedSize().layoutPriority(1)
                }
                Text(SearchPresentation.path(result.folderPathComponents)).truncationMode(.head)
            }.font(.subheadline).foregroundStyle(.secondary).lineLimit(1).frame(height: 15)
            Text(SearchPresentation.highlight(result.snippet, ranges: result.matchRanges, font: .system(size: 12)))
                .font(.system(size: 12)).lineSpacing(DocumentRow.excerptLineSpacing).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
        }
        // 11 pt inside the 1 pt-inset capsule: the 96 pt `DocumentRow` height.
        .padding(.vertical, 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.displayName), in \(SearchPresentation.path(result.folderPathComponents))")
        .accessibilityValue(result.snippet)
    }
}

/// The document list's selection capsule (1.62) behind a search result, in place of the system highlight.
struct SearchResultCapsule: View {
    /// A plain List places its cells this far in from the table edges, even with zero row insets.
    static let cellInset: CGFloat = 8
    let focused: Bool
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let style = CapsuleStyle.fill(
            isKey: appearsActive, isFocused: focused,
            contrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        let shape = RoundedRectangle(cornerRadius: 8)
        shape.fill(style.tintsAccessories ? Color.silkwebSelection : Color.silkwebSelectionInactive)
            .overlay { if style.stroke != nil { shape.strokeBorder(Color.silkwebAccent, lineWidth: 1) } }
    }
}

/// Turns off the hosting table's own selection fill so only the capsule shows; selection itself is unchanged.
/// Search results and the Outline (#90).
struct SelectionHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.suppress() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            suppress()
        }

        func suppress() {
            var ancestor = superview
            while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
            if let table = ancestor as? NSTableView, table.selectionHighlightStyle != .none {
                table.selectionHighlightStyle = .none
            }
        }
    }
}

/// Convert model UTF-16 ranges only for visible rows, never per document during queries.
enum SearchPresentation {
    static func path(_ components: [String]) -> String {
        components.isEmpty ? "Library" : components.joined(separator: " › ")
    }

    static func highlight(_ text: String, query: String, font: Font = .body) -> AttributedString {
        highlight(text, ranges: SearchNavigation.matchRanges(in: text, query: query), font: font)
    }

    static func highlight(_ text: String, ranges: [NSRange], font: Font = .body) -> AttributedString {
        var value = AttributedString(text)
        for range in ranges {
            guard let stringRange = Range(range, in: text),
                let attributedRange = Range(stringRange, in: value)
            else { continue }
            value[attributedRange].font = font.weight(.semibold)
            value[attributedRange].foregroundColor = .primary
        }
        return value
    }
}

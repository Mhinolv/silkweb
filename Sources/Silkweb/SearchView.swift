import SwiftUI
import SilkwebCore

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
                    .accessibilityIdentifier("library-search")
                    .columnLayoutAnchor("library-search")
                    .onSubmit { openSelected() }
                    .onKeyPress(.downArrow) {
                        selected = selected ?? results.first?.id
                        resultsFocused = true
                        return .handled
                    }
                if !search.text.isEmpty {
                    Button { search.text = ""; search.results = [] } label: { Image(systemName: "xmark.circle.fill") }
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
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8)
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
                                        openSelected()
                                    } label: {
                                        SearchResultRow(result: result, query: search.resultText)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .tag(result.id)
                                }
                                .focused($resultsFocused)
                                .onKeyPress(.return) { openSelected(); return .handled }
                            }
                            if let note = search.error ?? search.indexingNote {
                                Text(note).font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
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
        .onExitCommand { search.text = ""; search.results = [] }
        .task(id: SearchRequestIdentity(text: search.text, scope: search.folderScope, revision: search.revision)) {
            if !search.text.isEmpty { await search.query(quick: false) }
        }
    }

    private func openSelected() {
        guard let result = workspace.filteredSearchResults.first(where: { $0.id == selected }) ?? workspace.filteredSearchResults.first else { return }
        let query = search.text
        Task { await workspace.openSearchResult(result, findText: query) }
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
            Text(SearchPresentation.highlight(result.displayName, query: query, font: .system(size: 13, weight: .semibold)))
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
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(result.displayName), in \(SearchPresentation.path(result.folderPathComponents))")
        .accessibilityValue(result.snippet)
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
                  let attributedRange = Range(stringRange, in: value) else { continue }
            value[attributedRange].font = font.weight(.semibold)
            value[attributedRange].foregroundColor = .primary
        }
        return value
    }
}

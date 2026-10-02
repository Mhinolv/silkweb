import SwiftUI
import SilkwebCore

struct QuickOpenPanel: View {
    let workspace: LibraryWorkspace
    @FocusState private var fieldFocused: Bool
    @State private var selected: UUID?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Button { workspace.search.dismissQuickOpen() } label: { Color.clear.contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss Quick Open")
                panel
                    .frame(width: 560)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 12, y: 4)
                    .padding(.top, geometry.size.height * 0.2)
            }
        }
        .onExitCommand { workspace.search.dismissQuickOpen() }
        .task(id: SearchRequestIdentity(text: workspace.search.quickText, revision: workspace.search.revision)) {
            await workspace.search.query(quick: true)
        }
        .onChange(of: workspace.search.quickResults) { selected = workspace.search.quickResults.first?.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Open")
        .accessibilityAddTraits(.isModal)
    }

    private var panel: some View {
        @Bindable var search = workspace.search
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Open a document by name", text: $search.quickText)
                    .font(.title3).textFieldStyle(.plain).focused($fieldFocused)
                    .onSubmit { openSelected() }
                    .onKeyPress(.return, phases: .down) { event in
                        guard event.modifiers.contains(.command) else { return .ignored }
                        openSelected(pinned: true); return .handled
                    }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.downArrow) { move(1); return .handled }
            }.padding(16)
            Divider()
            if search.quickText.isEmpty {
                Text("Recent").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.top, 8)
            }
            if search.quickResults.isEmpty {
                Text(search.error ?? (search.quickText.isEmpty ? "No recent documents" : "No documents named “\(search.quickText)”"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            } else {
                ForEach(search.quickResults) { result in
                    Button {
                        selected = result.id
                        openSelected()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text").foregroundStyle(.secondary)
                            Text(SearchPresentation.highlight(result.displayName, query: search.quickText)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(SearchPresentation.path(result.folderPathComponents))
                                .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                        }
                        .padding(.horizontal, 16).frame(height: 32).frame(maxWidth: .infinity, alignment: .leading)
                        .background(selected == result.id ? Color.accentColor.opacity(0.18) : Color.clear)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .accessibilityLabel("\(result.displayName), in \(SearchPresentation.path(result.folderPathComponents))")
                    .accessibilityAddTraits(selected == result.id ? .isSelected : [])
                }
            }
        }
        .padding(.bottom, 8)
        .defaultFocus($fieldFocused, true)
    }

    private func move(_ delta: Int) {
        let results = workspace.search.quickResults
        let current = results.firstIndex { $0.id == selected }
        selected = SearchNavigation.nextIndex(current: current, count: results.count, delta: delta).map { results[$0].id }
    }

    private func openSelected(pinned: Bool = false) {
        guard let result = workspace.search.quickResults.first(where: { $0.id == selected }) ?? workspace.search.quickResults.first else { return }
        Task { await workspace.openSearchResult(result, pinned: pinned) }
    }
}

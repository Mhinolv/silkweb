import AppKit
import SilkwebCore
import SwiftUI

/// The welcome screen's Recent Libraries (#195): up to five of Open Recent's entries. Click or Return adds the
/// Library as a sidebar section; a folder that is gone is dimmed with “Not found”.
struct WelcomeRecents: View {
    static let maximumRows = 5
    static let rowHeight: CGFloat = 36
    static let width: CGFloat = 464

    let registry: LibraryWindowRegistry
    /// Paths checked off the main thread; a disconnected volume never stalls the window.
    @State private var missing: Set<String> = []
    @State private var hovered: String?
    @State private var selected: Int?
    @FocusState private var focused: Bool

    private var items: [RecentLibraryItem] { Array(registry.recentItems().prefix(Self.maximumRows)) }

    var body: some View {
        let items = items
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent Libraries").font(.headline).foregroundStyle(.secondary).padding(.leading, 8)
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.path) { index, item in
                    row(item, selected: focused && selected == index)
                        .onHover { hovered = $0 ? item.path : (hovered == item.path ? nil : hovered) }
                        .onTapGesture { open(item) }
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onChange(of: focused) { if focused, selected == nil, !items.isEmpty { selected = 0 } }
            .onKeyPress(.downArrow) { move(1, count: items.count) }
            .onKeyPress(.upArrow) { move(-1, count: items.count) }
            .onKeyPress(.return) {
                guard let selected, items.indices.contains(selected) else { return .ignored }
                open(items[selected])
                return .handled
            }
        }
        .frame(width: Self.width, alignment: .leading)
        .task(id: items.map(\.path)) {
            let paths = items.map(\.path)
            missing = await Task.detached(priority: .utility) {
                Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            }.value
        }
    }

    private func move(_ step: Int, count: Int) -> KeyPress.Result {
        guard count > 0 else { return .ignored }
        selected = min(max((selected ?? -step) + step, 0), count - 1)
        return .handled
    }

    private func open(_ item: RecentLibraryItem) {
        Task { await registry.openRecent(item.path) }
    }

    private func row(_ item: RecentLibraryItem, selected: Bool) -> some View {
        let isMissing = missing.contains(item.path)
        let parent = (URL(fileURLWithPath: item.path).deletingLastPathComponent().path as NSString)
            .abbreviatingWithTildeInPath
        return HStack(spacing: 10) {
            Image(systemName: "books.vertical").foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 13))
                    .foregroundStyle(isMissing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                Text(isMissing ? "Not found" : parent).font(.system(size: 11))
                    .foregroundStyle(isMissing ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .truncationMode(.middle)
            }
            .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .contentShape(Rectangle())
        .background {
            if selected || hovered == item.path {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.silkwebSelection : Color.silkwebSelectionInactive)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.path)
        .accessibilityHint("Opens the library")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open(item) }
    }
}

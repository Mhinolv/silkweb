import SwiftUI
import SilkwebCore

/// Additional document sections can join the outline here without changing the detail panes.
struct InspectorView: View {
    let workspace: LibraryWorkspace
    @State private var selectedHeading: String?
    private var preview: PreviewCoordinator { workspace.preview }
    var body: some View {
        let current = preview.currentHeading(caret: workspace.editor.caretLocation)
        let shallowest = preview.headings.map(\.level).min() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            Text("Outline").font(.headline).padding(12)
            Divider()
            if preview.headings.isEmpty {
                ContentUnavailableView("No Headings", systemImage: "list.bullet.indent", description: Text("Start a line with # to add a heading."))
            } else {
                List(selection: $selectedHeading) {
                    Section("Headings") {
                        ForEach(preview.headings, id: \.id) { heading in
                            Button {
                                selectedHeading = heading.id
                                preview.navigate(heading)
                            } label: {
                                row(heading, current: current == heading.id, shallowest: shallowest)
                                    .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).tag(heading.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .onKeyPress(.return) {
                    guard let heading = preview.headings.first(where: { $0.id == selectedHeading }) else { return .ignored }
                    preview.navigate(heading)
                    return .handled
                }
                .accessibilityLabel("Heading outline")
            }
        }
    }

    private func row(_ heading: MarkdownHeading, current: Bool, shallowest: Int) -> some View {
        return HStack(spacing: 8) {
            Rectangle().fill(current ? Color.accentColor : .clear).frame(width: 3)
            Text(heading.text).font(heading.level <= 2 ? .body : .callout)
                .foregroundStyle(current || heading.level <= 2 ? .primary : .secondary)
                .lineLimit(1).truncationMode(.tail)
                .padding(.leading, CGFloat(heading.level - shallowest) * 12)
        }
        .help(heading.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heading level \(heading.level), \(heading.text)")
        .accessibilityValue(current ? "current" : "")
    }
}

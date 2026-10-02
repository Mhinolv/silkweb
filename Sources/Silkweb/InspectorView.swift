import SwiftUI
import SilkwebCore

/// Additional document sections can join the outline here without changing the detail panes.
struct InspectorView: View {
    let workspace: LibraryWorkspace
    @State private var selectedHeading: String?
    @State private var outlineHovered = false
    @State private var manualScrollUntil = Date.distantPast
    @FocusState private var outlineFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var preview: PreviewCoordinator { workspace.preview }

    private struct ScrollRequest: Equatable {
        let heading: String?
        let resume: Date
    }
    var body: some View {
        let current = preview.currentHeading(caret: workspace.editor.caretLocation)
        let shallowest = preview.headings.map(\.level).min() ?? 1
        return PinnedColumn {
            Text("Outline").font(.headline).columnLayoutAnchor("outline-title")
                .padding(12).accessibilityIdentifier("outline-title")
            if !preview.headings.isEmpty {
                Text(CountPresentation.label(preview.headings.count, unit: .heading))
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(height: 28)
            }
            Divider()
        } content: {
            if preview.headings.isEmpty {
                ColumnEmptyState {
                    ContentUnavailableView("No Headings", systemImage: "list.bullet.indent", description: Text("Start a line with # to add a heading."))
                }
            } else {
                ScrollViewReader { proxy in
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
                                .buttonStyle(.plain).tag(heading.id).id(heading.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .environment(\.defaultMinListRowHeight, 1)
                    .focused($outlineFocused)
                    .onHover { outlineHovered = $0 }
                    // Native live-scroll notifications do not fire for programmatic scrolling.
                    .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification)) { _ in
                        if outlineHovered { manualScrollUntil = .distantFuture }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didEndLiveScrollNotification)) { _ in
                        if manualScrollUntil == .distantFuture { manualScrollUntil = Date().addingTimeInterval(2) }
                    }
                    .task(id: ScrollRequest(heading: current, resume: manualScrollUntil)) {
                        guard let current, manualScrollUntil != .distantFuture else { return }
                        let delay = manualScrollUntil.timeIntervalSinceNow
                        if delay > 0 {
                            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                        }
                        guard !Task.isCancelled else { return }
                        // With no anchor, ScrollViewReader moves only enough to reveal the row.
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(current) }
                    }
                    .onChange(of: preview.renderedURL) {
                        selectedHeading = nil
                        manualScrollUntil = .distantPast
                    }
                    .onKeyPress(.return) {
                        guard let heading = preview.headings.first(where: { $0.id == selectedHeading }) else { return .ignored }
                        preview.navigate(heading)
                        return .handled
                    }
                    .accessibilityLabel("Heading outline")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ heading: MarkdownHeading, current: Bool, shallowest: Int) -> some View {
        let style = OutlineRowStyle(level: heading.level, shallowest: shallowest,
                                    isFirst: heading.id == preview.headings.first?.id)
        let selected = outlineFocused && selectedHeading == heading.id
        return HStack(spacing: 8) {
            Rectangle().fill(current && !selected ? Color.accentColor : .clear).frame(width: 3)
            Text(heading.text).font(.system(size: style.fontSize, weight: style.isSemibold ? .semibold : .regular))
                .foregroundStyle(selected ? Color(nsColor: .alternateSelectedControlTextColor) :
                                    Color(nsColor: current || heading.level <= 2 ? .labelColor : .secondaryLabelColor))
                .lineLimit(1).truncationMode(.middle)
                .padding(.leading, style.indent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .background {
            if current && !selected {
                RoundedRectangle(cornerRadius: 4).fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
            }
        }
        .padding(.top, style.spacingAbove)
        .help(heading.text)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heading level \(heading.level), \(heading.text)")
        .accessibilityValue(current ? "current" : "")
    }
}

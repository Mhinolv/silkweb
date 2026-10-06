import SilkwebCore
import SwiftUI

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
        VStack(spacing: 0) {
            Picker(
                "Inspector", selection: Binding(get: { workspace.inspectorInfo }, set: { workspace.inspectorInfo = $0 })
            ) {
                Text("Outline").tag(false)
                Text("Info").tag(true)
            }.pickerStyle(.segmented).labelsHidden().columnLayoutAnchor("outline-title").padding(12)
            if workspace.inspectorInfo {
                DocumentInfo(workspace: workspace).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                outline
            }
        }
        .background(Color.silkwebPaneBackground.ignoresSafeArea())
        // Esc returns keyboard focus to the document (#89). Text fields handle their own Esc first.
        .onKeyPress(.escape) { preview.focusDocument() ? .handled : .ignored }
    }
    private var outline: some View {
        // Until the editor catches up with a list click (#87), the caret belongs to another note.
        let followsEditor = preview.outlineURL == workspace.editor.url && !preview.outlinePending
        let current = followsEditor ? preview.currentItem(caret: workspace.editor.caretLocation) : nil
        // #90: one capsule, on the keyboard selection while the Outline is focused, else on the caret's section.
        let highlight = outlineFocused ? selectedHeading ?? current : current
        let items =
            preview.outlineItems.isEmpty ? OutlineItem.parse("", headings: preview.headings) : preview.outlineItems
        let imageCount = items.count - preview.headings.count
        let summary = [(preview.headings.count, CountPresentation.Unit.heading), (imageCount, .image)]
            .filter { $0.0 > 0 }.map { CountPresentation.label($0.0, unit: $0.1) }.joined(separator: " · ")
        return PinnedColumn {
            if !items.isEmpty {
                Text(summary)
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    .padding(.horizontal, 12).frame(height: 28)
            }
            Divider()
        } content: {
            if items.isEmpty {
                ColumnEmptyState {
                    ContentUnavailableView(
                        "No Headings", systemImage: "list.bullet.indent",
                        description: Text("Start a line with # to add a heading."))
                }
            } else {
                ScrollViewReader { proxy in
                    let threads = OutlineRowStyle.threads(depths: items.map(\.depth))
                    List(selection: $selectedHeading) {
                        ForEach(Array(zip(items, threads).enumerated()), id: \.offset) { position, pair in
                            let (item, thread) = pair
                            let highlighted = highlight == item.id
                            Button {
                                // A click jumps and focuses the editor (owner decision #89, replacing #72's
                                // focused Outline). The caret is then in the clicked section, so ↑/↓ resume
                                // there once the Outline is focused again (Tab or a click on its background).
                                guard followsEditor else { return }
                                selectedHeading = item.id
                                preview.navigate(item)
                            } label: {
                                Group {
                                    switch item.content {
                                    case .heading(let heading):
                                        row(
                                            heading, depth: item.depth, current: current == item.id,
                                            highlighted: highlighted)
                                    case .image:
                                        OutlineImageRow(
                                            item: item, document: preview.outlineURL, root: workspace.root,
                                            current: current == item.id, highlighted: highlighted)
                                    }
                                }
                                .outlineRowChrome(thread: thread, indent: item.indent, highlighted: highlighted)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).tag(item.id).id(position)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            // #90: only Silkweb's capsule shows; the List's system-accent fill never does.
                            .background(SelectionHighlightSuppressor())
                        }
                    }
                    .listStyle(.sidebar)
                    .scrollContentBackground(.hidden)
                    .environment(\.defaultMinListRowHeight, 1)
                    // A large note still parsing: the previous rows must not look current.
                    .opacity(preview.outlinePending ? 0.4 : 1)
                    .allowsHitTesting(!preview.outlinePending)
                    .focused($outlineFocused)
                    .onHover { outlineHovered = $0 }
                    // Native live-scroll notifications do not fire for programmatic scrolling.
                    .onReceive(NotificationCenter.default.publisher(for: NSScrollView.willStartLiveScrollNotification))
                    { _ in
                        if outlineHovered { manualScrollUntil = .distantFuture }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSScrollView.didEndLiveScrollNotification)) {
                        _ in
                        if manualScrollUntil == .distantFuture { manualScrollUntil = Date().addingTimeInterval(2) }
                    }
                    .task(id: ScrollRequest(heading: current, resume: manualScrollUntil)) {
                        guard let target = items.firstIndex(where: { $0.id == current }),
                            manualScrollUntil != .distantFuture
                        else { return }
                        let delay = manualScrollUntil.timeIntervalSinceNow
                        if delay > 0 {
                            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                        }
                        guard !Task.isCancelled else { return }
                        // With no anchor, ScrollViewReader moves only enough to reveal the row.
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo(target) }
                    }
                    .onChange(of: preview.outlineURL) {
                        selectedHeading = nil
                        manualScrollUntil = .distantPast
                        // A new note starts at the top with no scroll animation (#87). Rows are identified by
                        // position, so the List reuses them instead of rebuilding on every switch.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(0, anchor: .top) }
                    }
                    .onChange(of: items.map(\.id)) { _, ids in
                        if let selectedHeading, !ids.contains(selectedHeading) { self.selectedHeading = nil }
                    }
                    .onChange(of: outlineFocused) { _, focused in
                        // Tab into the Outline starts at the current row; leaving it drops the keyboard
                        // selection, so the capsule returns to the caret's section (#90).
                        selectedHeading = focused ? current ?? selectedHeading ?? items.first?.id : nil
                    }
                    .onKeyPress(.return) {
                        guard followsEditor, let item = items.first(where: { $0.id == selectedHeading }) else {
                            return .ignored
                        }
                        preview.navigate(item, focusEditor: false)
                        return .handled
                    }
                    .accessibilityLabel("Heading outline")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ heading: MarkdownHeading, depth: Int, current: Bool, highlighted: Bool) -> some View {
        let style = OutlineRowStyle(level: heading.level, depth: depth)
        return Text(heading.text)
            .font(.system(size: OutlineRowStyle.fontSize, weight: style.isSemibold ? .semibold : .regular))
            .foregroundStyle(
                Color(nsColor: highlighted || current || !style.isSecondary ? .labelColor : .secondaryLabelColor)
            )
            .lineLimit(1).truncationMode(.tail)
            .help(heading.text)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Heading level \(heading.level), \(heading.text)")
            .accessibilityValue(current ? "current" : "")
    }
}

/// #72 thread tree: a fixed-height row hanging from the sidebar's 1.5 pt `SilkwebThread` guides, with the
/// highlighted row on the sidebar's capsule (#90): `SilkwebSelection` in the key window, focused or not, and
/// `SilkwebSelectionInactive` in a background window. The List's own selection fill is suppressed.
struct OutlineRowChrome: ViewModifier {
    static let leading: CGFloat = 6
    static let trailing: CGFloat = 8
    let thread: OutlineRowStyle.Thread
    let indent: Double
    let highlighted: Bool
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.controlActiveState) private var activeState

    func body(content: Content) -> some View {
        content
            .padding(.leading, indent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Self.leading).padding(.trailing, Self.trailing)
            .frame(height: OutlineRowStyle.rowHeight)
            .background {
                ZStack(alignment: .leading) {
                    if highlighted {
                        let key = activeState == .key
                        RoundedRectangle(cornerRadius: 6)
                            .fill(key ? Color.silkwebSelection : Color.silkwebSelectionInactive)
                        if key && contrast == .increased {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(Color.silkwebAccent, lineWidth: 1)
                        }
                    }
                    OutlineThreadShape(thread: thread)
                        .stroke(
                            Color.silkwebThread, style: StrokeStyle(lineWidth: 1.5, lineCap: .butt, lineJoin: .round)
                        )
                        .padding(.leading, Self.leading)
                        .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func outlineRowChrome(thread: OutlineRowStyle.Thread, indent: Double, highlighted: Bool) -> some View {
        modifier(OutlineRowChrome(thread: thread, indent: indent, highlighted: highlighted))
    }
}

/// The same rails and rounded elbows as `ThreadRowView`, in row coordinates with y running down.
struct OutlineThreadShape: Shape {
    let thread: OutlineRowStyle.Thread

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for segment in thread.segments(rowHeight: rect.height) {
            switch segment {
            case .rail(let x):
                path.move(to: CGPoint(x: rect.minX + x, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.minX + x, y: rect.maxY))
            case .elbow(let x, let cornerY, let radius, let endX):
                let k = 0.5523 * radius // Quarter-circle control distance.
                let x = rect.minX + x, y = rect.minY + cornerY
                path.move(to: CGPoint(x: x, y: rect.minY))
                path.addLine(to: CGPoint(x: x, y: y - radius))
                path.addCurve(
                    to: CGPoint(x: x + radius, y: y), control1: CGPoint(x: x, y: y - radius + k),
                    control2: CGPoint(x: x + radius - k, y: y))
                path.addLine(to: CGPoint(x: rect.minX + endX, y: y))
            }
        }
        return path
    }
}

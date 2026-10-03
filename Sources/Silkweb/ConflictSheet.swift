import AppKit
import SwiftUI

struct ConflictSheet: View {
    let session: DocumentSession
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Your Version (not saved)").frame(maxWidth: .infinity, alignment: .leading)
                Text("Version on Disk" + (session.diskModified.map { " · modified " + $0.formatted(date: .omitted, time: .shortened) } ?? ""))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.font(.headline)
            ConflictComparison(mine: session.text, disk: session.diskText ?? "")
            HStack {
                Spacer()
                Button("Cancel") { session.showingComparison = false }.keyboardShortcut(.cancelAction)
                Button("Use Disk Version") { Task { await session.resolveConflict(keepMine: false) } }
                Button("Keep My Version") { Task { await session.resolveConflict(keepMine: true) } }.keyboardShortcut(.defaultAction)
            }.disabled(session.loading)
        }.padding(20).frame(width: 760, height: 520)
    }
}

struct ConflictComparison: NSViewRepresentable {
    let mine: String
    let disk: String
    func makeCoordinator() -> ConflictComparisonViews { ConflictComparisonViews() }
    func makeNSView(context: Context) -> NSStackView { context.coordinator.stack }
    func updateNSView(_ view: NSStackView, context: Context) { context.coordinator.load(mine: mine, disk: disk) }
}

/// Synchronize AppKit clip views directly, without publishing scroll state per frame.
@MainActor final class ConflictComparisonViews {
    let stack = NSStackView()
    let panes: [NSScrollView]
    private var observers: [NSObjectProtocol] = []
    private var synchronizing = false
    init() {
        panes = ["Your version", "Version on disk"].map { label in
            let scroll = MarkdownTextView.makeEditorScrollView(style: EditorStyle(fontSize: 13, lineHeight: 1.2, horizontalInset: 12, topInset: 12), followsSettings: false)
            let text = scroll.documentView as! NSTextView
            text.isEditable = false
            text.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
            text.setAccessibilityLabel(label)
            scroll.contentView.postsBoundsChangedNotifications = true
            return scroll
        }
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 16
        for pane in panes { stack.addArrangedSubview(pane) }
        for index in panes.indices {
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: panes[index].contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.synchronize(from: index) }
            })
        }
    }
    func load(mine: String, disk: String) {
        for (pane, value) in zip(panes, [mine, disk]) {
            let text = pane.documentView as! NSTextView
            if text.string != value { text.string = value; text.undoManager?.removeAllActions() }
        }
    }
    func synchronize(from index: Int) {
        guard !synchronizing else { return }
        synchronizing = true
        defer { synchronizing = false }
        let source = panes[index]
        let target = panes[1 - index]
        let sourceHeight = max(1, (source.documentView?.bounds.height ?? 0) - source.contentSize.height)
        let targetHeight = max(0, (target.documentView?.bounds.height ?? 0) - target.contentSize.height)
        let fraction = min(1, max(0, source.contentView.bounds.minY / sourceHeight))
        target.contentView.scroll(to: NSPoint(x: 0, y: fraction * targetHeight))
        target.reflectScrolledClipView(target.contentView)
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}

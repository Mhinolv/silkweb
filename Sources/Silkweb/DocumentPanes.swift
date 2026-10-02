import AppKit
import SwiftUI

/// Both hosted views remain alive when collapsed, preserving the editor's undo manager.
struct DocumentPanes: NSViewControllerRepresentable {
    let workspace: LibraryWorkspace
    func makeNSViewController(context: Context) -> DocumentPanesController { DocumentPanesController(workspace: workspace) }
    func updateNSViewController(_ controller: DocumentPanesController, context: Context) { controller.updateMode() }
}

final class DocumentPanesController: NSSplitViewController {
    let workspace: LibraryWorkspace
    private var installedMode: DocumentViewMode?
    private var resizeObserver: NSObjectProtocol?
    private var saveTask: Task<Void, Never>?
    private var applying = false
    private var pendingRatio: Double?

    init(workspace: LibraryWorkspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        let editor = NSHostingController(rootView: TabEditorContent(workspace: workspace))
        let preview = NSHostingController(rootView: PreviewView(workspace: workspace))
        editor.sizingOptions = []; preview.sizingOptions = []
        for controller in [editor as NSViewController, preview as NSViewController] {
            let item = NSSplitViewItem(viewController: controller)
            item.canCollapse = true
            item.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
            addSplitViewItem(item)
        }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: splitView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resized() }
        }
        updateMode()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit {
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        saveTask?.cancel()
    }

    func updateMode() {
        let mode = workspace.preview.mode
        guard installedMode != mode else { return }
        if installedMode == .split { persistRatio() }
        saveTask?.cancel()
        pendingRatio = nil
        applying = true
        defer { applying = false }
        installedMode = mode
        for item in splitViewItems { item.minimumThickness = mode == .split ? 280 : 0 }
        splitViewItems[0].isCollapsed = mode == .preview
        splitViewItems[1].isCollapsed = mode == .editor
        if mode == .split {
            let saved = workspace.preview.defaults.double(forKey: "Silkweb.Detail.SplitRatio")
            let ratio = saved > 0 && saved < 1 ? saved : 0.5
            if splitView.bounds.width > 0 { splitView.setPosition(splitView.bounds.width * ratio, ofDividerAt: 0) }
            else { pendingRatio = ratio }
        }
    }

    private func resized() {
        guard !applying, installedMode == .split, splitView.bounds.width > 0 else { return }
        if let ratio = pendingRatio {
            pendingRatio = nil
            applying = true
            splitView.setPosition(splitView.bounds.width * ratio, ofDividerAt: 0)
            applying = false
        }
        saveTask?.cancel()
        // Persist after a drag/resize settles; do not publish state on gesture frames.
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, self.installedMode == .split else { return }
            self.persistRatio()
        }
    }

    private func persistRatio() {
        let width = splitView.bounds.width - splitView.dividerThickness
        guard width > 0 else { return }
        let ratio = splitView.arrangedSubviews[0].frame.width / width
        guard ratio > 0 && ratio < 1 else { return }
        workspace.preview.defaults.set(ratio, forKey: "Silkweb.Detail.SplitRatio")
    }
}

/// Stable SwiftUI identities keep each native editor and its undo stack alive across activation.
struct TabEditorContent: View {
    let workspace: LibraryWorkspace
    var body: some View {
        ZStack {
            if workspace.tabs.isEmpty {
                MarkdownTextView(session: workspace.editor, workspace: workspace)
            }
            ForEach(workspace.tabs) { tab in
                MarkdownTextView(session: tab.editor, workspace: workspace)
                    .opacity(workspace.activeTabID == tab.id ? 1 : 0)
                    .allowsHitTesting(workspace.activeTabID == tab.id)
                    .accessibilityHidden(workspace.activeTabID != tab.id)
            }
        }
    }
}

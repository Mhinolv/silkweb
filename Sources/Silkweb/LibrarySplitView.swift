import AppKit
import SwiftUI
import QuartzCore

/// SwiftUI's column width hints do not control which pane absorbs a resize.
/// AppKit owns the dividers; the hosted panes keep their existing observation and focus.
struct LibrarySplitView: NSViewControllerRepresentable {
    let workspace: LibraryWorkspace

    func makeNSViewController(context: Context) -> LibrarySplitViewController {
        LibrarySplitViewController(workspace: workspace, autosaveName: workspace.columnAutosaveName)
    }

    func updateNSViewController(_ controller: LibrarySplitViewController, context: Context) {
        controller.updateRequests()
    }
}

final class LibrarySplitViewController: NSSplitViewController {
    private static let baseConstrainsSplitPosition = NSSplitViewController.instancesRespond(
        to: #selector(NSSplitViewDelegate.splitView(_:constrainSplitPosition:ofSubviewAt:)))
    let navigationController = NSSplitViewController()
    private let workspace: LibraryWorkspace
    private var lastSidebarToggleRequest: Int
    private var lastFocusRequest: Int
    private var navigationObserver: NSObjectProtocol?
    var navigationItem: NSSplitViewItem { splitViewItems[0] }

    var sidebarItem: NSSplitViewItem { navigationController.splitViewItems[0] }

    init(workspace: LibraryWorkspace, autosaveName: String = "Silkweb.LibraryColumns") {
        self.workspace = workspace
        lastSidebarToggleRequest = workspace.sidebarToggleRequest
        lastFocusRequest = workspace.focusRequest
        super.init(nibName: nil, bundle: nil)

        let sidebar = NSSplitViewItem(sidebarWithViewController: Self.host(LibrarySidebarPane(workspace: workspace)))
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 320
        sidebar.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebar.canCollapseFromWindowResize = false
        sidebar.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        let list = NSSplitViewItem(contentListWithViewController: Self.host(LibraryDocumentPane(workspace: workspace)))
        list.minimumThickness = 240
        list.maximumThickness = 480
        list.holdingPriority = NSLayoutConstraint.Priority(250)

        navigationController.addSplitViewItem(sidebar)
        navigationController.addSplitViewItem(list)
        navigationController.splitView.autosaveName = NSSplitView.AutosaveName(autosaveName + ".Navigation")

        // Two nested native splits isolate the first divider from the editor.
        // The outer divider resizes this group; its list yields before its sidebar.
        let navigation = NSSplitViewItem(viewController: navigationController)
        navigation.canCollapse = true
        navigation.canCollapseFromWindowResize = false
        navigation.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        navigation.holdingPriority = NSLayoutConstraint.Priority(260)
        let detail = NSSplitViewItem(viewController: Self.host(DocumentDetail(workspace: workspace)))
        detail.minimumThickness = 420
        detail.holdingPriority = NSLayoutConstraint.Priority(240)
        addSplitViewItem(navigation)
        addSplitViewItem(detail)
        splitView.autosaveName = NSSplitView.AutosaveName(autosaveName)
        workspace.librarySplitController = self
        navigationObserver = NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification,
            object: navigationController.splitView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let collapsed = self.sidebarItem.isCollapsed || self.navigationController.splitViewItems[1].isCollapsed
                    if self.workspace.libraryColumnCollapsed != collapsed { self.workspace.libraryColumnCollapsed = collapsed }
                }
            }
    }

    deinit {
        if let navigationObserver { NotificationCenter.default.removeObserver(navigationObserver) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        applySidebars(animated: false)
    }

    private static func host<Content: View>(_ content: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: content)
        // Empty/loading content must obey the same pane limits as populated content.
        controller.sizingOptions = []
        return controller
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        // This optional delegate method has no base implementation on some macOS
        // versions, even though the Swift interface exposes it as overridable.
        let position = Self.baseConstrainsSplitPosition
            ? super.splitView(splitView, constrainSplitPosition: proposedPosition, ofSubviewAt: dividerIndex)
            : proposedPosition
        if navigationItem.isCollapsed { return proposedPosition }
        let panes = navigationController.splitView.arrangedSubviews
        guard panes.count == 2 else { return position }
        // At the list's limits, stop the outer divider rather than taking space
        // from the sidebar. Window resizing still uses the holding priorities.
        let prefix = sidebarItem.isCollapsed ? 0 : panes[1].frame.minX
        let maximum = min(prefix + 480, splitView.bounds.width - splitView.dividerThickness - 420)
        return max(prefix + 240, min(maximum, position))
    }

    func applySidebars(animated: Bool) {
        let hidden = workspace.sidebarsHidden
        if hidden, let window = view.window, let responder = window.firstResponder as? NSView,
           responder.isDescendant(of: navigationController.view) {
            workspace.focusColumn = 2
            let target: NSView? = workspace.editor.url == nil ? nil
                : (workspace.preview.mode == .preview ? workspace.preview.webView : workspace.preview.editor)
            window.makeFirstResponder(target)
        }
        // Unordered hosts have no presentation animation clock. Apply final geometry directly.
        let shouldAnimate = animated && view.window?.isVisible == true
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let changes = {
            if !hidden {
                self.sidebarItem.isCollapsed = false
                self.navigationController.splitViewItems[1].isCollapsed = false
                self.workspace.libraryColumnCollapsed = false
            }
            if shouldAnimate {
                self.navigationItem.animator().isCollapsed = hidden
            } else {
                self.navigationItem.isCollapsed = hidden
            }
        }
        if shouldAnimate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                changes()
            }
        } else { changes() }
    }

    func updateRequests() {
        if lastSidebarToggleRequest != workspace.sidebarToggleRequest {
            lastSidebarToggleRequest = workspace.sidebarToggleRequest
            applySidebars(animated: true)
        } else if navigationItem.isCollapsed != workspace.sidebarsHidden {
            applySidebars(animated: false)
        }
        if lastFocusRequest != workspace.focusRequest {
            lastFocusRequest = workspace.focusRequest
            if workspace.focusColumn < 2 { applySidebars(animated: true) }
        }
    }
}

private struct LibrarySidebarPane: View {
    let workspace: LibraryWorkspace

    var body: some View {
        if let snapshot = workspace.snapshot {
            VStack(alignment: .leading, spacing: 0) {
                Text("LIBRARY").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12)
                FolderSidebar(snapshot: snapshot, workspace: workspace)
                Menu {
                    Button("New Folder") { workspace.create(folder: true) }
                    Button("New Document") { workspace.create(folder: false) }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize().padding(8)
                .accessibilityLabel("Add").help("Add")
                .disabled(!workspace.canMutate)
            }
        } else {
            DelayedLibraryProgress(count: workspace.loadingCount)
        }
    }
}

private struct LibraryDocumentPane: View {
    let workspace: LibraryWorkspace
    @FocusState private var focused: Bool

    var body: some View {
        DocumentList(workspace: workspace)
            .focused($focused)
            .onChange(of: focused) { if focused { workspace.focusColumn = 1 } }
            .onChange(of: workspace.focusRequest) {
                if workspace.rename == nil { focused = workspace.focusColumn == 1 }
            }
            .onKeyPress(keys: [.tab], phases: .down) { press in
                workspace.focus(press.modifiers.contains(.shift) ? 0 : 2)
                return .handled
            }
    }
}

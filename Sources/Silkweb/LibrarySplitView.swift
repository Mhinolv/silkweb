import AppKit
import QuartzCore
import SilkwebCore
import SwiftUI

/// SwiftUI's column width hints do not control which pane absorbs a resize.
/// AppKit owns the dividers; the hosted panes keep their existing observation and focus.
struct LibrarySplitView: NSViewControllerRepresentable {
    let workspace: LibraryWorkspace
    /// The window's sections (#195); without one the sidebar shows this workspace's Library alone.
    var registry: LibraryWindowRegistry? = nil

    func makeNSViewController(context: Context) -> LibrarySplitViewController {
        LibrarySplitViewController(workspace: workspace, autosaveName: workspace.columnAutosaveName, registry: registry)
    }

    func updateNSViewController(_ controller: LibrarySplitViewController, context: Context) {
        controller.show(workspace)
        controller.updateRequests()
    }
}

final class LibrarySplitViewController: NSSplitViewController {
    private static let baseConstrainsSplitPosition = NSSplitViewController.instancesRespond(
        to: #selector(NSSplitViewDelegate.splitView(_:constrainSplitPosition:ofSubviewAt:)))
    let navigationController: NSSplitViewController
    /// The current Library (#195): the list and the editor show it; the sidebar shows every section.
    private(set) var workspace: LibraryWorkspace
    private let registry: LibraryWindowRegistry?
    private let sidebarHost: NSHostingController<LibrarySidebarPane>
    private let listHost: NSHostingController<AnyView>
    private let detailHost: NSHostingController<AnyView>
    private var lastSidebarToggleRequest: Int
    private var lastFocusRequest: Int
    private var navigationObserver: NSObjectProtocol?
    var navigationItem: NSSplitViewItem { splitViewItems[0] }

    var sidebarItem: NSSplitViewItem { navigationController.splitViewItems[0] }

    init(
        workspace: LibraryWorkspace, autosaveName: String? = AppDefaults.columnAutosaveName,
        registry: LibraryWindowRegistry? = nil
    ) {
        let navigationController = LibraryNavigationSplitViewController()
        self.navigationController = navigationController
        self.workspace = workspace
        self.registry = registry
        sidebarHost = Self.host(LibrarySidebarPane(workspace: workspace, registry: registry))
        listHost = Self.host(Self.list(workspace, sectioned: registry != nil))
        detailHost = Self.host(Self.detail(workspace))
        lastSidebarToggleRequest = workspace.sidebarToggleRequest
        lastFocusRequest = workspace.focusRequest
        super.init(nibName: nil, bundle: nil)
        navigationController.libraryController = self

        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarHost)
        sidebar.minimumThickness = 180
        sidebar.maximumThickness = 320
        sidebar.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebar.canCollapseFromWindowResize = false
        sidebar.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        let list = NSSplitViewItem(contentListWithViewController: listHost)
        list.minimumThickness = 240
        list.maximumThickness = 480
        list.holdingPriority = NSLayoutConstraint.Priority(250)

        navigationController.addSplitViewItem(sidebar)
        navigationController.addSplitViewItem(list)
        if let autosaveName {
            navigationController.splitView.autosaveName = NSSplitView.AutosaveName(autosaveName + ".Navigation")
        }

        // Two nested native splits isolate the first divider from the editor.
        // The outer divider resizes this group; its list yields before its sidebar.
        let navigation = NSSplitViewItem(viewController: navigationController)
        navigation.canCollapse = true
        navigation.canCollapseFromWindowResize = false
        navigation.collapseBehavior = .preferResizingSiblingsWithFixedSplitView
        navigation.holdingPriority = NSLayoutConstraint.Priority(260)
        let detail = NSSplitViewItem(viewController: detailHost)
        detail.minimumThickness = 420
        detail.holdingPriority = NSLayoutConstraint.Priority(240)
        addSplitViewItem(navigation)
        addSplitViewItem(detail)
        if let autosaveName { splitView.autosaveName = NSSplitView.AutosaveName(autosaveName) }
        workspace.librarySplitController = self
        navigationObserver = NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification,
            object: navigationController.splitView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let collapsed = self.sidebarItem.isCollapsed || self.navigationController.splitViewItems[1].isCollapsed
                if self.workspace.libraryColumnCollapsed != collapsed {
                    self.workspace.libraryColumnCollapsed = collapsed
                }
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

    /// Each Library gets fresh list and editor views: their AppKit coordinators hold one workspace for life.
    private static func list(_ workspace: LibraryWorkspace, sectioned: Bool) -> AnyView {
        AnyView(LibraryDocumentPane(workspace: workspace, sectioned: sectioned).id(ObjectIdentifier(workspace)))
    }

    private static func detail(_ workspace: LibraryWorkspace) -> AnyView {
        AnyView(DocumentDetail(workspace: workspace).id(ObjectIdentifier(workspace)))
    }

    /// Another section became current (#195): the columns, their widths and the sidebar stay; the list and the
    /// editor switch to its Library.
    func show(_ next: LibraryWorkspace) {
        guard next !== workspace else { return }
        let previous = workspace
        if previous.librarySplitController === self { previous.librarySplitController = nil }
        workspace = next
        next.librarySplitController = self
        lastSidebarToggleRequest = next.sidebarToggleRequest
        lastFocusRequest = next.focusRequest
        sidebarHost.rootView = LibrarySidebarPane(workspace: next, registry: registry)
        listHost.rootView = Self.list(next, sectioned: registry != nil)
        detailHost.rootView = Self.detail(next)
        if navigationItem.isCollapsed != next.sidebarsHidden { applySidebars(animated: false) }
    }

    private static func host<Content: View>(_ content: Content) -> NSHostingController<Content> {
        let controller = NSHostingController(rootView: content)
        // Empty/loading content must obey the same pane limits as populated content.
        controller.sizingOptions = []
        return controller
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // AppKit can send this action to either nested split before SwiftUI's
    // command closure runs. Never let its default implementation hide only folders.
    override func toggleSidebar(_ sender: Any?) {
        workspace.toggleSidebars()
    }

    override func responds(to selector: Selector!) -> Bool {
        // NSSplitViewController hides this action from target resolution when
        // it has no direct sidebar item; ours lives in the nested navigation split.
        if selector == #selector(toggleSidebar(_:)) { return true }
        return super.responds(to: selector)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) {
            (item as? NSMenuItem)?.title = workspace.sidebarsTitle
            return workspace.snapshot != nil || workspace.loading
        }
        return super.validateUserInterfaceItem(item)
    }

    override func splitView(
        _ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // This optional delegate method has no base implementation on some macOS
        // versions, even though the Swift interface exposes it as overridable.
        let position =
            Self.baseConstrainsSplitPosition
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
            responder.isDescendant(of: navigationController.view)
        {
            workspace.focusColumn = 2
            let target: NSView? =
                workspace.editor.url == nil
                ? nil
                : (workspace.preview.mode == .preview ? workspace.preview.webView : workspace.preview.editor)
            window.makeFirstResponder(target)
        }
        // Unordered hosts have no presentation animation clock. Apply final geometry directly.
        let shouldAnimate =
            animated && view.window?.isVisible == true
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
        } else {
            changes()
        }
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

private final class LibraryNavigationSplitViewController: NSSplitViewController {
    weak var libraryController: LibrarySplitViewController?

    override func toggleSidebar(_ sender: Any?) {
        libraryController?.toggleSidebar(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(toggleSidebar(_:)) {
            return libraryController?.validateUserInterfaceItem(item) ?? false
        }
        return super.validateUserInterfaceItem(item)
    }
}

struct LibrarySidebarPane: View {
    let workspace: LibraryWorkspace
    var registry: LibraryWindowRegistry? = nil

    var body: some View {
        Group {
            if let registry, registry.sections.contains(where: { $0.snapshot != nil }) {
                // #195: every open Library is a section under its own header; there is no `LIBRARY` caption.
                VStack(alignment: .leading, spacing: 0) {
                    LibrarySectionsSidebar(registry: registry, current: workspace)
                    addMenu
                }
            } else if registry == nil, let snapshot = workspace.snapshot {
                VStack(alignment: .leading, spacing: 0) {
                    Text("LIBRARY").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
                        .padding(.top, 12)
                    FolderSidebar(snapshot: snapshot, workspace: workspace)
                    addMenu
                }
            } else {
                DelayedLibraryProgress(count: workspace.loadingCount)
            }
        }
        // Covers the sidebar item's full-height material, including the titlebar strip.
        .background(Color.silkwebPaneBackground.ignoresSafeArea())
    }

    /// The footer `+` acts on the current Library.
    private var addMenu: some View {
        Menu {
            Button("New Folder") { workspace.create(folder: true) }
            Button("New Document") { workspace.create(folder: false) }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton).fixedSize().padding(8)
        .accessibilityLabel("Add").help("Add")
        .disabled(!workspace.canMutate)
    }
}

private struct LibraryDocumentPane: View {
    let workspace: LibraryWorkspace
    /// #195: a section that is still loading shows its progress here, beside the other sections in the sidebar.
    var sectioned = false
    @FocusState private var focused: Bool

    var body: some View {
        if sectioned, workspace.snapshot == nil, workspace.loading {
            DelayedLibraryProgress(count: workspace.loadingCount)
                .background(Color.silkwebPaneBackground.ignoresSafeArea())
        } else {
            list
        }
    }

    private var list: some View {
        DocumentList(workspace: workspace)
            .focused($focused)
            .onChange(of: focused) { if focused { workspace.focusColumn = 1 } }
            .onChange(of: workspace.focusRequest) {
                if workspace.rename == nil { focused = workspace.focusColumn == 1 }
            }
            .onKeyPress(keys: [.tab], phases: .down) { press in
                // Tab in a rename field commits the name instead of changing panes (#106).
                guard workspace.rename == nil else { return .ignored }
                workspace.focus(press.modifiers.contains(.shift) ? 0 : 2)
                return .handled
            }
            .background(Color.silkwebPaneBackground.ignoresSafeArea())
    }
}

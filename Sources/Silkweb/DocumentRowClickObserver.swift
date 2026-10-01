import AppKit
import SwiftUI
import SilkwebCore

/// Observes clicks without taking hit tests or consuming events from the native List.
struct DocumentRowClickObserver: NSViewRepresentable {
    let path: String
    let workspace: LibraryWorkspace

    func makeNSView(context: Context) -> DocumentRowClickView {
        let view = DocumentRowClickView()
        view.configure(path: path, workspace: workspace)
        return view
    }

    func updateNSView(_ view: DocumentRowClickView, context: Context) {
        view.configure(path: path, workspace: workspace)
    }

    static func dismantleNSView(_ view: DocumentRowClickView, coordinator: ()) {
        view.stopObserving()
    }
}

final class DocumentRowClickView: NSView {
    private(set) var path = ""
    private weak var workspace: LibraryWorkspace?
    private var monitor: Any?
    private var renameWork: DispatchWorkItem?
    private var timing = SlowClickRename()
    private var pending: (timestamp: TimeInterval, count: Int, selected: Bool, modifiers: Bool)?

    var nativeRow: NSTableRowView? {
        var ancestor = superview
        while let view = ancestor {
            if let row = view as? NSTableRowView { return row }
            ancestor = view.superview
        }
        return nil
    }

    var clickBounds: NSRect {
        nativeRow.map { convert($0.bounds, from: $0) } ?? bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(path: String, workspace: LibraryWorkspace) {
        if self.path != path { timing.reset(); pending = nil }
        self.path = path
        self.workspace = workspace
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .leftMouseDragged]) { [weak self] event in
            self?.observe(event)
            return event
        }
    }

    func stopObserving() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        renameWork?.cancel()
        renameWork = nil
        pending = nil
        timing.reset()
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    private func observe(_ event: NSEvent) {
        guard let workspace, let window, event.window === window else { return }
        let point = convert(event.locationInWindow, from: nil)
        let inside = clickBounds.contains(point) && (nativeRow.map {
            $0.visibleRect.contains($0.convert(event.locationInWindow, from: nil))
        } ?? visibleRect.contains(point))
        switch event.type {
        case .leftMouseDown:
            renameWork?.cancel(); renameWork = nil
            guard inside, workspace.rename == nil else { pending = nil; timing.reset(); return }
            pending = (event.timestamp, event.clickCount,
                       workspace.session.selectedDocuments == [path],
                       !event.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty)
        case .leftMouseDragged:
            renameWork?.cancel(); renameWork = nil
            pending = nil
            timing.reset()
        case .leftMouseUp:
            guard inside, let click = pending else { pending = nil; return }
            pending = nil
            if timing.click(path: path, timestamp: click.timestamp, clickCount: click.count,
                            wasSingleSelected: click.selected,
                            isSingleSelected: workspace.session.selectedDocuments == [path],
                            hasModifiers: click.modifiers) {
                // Wait out a possible double-click before introducing the inline field.
                let work = DispatchWorkItem { [weak self, weak workspace, path] in
                    guard self?.window != nil, let workspace,
                          workspace.session.selectedDocuments == [path], workspace.rename == nil else { return }
                    workspace.beginRename(LibraryRename(path: path, isFolder: false))
                }
                renameWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
            }
        default: break
        }
    }
}

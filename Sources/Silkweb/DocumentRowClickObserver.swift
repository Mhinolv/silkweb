import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SilkwebCore

/// Shared pointer anchor without publishing state during mouse tracking.
final class DocumentRowPointerState {
    var anchor: String?
    var timing = SlowClickRename()
    var renameWork: DispatchWorkItem?

    func cancelRename() {
        renameWork?.cancel()
        renameWork = nil
    }

    deinit { renameWork?.cancel() }
}

/// AppKit owns primary-button tracking; the table retains keyboard selection and menus.
struct DocumentRowClickObserver: NSViewRepresentable {
    let path: String
    let workspace: LibraryWorkspace
    let pointerState: DocumentRowPointerState

    func makeNSView(context: Context) -> DocumentRowClickView {
        let view = DocumentRowClickView()
        view.configure(path: path, workspace: workspace, pointerState: pointerState)
        return view
    }

    func updateNSView(_ view: DocumentRowClickView, context: Context) {
        view.configure(path: path, workspace: workspace, pointerState: pointerState)
    }

    static func dismantleNSView(_ view: DocumentRowClickView, coordinator: ()) {
        view.stopObserving()
    }
}

final class DocumentRowClickView: NSView, NSDraggingSource {
    private(set) var path = ""
    private weak var workspace: LibraryWorkspace?
    private var pointerState: DocumentRowPointerState?
    private var mouseDownEvent: NSEvent?
    private var dragPaths: [String] = []
    private var wasSingleSelected = false

    // Substitute only the OS session call in offscreen tests: the sandbox cannot
    // contact the drag/pasteboard service. Hit testing and mouse tracking stay real.
    private var startDraggingSession: (([NSDraggingItem], NSEvent, NSDraggingSource) -> Void)? {
        (nativeTable as? DocumentTableView)?.startDraggingSession
    }

    var nativeRow: NSTableRowView? {
        var ancestor = superview
        while let view = ancestor {
            if let row = view as? NSTableRowView { return row }
            ancestor = view.superview
        }
        return nil
    }

    private var nativeTable: NSTableView? {
        var ancestor = superview
        while let view = ancestor {
            if let table = view as? NSTableView { return table }
            ancestor = view.superview
        }
        return nil
    }

    var clickBounds: NSRect {
        nativeRow.map { convert($0.bounds, from: $0) } ?? bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard workspace?.rename == nil, !isHidden,
              clickBounds.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    func configure(path: String, workspace: LibraryWorkspace, pointerState: DocumentRowPointerState) {
        if self.path != path { stopObserving() }
        self.path = path
        self.workspace = workspace
        self.pointerState = pointerState
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stopObserving() }
    }

    func stopObserving() {
        mouseDownEvent = nil
        dragPaths = []
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        pointerState?.cancelRename()
        guard let workspace, workspace.rename == nil else { return }
        mouseDownEvent = event
        wasSingleSelected = workspace.session.selectedDocuments == [path]
        // Freeze the payload before selection/navigation can update the hosted row.
        dragPaths = workspace.documentDragPaths(path)
        window?.makeFirstResponder(nativeTable)
        workspace.focusColumn = 1
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent, let workspace, workspace.canMutate else { return }
        let distance = hypot(event.locationInWindow.x - down.locationInWindow.x,
                             event.locationInWindow.y - down.locationInWindow.y)
        guard distance >= 4 else { return }
        mouseDownEvent = nil
        pointerState?.timing.reset()
        let writer = NSPasteboardItem()
        writer.setData(workspace.documentDragData(dragPaths),
                       forType: NSPasteboard.PasteboardType(UTType.silkwebMove.identifier))
        let item = NSDraggingItem(pasteboardWriter: writer)
        let title = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let label = NSTextField(labelWithString: dragPaths.count > 1 ? "\(dragPaths.count) Documents" : title)
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.sizeToFit()
        let size = NSSize(width: min(280, max(80, label.frame.width + 24)), height: 32)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            label.stringValue.draw(at: NSPoint(x: 12, y: 9), withAttributes: [
                .font: label.font!, .foregroundColor: NSColor.labelColor])
            return true
        }
        let location = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(origin: location, size: size), contents: image)
        if let startDraggingSession {
            startDraggingSession([item], event, self)
        } else {
            beginDraggingSession(with: [item], event: event, source: self)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let down = mouseDownEvent, let workspace else { return }
        mouseDownEvent = nil
        guard clickBounds.contains(convert(event.locationInWindow, from: nil)) else { pointerState?.timing.reset(); return }
        let hasModifiers = !down.modifierFlags.intersection([.command, .shift, .control, .option]).isEmpty
        let selection = DocumentPointerSelection.selection(
            path: path, orderedPaths: workspace.documents.map(\.relativePath),
            selected: workspace.session.selectedDocuments, anchor: pointerState?.anchor,
            extendRange: down.modifierFlags.contains(.shift), toggle: down.modifierFlags.contains(.command))
        if !down.modifierFlags.contains(.shift) { pointerState?.anchor = path }
        if down.clickCount == 2, !hasModifiers { workspace.openSelectionInNewTab(path) }
        else { workspace.selectDocuments(selection) }
        if pointerState?.timing.click(path: path, timestamp: down.timestamp, clickCount: down.clickCount,
                        wasSingleSelected: wasSingleSelected, isSingleSelected: selection == [path],
                        hasModifiers: hasModifiers) == true {
            let work = DispatchWorkItem { [weak window, weak workspace, weak pointerState, path] in
                guard pointerState != nil, window?.contentView != nil, let workspace,
                      workspace.session.selectedDocuments == [path], workspace.rename == nil else { return }
                workspace.beginRename(LibraryRename(path: path, isFolder: false))
            }
            pointerState?.renameWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval, execute: work)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? { nativeTable?.menu(for: event) }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

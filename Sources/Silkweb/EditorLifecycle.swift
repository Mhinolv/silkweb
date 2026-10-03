import AppKit
import SwiftUI

@MainActor final class EditorApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var workspace: LibraryWorkspace?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let workspace else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await workspace.prepareToExit()) }
        return .terminateLater
    }
    func applicationDidResignActive(_ notification: Notification) {
        Task { await workspace?.flushEditors() }
    }
}

struct EditorWindowLifecycle: NSViewRepresentable {
    let workspace: LibraryWorkspace
    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }
    func makeNSView(context: Context) -> WindowProbe {
        let probe = WindowProbe()
        probe.attached = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(window)
        }
        context.coordinator.installTabKeys()
        return probe
    }
    func updateNSView(_ view: WindowProbe, context: Context) {
        view.window?.isDocumentEdited = workspace.allEditors.contains { $0.state.isDirty }
    }
    final class WindowProbe: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let workspace: LibraryWorkspace
        weak var previousDelegate: NSWindowDelegate?
        private var keyMonitor: Any?
        deinit { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        func installTabKeys() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window?.delegate === self else { return false }
                    return self.handleTabKey(event)
                }
                return handled ? nil : event
            }
        }
        func handleTabKey(_ event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
            if event.keyCode == 48, modifiers == .control || modifiers == [.control, .shift], !workspace.tabs.isEmpty {
                workspace.cycleTab(modifiers.contains(.shift) ? -1 : 1)
                return true
            }
            // Handle before the standard window Close command or text view sees the key.
            if event.charactersIgnoringModifiers == "w", modifiers == .command, let id = workspace.activeTabID {
                Task { await workspace.closeTab(id) }
                return true
            }
            return false
        }
        var allowingClose = false
        var checkingClose = false
        init(workspace: LibraryWorkspace) { self.workspace = workspace }
        func attach(_ window: NSWindow) {
            window.tabbingMode = .disallowed
            if window.delegate !== self {
                previousDelegate = window.delegate
                window.delegate = self
            }
        }
        func windowWillClose(_ notification: Notification) {
            previousDelegate?.windowWillClose?(notification)
            Task { await workspace.didCloseWindow() }
        }
        override func responds(to selector: Selector!) -> Bool {
            super.responds(to: selector) || previousDelegate?.responds(to: selector) == true
        }
        override func forwardingTarget(for selector: Selector!) -> Any? { previousDelegate }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if allowingClose { return previousDelegate?.windowShouldClose?(sender) ?? true }
            guard !checkingClose else { return false }
            checkingClose = true
            Task {
                let permitted = await workspace.prepareToExit()
                checkingClose = false
                if permitted { allowingClose = true; sender.performClose(nil); allowingClose = false }
            }
            return false
        }
    }
}

import AppKit
import SwiftUI

@MainActor final class EditorApplicationDelegate: NSObject, NSApplicationDelegate {
    var registry = LibraryWindowRegistry.shared
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Library windows never tab natively: no tab bar, Merge All Windows or clash with ⇧⌘[ / ⇧⌘] (#194).
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    /// Every open Library, the current one first (#195); see `LibraryWindowRegistry.prepareToQuit`.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WritingSettings.shared.flush()
        Task { sender.reply(toApplicationShouldTerminate: await registry.prepareToQuit()) }
        return .terminateLater
    }
    func applicationDidResignActive(_ notification: Notification) {
        Task { await registry.flushEditors() }
    }
}

struct EditorWindowLifecycle: NSViewRepresentable {
    let workspace: LibraryWorkspace
    /// The app's registry; offscreen tests that host one workspace leave it out.
    var registry: LibraryWindowRegistry? = nil
    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace, registry: registry) }
    func makeNSView(context: Context) -> WindowProbe {
        let probe = WindowProbe()
        probe.attached = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(window)
        }
        context.coordinator.installTabKeys()
        return probe
    }
    func updateNSView(_ view: WindowProbe, context: Context) {
        context.coordinator.workspace = workspace
        let libraries = registry?.workspaces ?? [workspace]
        view.window?.isDocumentEdited = libraries.contains { $0.allEditors.contains { $0.state.isDirty } }
    }
    final class WindowProbe: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        /// The current Library: tab keys act on it (#195).
        var workspace: LibraryWorkspace
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
        let registry: LibraryWindowRegistry?
        init(workspace: LibraryWorkspace, registry: LibraryWindowRegistry? = nil) {
            self.workspace = workspace
            self.registry = registry
        }
        func attach(_ window: NSWindow) {
            window.tabbingMode = .disallowed
            if window.delegate !== self {
                previousDelegate = window.delegate
                window.delegate = self
            }
            workspace.attachedWindow = window
            registry?.register(window: window)
        }
        /// The compact bar stays visible in full screen (1.65); its leading items move into the freed space.
        func window(
            _ window: NSWindow,
            willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []
        ) -> NSApplication.PresentationOptions {
            let options =
                previousDelegate?.window?(window, willUseFullScreenPresentationOptions: proposedOptions)
                ?? proposedOptions
            return options.subtracting(.autoHideToolbar)
        }
        func windowWillClose(_ notification: Notification) {
            previousDelegate?.windowWillClose?(notification)
            if let registry {
                Task { await registry.windowClosed() }
            } else {
                Task { await workspace.didCloseWindow() }
            }
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
                // Every section's unsaved text, the current Library first (#195).
                let permitted: Bool
                if let registry {
                    permitted = await registry.prepareToExit(.closeWindow)
                } else {
                    permitted = await workspace.prepareToExit(.closeWindow)
                }
                checkingClose = false
                if permitted { allowingClose = true; sender.performClose(nil); allowingClose = false }
            }
            return false
        }
    }
}

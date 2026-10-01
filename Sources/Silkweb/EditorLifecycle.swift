import AppKit
import SwiftUI

@MainActor final class EditorApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var session: DocumentSession?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let session else { return .terminateNow }
        Task { sender.reply(toApplicationShouldTerminate: await session.prepareToExit()) }
        return .terminateLater
    }
    func applicationDidResignActive(_ notification: Notification) {
        Task { await session?.flush() }
    }
}

struct EditorWindowLifecycle: NSViewRepresentable {
    let session: DocumentSession
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> WindowProbe {
        let probe = WindowProbe()
        probe.attached = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(window)
        }
        return probe
    }
    func updateNSView(_ view: WindowProbe, context: Context) {
        view.window?.isDocumentEdited = session.state.isDirty
    }
    final class WindowProbe: NSView {
        var attached: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attached?(window) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let session: DocumentSession
        weak var previousDelegate: NSWindowDelegate?
        var allowingClose = false
        var checkingClose = false
        init(session: DocumentSession) { self.session = session }
        func attach(_ window: NSWindow) {
            if window.delegate !== self {
                previousDelegate = window.delegate
                window.delegate = self
            }
        }
        func windowWillClose(_ notification: Notification) {
            previousDelegate?.windowWillClose?(notification)
            Task { await session.didCloseWindow() }
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
                let permitted = await session.prepareToExit()
                checkingClose = false
                if permitted { allowingClose = true; sender.performClose(nil); allowingClose = false }
            }
            return false
        }
    }
}

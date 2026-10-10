import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

/// #226: ⇧⌘O from the editor puts the caret in Quick Open's field; typing never reaches the document, and Esc or
/// ⇧⌘O again gives focus back to the editor with its selection.
@MainActor
final class QuickOpenFocusTests: XCTestCase {
    private func settle(_ window: NSWindow, _ rounds: Int = 4) async throws {
        for _ in 0..<rounds {
            window.contentView?.superview?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(120))
        }
    }

    private func key(_ characters: String, keyCode: UInt16, in window: NSWindow) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        window.sendEvent(event)
    }

    func testQuickOpenTakesFocusFromTheEditorAndGivesItBack() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebQuickFocus-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("# Kyoto\n\nTemples and tea.".utf8).write(to: root.appendingPathComponent("Kyoto.md"))
        try Data("# Coffee\n\nBeans.".utf8).write(to: root.appendingPathComponent("Coffee.md"))
        let workspace = LibraryWorkspace(defaults: disposableDefaults("QuickOpenFocus"))
        workspace.canSaveWindowSession = false
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        await workspace.search.waitForIndex()
        let window = KeyedTestWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let controller = NSHostingController(rootView: AnyView(LibraryWorkspaceView(workspace: workspace)))
        controller.sizingOptions = []
        window.contentViewController = controller // Never ordered on screen.
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        defer {
            workspace.search.dismissQuickOpen(restoreFocus: false)
            window.contentViewController = nil
            window.close()
            try? FileManager.default.removeItem(at: root)
        }
        try await settle(window)
        workspace.selectDocuments(["Kyoto.md"])
        await workspace.waitForNavigation()
        try await settle(window)

        let editor = try XCTUnwrap(workspace.preview.editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let selection = NSRange(location: 2, length: 5)
        editor.setSelectedRange(selection)
        let source = editor.string
        XCTAssertFalse(workspace.editor.state.isDirty)

        for close in ["Esc", "⇧⌘O"] {
            workspace.search.toggleQuickOpen()
            try await settle(window)
            let field = window.firstResponder as? NSTextView
            XCTAssertFalse(window.firstResponder === editor, "\(close): Quick Open left the editor first responder")
            XCTAssertEqual(field?.isFieldEditor, true, "\(close): Quick Open's field must hold the caret")
            try key("k", keyCode: 40, in: window)
            try key("y", keyCode: 16, in: window)
            try await settle(window, 2)
            XCTAssertEqual(workspace.search.quickText, "ky", "\(close): typing goes to Quick Open")
            XCTAssertEqual(editor.string, source, "\(close): typing edited the document behind Quick Open")
            XCTAssertFalse(workspace.editor.state.isDirty, "\(close): the document must stay clean")
            XCTAssertTrue(workspace.search.showsQuickOpen)

            if close == "Esc" { try key("\u{1b}", keyCode: 53, in: window) } else { workspace.search.toggleQuickOpen() }
            try await settle(window)
            XCTAssertFalse(workspace.search.showsQuickOpen, "\(close) dismisses Quick Open")
            XCTAssertTrue(window.firstResponder === editor, "\(close): focus returns to the editor")
            XCTAssertEqual(editor.selectedRange(), selection, "\(close): the editor keeps its selection")
        }
        XCTAssertEqual(editor.string, source)
    }
}

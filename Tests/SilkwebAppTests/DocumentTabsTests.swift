import AppKit
import SwiftUI
import XCTest
import SilkwebCore
@testable import Silkweb

final class DocumentTabsTests: XCTestCase {
    @MainActor private func fixture() async throws -> LibraryWorkspace {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        for name in ["A", "B", "C", "D"] { try Data(name.utf8).write(to: root.appendingPathComponent(name + ".md")) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SilkwebTabs-\(UUID().uuidString)"))
        let workspace = LibraryWorkspace(defaults: defaults)
        workspace.root = root
        workspace.recoveryDirectory = root.appendingPathComponent(".recovery")
        workspace.install(try await LibraryScanner.scan(root: root))
        return workspace
    }
    @MainActor private func select(_ name: String, in workspace: LibraryWorkspace, pinned: Bool = false) async {
        workspace.navigate(folder: "", documents: [name + ".md"], pinned: pinned)
        await workspace.waitForNavigation()
    }

    @MainActor func testPreviewPinReplaceReorderCloseSubsetsAndCycling() async throws {
        let workspace = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root!) }
        await select("A", in: workspace)
        let a = try XCTUnwrap(workspace.tabs.first)
        XCTAssertTrue(a.isPreview)
        a.editor.edit("A edited")
        XCTAssertFalse(a.isPreview)
        await select("B", in: workspace)
        let b = try XCTUnwrap(workspace.tabs.last)
        await select("C", in: workspace)
        XCTAssertEqual(workspace.tabs.map { $0.editor.name }, ["A", "C"])
        XCTAssertNil(b.editor.url)
        await select("A", in: workspace)
        XCTAssertTrue(workspace.editor === a.editor)
        XCTAssertEqual(workspace.editor.text, "A edited")
        workspace.editor.selection = NSRange(location: 3, length: 2)
        workspace.editor.scroll = NSPoint(x: 0, y: 100)
        await select("D", in: workspace, pinned: true)
        XCTAssertEqual(workspace.tabs.map { $0.editor.name }, ["A", "D", "C"])
        let d = try XCTUnwrap(workspace.tabs.first { $0.editor.name == "D" })
        workspace.reorderTab(d.id, to: 0)
        XCTAssertEqual(workspace.tabs.map { $0.editor.name }, ["D", "A", "C"])
        workspace.activateTab(a.id)
        workspace.moveActiveTab(-1)
        XCTAssertEqual(workspace.tabs.first?.id, a.id)
        workspace.moveActiveTab(1)
        XCTAssertEqual(workspace.tabs[1].id, a.id)
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.editor.name, "C")
        workspace.cycleTab(1)
        XCTAssertEqual(workspace.editor.name, "D")
        workspace.cycleTab(-1)
        XCTAssertEqual(workspace.editor.name, "C")
        await workspace.closeTabs(otherThan: a.id, toRight: true)
        XCTAssertEqual(workspace.tabs.map { $0.editor.name }, ["D", "A"])
        await workspace.closeTabs(otherThan: a.id)
        XCTAssertEqual(workspace.tabs.map { $0.editor.name }, ["A"])
        XCTAssertEqual(workspace.editor.selection, NSRange(location: 3, length: 2))
        XCTAssertEqual(workspace.editor.scroll.y, 100)
        let closed = await workspace.closeTab(a.id)
        XCTAssertTrue(closed)
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertEqual(try String(contentsOf: workspace.root!.appendingPathComponent("A.md"), encoding: .utf8), "A edited")
    }

    @MainActor func testFailedCloseRetainsInactiveBufferAndAllTabsFlush() async throws {
        let workspace = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root!) }
        await select("A", in: workspace, pinned: true)
        let a = try XCTUnwrap(workspace.tabs.first)
        // Conflict is a deterministic save failure, with no OS permission assumptions.
        a.editor.edit("mine")
        try Data("external".utf8).write(to: a.editor.url!, options: .atomic)
        await a.editor.reconcileExternalChange()
        await select("B", in: workspace, pinned: true)
        XCTAssertEqual(workspace.editor.name, "B")
        workspace.editor.edit("B changed")
        let closed = await workspace.closeTab(a.id)
        XCTAssertFalse(closed)
        XCTAssertEqual(workspace.activeTabID, a.id)
        XCTAssertEqual(a.editor.text, "mine")
        XCTAssertTrue(a.editor.externalConflict)
        XCTAssertEqual(workspace.tabs.count, 2)
        await a.editor.resolveConflict(keepMine: true)
        let exited = await workspace.prepareToExit()
        XCTAssertTrue(exited)
        XCTAssertEqual(try String(contentsOf: workspace.root!.appendingPathComponent("A.md"), encoding: .utf8), "mine")
        XCTAssertEqual(try String(contentsOf: workspace.root!.appendingPathComponent("B.md"), encoding: .utf8), "B changed")
    }

    /// Types (plain inserts and IME marked text) through the editor delegate while `tick` runs.
    /// Returns how many keystrokes the delegate refused.
    @MainActor private func type(into text: NSTextView, during tick: @escaping @MainActor () async -> Void) async -> Int {
        final class Done { var value = false }
        let done = Done()
        let task = Task { @MainActor in await tick(); done.value = true }
        var refused = 0
        var keys = 0
        while !done.value {
            keys += 1
            let end = NSRange(location: (text.string as NSString).length, length: 0)
            if keys % 3 == 0 {
                // IME composition, then commit.
                text.setSelectedRange(end)
                text.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: end)
                if !text.hasMarkedText() { refused += 1 }
                text.insertText("火", replacementRange: text.hasMarkedText() ? text.markedRange() : end)
            } else {
                if text.delegate?.textView?(text, shouldChangeTextIn: end, replacementString: "k") == false { refused += 1 }
                text.insertText("k", replacementRange: end)
            }
            await Task.yield()
        }
        await task.value
        return refused
    }

    @MainActor func testTypingAcceptedDuringNoOpWatcherTickAfterAutosave() async throws {
        let workspace = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root!) }
        await select("A", in: workspace, pinned: true)
        let session = workspace.editor
        let coordinator = MarkdownTextView.Coordinator(session: session)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        text.string = session.text
        text.delegate = coordinator
        coordinator.textView = text
        text.insertText(" saved", replacementRange: NSRange(location: 1, length: 0))
        // Simulated autosave: the file now carries our own new revision.
        let saved = await session.flush()
        XCTAssertTrue(saved)
        XCTAssertEqual(try String(contentsOf: session.url!, encoding: .utf8), "A saved")
        for tick in 0..<3 {
            let refused = await type(into: text) {
                if tick == 0 { await workspace.reconcileFinderChanges() } else { await session.reconcileExternalChange() }
            }
            XCTAssertEqual(refused, 0, "tick \(tick): a no-op reconcile must not refuse typing or IME input")
            XCTAssertFalse(session.loading)
        }
        XCTAssertEqual(session.text, text.string)
        XCTAssertTrue(session.text.hasPrefix("A saved"))
        XCTAssertGreaterThan(session.text.count, "A saved".count)
        let flushed = await session.flush()
        XCTAssertTrue(flushed)
        XCTAssertEqual(try String(contentsOf: session.url!, encoding: .utf8), text.string)
    }

    @MainActor func testExternalChangeStillLocksBufferUntilReloadApplies() async throws {
        let workspace = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root!) }
        await select("A", in: workspace, pinned: true)
        let session = workspace.editor
        let coordinator = MarkdownTextView.Coordinator(session: session)
        try Data("external".utf8).write(to: session.url!, options: .atomic)
        let task = Task { @MainActor in await session.reconcileExternalChange() }
        var locked = false
        while !locked, session.text != "external" {
            locked = !coordinator.textView(NSTextView(), shouldChangeTextIn: NSRange(location: 0, length: 0), replacementString: "x")
            await Task.yield()
        }
        await task.value
        XCTAssertTrue(locked, "edits must be refused while the changed file replaces the buffer")
        XCTAssertEqual(session.text, "external")
        XCTAssertEqual(session.state, .clean)
        XCTAssertFalse(session.loading)
    }

    @MainActor func testRestoreAndInactiveRenameAndFinderMove() async throws {
        let workspace = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root!) }
        await select("A", in: workspace, pinned: true)
        let a = try XCTUnwrap(workspace.tabs.first)
        await select("B", in: workspace)
        let b = try XCTUnwrap(workspace.tabs.last)
        let engine = try LibraryMutations(root: workspace.root!)
        let changes = try await engine.rename("A.md", to: "Renamed.md")
        try await workspace.refresh(changes)
        XCTAssertEqual(a.editor.name, "Renamed")
        XCTAssertEqual(a.editor.text, "A")
        let moved = workspace.root!.appendingPathComponent("Finder.md")
        try FileManager.default.moveItem(at: a.editor.url!, to: moved)
        await workspace.reconcileFinderChanges()
        XCTAssertEqual(a.editor.url, moved)
        a.editor.selection = NSRange(location: 1, length: 0)
        workspace.preview.mode = .split
        await workspace.saveSessionNow()
        let loaded = try await WindowSessionMetadata.load(root: workspace.root!)
        let saved = try XCTUnwrap(loaded)
        await workspace.didCloseWindow()
        await workspace.restoreTabs(saved)
        XCTAssertEqual(workspace.tabs.map { $0.editor.name }, ["Finder", "B"])
        XCTAssertEqual(workspace.activeTabID, b.id)
        XCTAssertTrue(workspace.tabs.last!.isPreview)
        XCTAssertEqual(workspace.tabs.first!.editor.selection.location, 1)
        XCTAssertEqual(workspace.preview.mode, .split)
        try FileManager.default.removeItem(at: moved)
        let rescanned = try await LibraryScanner.scan(root: workspace.root!)
        XCTAssertEqual(saved.resolving(in: rescanned).tabs.map(\.documentID), [b.id])
    }

    @MainActor func testEmptyRestoredTabsClearStaleListSelection() async throws {
        let workspace = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root!) }
        // A stale navigation selection can survive independently of the window session.
        workspace.session.selectedDocuments = ["A.md", "B.md"]
        await workspace.restoreTabs(WindowSessionMetadata())
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNil(workspace.activeTabID)
        XCTAssertNil(workspace.editor.url)
        XCTAssertTrue(workspace.session.selectedDocuments.isEmpty)
    }

    @MainActor func testInvalidSessionFilesNeverBlockLibraryOpen() async throws {
        for json in ["{", "null", "{\"tabs\":[{},null,42],\"activeDocumentID\":\"invalid\"}",
                     "{\"tabs\":false,\"selectedFolderID\":\"invalid\",\"viewMode\":42}"] {
            let workspace = try await fixture()
            let root = try XCTUnwrap(workspace.root)
            defer { try? FileManager.default.removeItem(at: root) }
            workspace.root = nil // Open as a fresh launch, without saving over the fixture.
            workspace.snapshot = nil
            let directory = root.appendingPathComponent(".silkweb")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(json.utf8).write(to: directory.appendingPathComponent("window-session.json"))
            var navigation = LibrarySession()
            navigation.selectedDocuments = ["A.md"]
            try await navigation.save(root: root)
            workspace.open(root)
            for _ in 0..<500 {
                if workspace.error != nil || (!workspace.loading && workspace.snapshot != nil) { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(workspace.loading)
            XCTAssertNil(workspace.error)
            XCTAssertEqual(workspace.snapshot?.documents.count, 4)
            if json.contains("tabs") {
                XCTAssertTrue(workspace.tabs.isEmpty)
                XCTAssertNil(workspace.editor.url)
                XCTAssertTrue(workspace.session.selectedDocuments.isEmpty)
            }
            await workspace.didCloseWindow()
        }
    }

    @MainActor func testSingleTabDetailVisibilityAndStableContentOrigin() async throws {
        _ = NSApplication.shared
        let workspace = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root!) }
        let host = NSHostingView(rootView: DocumentDetail(workspace: workspace))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func settle() async throws {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func bar() throws -> EditorTabBarView {
            try XCTUnwrap(descendants(host).compactMap { $0 as? EditorTabBarView }.first)
        }
        func editorFrame() throws -> NSRect {
            let editor = try XCTUnwrap(descendants(host).compactMap { $0 as? PlainMarkdownTextView }
                .first { $0.string == workspace.editor.text })
            let scroll = try XCTUnwrap(editor.enclosingScrollView)
            XCTAssertEqual(editor.textContainerInset.height, 16)
            return scroll.convert(scroll.bounds, to: host)
        }
        try await settle()
        XCTAssertFalse(descendants(host).contains { $0 is EditorTabBarView })
        await select("A", in: workspace, pinned: true)
        try await settle()
        XCTAssertEqual(try bar().buttons.count, 1)
        XCTAssertEqual(try bar().accessibilityRole(), .tabGroup)
        XCTAssertEqual(try bar().buttons[0].frame.width, 220, accuracy: 1)
        XCTAssertFalse(try bar().overflow.isHidden)
        for size in [NSSize(width: 420, height: 300), NSSize(width: 900, height: 560), NSSize(width: 1600, height: 1000)] {
            window.setContentSize(size)
            for mode in DocumentViewMode.allCases {
                workspace.preview.mode = mode
                try await settle()
                let singleBar = try bar().convert(try bar().bounds, to: host)
                XCTAssertEqual(singleBar.height, Spacing.tabBarHeight, accuracy: 1)
                let singleEditor = mode == .preview ? nil : try editorFrame()
                await select("B", in: workspace, pinned: true)
                try await settle()
                XCTAssertEqual(try bar().buttons.count, 2)
                XCTAssertEqual(try bar().convert(try bar().bounds, to: host), singleBar)
                if let singleEditor {
                    XCTAssertEqual(try editorFrame().minY, singleEditor.minY, accuracy: 1)
                    XCTAssertEqual(try editorFrame().maxY, singleEditor.maxY, accuracy: 1)
                }
                let closed = await workspace.closeTab(workspace.activeTabID!)
                XCTAssertTrue(closed)
                try await settle()
                XCTAssertEqual(try bar().buttons.count, 1)
                if let singleEditor { XCTAssertEqual(try editorFrame(), singleEditor) }
            }
        }
        workspace.preview.mode = .editor
        try await settle()
        let withoutBanner = try editorFrame()
        workspace.editor.readOnly = true
        workspace.editor.error = "This document is read-only."
        try await settle()
        let withBanner = try editorFrame()
        XCTAssertGreaterThanOrEqual(withoutBanner.height - withBanner.height, 36)
        let tabFrame = try bar().convert(try bar().bounds, to: host)
        XCTAssertFalse(tabFrame.intersects(withBanner))
        workspace.editor.readOnly = false
        workspace.editor.error = nil
        workspace.selectDocuments(["A.md", "B.md"])
        await workspace.waitForNavigation()
        workspace.activeTabID = nil
        try await settle()
        XCTAssertNil(workspace.editor.url)
        XCTAssertEqual(try bar().buttons.count, 1, "Multi-selection retains the existing tab strip")
        XCTAssertEqual(try bar().convert(try bar().bounds, to: host).minY, host.bounds.minY, accuracy: 1)
        let closed = await workspace.closeTab(workspace.tabs[0].id)
        XCTAssertTrue(closed)
        try await settle()
        XCTAssertFalse(descendants(host).contains { $0 is EditorTabBarView })
        XCTAssertFalse(descendants(host).contains { $0 is PlainMarkdownTextView })
        XCTAssertFalse(window.isVisible)
    }

    @MainActor func testOffscreenTabsAndEditorLifecycleResizeSweep() async throws {
        let workspace = try await fixture()
        defer { try? FileManager.default.removeItem(at: workspace.root!) }
        await select("A", in: workspace, pinned: true)
        await select("B", in: workspace)
        let bar = EditorTabBarView(workspace: workspace)
        let panes = DocumentPanesController(workspace: workspace)
        _ = panes.view
        let probe = EditorWindowLifecycle.WindowProbe()
        let coordinator = EditorWindowLifecycle.Coordinator(workspace: workspace)
        // An unshown window exercises attachment and delegation without launching the app.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: true)
        probe.attached = { coordinator.attach($0) }
        window.contentView = probe
        probe.viewDidMoveToWindow()
        XCTAssertTrue(window.delegate === coordinator)
        XCTAssertEqual(window.tabbingMode, .disallowed)
        let content = panes.view
        content.frame = probe.bounds
        content.autoresizingMask = [.width, .height]
        probe.addSubview(content)
        content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(workspace.tabs.compactMap(\.textView).count, 2)
        let active = workspace.activeTabID
        let next = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        XCTAssertTrue(coordinator.handleTabKey(next))
        XCTAssertNotEqual(workspace.activeTabID, active)
        let previous = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.control, .shift],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\t",
            charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        XCTAssertTrue(coordinator.handleTabKey(previous))
        XCTAssertEqual(workspace.activeTabID, active)
        for mode in DocumentViewMode.allCases {
            workspace.preview.mode = mode
            panes.updateMode()
            for width in [0.0, 1, 110, 600, 4096] {
                bar.setFrameSize(NSSize(width: width, height: 28))
                bar.layoutSubtreeIfNeeded()
                panes.view.setFrameSize(NSSize(width: width, height: 560))
                panes.view.layoutSubtreeIfNeeded()
                probe.setFrameSize(NSSize(width: width, height: 560))
                probe.viewDidMoveToWindow()
                for button in bar.buttons {
                    button.layoutSubtreeIfNeeded()
                    XCTAssertGreaterThanOrEqual(button.frame.width, 110)
                    XCTAssertLessThanOrEqual(button.frame.width, 220)
                }
            }
        }
        XCTAssertEqual(bar.accessibilityRole(), .tabGroup)
        XCTAssertEqual(bar.buttons.count, 2)
        XCTAssertEqual(bar.buttons.first?.accessibilityRole(), .radioButton)
        // Production editors have independent undo managers, including while offscreen.
        let one = MarkdownTextView.makeEditorScrollView(style: EditorStyle()).documentView as! PlainMarkdownTextView
        let two = MarkdownTextView.makeEditorScrollView(style: EditorStyle()).documentView as! PlainMarkdownTextView
        let firstDelegate = MarkdownTextView.Coordinator(session: DocumentSession())
        let secondDelegate = MarkdownTextView.Coordinator(session: DocumentSession())
        one.delegate = firstDelegate; two.delegate = secondDelegate
        XCTAssertNotNil(one.undoManager)
        XCTAssertFalse(one.undoManager === two.undoManager)
        for text in ["", "👩🏽‍💻", String(repeating: "line\n", count: 1000)] {
            one.string = text
            for width in [1.0, 600, 4096] { one.setFrameSize(NSSize(width: width, height: 500)); one.viewDidMoveToWindow() }
            XCTAssertEqual(one.string, text)
        }
        window.delegate = nil
    }
}

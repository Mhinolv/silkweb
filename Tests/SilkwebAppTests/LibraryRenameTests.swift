import AppKit
import SilkwebCore
import SwiftUI
import XCTest

@testable import Silkweb

final class LibraryRenameTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor private func settle(_ host: NSView) async throws {
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @MainActor private func key(_ window: NSWindow, text: String, code: UInt16) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: text,
                charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    @MainActor func testRealSplitRenameMenuReturnAndCreation() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        try Data("Body".utf8).write(to: root.appendingPathComponent("Note.md"))
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        await workspace.editor.configure(root: root)
        let host = NSHostingView(rootView: LibrarySplitView(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host // Never ordered front or made key.
        defer { window.contentView = nil }
        try await settle(host)

        for folder in [true, false] {
            var path = folder ? "Folder" : "Note.md"
            for mode in ["menu", "return", "create"] {
                workspace.session.selectedFolder = folder ? path : ""
                workspace.session.selectedDocuments = folder ? [] : [path]
                workspace.focusColumn = folder ? 0 : 1
                if !folder { _ = await workspace.editor.open(root.appendingPathComponent(path), readOnly: false) }
                try await settle(host)
                let table = try XCTUnwrap(
                    descendants(host).compactMap { $0 as? NSTableView }.first {
                        folder ? $0 is SidebarOutlineView : !($0 is SidebarOutlineView)
                    }, "\(folder) \(mode), documents: \(workspace.documents.map(\.relativePath))")
                if mode == "create" {
                    workspace.create(folder: folder, parent: "")
                } else if mode == "menu" {
                    let row: Int
                    if let outline = table as? SidebarOutlineView {
                        row = (0..<outline.numberOfRows).first {
                            (outline.item(atRow: $0) as? FolderSidebar.Item)?.folder?.relativePath == path
                        }!
                    } else {
                        row = workspace.documents.firstIndex { $0.relativePath == path }!
                    }
                    let point = table.convert(NSPoint(x: 60, y: table.rect(ofRow: row).midY), to: nil)
                    let event = try XCTUnwrap(
                        NSEvent.mouseEvent(
                            with: .rightMouseDown, location: point,
                            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
                    )
                    let menu = try XCTUnwrap(table.menu(for: event))
                    let index = menu.indexOfItem(withTitle: "Rename…")
                    XCTAssertGreaterThanOrEqual(index, 0)
                    guard index >= 0 else { return }
                    menu.performActionForItem(at: index)
                } else {
                    XCTAssertTrue(window.makeFirstResponder(table))
                    try key(window, text: "\r", code: 36)
                }
                // Menu, Return and creation all begin the rename in a task (#56): wait for the session and its
                // field instead of a fixed layout pass a loaded runner can outlast.
                try await waitUntil("\(folder) \(mode): rename session and field") {
                    host.layoutSubtreeIfNeeded()
                    return workspace.rename != nil && descendants(host).contains { $0 is RenameNameField }
                }
                try await settle(host)
                let item = try XCTUnwrap(workspace.rename, "\(folder) \(mode): rename disappeared")
                path = item.path
                let field = try XCTUnwrap(descendants(host).compactMap { $0 as? RenameNameField }.first)
                let editor = try XCTUnwrap(field.currentEditor())
                XCTAssertTrue(window.firstResponder === editor, "Rename must own the field editor")
                let name = (folder ? "Folder" : "Note") + mode
                try key(window, text: name, code: 0)
                XCTAssertEqual(field.stringValue, name)
                // A save and revision update must preserve both the field and its draft.
                workspace.revision += 1
                if !folder { workspace.editor.edit("Saved during rename") }
                let saved = await workspace.editor.flush()
                XCTAssertTrue(saved)
                await workspace.refreshSavedDocumentDates()
                try await settle(host)
                XCTAssertEqual(workspace.rename, item)
                XCTAssertTrue(descendants(host).contains { $0 === field })
                XCTAssertTrue(window.firstResponder === editor)
                XCTAssertEqual(field.stringValue, name)
                try key(window, text: "\r", code: 36)
                // Return validates asynchronously before the rename mutation starts.
                try await waitUntil("\(folder) \(mode): rename committed") {
                    workspace.rename == nil && !workspace.mutating
                }
                try await settle(host)
                XCTAssertNil(workspace.rename)
                XCTAssertNil(workspace.mutationError)
                let newPath = folder ? name : name + ".md"
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(newPath).path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
                if folder {
                    XCTAssertEqual(workspace.session.selectedFolder, newPath)
                } else {
                    XCTAssertEqual(workspace.session.selectedDocuments, [newPath])
                }
                path = newPath
            }
            // Invalid Return retains the draft; Escape cancels it and a focus change keeps the old name (#106).
            for cancellation in ["escape", "blur"] {
                workspace.beginRename(LibraryRename(path: path, isFolder: folder))
                try await waitUntil("\(folder) \(cancellation): rename field") {
                    host.layoutSubtreeIfNeeded()
                    return workspace.rename != nil
                        && descendants(host).contains { ($0 as? RenameNameField)?.currentEditor() != nil }
                }
                let field = try XCTUnwrap(descendants(host).compactMap { $0 as? RenameNameField }.first)
                try key(window, text: "a/b", code: 0)
                try key(window, text: "\r", code: 36)
                try await waitUntil("\(folder) \(cancellation): invalid name flagged") { field.layer?.borderWidth == 1 }
                XCTAssertNotNil(workspace.rename)
                XCTAssertEqual(field.layer?.borderWidth, 1)
                if cancellation == "escape" {
                    try XCTUnwrap(field.currentEditor()).selectAll(nil)
                    try key(window, text: "Discarded", code: 0)
                    try key(window, text: "\u{1b}", code: 53)
                } else {
                    let table = try XCTUnwrap(descendants(host).compactMap { $0 as? SidebarOutlineView }.first)
                    XCTAssertTrue(window.makeFirstResponder(table))
                }
                try await waitUntil("\(folder) \(cancellation): rename cancelled") {
                    workspace.rename == nil && !workspace.mutating
                }
                try await settle(host)
                XCTAssertNil(workspace.rename)
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path))
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: root.appendingPathComponent(folder ? "Discarded" : "Discarded.md").path))
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
            }
        }
        for width: CGFloat in [960, 1200, 4096] {
            window.setContentSize(NSSize(width: width, height: 760))
            try await settle(host)
        }
    }

    /// #106: like Finder, Tab and focus leaving the field commit a valid name; the clicked view keeps focus.
    /// Escape, an unchanged name and removal of the field by a reload still cancel.
    @MainActor func testFocusLeavingRenameCommitsValidName() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Folder"), withIntermediateDirectories: false)
        try Data("Body".utf8).write(to: root.appendingPathComponent("Note.md"))
        // Keeps the list's table on screen while the folder is selected.
        try Data("Body".utf8).write(to: root.appendingPathComponent("Folder/Inside.md"))
        let workspace = LibraryWorkspace()
        workspace.root = root
        workspace.install(try await LibraryScanner.scan(root: root))
        await workspace.editor.configure(root: root)
        let host = NSHostingView(rootView: LibrarySplitView(workspace: workspace))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 760),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host // Never ordered front or made key.
        defer { window.contentView = nil }
        try await settle(host)
        let outline = try XCTUnwrap(descendants(host).compactMap { $0 as? SidebarOutlineView }.first)
        let list = try XCTUnwrap(
            descendants(host).compactMap { $0 as? NSTableView }.first { !($0 is SidebarOutlineView) })
        func exists(_ path: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
        }
        func type(_ label: String, _ text: String) async throws -> RenameNameField {
            try await waitUntil("\(label): rename field") {
                host.layoutSubtreeIfNeeded()
                return workspace.rename != nil
                    && descendants(host).contains { ($0 as? RenameNameField)?.currentEditor() != nil }
            }
            try await settle(host)
            let field = try XCTUnwrap(
                descendants(host).compactMap { $0 as? RenameNameField }.first { $0.currentEditor() != nil })
            try XCTUnwrap(field.currentEditor()).selectAll(nil)
            try key(window, text: text, code: 0)
            XCTAssertEqual(field.stringValue, text, label)
            return field
        }
        func finished(_ label: String) async throws {
            try await waitUntil("\(label): rename finished") { workspace.rename == nil && !workspace.mutating }
            try await settle(host)
        }

        // A valid folder name commits when the list takes focus, and the list keeps it.
        workspace.beginRename(LibraryRename(path: "Folder", isFolder: true))
        _ = try await type("folder blur", "Blurred")
        XCTAssertTrue(window.makeFirstResponder(list))
        try await finished("folder blur")
        XCTAssertTrue(exists("Blurred"), "Clicking away must commit a valid folder name")
        XCTAssertFalse(exists("Folder"))
        XCTAssertTrue(window.firstResponder === list, "A click-away commit must not take focus back")

        // A new document's rename normally hands focus to the editor; a click-away commit leaves it where it went.
        workspace.selectFolder("")
        try await settle(host)
        workspace.create(folder: false, parent: "")
        _ = try await type("new document blur", "Fresh")
        XCTAssertTrue(window.makeFirstResponder(outline))
        try await finished("new document blur")
        XCTAssertTrue(exists("Fresh.md"), "Clicking away must commit a valid document name")
        XCTAssertTrue(window.firstResponder === outline, "A click-away commit must not focus the editor")

        // Tab commits like Return.
        workspace.beginRename(LibraryRename(path: "Note.md", isFolder: false))
        _ = try await type("tab", "Tabbed")
        try key(window, text: "\t", code: 48)
        try await finished("tab")
        XCTAssertTrue(exists("Tabbed.md"), "Tab must commit a valid name")
        XCTAssertFalse(exists("Note.md"))

        // An invalid Tab acts like an invalid Return: the field stays open with the message.
        workspace.beginRename(LibraryRename(path: "Tabbed.md", isFolder: false))
        let invalid = try await type("invalid tab", "a/b")
        try key(window, text: "\t", code: 48)
        try await waitUntil("invalid tab flagged") { invalid.layer?.borderWidth == 1 }
        XCTAssertNotNil(workspace.rename)
        XCTAssertNotNil(invalid.currentEditor(), "An invalid Tab keeps the field editing")
        try key(window, text: "\u{1b}", code: 53)
        try await finished("invalid tab escape")
        XCTAssertTrue(exists("Tabbed.md"))

        // An invalid click-away closes the field and keeps the old name.
        workspace.beginRename(LibraryRename(path: "Blurred", isFolder: true))
        _ = try await type("invalid blur", "a/b")
        XCTAssertTrue(window.makeFirstResponder(list))
        try await finished("invalid blur")
        XCTAssertTrue(exists("Blurred"))
        XCTAssertTrue(window.firstResponder === list)

        // An unchanged name cancels without a mutation or an undo step.
        let undo = workspace.libraryUndo.count
        workspace.beginRename(LibraryRename(path: "Blurred", isFolder: true))
        _ = try await type("unchanged blur", "Blurred")
        XCTAssertTrue(window.makeFirstResponder(list))
        try await finished("unchanged blur")
        XCTAssertTrue(exists("Blurred"))
        XCTAssertEqual(workspace.libraryUndo.count, undo)

        // A reload that removes the field is not a user focus change: the half-typed name is discarded.
        workspace.beginRename(LibraryRename(path: "Blurred", isFolder: true))
        let removed = try await type("reload", "Half")
        outline.reloadData()
        try await settle(host)
        XCTAssertNil(removed.window)
        XCTAssertFalse(exists("Half"), "A reload must not commit a half-typed name")
        XCTAssertTrue(exists("Blurred"))
        if let field = descendants(host).compactMap({ $0 as? RenameNameField }).first {
            XCTAssertEqual(field.stringValue, "Blurred", "The re-created field starts from the old name")
        }
        workspace.rename.map { workspace.finishRename($0, value: nil) }
        try await finished("reload")
        XCTAssertFalse(exists("Half"))
    }
}

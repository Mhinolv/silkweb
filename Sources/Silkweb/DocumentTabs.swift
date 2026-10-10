import AppKit
import SilkwebCore
import SwiftUI

@MainActor @Observable
final class DocumentTab: Identifiable {
    let id: UUID
    let editor: DocumentSession
    var isPreview: Bool
    @ObservationIgnored weak var textView: PlainMarkdownTextView?
    init(id: UUID, editor: DocumentSession, isPreview: Bool) {
        self.id = id; self.editor = editor; self.isPreview = isPreview
    }
}

extension LibraryWorkspace {
    var allEditors: [DocumentSession] {
        tabs.isEmpty ? [emptyEditor] : tabs.map(\.editor)
    }

    func openTab(_ document: LibraryDocument, pinned: Bool = false) async -> Bool {
        guard let snapshot else { return false }
        if let tab = tabs.first(where: { $0.id == document.id }) {
            if pinned { tab.isPreview = false }
            activateTab(tab.id, syncSelection: false)
            return true
        }
        let oldPreview = pinned ? nil : tabs.first(where: \.isPreview)
        if let oldPreview, !(await oldPreview.editor.flush()) {
            // A recovered/conflicted preview must retain its buffer. Keep it and open a new slot.
            oldPreview.isPreview = false
        }
        guard let editor = await openEditor(snapshot.rootURL.appendingPathComponent(document.relativePath)) else {
            return false
        }
        if let tab = tabs.first(where: { $0.id == document.id }) {
            // A concurrent open (e.g. session restore vs. a click) added this document meanwhile: focus it instead.
            await editor.didCloseWindow()
            if pinned { tab.isPreview = false }
            activateTab(tab.id, syncSelection: false)
            return true
        }
        let tab = DocumentTab(id: document.id, editor: editor, isPreview: !pinned && !editor.state.isDirty)
        editor.didEdit = { [weak self, weak tab] in
            guard let self, let tab, tab.isPreview else { return }
            tab.isPreview = false
            self.persistSession()
        }
        if let oldPreview, oldPreview.isPreview, let index = tabs.firstIndex(where: { $0.id == oldPreview.id }) {
            await oldPreview.editor.didCloseWindow()
            tabs[index] = tab
        } else {
            let index =
                activeTabID.flatMap { active in tabs.firstIndex { $0.id == active } }.map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: index)
        }
        activateTab(tab.id, syncSelection: false)
        return true
    }

    private func openEditor(_ url: URL) async -> DocumentSession? {
        guard let snapshot else { return nil }
        let editor = DocumentSession()
        editor.didSave = { [weak self] url, digest in self?.noteSilkwebSave(url, digest: digest) }
        await editor.configure(root: snapshot.rootURL, recoveryDirectory: recoveryDirectory)
        guard await editor.open(url, readOnly: snapshot.isReadOnly) else { return nil }
        reportUnreadableRecovery(editor.unreadableRecovery)
        return editor
    }

    /// A recovery draft whose note was deleted outside Silkweb has no library row (1.70).
    /// It opens as a pinned tab; `reconcileFinderChanges` re-keys it once Save Again recreates the note.
    func openOrphanDraft(_ url: URL) async {
        guard let tab = await makeOrphanTab(url) else { return }
        let index = activeTabID.flatMap { active in tabs.firstIndex { $0.id == active } }.map { $0 + 1 } ?? tabs.count
        tabs.insert(tab, at: index)
        activateTab(tab.id, syncSelection: false)
    }

    /// Launch opens every orphan draft after the restored tabs, in the given order; the first is active (#108).
    func openOrphanDrafts(_ urls: [URL]) async {
        var first: UUID?
        for url in urls {
            guard let tab = await makeOrphanTab(url) else { continue }
            tabs.append(tab)
            first = first ?? tab.id
        }
        if let first { activateTab(first, syncSelection: false) }
    }

    private func makeOrphanTab(_ url: URL) async -> DocumentTab? {
        guard !tabs.contains(where: { $0.editor.url == url }), let editor = await openEditor(url) else { return nil }
        guard !tabs.contains(where: { $0.editor.url == url }) else {
            await editor.didCloseWindow()
            return nil
        }
        return DocumentTab(id: UUID(), editor: editor, isPreview: false)
    }

    /// Tabs whose note came back under a new library ID (Save Again) follow the new row.
    func rekeyTabs(in snapshot: LibrarySnapshot) {
        let ids = Set(snapshot.documents.map(\.id))
        for (index, tab) in tabs.enumerated() where !ids.contains(tab.id) {
            guard let url = tab.editor.url,
                let document = snapshot.documents.first(where: {
                    snapshot.rootURL.appendingPathComponent($0.relativePath) == url
                }),
                !tabs.contains(where: { $0.id == document.id })
            else { continue }
            let replacement = DocumentTab(id: document.id, editor: tab.editor, isPreview: tab.isPreview)
            replacement.textView = tab.textView
            tabs[index] = replacement
            if activeTabID == tab.id { activeTabID = document.id }
        }
    }

    func openSelectionInNewTab(_ path: String? = nil) {
        guard
            let path = path ?? selectedDocument?.relativePath
                ?? editor.url.map({ url in
                    String(url.path.dropFirst((root?.path.count ?? 0) + 1))
                })
        else { return }
        selectDocuments([path], pinned: true)
    }

    func activateTab(_ id: UUID, syncSelection: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let wasEditing = NSApp?.keyWindow?.firstResponder is PlainMarkdownTextView
        activeTabID = id
        // A click queued while the library is busy (#209) is newer than any background activation.
        if syncSelection, pendingSelection == nil, search.text.isEmpty,
            let document = snapshot?.documents.first(where: { $0.id == id })
        {
            session.selectedFolder = (document.relativePath as NSString).deletingLastPathComponent
            session.selectedDocuments = [document.relativePath]
            revision += 1
        }
        // An existing hidden editor does not receive another update merely by reattachment.
        if let view = tab.textView { preview.editor = view }
        if wasEditing { focus(2) }
        persistSession()
    }

    func removeClosedTabs() {
        tabs.removeAll { $0.editor.url == nil }
        if !tabs.contains(where: { $0.id == activeTabID }) {
            activeTabID = tabs.first?.id
            if let id = activeTabID { activateTab(id) } else { session.selectedDocuments = []; preview.editor = nil }
        }
        persistSession()
    }

    func keepTab(_ id: UUID) {
        tabs.first { $0.id == id }?.isPreview = false
        persistSession()
    }

    func cycleTab(_ delta: Int) {
        guard !mutating, !tabs.isEmpty else { return }
        let current = tabs.firstIndex { $0.id == activeTabID } ?? 0
        activateTab(tabs[(current + delta % tabs.count + tabs.count) % tabs.count].id)
    }

    func moveActiveTab(_ delta: Int) {
        guard let id = activeTabID, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard tabs.indices.contains(target) else { return }
        reorderTab(id, to: delta > 0 ? target + 1 : target)
    }

    func reorderTab(_ id: UUID, to gap: Int) {
        guard let old = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: old)
        tabs.insert(tab, at: min(tabs.count, max(0, gap > old ? gap - 1 : gap)))
        persistSession()
    }

    /// File ▸ Close Tab/Close Window (⌘W): the active tab only while the library window is key;
    /// otherwise the front window (Settings, panels) closes and library tabs stay open (#104).
    /// `closeFrontWindow` replaces `performClose` in offscreen tests.
    func performCloseCommand(closeFrontWindow: (() -> Void)? = nil) {
        if libraryIsKey, let id = activeTabID {
            Task { await closeTab(id) }
        } else if let closeFrontWindow {
            closeFrontWindow()
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func closeTab(_ id: UUID) async -> Bool {
        await waitForNavigation()
        guard !mutating, let tab = tabs.first(where: { $0.id == id }), closingTabIDs.insert(id).inserted else {
            return false
        }
        defer { closingTabIDs.remove(id) }
        tab.editor.loading = true
        defer { tab.editor.loading = false }
        // Closing an orphan recovery draft keeps the draft instead of refusing (1.70).
        var closable = await tab.editor.flush()
        if !closable { closable = await tab.editor.preserveOrphanDraft() }
        guard closable else { activateTab(id); return false }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return true }
        await tab.editor.didCloseWindow()
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = nil
            if !tabs.isEmpty {
                activateTab(tabs[min(index, tabs.count - 1)].id)
            } else {
                session.selectedDocuments = []; preview.editor = nil
            }
        }
        persistSession()
        return true
    }

    func closeTabs(otherThan id: UUID, toRight: Bool = false) async {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let ids = (toRight ? Array(tabs.dropFirst(index + 1)) : tabs.filter { $0.id != id }).map(\.id)
        for id in ids { if !(await closeTab(id)) { break } }
    }

    @discardableResult
    func flushEditors() async -> Bool {
        for editor in allEditors {
            guard await editor.flush() else {
                if let tab = tabs.first(where: { $0.editor === editor }) { activateTab(tab.id) }
                return false
            }
        }
        return true
    }

    /// `beforeAlert` runs right before an unsaved-changes alert, e.g. to bring this window to the front on Quit.
    func prepareToExit(_ reason: DocumentSession.ExitReason, beforeAlert: (() -> Void)? = nil) async -> Bool {
        await waitForNavigation()
        guard !mutating else { return false }
        let editors = allEditors
        for editor in editors { editor.loading = true }
        defer { for editor in editors { editor.loading = false } }
        for editor in editors {
            guard await editor.prepareToExit(reason, beforeAlert: beforeAlert) else {
                if let tab = tabs.first(where: { $0.editor === editor }) { activateTab(tab.id) }
                return false
            }
        }
        await saveSessionNow()
        return true
    }

    func didCloseWindow() async {
        // Preserve the working set; the sessions reopen on the next window appearance.
        for editor in allEditors { await editor.didCloseWindow() }
        tabs = []; activeTabID = nil
    }

    func windowMetadata() -> WindowSessionMetadata {
        var value = WindowSessionMetadata()
        value.activeDocumentID = activeTabID
        value.selectedFolder = session.selectedFolder
        value.selectedFolderID = snapshot?.folders.first { $0.relativePath == session.selectedFolder }?.id
        value.viewMode = preview.mode.rawValue
        value.sidebarsHidden = sidebarsHidden
        value.tagsExpanded = tagsExpanded
        value.focusMode = focusMode
        value.typewriterMode = typewriterMode
        value.tabs = tabs.map { tab in
            var item = DocumentTabMetadata(
                documentID: tab.id,
                relativePath: tab.editor.url.map { String($0.path.dropFirst((root?.path.count ?? 0) + 1)) } ?? "",
                isPreview: tab.isPreview)
            item.selectionLocation = tab.editor.selection.location
            item.selectionLength = tab.editor.selection.length
            item.scrollY = max(0, tab.editor.scroll.y)
            return item
        }
        return value
    }

    /// Serialized with navigation, so a click during launch restore never races it.
    func restoreTabs(_ value: WindowSessionMetadata) async {
        await afterNavigation { await self.performRestoreTabs(value) }
    }

    private func performRestoreTabs(_ value: WindowSessionMetadata) async {
        guard let snapshot else { return }
        restoringTabs = true
        defer { restoringTabs = false }
        let resolved = value.resolving(in: snapshot)
        sidebarsHidden = resolved.sidebarsHidden
        tagsExpanded = resolved.tagsExpanded || session.selectedTagID != nil
        setWritingModes(focus: resolved.focusMode, typewriter: resolved.typewriterMode)
        librarySplitController?.applySidebars(animated: false)
        for item in resolved.tabs {
            guard let document = snapshot.documents.first(where: { $0.id == item.documentID }) else { continue }
            _ = await openTab(document, pinned: true)
            if let tab = tabs.first(where: { $0.id == item.documentID }) {
                tab.isPreview = item.isPreview && !tab.editor.state.isDirty
                let length = (tab.editor.text as NSString).length
                tab.editor.selection = NSRange(
                    location: min(item.selectionLocation, length),
                    length: min(item.selectionLength, max(0, length - item.selectionLocation)))
                tab.editor.scroll = NSPoint(x: 0, y: item.scrollY)
            }
        }
        session.selectedFolder = resolved.selectedFolder
        preview.mode = DocumentViewMode(rawValue: resolved.viewMode) ?? .editor
        if let id = resolved.activeDocumentID { activateTab(id, syncSelection: false) }
        if tabs.isEmpty {
            activeTabID = nil
            session.selectedDocuments = []
            preview.editor = nil
        }
    }
}

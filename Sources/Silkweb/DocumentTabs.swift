import AppKit
import SwiftUI
import SilkwebCore

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
        let editor = DocumentSession()
        await editor.configure(root: snapshot.rootURL, recoveryDirectory: recoveryDirectory)
        guard await editor.open(snapshot.rootURL.appendingPathComponent(document.relativePath), readOnly: snapshot.isReadOnly) else { return false }
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
            let index = activeTabID.flatMap { active in tabs.firstIndex { $0.id == active } }.map { $0 + 1 } ?? tabs.count
            tabs.insert(tab, at: index)
        }
        activateTab(tab.id, syncSelection: false)
        return true
    }

    func openSelectionInNewTab(_ path: String? = nil) {
        guard let path = path ?? selectedDocument?.relativePath ?? editor.url.map({ url in
            String(url.path.dropFirst((root?.path.count ?? 0) + 1))
        }) else { return }
        navigate(folder: session.selectedFolder, documents: [path], pinned: true)
    }

    func activateTab(_ id: UUID, syncSelection: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let wasEditing = NSApp?.keyWindow?.firstResponder is PlainMarkdownTextView
        activeTabID = id
        if syncSelection, search.text.isEmpty,
           let document = snapshot?.documents.first(where: { $0.id == id }) {
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
            if let id = activeTabID { activateTab(id) }
            else { session.selectedDocuments = []; preview.editor = nil }
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

    func closeTab(_ id: UUID) async -> Bool {
        await waitForNavigation()
        guard !mutating, let tab = tabs.first(where: { $0.id == id }), closingTabIDs.insert(id).inserted else { return false }
        defer { closingTabIDs.remove(id) }
        tab.editor.loading = true
        defer { tab.editor.loading = false }
        guard await tab.editor.flush() else { activateTab(id); return false }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return true }
        await tab.editor.didCloseWindow()
        tabs.remove(at: index)
        if activeTabID == id {
            activeTabID = nil
            if !tabs.isEmpty { activateTab(tabs[min(index, tabs.count - 1)].id) }
            else { session.selectedDocuments = []; preview.editor = nil }
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

    func prepareToExit() async -> Bool {
        await waitForNavigation()
        guard !mutating else { return false }
        let editors = allEditors
        for editor in editors { editor.loading = true }
        defer { for editor in editors { editor.loading = false } }
        for editor in editors {
            guard await editor.prepareToExit() else {
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
            var item = DocumentTabMetadata(documentID: tab.id,
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
                tab.editor.selection = NSRange(location: min(item.selectionLocation, length), length: min(item.selectionLength, max(0, length - item.selectionLocation)))
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

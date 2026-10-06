import AppKit
import SilkwebCore

extension LibraryWorkspace {
    var canTrashSelection: Bool {
        canMutate && rename == nil && libraryHasFocus && !movePaths.isEmpty
    }
    /// The sidebar or list, not the editor or a text field, has focus: Rename, Move To… and
    /// Move to Trash act on the library selection only then (design-system §6 †).
    var libraryHasFocus: Bool {
        focusColumn != 2 && !(NSApp.keyWindow?.firstResponder is NSTextView)
    }
    var trashMenuTitle: String {
        guard canTrashSelection else { return "Move to Trash" }
        return movePaths.count == 1
            ? "Move “\(trashName(movePaths[0]))” to Trash" : "Move \(movePaths.count) Items to Trash"
    }
    var trashTitle: String {
        guard let plan = trashPlan else { return "Move to the Trash?" }
        return plan.paths.count == 1
            ? "Move “\(trashName(plan.paths[0]))” to the Trash?" : "Move \(plan.paths.count) items to the Trash?"
    }
    var trashMessage: String {
        guard let plan = trashPlan else { return "" }
        let subject = plan.paths.count == 1 ? "“\(trashName(plan.paths[0]))” contains" : "The selected folders contain"
        let dirty =
            editor.url.map {
                plan.contains(String($0.path.dropFirst(plan.root.path.count + 1))) && editor.state.isDirty
            } == true
        return
            "\(subject) \(plan.counts.summary). Everything inside will be moved to the Trash with it. You can restore it from the Trash in Finder."
            + (dirty ? "\nUnsaved changes will be saved first." : "")
    }
    private func trashName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return snapshot?.folders.contains { $0.relativePath == path } == true
            ? name : (name as NSString).deletingPathExtension
    }

    func requestTrash(_ paths: [String]? = nil, pane: Int? = nil) {
        guard canMutate, rename == nil, let root else { return }
        if paths == nil && !canTrashSelection { return }
        let selection = paths ?? movePaths
        guard !selection.isEmpty, !selection.contains("") else { return }
        if let pane { focusColumn = pane }
        mutating = true
        Task {
            await waitForNavigation()
            do {
                let service = try TrashService(root: root)
                let window = NSApp.keyWindow
                let progress = makeMoveProgressPanel()
                progress.title = "Preparing Move to Trash"
                if let stack = progress.contentView?.subviews.first as? NSStackView,
                    let label = stack.arrangedSubviews.last as? NSTextField
                {
                    label.stringValue = "Counting folder contents…"
                }
                let delayed = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                    if let window { window.beginSheet(progress, completionHandler: { _ in }) }
                }
                let plan: DeletionPlan
                do { plan = try await service.plan(selection) } catch {
                    delayed.cancel()
                    if progress.sheetParent != nil { window?.endSheet(progress) }
                    progress.orderOut(nil)
                    throw error
                }
                delayed.cancel()
                if progress.sheetParent != nil { window?.endSheet(progress) }
                progress.orderOut(nil)
                if plan.needsConfirmation { trashPlan = plan } else { await performTrash(plan) }
            } catch {
                mutating = false
                mutationFailure(error, title: "The items couldn’t be moved to the Trash.")
            }
        }
    }

    func cancelTrash() { trashPlan = nil; mutating = false }
    func confirmTrash() {
        guard let plan = trashPlan else { return }
        trashPlan = nil
        // SwiftUI dismisses the alert before the Task resumes filesystem work.
        mutating = true
        Task { await performTrash(plan) }
    }

    /// The injected service is also used by offscreen tests of the real save gate.
    func performTrash(_ plan: DeletionPlan, using service: TrashService? = nil) async {
        mutating = true
        let editor = editor
        editor.loading = true
        defer { editor.loading = false; mutating = false }
        guard await flushEditors() else {
            mutationErrorTitle = "“\(editor.name)” couldn’t be saved, so nothing was moved to the Trash."
            mutationError = "Your changes are still open in Silkweb."
            mutationRevealURLs = []
            return
        }
        let pane = focusColumn
        let oldRows = documents.map(\.relativePath)
        do {
            let service = try service ?? TrashService(root: plan.root)
            let result = try await service.execute(plan)
            // Retain recovery information before refreshing any rebuildable state.
            if !result.items.isEmpty { libraryUndo.append(.trash(result.items)) }
            let removed = Set(result.items.map(\.originalPath))
            func gone(_ path: String) -> Bool { removed.contains { path == $0 || path.hasPrefix($0 + "/") } }
            let closing = tabs.filter {
                $0.editor.url.map({ gone(String($0.path.dropFirst(plan.root.path.count + 1))) }) == true
            }
            // Without a list successor the active tab falls to its neighbour in tab order (closeTab rule).
            let neighbour = tabs.firstIndex { $0.id == activeTabID }.map { index in
                tabs[..<index].filter { tab in !closing.contains { $0 === tab } }.count
            }
            for tab in closing { await tab.editor.didCloseWindow() }
            tabs.removeAll { $0.editor.url == nil }
            if !tabs.contains(where: { $0.id == activeTabID }) {
                activeTabID = nil
                if !tabs.isEmpty { activateTab(tabs[min(neighbour ?? 0, tabs.count - 1)].id, syncSelection: false) }
            }
            if tabs.isEmpty { _ = await editor.open(nil, readOnly: false) }
            if let selected = session.selectedFolder, gone(selected) {
                let parent = (selected as NSString).deletingLastPathComponent
                let siblings =
                    snapshot?.folders.filter {
                        ($0.relativePath as NSString).deletingLastPathComponent == parent && !$0.relativePath.isEmpty
                    }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(\.relativePath) ?? []
                session.selectedFolder =
                    DeletionSelection.successor(in: siblings, removing: Set(siblings.filter(gone))) ?? parent
            }
            session.expandedFolders = session.expandedFolders.filter { !gone($0) }
            let selectedWasRemoved = session.selectedDocuments.contains(where: gone)
            session.selectedDocuments = session.selectedDocuments.filter { !gone($0) }
            let successor =
                selectedWasRemoved ? DeletionSelection.successor(in: oldRows, removing: Set(oldRows.filter(gone))) : nil
            if let successor { session.selectedDocuments = [successor] }
            try await refresh(LibraryChangeSet(changes: []))
            session.selectedDocuments.formIntersection(Set(documents.map(\.relativePath)))
            // The list successor becomes the active document (#105): its tab if open, else a preview tab.
            if let document = selectedDocument,
                successor == document.relativePath || self.editor.url == nil
            {
                _ = await openTab(document)
            }
            persistSession()
            if !result.items.isEmpty {
                focus(pane)
                NSAccessibility.post(
                    element: NSApplication.shared.mainWindow ?? NSApplication.shared,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: "Moved \(result.items.count) items to the Trash",
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ])
            }
            reportTrashFailures(
                result.failures, reveal: result.failures.map { plan.root.appendingPathComponent($0.path) })
        } catch { mutationFailure(error, title: "The items couldn’t be moved to the Trash.") }
    }

    func reportTrashFailures(_ failures: [TrashFailure], reveal: [URL], restoring: Bool = false) {
        guard !failures.isEmpty else { return }
        if failures.count == 1, let failure = failures.first {
            mutationErrorTitle =
                restoring ? failure.reason : "“\(trashName(failure.path))” couldn’t be moved to the Trash."
        } else {
            mutationErrorTitle = "Some items couldn’t be moved \(restoring ? "back from" : "to") the Trash."
        }
        mutationError =
            failures.map { "“\(($0.path as NSString).lastPathComponent)”: \($0.reason)" }.joined(separator: "\n")
            + (restoring
                ? ""
                : "\nSilkweb never deletes documents permanently. If this disk doesn’t support the Trash, move the items in Finder.")
        mutationRevealURLs = reveal
        mutationRevealTitle = restoring ? "Reveal in Trash" : "Reveal in Finder"
    }
}

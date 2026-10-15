import AppKit
import SilkwebCore
import SwiftUI

/// The strip's Pending ▾ pull-down (#140), for the window session only.
enum ProposalFilter: String, CaseIterable {
    case pending = "Pending", applied = "Applied", rejected = "Rejected", all = "All"

    func includes(_ proposal: AgentProposal) -> Bool {
        switch self {
        case .pending: return proposal.status == .pending
        case .applied: return proposal.status == .applied
        case .rejected: return proposal.status == .rejected
        case .all: return true
        }
    }
}

/// One Library Undo entry for an Apply or Reject (#140). Undo restores the files and sets the Proposal back to
/// Pending.
struct ProposalUndo {
    enum Action {
        /// Reject: nothing in the Library changed.
        case decision
        /// The replaced bytes, and the revision the apply left, so Undo only replaces what Apply wrote.
        case edit(path: String, documentID: UUID?, previous: Data, applied: String)
        /// The exact reverse of the move or rename and its link rewrites.
        case move(MovePlan)
        /// The new Document, and the sources moved to the Trash with it.
        case merge(created: String, createdID: UUID?, trashed: [TrashedItem])
    }

    let proposalID: String
    let title: String
    let action: Action
}

/// What the review pane shows for one Proposal, read off the main thread. Unsaved editor changes are checked live
/// on the main thread instead (`unsavedTarget`), since they change with every keystroke's save state.
struct ProposalReview: Equatable {
    enum Block: Equatable {
        /// A target's bytes aren't the base revision any more; the name is the Document's title.
        case outOfDate(String)
        /// A target isn't in the Library any more.
        case missing
    }

    let id: String
    var block: Block?
    /// Each target's current Library path, `nil` when it's gone.
    var paths: [String?] = []
    /// Edit: the Document's text now and with the Proposal applied. Merge: `proposed` is the new Document.
    var current: String?
    var proposed: String?
    var diff: LineDiff?
    /// Move and rename: where the Document would go (Keep Both naming included).
    var destination: String?
    /// Move and rename: Documents whose links Move To… would rewrite, `nil` when they couldn't be checked.
    var links: [String]?
}

/// #140: Proposals agents save under `.silkweb/proposals/`, reviewed and applied only by the owner. Reloads read
/// the folder off the main thread and never rescan; Apply and Reject are Library mutations with one Undo entry each.
extension LibraryWorkspace {
    nonisolated static func loadProposals(root: URL) async -> [AgentProposal] {
        await Task.detached(priority: .utility) { AgentProposalStore.load(root: root) }.value
    }

    /// `.silkweb/proposals/` changed: reread it. No rescan, and nothing is written back.
    func reloadProposals() async {
        guard let root, snapshot != nil else { return }
        let previous = proposalReloadTask
        let task = Task {
            await previous?.value
            let loaded = await Self.loadProposals(root: root)
            guard !Task.isCancelled, self.root == root else { return }
            proposals = loaded
        }
        proposalReloadTask = task
        await task.value
    }

    /// The sidebar row and Go ▸ Proposals: shown once any Proposal existed this window session.
    var hasProposals: Bool { proposalsRowShown }
    var pendingProposalCount: Int { proposals.filter(\.isPending).count }
    var filteredProposals: [AgentProposal] { proposals.filter(proposalFilter.includes) }
    var selectedProposal: AgentProposal? { selectedProposalID.flatMap { id in proposals.first { $0.id == id } } }

    /// Go ▸ Proposals and the sidebar row. Keeps the selected Proposal, else selects the newest one listed.
    func selectProposals() {
        guard hasProposals else { return }
        navigate(folder: nil, documents: [], tag: nil, changesScope: true, proposals: true)
        guard proposalScope else { return }
        if selectedProposal.map(proposalFilter.includes) != true { selectedProposalID = filteredProposals.first?.id }
    }

    /// Document Info's “1 pending proposal · Review…”: opens that Proposal.
    func reviewProposal(_ id: String) {
        guard proposals.contains(where: { $0.id == id }) else { return }
        if proposals.first(where: { $0.id == id }).map(proposalFilter.includes) != true { proposalFilter = .all }
        selectedProposalID = id
        selectProposals()
    }

    /// Pending Proposals about one Document, newest first.
    func pendingProposals(for document: LibraryDocument) -> [AgentProposal] {
        proposals.filter { proposal in
            proposal.isPending && proposal.targets.contains { currentPath(of: $0) == document.relativePath }
        }
    }

    /// Where a target is now: by index identity (renames and moves are followed), else its recorded path when the
    /// index never learned it. `nil` when it isn't in the Library.
    func currentPath(of target: AgentProposal.Target) -> String? {
        guard let snapshot else { return nil }
        if let id = target.documentId, let path = itemPathsByID[id] { return path }
        return snapshot.metadata.IDsByPath[target.path] != nil ? target.path : nil
    }

    /// The title of a target with unsaved changes in this window, if any. Checked when Apply is clicked too.
    func unsavedTarget(_ proposal: AgentProposal) -> String? {
        guard let root else { return nil }
        for target in proposal.targets {
            guard let path = currentPath(of: target) else { continue }
            let url = root.appendingPathComponent(path).standardizedFileURL
            if allEditors.contains(where: { $0.url?.standardizedFileURL == url && $0.state.isDirty }) {
                return AgentProposal.title(of: path)
            }
        }
        return nil
    }

    /// Show Document in the unsaved-changes banner: the Document, in All Documents.
    func showProposalTarget(_ proposal: AgentProposal) {
        guard let path = proposal.targets.lazy.compactMap({ self.currentPath(of: $0) }).first, let root else { return }
        showDocument(root.appendingPathComponent(path))
    }

    /// Reloads the review pane for the selected Proposal, off the main thread. A newer request replaces an older one.
    func scheduleProposalReview() {
        proposalReviewTask?.cancel()
        guard let proposal = selectedProposal, let root else {
            proposalReview = nil
            return
        }
        let paths = proposal.targets.map(currentPath(of:))
        proposalReviewTask = Task {
            let review = await Self.review(proposal, paths: paths, root: root)
            guard !Task.isCancelled, selectedProposalID == proposal.id else { return }
            if proposalReview != review { proposalReview = review }
        }
    }

    /// Rechecks every pending Proposal's targets off the main thread, for the list's “Out of Date” status. A newer
    /// request replaces an older one; `staleProposals` is assigned only when it changes.
    func scheduleProposalStatus() {
        proposalStatusTask?.cancel()
        guard let root else { return }
        let pending = proposals.filter(\.isPending).map { ($0, $0.targets.map(currentPath(of:))) }
        proposalStatusTask = Task {
            let stale = await Task.detached(priority: .utility) {
                Set(pending.filter { Self.isStale($0.0, paths: $0.1, root: root) }.map(\.0.id))
            }.value
            guard !Task.isCancelled, self.root == root, staleProposals != stale else { return }
            staleProposals = stale
        }
    }

    /// A target is gone, or its bytes aren't the Proposal's base revision any more.
    nonisolated static func isStale(_ proposal: AgentProposal, paths: [String?], root: URL) -> Bool {
        zip(proposal.targets, paths).contains { target, path in
            path.flatMap { AgentProposalApply.revision(root: root, path: $0)?.revision } != target.baseRevision
        }
    }

    /// The list row's status: “Out of Date” for a stale pending Proposal.
    func statusLabel(_ proposal: AgentProposal) -> String {
        proposal.isPending && staleProposals.contains(proposal.id) ? "Out of Date" : proposal.statusLabel
    }

    /// Reads every target, compares revisions, and builds the edit diff or the move's link list.
    nonisolated static func review(_ proposal: AgentProposal, paths: [String?], root: URL) async -> ProposalReview {
        let read = await Task.detached(priority: .userInitiated) {
            paths.map { path in path.flatMap { AgentProposalApply.revision(root: root, path: $0) } }
        }.value
        var review = ProposalReview(id: proposal.id, paths: paths)
        if proposal.isPending {
            if read.contains(where: { $0 == nil }) {
                review.block = .missing
            } else if let index = proposal.targets.indices.first(where: {
                proposal.targets[$0].baseRevision != read[$0]?.revision
            }) {
                review.block = .outOfDate(AgentProposal.title(of: paths[index] ?? proposal.targets[index].path))
            }
        }
        switch proposal.kind {
        case .edit:
            guard let current = read.first??.text else { break }
            let proposed = proposal.editedText(current: current)
            review.current = current
            review.proposed = proposed
            if let proposed {
                review.diff = await Task.detached(priority: .userInitiated) {
                    LineDiff(old: current, new: proposed)
                }.value
            }
        case .merge:
            review.proposed = proposal.body
        case .move, .rename:
            guard proposal.isPending, review.block == nil, let path = paths.first ?? nil,
                let engine = try? LibraryMutations(root: root)
            else { break }
            let plan: MovePlan?
            if proposal.kind == .move {
                plan = try? await engine.planMove([path], toFolder: proposal.destination ?? "", keepBoth: true)
            } else {
                plan = try? await engine.planRename(path, to: renamedFile(proposal, path: path))
            }
            review.destination = plan?.changes.changes.first?.newPath
            review.links = plan?.rewrittenDocuments.filter { $0 != path }
        }
        return review
    }

    /// The renamed Document's filename, keeping its extension.
    nonisolated static func renamedFile(_ proposal: AgentProposal, path: String) -> String {
        let ext = (path as NSString).pathExtension
        return (proposal.title ?? "") + "." + (ext.isEmpty ? "md" : ext)
    }

    // MARK: Apply and reject

    /// Applies a pending Proposal after checking its base revisions again at the moment of the click. A blocked
    /// Proposal changes nothing; its banner says why. One Library Undo entry, “Undo Apply Proposal”.
    func applyProposal(_ id: String, trashSources: Bool = false) {
        guard canMutate, decidingProposal == nil, let root, let proposal = proposals.first(where: { $0.id == id }),
            proposal.isPending
        else { return }
        mutating = true
        decidingProposal = id
        Task {
            await waitForNavigation()
            defer {
                mutating = false
                decidingProposal = nil
            }
            let review = await Self.review(proposal, paths: proposal.targets.map(currentPath(of:)), root: root)
            if selectedProposalID == id { proposalReview = review }
            guard review.block == nil, unsavedTarget(proposal) == nil else { return }
            do {
                guard
                    let (action, applied) = try await perform(proposal, review: review, root: root, trash: trashSources)
                else { return }
                let now = MemoryEnvelope.timestamp(Date())
                libraryUndo.append(
                    .proposal(ProposalUndo(proposalID: id, title: "Undo Apply Proposal", action: action)))
                do {
                    _ = try await Task.detached {
                        try AgentProposalStore.update(id, root: root) {
                            $0.status = .applied
                            $0.decidedAt = now
                            $0.appliedPath = applied
                        }
                    }.value
                } catch {
                    mutationFailure(error, title: "The proposal was applied, but its status couldn’t be saved.")
                }
                await reloadProposals()
                scheduleProposalReview()
            } catch {
                mutationFailure(error, title: "The proposal couldn’t be applied.")
                if let failure = error as? LibraryMutationError, case .rollbackFailed = failure {
                    // The recovery suggestion identifies the preserved items.
                } else {
                    mutationError = (mutationError ?? "") + "\nNothing was changed."
                }
            }
        }
    }

    /// The Library change itself. `nil` when the owner cancelled (links Silkweb can't rewrite).
    private func perform(_ proposal: AgentProposal, review: ProposalReview, root: URL, trash: Bool) async throws
        -> (ProposalUndo.Action, String?)?
    {
        let target = proposal.targets.first
        let path = review.paths.first ?? nil
        switch proposal.kind {
        case .edit:
            guard let target, let path, let current = review.current,
                let edited = proposal.editedText(current: current)
            else { throw AgentProposalError.sourceMissing }
            let data = Data(edited.utf8)
            let previous = try await Task.detached {
                try AgentProposalApply.replace(root: root, path: path, expected: target.baseRevision, with: data)
            }.value
            try await reloadAfterWrite(path, root: root)
            return (
                .edit(
                    path: path, documentID: target.documentId, previous: previous,
                    applied: AgentProposalApply.revision(of: data)), path
            )
        case .move, .rename:
            guard let path else { throw AgentProposalError.sourceMissing }
            guard await flushEditors() else { return nil }
            let engine = try LibraryMutations(root: root)
            let plan =
                proposal.kind == .move
                ? try await engine.planMove([path], toFolder: proposal.destination ?? "", keepBoth: true)
                : try await engine.planRename(path, to: Self.renamedFile(proposal, path: path))
            guard await confirmUnsupportedLinks(plan, action: "Apply Anyway", window: libraryWindow) else {
                return nil
            }
            let changes = try await commitMove(plan, using: engine)
            if let folder = proposal.destination { session.expandedFolders.insert(folder) }
            return (.move(plan.reversed), changes.changes.first?.newPath)
        case .merge:
            guard await flushEditors() else { return nil }
            let folder = proposal.destination ?? ""
            let engine = try LibraryMutations(root: root)
            let name = try await engine.uniqueName(base: (proposal.title ?? "Merged") + ".md", in: folder)
            let changes = try await engine.createDocument(named: name, in: folder, text: proposal.body ?? "")
            try await refresh(changes)
            let created = changes.changes.first
            var trashed: [TrashedItem] = []
            let sources = review.paths.compactMap { $0 }
            if trash, !sources.isEmpty {
                // The checkbox is the owner's confirmation; Undo Apply Proposal puts them back.
                let plan = try await TrashService(root: root).plan(sources)
                trashed = await performTrash(plan, recordsUndo: false)
                mutating = true
            }
            return (.merge(created: created?.newPath ?? "", createdID: created?.id, trashed: trashed), created?.newPath)
        }
    }

    /// A Silkweb write to one Document: rescan, account for it (never “changed outside Silkweb”), and reload an
    /// open clean buffer through the normal external-change path.
    private func reloadAfterWrite(_ path: String, root: URL) async throws {
        try await refresh(LibraryChangeSet(changes: []), added: [path])
        let url = root.appendingPathComponent(path).standardizedFileURL
        for editor in allEditors where editor.url?.standardizedFileURL == url {
            await editor.reconcileExternalChange()
        }
    }

    /// Rejects a Proposal; the Documents are never touched. One Library Undo entry, “Undo Reject Proposal”.
    func rejectProposal(_ id: String) {
        guard canMutate, decidingProposal == nil, let root, proposals.first(where: { $0.id == id })?.isPending == true
        else { return }
        mutating = true
        decidingProposal = id
        Task {
            await waitForNavigation()
            defer {
                mutating = false
                decidingProposal = nil
            }
            let now = MemoryEnvelope.timestamp(Date())
            do {
                _ = try await Task.detached {
                    try AgentProposalStore.update(id, root: root) {
                        guard $0.status == .pending else { throw AgentProposalError.decided }
                        $0.status = .rejected
                        $0.decidedAt = now
                    }
                }.value
                libraryUndo.append(
                    .proposal(ProposalUndo(proposalID: id, title: "Undo Reject Proposal", action: .decision)))
                await reloadProposals()
                scheduleProposalReview()
            } catch {
                mutationFailure(error, title: "The proposal couldn’t be rejected.")
            }
        }
    }

    /// Undo Apply Proposal / Undo Reject Proposal: restores the files, then sets the Proposal back to Pending.
    /// The caller has removed the entry; a failure reports that nothing was changed.
    func undoProposal(_ undo: ProposalUndo, root: URL) async {
        do {
            switch undo.action {
            case .decision:
                break
            case .edit(let path, let id, let previous, let applied):
                let current = id.flatMap { itemPathsByID[$0] } ?? path
                _ = try await Task.detached {
                    try AgentProposalApply.replace(root: root, path: current, expected: applied, with: previous)
                }.value
                try await reloadAfterWrite(current, root: root)
            case .move(let plan):
                guard await flushEditors() else { return }
                let engine = try LibraryMutations(root: root)
                do { _ = try await commitMove(plan, using: engine) } catch MovePlanError.changed {
                    // Something changed since the apply: move back and rewrite links afresh.
                    _ = try await commitMove(engine.planRestore(plan.changes), using: engine)
                }
            case .merge(let created, let id, let trashed):
                guard await flushEditors() else { return }
                if !trashed.isEmpty {
                    let result = await (try TrashService(root: root)).restore(trashed)
                    try await refresh(LibraryChangeSet(changes: []), added: result.items.map(\.originalPath))
                    if let failure = result.failures.first {
                        throw LibraryMutationError.filesystemFailure(
                            name: (failure.path as NSString).lastPathComponent, operation: "restored",
                            reason: failure.reason)
                    }
                }
                let current = id.flatMap { itemPathsByID[$0] } ?? created
                if snapshot?.documents.contains(where: { $0.relativePath == current }) == true {
                    // Never deleted: the merged Document goes to the Trash.
                    let plan = try await TrashService(root: root).plan([current])
                    _ = await performTrash(plan, recordsUndo: false)
                    mutating = true
                }
            }
            let id = undo.proposalID
            _ = try await Task.detached {
                try AgentProposalStore.update(id, root: root) {
                    $0.status = .pending
                    $0.decidedAt = nil
                    $0.appliedPath = nil
                }
            }.value
            await reloadProposals()
            scheduleProposalReview()
        } catch {
            mutationFailure(error, title: "“\(undo.title)” couldn’t be completed.")
            mutationError = (mutationError ?? "") + "\nNothing was changed."
        }
    }
}

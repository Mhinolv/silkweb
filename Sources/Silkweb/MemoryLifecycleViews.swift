import AppKit
import SilkwebCore
import SwiftUI

/// What the lifecycle rows need from disk for one Document (#141): its saved revision, the envelope's suggested review
/// date and `consolidates`, and the revisions of the Documents it replaces or that claim to replace it.
struct LoadedMemoryInfo: Equatable {
    let path: String
    var revision: String?
    var suggestedReviewAfter: Date?
    var consolidates: [String] = []
    /// Library-relative path → saved revision, for related Documents.
    var revisions: [String: String] = [:]

    nonisolated static func load(path: String, related: [String], root: URL) -> LoadedMemoryInfo {
        var info = LoadedMemoryInfo(path: path)
        if let data = try? Data(contentsOf: root.appendingPathComponent(path)) {
            info.revision = MemoryStateStore.revision(data)
            if case .envelope(let envelope, _) = MemoryEnvelope.parse(String(decoding: data, as: UTF8.self)) {
                info.suggestedReviewAfter = envelope.string("review_after").flatMap(AgentMemorySearchRequest.date)
                if case .list(let ids) = envelope["consolidates"] { info.consolidates = ids }
            }
        }
        for other in related {
            if let data = try? Data(contentsOf: root.appendingPathComponent(other)) {
                info.revisions[other] = MemoryStateStore.revision(data)
            }
        }
        return info
    }
}

/// Loads `LoadedMemoryInfo` off the main thread whenever the Document, its claims or a related Document changes.
struct MemoryInfoLoader: ViewModifier {
    let workspace: LibraryWorkspace
    let document: LibraryDocument?
    @Binding var loaded: LoadedMemoryInfo?

    private struct Identity: Hashable {
        let path: String?
        let modified: Date?
        let related: [String]
        let relatedModified: [Date?]
    }

    func body(content: Content) -> some View {
        let related =
            document.map { MemoryLifecycleSection.related($0.relativePath, links: workspace.memoryLinks) } ?? []
        let dates = Dictionary(
            (workspace.snapshot?.documents ?? []).filter { related.contains($0.relativePath) }.map {
                ($0.relativePath, $0.modified)
            }, uniquingKeysWith: { first, _ in first })
        content.task(
            id: Identity(
                path: document?.relativePath, modified: document?.modified, related: related,
                relatedModified: related.map { dates[$0] ?? nil })
        ) {
            guard let document, workspace.isMemoryDocument(document.relativePath), let root = workspace.root else {
                return
            }
            let path = document.relativePath
            let info = await Task.detached(priority: .utility) {
                LoadedMemoryInfo.load(path: path, related: related, root: root)
            }.value
            guard !Task.isCancelled, loaded != info else { return }
            loaded = info
        }
    }
}

/// Document Info's lifecycle rows for a Document with an agent memory envelope (#141): review, review date, pin,
/// supersession in both directions, consolidation and archive. The same `.headline`/`.caption` pairs as the Agent
/// block. State is always text, never colour.
struct MemoryLifecycleSection: View {
    let workspace: LibraryWorkspace
    let document: LibraryDocument
    let link: MemoryLink
    let loaded: LoadedMemoryInfo?
    var now = Date()
    @State private var editingDate = false

    /// The Documents this one claims to replace, and those that claim to replace it.
    static func related(_ path: String, links: MemoryLinkMap) -> [String] {
        guard let link = links.links[path] else { return [] }
        let targets = link.supersedes.compactMap(links.path(of:))
        let claimants = links.claimants[link.memoryID] ?? []
        return Array(Set(targets + claimants).subtracting([path])).sorted()
    }

    private var entry: MemoryLifecycleEntry { workspace.memoryState[document.id] }
    private var info: LoadedMemoryInfo? { loaded?.path == document.relativePath ? loaded : nil }
    private var enabled: Bool { workspace.canChangeMemoryState }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            reviewRow
            reviewDateRow
            VStack(alignment: .leading, spacing: 4) {
                Text("Pinned").font(.headline)
                Toggle(
                    "Pin",
                    isOn: Binding(
                        get: { entry.pinned },
                        set: { workspace.setPinned([document.relativePath], pinned: $0) })
                )
                .toggleStyle(.checkbox).font(.caption).disabled(!enabled)
                .accessibilityLabel("Pin, keeps this Document at the top of agent results")
            }
            ForEach(supersedes, id: \.memoryID) { row in
                claimRow("Supersedes", row: row)
            }
            ForEach(supersededBy, id: \.memoryID) { row in
                claimRow("Superseded by", row: row)
            }
            if let info, !info.consolidates.isEmpty { consolidatesRow(info.consolidates) }
            if let archived = entry.archived { archivedRow(archived) }
            if let problem { pair("Problems", problem) }
            Text("Saved in Silkweb’s index, not in the file.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Memory review")
    }

    // MARK: Review

    static func reviewText(_ entry: MemoryLifecycleEntry, revision: String?) -> (text: String, offersReview: Bool) {
        guard let reviewed = entry.reviewed else { return ("Not reviewed", true) }
        if let revision, reviewed.revision != revision { return ("Reviewed an earlier version", true) }
        return ("Reviewed " + reviewed.at.formatted(.dateTime.month(.abbreviated).day()), false)
    }

    private var reviewRow: some View {
        let (text, offers) = Self.reviewText(entry, revision: info?.revision)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Review").font(.headline)
            HStack(spacing: 0) {
                Text(offers ? text + " · " : text).font(.caption)
                if offers {
                    Button("Mark as Reviewed") { workspace.markReviewed([document.relativePath]) }
                        .buttonStyle(.link).font(.caption).disabled(!enabled)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// “Jan 6, 2027 (set by agent)”, “Passed Jan 6”, or “None”.
    static func reviewDateText(_ entry: MemoryLifecycleEntry, suggested: Date?, now: Date) -> String {
        guard let date = entry.reviewDate(suggested: suggested) else { return "None" }
        if entry.reviewDue(suggested: suggested, now: now) {
            return "Passed " + date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(date: .abbreviated, time: .omitted)
            + (entry.reviewAfter == nil ? " (set by agent)" : " (set by you)")
    }

    private var reviewDateRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review date").font(.headline)
            HStack(spacing: 0) {
                Text(Self.reviewDateText(entry, suggested: info?.suggestedReviewAfter, now: now) + " · ")
                    .font(.caption)
                Button("Change…") { editingDate = true }
                    .buttonStyle(.link).font(.caption).disabled(!enabled)
                    .accessibilityLabel("Change review date")
                    .popover(isPresented: $editingDate, arrowEdge: .bottom) {
                        ReviewDatePopover(
                            date: entry.reviewDate(suggested: info?.suggestedReviewAfter) ?? now,
                            onDone: { date in
                                editingDate = false
                                workspace.setReviewDate(document, to: date)
                            },
                            onClear: {
                                editingDate = false
                                workspace.setReviewDate(document, to: nil)
                            })
                    }
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Supersession

    struct ClaimRow: Equatable {
        let memoryID: String
        /// The other Document, when it's in this Library.
        let path: String?
        let state: MemoryLifecycleEntry.ClaimState?
        let decided: Date?
        /// Accept and Decline name the predecessor first.
        let target: String?
        let successor: String?

        var title: String {
            path.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? memoryID
        }
    }

    /// Documents this one claims to replace. The decision lives on each of them.
    private var supersedes: [ClaimRow] {
        link.supersedes.filter { $0 != link.memoryID }.map { id in
            let path = workspace.memoryLinks.path(of: id)
            let target = path.flatMap { path in workspace.snapshot?.documents.first { $0.relativePath == path } }
            var state: MemoryLifecycleEntry.ClaimState?
            var decided: Date?
            if let target, let path, let revision = info?.revisions[path], let mine = info?.revision {
                let entry = workspace.memoryState[target.id]
                state = entry.claimState(by: link.memoryID, revision: revision, successorRevision: mine)
                decided = entry.supersession.last { $0.by == link.memoryID }?.at
            }
            return ClaimRow(
                memoryID: id, path: path, state: state, decided: decided, target: path,
                successor: document.relativePath)
        }
    }

    /// Documents that claim to replace this one. The decision lives on this one.
    private var supersededBy: [ClaimRow] {
        (workspace.memoryLinks.claimants[link.memoryID] ?? []).compactMap { path in
            guard let id = workspace.memoryLinks.links[path]?.memoryID else { return nil }
            var state: MemoryLifecycleEntry.ClaimState?
            if let revision = info?.revisions[path], let mine = info?.revision {
                state = entry.claimState(by: id, revision: mine, successorRevision: revision)
            }
            return ClaimRow(
                memoryID: id, path: path, state: state, decided: entry.supersession.last { $0.by == id }?.at,
                target: document.relativePath, successor: path)
        }
    }

    static func claimText(_ row: ClaimRow) -> String {
        guard row.path != nil else { return "“\(row.memoryID)” · Not in this Library" }
        let state: String
        switch row.state {
        case .accepted?:
            state = "Accepted" + (row.decided.map { " " + $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "")
        case .declined?: state = "Declined"
        case .claimed?: state = "Claimed"
        case nil: state = "Checking…"
        }
        return "“\(row.title)” · \(state)"
    }

    private func claimRow(_ label: String, row: ClaimRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            // Long titles wrap; the actions keep their own line.
            Text(Self.claimText(row)).font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if row.state == .claimed, let target = row.target, let successor = row.successor {
                HStack(spacing: 12) {
                    Button("Accept") { workspace.decideSupersession(target: target, successor: successor, .accepted) }
                        .accessibilityLabel("Accept replacement")
                    Button("Decline") { workspace.decideSupersession(target: target, successor: successor, .declined) }
                        .accessibilityLabel("Decline replacement")
                }
                .buttonStyle(.link).font(.caption).disabled(!enabled)
            }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Consolidation, archive, problems

    private func consolidatesRow(_ ids: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Consolidates").font(.headline)
            Text(ids.count == 1 ? "1 Document" : "\(ids.count) Documents").font(.caption)
            ForEach(ids, id: \.self) { id in
                if let path = workspace.memoryLinks.path(of: id),
                    let source = workspace.snapshot?.documents.first(where: { $0.relativePath == path })
                {
                    Button(((path as NSString).lastPathComponent as NSString).deletingPathExtension) {
                        workspace.queueOpen(source, pinned: false)
                    }
                    .buttonStyle(.link).font(.caption)
                } else {
                    Text("“\(id)” · Not in this Library").font(.caption)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func archivedRow(_ archived: MemoryLifecycleEntry.Archived) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Archived").font(.headline)
            Text(Self.archivedText(archived)).font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("Restore") { workspace.restoreDocument(document) }
                .buttonStyle(.link).font(.caption).disabled(!enabled)
        }
        .accessibilityElement(children: .contain)
    }

    /// “Oct 8 · from Memory › Projects › Silkweb › Progress”.
    static func archivedText(_ archived: MemoryLifecycleEntry.Archived) -> String {
        archived.at.formatted(.dateTime.month(.abbreviated).day()) + " · from "
            + (archived.fromPath.isEmpty ? "Library" : archived.fromPath.replacingOccurrences(of: "/", with: " › "))
    }

    /// Duplicate memory IDs and more than one open claim against this Document.
    private var problem: String? {
        var lines: [String] = []
        let shared = workspace.memoryLinks.paths[link.memoryID]?.count ?? 0
        if shared > 1 { lines.append("\(shared) documents share this memory ID") }
        let open = supersededBy.filter { $0.state != .declined }.count
        if open > 1 { lines.append("\(open) documents claim to replace this one") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func pair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            Text(value).font(.caption).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Change… : a graphical date picker with Clear and Done as small links.
struct ReviewDatePopover: View {
    @State var date: Date
    let onDone: (Date) -> Void
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker("Review date", selection: $date, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden()
            HStack {
                Button("Clear", action: onClear).buttonStyle(.link)
                Spacer()
                Button("Done") { onDone(date) }.buttonStyle(.link)
            }
            .font(.caption)
        }
        .padding(12)
    }
}

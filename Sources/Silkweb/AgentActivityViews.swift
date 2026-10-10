import AppKit
import SilkwebCore
import SwiftUI

/// #137: quiet agent provenance. Receipts reload off the main thread and only update what changed; nothing here
/// moves focus, selection, scroll or tabs, and nothing is announced.
extension LibraryWorkspace {
    nonisolated static func loadAgentActivity(root: URL) async -> AgentActivity {
        await Task.detached(priority: .utility) { AgentActivity.load(root: root) }.value
    }

    /// `.silkweb/agent-events/` changed: reread the receipts only. No rescan, and nothing is written back.
    func reloadAgentActivity() async {
        guard let root, snapshot != nil else { return }
        let previous = agentReloadTask
        let task = Task {
            await previous?.value
            let loaded = await Self.loadAgentActivity(root: root)
            guard !Task.isCancelled, self.root == root else { return }
            agentActivity = loaded
        }
        agentReloadTask = task
        await task.value
        await waitForOutsideDetection()
    }

    func selectAgentActivity() {
        guard hasAgentActivity else { return }
        navigate(folder: nil, documents: [], tag: nil, changesScope: true, agents: true)
    }

    /// The receipt the Info pane describes for one Document, in any scope.
    func agentEntry(for document: LibraryDocument) -> AgentActivityEntry? {
        agentEntriesByPath[document.relativePath].flatMap { $0.document.id == document.id ? $0 : nil }
    }
}

/// The pinned strip in Agent Activity scope: “Agent activity · 14 documents”, Access Requests (#203, opening the
/// Agent Access window since #229) and the All Agents ▾ pull-down.
struct AgentActivityStrip: View {
    let workspace: LibraryWorkspace
    var access = AgentAccessModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let agents = AgentActivity.agents(in: workspace.agentEntries)
        let grants = AgentActivity.grants(in: workspace.agentEntries)
        let waiting = workspace.pendingAccessRequestCount
        HStack {
            Text("Agent activity · \(CountPresentation.label(workspace.documents.count, unit: .document))")
                .lineLimit(1)
            Spacer(minLength: Spacing.small)
            Button(waiting > 0 ? "Access Requests (\(waiting))" : "Access Requests") {
                openWindow(id: AgentAccessModel.sceneID)
                Task { await access.select(.requests) }
            }
            .buttonStyle(.borderless).fixedSize()
            .accessibilityValue(workspace.accessRequestsWaitingLabel ?? "")
            Menu {
                Button("All Agents") {
                    workspace.agentFilter = nil
                    workspace.grantFilter = nil
                    workspace.outsideFilter = false
                }
                Divider()
                ForEach(agents, id: \.name) { agent in
                    Button("\(agent.name) (\(agent.count))") { workspace.agentFilter = agent.name }
                }
                // #229: the grant behind each write; Show in Agent Activity picks one.
                if !grants.isEmpty {
                    Section("Grants") {
                        ForEach(grants, id: \.id) { grant in
                            Button("\(access.label(for: grant.id)) (\(grant.count))") {
                                workspace.grantFilter = grant.id
                            }
                        }
                    }
                }
                // #230: changes no receipt accounts for, after the claimed agents.
                if !workspace.outsideChanges.isEmpty {
                    Divider()
                    Button("Outside Silkweb (\(workspace.outsideChanges.count))") { workspace.outsideFilter = true }
                }
            } label: {
                Text(filterTitle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Filter by agent")
            .accessibilityValue(filterTitle)
        }
        .font(.caption).monospacedDigit().padding(.horizontal, Spacing.small).frame(height: 28)
        .paneStrip(hairline: .bottom)
        .accessibilityElement(children: .contain).accessibilityLabel("Agent activity")
    }

    private var filterTitle: String {
        if workspace.outsideFilter { return "Outside Silkweb" }
        if let grant = workspace.grantFilter { return access.label(for: grant) }
        return workspace.agentFilter ?? "All Agents"
    }
}

/// #230: Document Info's text-only block for a change made outside Silkweb, in the Agent block's label/value pairs.
/// Keep clears the flag; Move to Trash… is the existing Trash command. Nothing happens on its own.
struct OutsideChangeSection: View {
    let change: OutsideChange
    let workspace: LibraryWorkspace

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // With a receipt the Agent block below names the agent; this one only says what changed.
            pair(change.hasReceipt ? "Status" : "Agent", change.label)
            if !change.hasReceipt { pair("Operation", "No Silkweb receipt") }
            HStack(spacing: 8) {
                Button("Keep") { Task { await workspace.keepOutsideChanges([change.document.relativePath]) } }
                    .disabled(!workspace.canKeepOutsideChanges)
                    .accessibilityHint("Stops listing this document as changed outside Silkweb")
                Button("Move to Trash…") { workspace.trashOutsideChanges([change.document.relativePath]) }
                    .disabled(!workspace.canMutate)
            }
            .controlSize(.small)
            Text("Silkweb can’t tell which app made this change.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(change.label)
    }

    private func pair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            Text(value).font(.caption).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Document Info's text-only Agent block (#137, #204): no box and no colour, the same label/value pairs as above it.
struct AgentProvenanceSection: View {
    let provenance: AgentProvenance
    let modified: Date?
    /// The Library, for revealing the newest earlier version in Finder.
    var root: URL? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            pair("Agent", provenance.agentLabel)
            if let session = provenance.session {
                pair("Session", "\(session)  (claimed by the agent)")
            }
            if let client = provenance.client { pair("Client", client) }
            VStack(alignment: .leading, spacing: 4) {
                Text("Operation").font(.headline)
                Text(provenance.operationLabel)
                    .font(provenance.hasReceipt ? .caption.monospaced() : .caption)
                    .textSelection(.enabled)
                    .contextMenu {
                        if let operation = provenance.operationId {
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(operation, forType: .string)
                            }
                        }
                    }
            }
            .accessibilityElement(children: .combine)
            if let created = provenance.created {
                pair("Created", created.formatted(date: .abbreviated, time: .shortened))
            }
            if provenance.updates > 0 {
                pair(
                    "Last update",
                    (provenance.lastUpdate.map { $0.formatted(date: .abbreviated, time: .shortened) + " · " } ?? "")
                        + provenance.updatesLabel)
            }
            if let since = provenance.sinceValue(
                edited: modified.map { $0.formatted(.dateTime.month().day().hour().minute()) })
            {
                pair(provenance.sinceLabel, since)
            }
            if let updates = provenance.agentUpdates { pair("Agent updates", updates.label) }
            if provenance.earlierVersions > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Earlier versions").font(.headline)
                    HStack(spacing: 0) {
                        Text("\(provenance.earlierVersions) saved · ").font(.caption)
                        Button("Show in Finder") { revealNewestVersion() }
                            .buttonStyle(.link).font(.caption)
                            .accessibilityLabel("Show earlier versions in Finder")
                    }
                }
                .accessibilityElement(children: .contain)
            }
            // Display only; the review workflow and its controls come with #140.
            pair("Review", "Not reviewed")
            Text("Agent and session are reported by the agent, not verified.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent provenance")
    }

    /// Selects the newest saved version in Finder; plain `.md` files, readable without Silkweb.
    private func revealNewestVersion() {
        guard let root, let path = provenance.newestVersion else { return }
        NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(path)])
    }

    private func pair(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.headline)
            Text(value).font(.caption).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The provenance one Document Info shows, with the Document it describes, so another selection never shows
/// the previous one's values.
struct LoadedAgentProvenance: Equatable {
    let path: String
    let provenance: AgentProvenance?
}

/// Loads the selected Document's provenance off the main thread. Attached to the always-present Info column
/// (a `.task` on an empty view never runs); the result updates in place, so Info keeps its scroll position.
struct AgentProvenanceLoader: ViewModifier {
    let workspace: LibraryWorkspace
    let document: LibraryDocument?
    @Binding var loaded: LoadedAgentProvenance?

    private struct Identity: Hashable {
        let path: String?
        let modified: Date?
        let receipt: String?
    }

    func body(content: Content) -> some View {
        let receipts = document.flatMap { workspace.agentEntry(for: $0)?.receipts } ?? []
        content.task(
            id: Identity(
                path: document?.relativePath, modified: document?.modified, receipt: receipts.last?.operationId)
        ) {
            guard let document, let root = workspace.snapshot?.rootURL else { return }
            let path = document.relativePath
            let provenance = await Task.detached(priority: .utility) {
                AgentProvenance.load(relativePath: path, root: root, receipts: receipts)
            }.value
            guard !Task.isCancelled else { return }
            let next = LoadedAgentProvenance(path: path, provenance: provenance)
            if loaded != next { loaded = next }
        }
    }
}

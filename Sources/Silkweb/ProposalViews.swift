import AppKit
import SilkwebCore
import SwiftUI

/// The pinned strip in Proposals scope (#140): “Proposals · 4 pending” and the Pending ▾ pull-down.
struct ProposalStrip: View {
    @Bindable var workspace: LibraryWorkspace

    var body: some View {
        HStack {
            Text("Proposals · \(workspace.pendingProposalCount) pending").lineLimit(1)
            Spacer(minLength: Spacing.small)
            Menu {
                ForEach(ProposalFilter.allCases, id: \.self) { filter in
                    Button(filter.rawValue) { workspace.proposalFilter = filter }
                }
            } label: {
                Text(workspace.proposalFilter.rawValue)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Show proposals")
            .accessibilityValue(workspace.proposalFilter.rawValue)
        }
        .font(.caption).monospacedDigit().padding(.horizontal, Spacing.small).frame(height: 28)
        .paneStrip(hairline: .bottom)
        .accessibilityElement(children: .contain).accessibilityLabel("Proposals")
    }
}

/// The Proposals list: `DocumentRow`'s layout with a verb-phrase title, `date · agent · status` and the reason as
/// plain text. Newest first.
struct ProposalList: View {
    @Bindable var workspace: LibraryWorkspace
    @State private var dateReference = Date()

    var body: some View {
        let proposals = workspace.filteredProposals
        if proposals.isEmpty {
            ColumnEmptyState {
                ContentUnavailableView(
                    workspace.proposalFilter == .all
                        ? "No Proposals" : "No \(workspace.proposalFilter.rawValue) Proposals",
                    systemImage: "text.badge.checkmark",
                    description: Text("Agents haven’t proposed any changes."))
            }
        } else {
            List(
                selection: Binding(
                    get: { workspace.selectedProposalID }, set: { workspace.selectedProposalID = $0 })
            ) {
                ForEach(proposals) { proposal in
                    ProposalRow(
                        title: workspace.proposalHeadline(proposal),
                        secondary: workspace.proposalSecondary(proposal, now: dateReference),
                        reason: proposal.reason
                    )
                    .tag(proposal.id)
                    .frame(height: DocumentRow.height)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .accessibilityLabel("Proposals")
        }
    }
}

struct ProposalRow: View {
    let title: String
    let secondary: String
    let reason: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(height: 17)
            Text(secondary).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).frame(height: 15)
            // Plain text: never rendered as Markdown.
            Text(verbatim: reason)
                .font(.system(size: 12)).lineSpacing(DocumentRow.excerptLineSpacing)
                .foregroundStyle(.secondary)
                .lineLimit(2).truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(secondary + ". " + reason)
    }
}

extension LibraryWorkspace {
    /// The row and pane title, with each target's current title.
    func proposalHeadline(_ proposal: AgentProposal) -> String {
        proposal.headline { target in self.currentPath(of: target).map(AgentProposal.title(of:)) }
    }

    /// `date · claude-code · Pending`.
    func proposalSecondary(_ proposal: AgentProposal, now: Date = Date()) -> String {
        let date = proposal.created.map { DocumentRowPresentation.dateLabel($0, now: now, locale: .current) }
        return ([date, proposal.agent.isEmpty ? nil : proposal.agent, statusLabel(proposal)] as [String?])
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Why Apply is unavailable: the banner sentence, `nil` when it can be applied.
    func proposalBlock(_ proposal: AgentProposal, review: ProposalReview?) -> (message: String, showsDocument: Bool)? {
        guard proposal.isPending else { return nil }
        switch review?.block {
        case .missing: return (AgentProposalError.sourceMissing.errorDescription ?? "", false)
        case .outOfDate(let name): return (AgentProposalError.outOfDate(name).errorDescription ?? "", false)
        case nil: break
        }
        if let name = unsavedTarget(proposal) {
            return (AgentProposalError.unsavedChanges(name).errorDescription ?? "", true)
        }
        return nil
    }
}

/// The review pane (#140): replaces the editor while the Proposals scope is selected.
struct ProposalReviewPane: View {
    @Bindable var workspace: LibraryWorkspace
    /// Merge (#141): the After merging pop-up, Keep Sources by default, per Proposal.
    @State private var afterMerging = AfterMerging.keep

    var body: some View {
        if let proposal = workspace.selectedProposal {
            // Laid out at exactly the size the detail column offers: a child's minimum height never grows the
            // column, which would centre it and clip the banner and header under the toolbar.
            GeometryReader { geometry in
                content(proposal).id(proposal.id)
                    .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
            .clipped()
        } else {
            ContentUnavailableView(
                "No Proposal Selected", systemImage: "text.badge.checkmark",
                description: Text("Select a proposal in the list.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func content(_ proposal: AgentProposal) -> some View {
        let review = workspace.proposalReview?.id == proposal.id ? workspace.proposalReview : nil
        let block = workspace.proposalBlock(proposal, review: review)
        VStack(spacing: 0) {
            if let block { banner(block, proposal: proposal) }
            header(proposal)
            Divider()
            Group {
                switch proposal.kind {
                case .edit: edit(review)
                case .move, .rename: organization(proposal, review: review)
                case .merge: merge(proposal, review: review)
                }
            }
            // Only the middle shrinks, so a long diff or preview never pushes the header out of the pane.
            .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            if proposal.isPending {
                buttons(proposal, review: review, block: block)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onExitCommand { workspace.focus(1) }
        .onChange(of: proposal.id) { afterMerging = .keep }
    }

    private func banner(_ block: (message: String, showsDocument: Bool), proposal: AgentProposal) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
            Text(block.message).font(.callout)
            Spacer()
            if block.showsDocument {
                Button("Show Document") { workspace.showProposalTarget(proposal) }
            }
        }
        .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
        .frame(minHeight: 36).paneStrip(hairline: .bottom)
        .accessibilityElement(children: .contain)
    }

    private func header(_ proposal: AgentProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(workspace.proposalHeadline(proposal)).font(.headline)
            Text(byline(proposal)).font(.caption).foregroundStyle(.secondary)
            if let decided = decision(proposal) {
                Text(decided).font(.caption).foregroundStyle(.secondary)
            }
            Text("Reason").font(.subheadline.weight(.semibold)).padding(.top, 4)
            Text(verbatim: proposal.reason).font(.body).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func byline(_ proposal: AgentProposal) -> String {
        let agent = proposal.agent.isEmpty ? "an agent" : proposal.agent
        let date = proposal.created.map { " · " + Self.timestamp($0) } ?? ""
        return "Proposed by \(agent) (claimed)" + date
    }

    private func decision(_ proposal: AgentProposal) -> String? {
        guard !proposal.isPending else { return nil }
        let date = proposal.decided.map { " " + Self.timestamp($0) } ?? ""
        return (proposal.status == .applied ? "Applied" : "Rejected") + date
    }

    /// “Oct 6 at 2:32 PM”.
    static func timestamp(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day()) + " at " + date.formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder private func edit(_ review: ProposalReview?) -> some View {
        if let review, let current = review.current, let proposed = review.proposed, let diff = review.diff {
            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Text("Current Version").frame(maxWidth: .infinity, alignment: .leading)
                    Text("Proposed Version").frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                ConflictComparison(
                    mine: current, disk: proposed, labels: ["Current Version", "Proposed Version"], diff: diff)
            }
            .padding(16)
        } else if review != nil {
            unavailable("The document can’t be shown.")
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func organization(_ proposal: AgentProposal, review: ProposalReview?) -> some View {
        let from: String = review?.paths.first.flatMap { $0 } ?? proposal.targets.first?.path ?? ""
        let to: String = proposal.appliedPath ?? review?.destination ?? Self.intended(proposal, from: from)
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                    GridRow {
                        Text("From").foregroundStyle(.secondary)
                        Text(AgentMemoryContract.displayPath(from)).textSelection(.enabled)
                    }
                    GridRow {
                        Text("To").foregroundStyle(.secondary)
                        Text(AgentMemoryContract.displayPath(to)).textSelection(.enabled)
                    }
                }
                if proposal.isPending {
                    if let links = review?.links {
                        if links.isEmpty {
                            Text("Links to update: none").foregroundStyle(.secondary)
                        } else {
                            DisclosureGroup(
                                "Links to update: \(CountPresentation.label(links.count, unit: .document))"
                            ) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(links, id: \.self) { path in
                                        Text(AgentMemoryContract.displayPath(path)).font(.callout)
                                            .textSelection(.enabled)
                                    }
                                }
                                .padding(.leading, 4)
                            }
                        }
                    } else if review != nil, review?.block == nil {
                        Text("Links to update: couldn’t be checked").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Where a move or rename would put the Document, before Keep Both naming.
    static func intended(_ proposal: AgentProposal, from: String) -> String {
        let name = (from as NSString).lastPathComponent
        if proposal.kind == .move {
            return ((proposal.destination ?? "") as NSString).appendingPathComponent(name)
        }
        let folder = (from as NSString).deletingLastPathComponent as NSString
        return folder.appendingPathComponent(LibraryWorkspace.renamedFile(proposal, path: from))
    }

    static func mergeTitle(_ proposal: AgentProposal) -> String {
        let folder = proposal.destination ?? ""
        let place = folder.isEmpty ? "the Library" : AgentMemoryContract.displayPath(folder)
        return "New Document “\(proposal.title ?? "")” in \(place)"
    }

    static func sourceLabel(_ target: AgentProposal.Target, path: String?, checked: Bool) -> String {
        let label = AgentMemoryContract.displayPath(path ?? target.path)
        return path == nil && checked ? label + " (missing)" : label
    }

    @ViewBuilder private func merge(_ proposal: AgentProposal, review: ProposalReview?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(Self.mergeTitle(proposal)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ProposalTextPane(text: proposal.body ?? "", label: "Proposed Document")
            Text("Sources").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(proposal.targets.enumerated()), id: \.offset) { index, target in
                Text(Self.sourceLabel(target, path: review?.paths[safe: index] ?? nil, checked: review != nil))
                    .font(.callout).textSelection(.enabled)
            }
            if proposal.isPending {
                Picker("After merging:", selection: $afterMerging) {
                    ForEach(AfterMerging.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).fixedSize()
                .help("Keep Sources leaves the \(proposal.targets.count) sources as they are.")
            }
        }
        .padding(16)
    }

    private func buttons(
        _ proposal: AgentProposal, review: ProposalReview?, block: (message: String, showsDocument: Bool)?
    )
        -> some View
    {
        let readOnly = workspace.snapshot?.isReadOnly == true
        let busy = workspace.decidingProposal != nil || !workspace.canMutate
        let applyHelp = readOnly ? "This library is read-only." : block?.message ?? ""
        return HStack(spacing: 8) {
            Spacer()
            // Neither is the default button: Return does nothing here.
            Button("Reject") { workspace.rejectProposal(proposal.id) }
                .disabled(readOnly || busy)
            Button("Apply") { workspace.applyProposal(proposal.id, afterMerging: afterMerging) }
                .disabled(readOnly || busy || block != nil || review == nil)
                .help(applyHelp)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .paneStrip(hairline: .top)
    }

    private func unavailable(_ message: String) -> some View {
        Text(message).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A read-only text pane for a merge's new Document.
struct ProposalTextPane: NSViewRepresentable {
    let text: String
    let label: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = DiffTextView.makeScrollView()
        scroll.documentView?.setAccessibilityLabel(label)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        (view.documentView as? DiffTextView)?.show(text, changed: [], removed: false)
    }

    /// Takes the space it's offered; the text scrolls inside, never sizing the pane.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 200)
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

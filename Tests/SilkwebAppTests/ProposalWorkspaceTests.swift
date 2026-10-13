import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #140: Proposals in the real library window, never ordered on screen. The review pane shows the edit diff,
/// Apply and Reject each push one Library Undo entry, a rename keeps identity and rewrites links, and unsaved
/// changes or a changed base block Apply without touching the Document.
final class ProposalWorkspaceTests: XCTestCase {
    static let notes = "Memory/Projects/Silkweb/Notes"
    static let plan = notes + "/Plan.md"
    static let ideas = notes + "/Ideas.md"
    static let original = "# Plan\n\nOne\nTwo\nThree\n"
    static let edited = "# Plan\n\nOne\nTwo, revised\nThree\n"

    private static func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private static func propose(_ root: URL, _ request: AgentProposeRequest) throws -> AgentProposal {
        let scope = try AgentScope(
            grant: AgentGrant(project: "Silkweb", library: LibraryLocation(path: root.path), access: .readCreatePropose)
        )
        let service = AgentProposeService(
            library: root, grantId: "Silkweb", scope: scope, maxBytes: AgentGrantLimits.defaultMaxCreateBytes,
            maxReadBytes: AgentGrantLimits.defaultMaxReadBytes)
        return try service.propose(request).proposal
    }

    private static func request(
        _ kind: AgentProposal.Kind, key: String, path: String? = nil, sources: [String] = [],
        revision: String? = nil, body: String? = nil, destination: String? = nil, title: String? = nil
    ) -> AgentProposeRequest {
        AgentProposeRequest(
            kind: kind, idempotencyKey: key, path: path, sources: sources, expectedRevision: revision, body: body,
            destination: destination, title: title, reason: "Keep the notes tidy.", agent: "claude-code",
            session: "s-1")
    }

    @MainActor
    func testOffscreenReviewApplyRejectUndoAndBlocks() async throws {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebProposals-" + UUID().uuidString)
        let unresolved = container.appendingPathComponent("Library")
        try FileManager.default.createDirectory(
            at: unresolved.appendingPathComponent(Self.notes), withIntermediateDirectories: true)
        let root = unresolved.resolvingSymlinksInPath()
        let planURL = root.appendingPathComponent(Self.plan)
        let ideasURL = root.appendingPathComponent(Self.ideas)
        try Data(Self.original.utf8).write(to: planURL)
        try Data("# Ideas\n\nSee [the plan](Plan.md).\n".utf8).write(to: ideasURL)
        let base = AgentCreateService.digest(try Data(contentsOf: planURL))
        let ideasBase = AgentCreateService.digest(try Data(contentsOf: ideasURL))
        let edit = try Self.propose(
            root, Self.request(.edit, key: "e1", path: Self.plan, revision: base, body: Self.edited))
        let rename = try Self.propose(root, Self.request(.rename, key: "r1", path: Self.plan, title: "Roadmap"))
        let dirty = try Self.propose(
            root, Self.request(.edit, key: "e2", path: Self.ideas, revision: ideasBase, body: "# Ideas\n\nAgent.\n"))
        let merge = try Self.propose(
            root,
            Self.request(
                .merge, key: "m1", sources: [Self.plan, Self.ideas], body: "# Combined\n\nBoth.\n",
                destination: Self.notes, title: "Combined"))

        let suite = "Silkweb.Proposals." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let workspace = LibraryWorkspace(defaults: defaults, columnAutosaveName: suite)
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unifiedCompact
        let controller = NSHostingController(rootView: LibraryWorkspaceView(workspace: workspace))
        controller.sizingOptions = []
        window.contentViewController = controller
        window.setFrame(NSRect(x: 0, y: 0, width: 1400, height: 900), display: false)
        defer {
            window.contentViewController = nil
            window.close()
            defaults.removePersistentDomain(forName: suite)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.contains(suite) {
                UserDefaults.standard.removeObject(forKey: key)
            }
            try? FileManager.default.removeItem(at: container)
        }
        let content = try XCTUnwrap(window.contentView)
        func layout() { content.superview?.layoutSubtreeIfNeeded() }
        func resizeSweep() async throws {
            for width: CGFloat in [900, 2400, 1100, 1400] {
                window.setContentSize(NSSize(width: width, height: width == 900 ? 560 : 900))
                try await Task.sleep(for: .milliseconds(1))
                layout()
            }
        }
        /// A long diff or preview scrolls inside the review pane; it never grows the detail column past the window,
        /// which centred it and clipped the header under the toolbar.
        func assertDetailFits(_ state: String) {
            layout()
            let hosts = Self.descendants(content).filter { "\(type(of: $0))".contains("SystemSplitView") }
            XCTAssertFalse(hosts.isEmpty, state)
            for host in hosts {
                let column = host.superview?.bounds.height ?? 0
                XCTAssertLessThanOrEqual(host.frame.height, column + 0.5, "\(state): the detail overflows")
                XCTAssertGreaterThanOrEqual(host.frame.minY, -0.5, "\(state): the detail is shifted")
            }
        }
        func status(_ id: String) -> AgentProposal.Status? { workspace.proposals.first { $0.id == id }?.status }
        func select(_ id: String) async throws {
            workspace.selectedProposalID = id
            try await waitUntil("the review loads", timeout: .seconds(10)) {
                layout()
                return workspace.proposalReview?.id == id
            }
        }
        func decide(_ label: String, _ action: () -> Void, until done: @escaping () -> Bool) async throws {
            action()
            try await waitUntil(label, timeout: .seconds(10)) { done() && workspace.decidingProposal == nil }
            try await waitUntil("\(label): idle", timeout: .seconds(10)) { !workspace.mutating }
        }

        try await openLibrary(root, in: workspace)
        try await waitUntil("the proposals load", timeout: .seconds(10)) { workspace.proposals.count == 4 }
        XCTAssertTrue(workspace.hasProposals)
        XCTAssertEqual(workspace.pendingProposalCount, 4)
        workspace.selectProposals()
        await workspace.waitForNavigation()
        XCTAssertTrue(workspace.proposalScope)
        XCTAssertEqual(workspace.filteredProposals.count, 4)

        // Edit: the review pane shows both versions with the changed line marked in each.
        try await select(edit.id)
        try await waitUntil("the diff panes load", timeout: .seconds(10)) {
            layout()
            return Self.descendants(content).compactMap { $0 as? DiffTextView }.count == 2
        }
        let panes = Self.descendants(content).compactMap { $0 as? DiffTextView }
        XCTAssertEqual(Set(panes.map(\.string)), [Self.original, Self.edited])
        XCTAssertTrue(panes.allSatisfy { $0.changedRanges.count == 1 }, "one changed line in each pane")
        let current = try XCTUnwrap(panes.first { $0.string == Self.original })
        XCTAssertTrue(current.marksRemovals)
        XCTAssertTrue(current.accessibilityValue()?.contains("Removed: Two") == true)
        try await resizeSweep()
        assertDetailFits("edit")
        XCTAssertTrue(current.bandRects().allSatisfy { $0.width == current.bounds.width && $0.height > 0 })

        // Apply, then Undo Apply Proposal: the bytes come back and the Proposal is pending again.
        try await decide("the edit applies", { workspace.applyProposal(edit.id) }) { status(edit.id) == .applied }
        XCTAssertEqual(try String(contentsOf: planURL, encoding: .utf8), Self.edited)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Apply Proposal")
        XCTAssertEqual(workspace.selectedProposalID, edit.id, "the selection stays on the proposal")
        workspace.undoLibrary()
        try await waitUntil("the apply is undone", timeout: .seconds(10)) {
            status(edit.id) == .pending && !workspace.mutating
        }
        XCTAssertEqual(try String(contentsOf: planURL, encoding: .utf8), Self.original)

        // Reject never touches the Document; Undo Reject Proposal sets it back to Pending.
        try await decide("the edit is rejected", { workspace.rejectProposal(edit.id) }) { status(edit.id) == .rejected }
        XCTAssertEqual(try String(contentsOf: planURL, encoding: .utf8), Self.original)
        XCTAssertEqual(workspace.libraryUndo.last?.title, "Undo Reject Proposal")
        workspace.undoLibrary()
        try await waitUntil("the reject is undone", timeout: .seconds(10)) {
            status(edit.id) == .pending && !workspace.mutating
        }

        // Rename: identity kept, links rewritten like Move To…, and undone the same way.
        let planID = try XCTUnwrap(workspace.itemPathsByID.first { $0.value == Self.plan }?.key)
        try await select(rename.id)
        try await waitUntil("the links to update load", timeout: .seconds(10)) {
            workspace.proposalReview?.links != nil
        }
        XCTAssertEqual(workspace.proposalReview?.links, [Self.ideas])
        try await resizeSweep()
        assertDetailFits("rename")
        try await decide("the rename applies", { workspace.applyProposal(rename.id) }) {
            status(rename.id) == .applied
        }
        let renamed = Self.notes + "/Roadmap.md"
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(renamed).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: planURL.path))
        XCTAssertEqual(workspace.itemPathsByID[planID], renamed, "the Document keeps its identity")
        XCTAssertTrue(try String(contentsOf: ideasURL, encoding: .utf8).contains("(Roadmap.md)"))
        workspace.undoLibrary()
        try await waitUntil("the rename is undone", timeout: .seconds(10)) {
            status(rename.id) == .pending && !workspace.mutating
        }
        XCTAssertEqual(try String(contentsOf: planURL, encoding: .utf8), Self.original)
        XCTAssertTrue(try String(contentsOf: ideasURL, encoding: .utf8).contains("(Plan.md)"))

        // Merge: the pane previews the new Document; nothing is applied here (Apply would use the real Trash).
        try await select(merge.id)
        try await waitUntil("the merge preview loads", timeout: .seconds(10)) {
            layout()
            return Self.descendants(content).compactMap { $0 as? DiffTextView }.contains {
                $0.string == "# Combined\n\nBoth.\n"
            }
        }
        assertDetailFits("merge")

        // Unsaved changes block Apply; after the save the base changed, so it's Out of Date.
        let ideasBefore = try Data(contentsOf: ideasURL)
        workspace.navigate(folder: Self.notes, documents: [Self.ideas])
        await workspace.waitForNavigation()
        try await waitUntil("the editor shows Ideas", timeout: .seconds(10)) {
            workspace.editor.url?.standardizedFileURL == ideasURL.standardizedFileURL
        }
        workspace.editor.edit(workspace.editor.text + "Owner typing.\n")
        XCTAssertEqual(workspace.unsavedTarget(dirty), "Ideas")
        XCTAssertEqual(
            workspace.proposalBlock(dirty, review: nil)?.message,
            "“Ideas” has unsaved changes. Save or discard them before applying.")
        workspace.applyProposal(dirty.id)
        try await waitUntil("the blocked apply ends", timeout: .seconds(10)) {
            workspace.decidingProposal == nil && !workspace.mutating
        }
        XCTAssertEqual(status(dirty.id), .pending)
        XCTAssertEqual(try Data(contentsOf: ideasURL), ideasBefore, "a blocked apply changes nothing")
        let saved = await workspace.flushEditors()
        XCTAssertTrue(saved)
        XCTAssertNil(workspace.unsavedTarget(dirty))
        workspace.selectProposals()
        await workspace.waitForNavigation()
        try await select(dirty.id)
        XCTAssertEqual(workspace.proposalReview?.block, .outOfDate("Ideas"))
        assertDetailFits("out-of-date")
        workspace.applyProposal(dirty.id)
        try await waitUntil("the out-of-date apply ends", timeout: .seconds(10)) {
            workspace.decidingProposal == nil && !workspace.mutating
        }
        XCTAssertEqual(status(dirty.id), .pending)
        XCTAssertTrue(try String(contentsOf: ideasURL, encoding: .utf8).hasSuffix("Owner typing.\n"))
        try await waitUntil("the list says Out of Date", timeout: .seconds(10)) {
            workspace.statusLabel(dirty) == "Out of Date"
        }
        try await resizeSweep()
    }
}

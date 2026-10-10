import AppKit
import SilkwebCore
import SwiftUI

/// Owns cancellable work for both search surfaces; the index actor owns all disk IO.
@MainActor @Observable
final class LibrarySearch {
    var text = "" {
        didSet { if text.isEmpty { completed = nil } }
    }
    var folderScope: UUID?
    /// Search Library's All Libraries segment (#197): every open Library, not only this one. A new search starts
    /// with this Library.
    var allLibraries = false
    /// Quick Open's All Libraries toggle (#197, owner decision): off each time Quick Open opens.
    var quickAllLibraries = false
    var results: [SearchResult] = []
    var isSearching = false
    var isQuickSearching = false
    var resultText = ""
    var quickResultText = ""
    private var completed: SearchRequestIdentity?
    private var quickCompleted: SearchRequestIdentity?
    @ObservationIgnored private var request: UUID?
    @ObservationIgnored private var quickRequest: UUID?
    #if DEBUG
        @ObservationIgnored private(set) var queryCount = 0
        @ObservationIgnored var resultsBodyCount = 0
    #endif
    var hasPendingQuery: Bool {
        completed?.text != text || completed?.scope != searchScope || completed?.allLibraries != searchesAllLibraries
    }
    var quickHasPendingQuery: Bool {
        quickCompleted?.text != quickText || quickCompleted?.allLibraries != quickSearchesAllLibraries
    }
    /// The folder Search Library is scoped to; All Libraries has none.
    var searchScope: UUID? { searchesAllLibraries ? nil : folderScope }
    var searchesAllLibraries: Bool { allLibraries && !otherLibraries().isEmpty }
    var quickSearchesAllLibraries: Bool { quickAllLibraries && !otherLibraries().isEmpty }
    var quickText = ""
    var quickResults: [SearchResult] = []
    var showsQuickOpen = false
    var focusRequest = 0
    var revision = 0
    var state: SearchIndexState = .ready
    var error: String?
    @ObservationIgnored private(set) var index: SearchIndex?
    /// BM25 statistics for Search Library (#179); Quick Open never reads them.
    @ObservationIgnored weak var knowledge: LibraryKnowledge?
    /// The Tags typed `tag:` filters match.
    @ObservationIgnored private var metadata: LibraryMetadata?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private weak var previousResponder: NSResponder?
    @ObservationIgnored private weak var previousWindow: NSWindow?

    /// Another open Library in the window, for All Libraries (#197).
    struct Peer {
        let name: String
        let root: URL
        let search: LibrarySearch
    }
    /// The window's other loaded Libraries, in sidebar order. Set by the registry; a lone workspace has none.
    @ObservationIgnored var otherLibraries: @MainActor () -> [Peer] = { [] }
    /// The Library's window, where Quick Open shows. Set by the workspace; nil falls back to the key window.
    @ObservationIgnored var window: @MainActor () -> NSWindow? = { nil }
    /// The id each other Library's document shows under, kept for the session so a selected row stays selected.
    @ObservationIgnored private var foreignIDs: [ForeignKey: UUID] = [:]
    /// The rows of the last All Libraries results that belong to another Library: their Library and real result.
    @ObservationIgnored private var foreignResults: [UUID: (root: URL, result: SearchResult)] = [:]
    @ObservationIgnored private var quickForeignResults: [UUID: (root: URL, result: SearchResult)] = [:]
    private struct ForeignKey: Hashable {
        let root: URL
        let id: UUID
    }

    /// A row from another Library: where it lives and the result to open there.
    func foreignResult(_ id: UUID) -> (root: URL, result: SearchResult)? {
        foreignResults[id] ?? quickForeignResults[id]
    }

    deinit {
        buildTask?.cancel()
        stateTask?.cancel()
    }

    var indexingNote: String? {
        switch state {
        case .building(let indexed, let total):
            return "Indexing library… \(indexed.formatted()) of \(total.formatted()) · Results may be incomplete"
        case .rebuilding: return "Rebuilding search index… Results may be incomplete"
        case .ready: return nil
        }
    }

    func reset() {
        buildTask?.cancel()
        stateTask?.cancel()
        completed = nil; quickCompleted = nil; request = nil; quickRequest = nil
        isSearching = false; isQuickSearching = false
        root = nil
        index = nil
        metadata = nil
        text = ""; quickText = ""; results = []; quickResults = []
        folderScope = nil
        allLibraries = false; quickAllLibraries = false
        foreignResults = [:]; quickForeignResults = [:]
        error = nil
        dismissQuickOpen(restoreFocus: false)
    }

    func install(_ snapshot: LibrarySnapshot) {
        // A Tag edit leaves the index unchanged but changes what `tag:` matches.
        let retagged =
            root == snapshot.rootURL
            && (metadata?.tags != snapshot.metadata.tags
                || metadata?.tagsByDocument != snapshot.metadata.tagsByDocument)
        metadata = snapshot.metadata
        if retagged { revision += 1 }
        if root != snapshot.rootURL {
            buildTask?.cancel()
            stateTask?.cancel()
            completed = nil; quickCompleted = nil
            root = snapshot.rootURL
            index = SearchIndex(root: snapshot.rootURL)
            text = ""; quickText = ""; results = []; quickResults = []
            folderScope = nil
            dismissQuickOpen(restoreFocus: false)
            let index = index!
            stateTask = Task { [weak self] in
                for await state in await index.states() {
                    guard !Task.isCancelled, let self else { return }
                    if self.state != state { self.state = state }
                }
            }
        }
        buildTask?.cancel()
        guard let index else { return }
        buildTask = Task { [weak self] in
            do {
                let changed = try await index.reconcile(snapshot)
                guard !Task.isCancelled else { return }
                self?.error = nil
                if changed { self?.revision += 1 }
            } catch is CancellationError {} catch {
                self?.error = "Search is unavailable: \(error.localizedDescription)"
            }
        }
    }

    func waitForIndex() async { await buildTask?.value }

    /// Finishes a debouncing query now so Return chooses from the text in the field (silkweb-1.75).
    /// False when results for that text still aren't available (no index, error, or the text changed again).
    func settle(quick: Bool) async -> Bool {
        if !quick, text.isEmpty { return false }
        if quick ? quickHasPendingQuery : hasPendingQuery { await query(quick: quick, debounce: false) }
        return !(quick ? quickHasPendingQuery : hasPendingQuery)
    }

    func query(quick: Bool, debounce: Bool = true) async {
        guard !Task.isCancelled, let index else { return }
        let queryText = quick ? quickText : text
        let scope = quick ? nil : searchScope
        let everywhere = quick ? quickSearchesAllLibraries : searchesAllLibraries
        let identity = SearchRequestIdentity(
            text: queryText, scope: scope, allLibraries: everywhere, revision: revision)
        guard identity != (quick ? quickCompleted : completed) else { return }
        let token = UUID()
        if quick { quickRequest = token } else { request = token }
        // Keep old rows and count during debounce. Only slow queries show progress.
        let progress = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            guard let self else { return }
            if quick, self.quickRequest == token { self.isQuickSearching = true }
            if !quick, self.request == token { self.isSearching = true }
        }
        defer {
            progress.cancel()
            if quick, quickRequest == token { isQuickSearching = false }
            if !quick, request == token { isSearching = false }
        }
        do {
            if debounce {
                try await Task.sleep(for: .milliseconds(150))
                // Return may have settled this exact query during the debounce.
                guard identity != (quick ? quickCompleted : completed) else { return }
            }
            #if DEBUG
                queryCount += 1
            #endif
            var hits = try await Self.hits(
                queryText, quick: quick, scope: scope, index: index, root: root, knowledge: knowledge,
                metadata: metadata)
            var foreign: [UUID: (root: URL, result: SearchResult)] = [:]
            if everywhere, let root {
                // #197: this Library's rows first, then each other Library's in sidebar order; every row's location
                // leads with its Library. Quick Open takes the best of each Library in turn, 12 rows in all.
                var groups = [hits.map { $0.inLibrary(root.lastPathComponent, id: $0.id) }]
                for peer in otherLibraries() {
                    guard let peerIndex = peer.search.index else { continue }
                    let peerHits = try await Self.hits(
                        queryText, quick: quick, scope: nil, index: peerIndex, root: peer.search.root,
                        knowledge: peer.search.knowledge, metadata: peer.search.metadata)
                    groups.append(
                        peerHits.map { hit in
                            let key = ForeignKey(root: peer.root, id: hit.id)
                            let id = foreignIDs[key] ?? UUID()
                            foreignIDs[key] = id
                            foreign[id] = (peer.root, hit)
                            return hit.inLibrary(peer.name, id: id)
                        })
                }
                hits = quick ? Self.interleave(groups, limit: 12) : groups.flatMap { $0 }
            }
            try Task.checkCancellation()
            guard self.index === index, queryText == (quick ? quickText : text),
                quick || scope == searchScope,
                everywhere == (quick ? quickSearchesAllLibraries : searchesAllLibraries),
                identity.revision == revision
            else { return }
            let previous = quick ? quickCompleted : completed
            let countChanged = hits.count != (quick ? quickResults.count : results.count)
            if quick {
                quickForeignResults = foreign
                if quickResults != hits { quickResults = hits }
                if quickResultText != queryText { quickResultText = queryText }
                quickCompleted = identity
            } else {
                foreignResults = foreign
                if results != hits { results = hits }
                if resultText != queryText { resultText = queryText }
                completed = identity
            }
            if countChanged || previous?.text != queryText {
                NSAccessibility.post(
                    element: NSApplication.shared.keyWindow as Any, notification: .announcementRequested,
                    userInfo: [
                        .announcement: Self.resultCount(hits.count),
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ])
            }
        } catch is CancellationError {} catch {
            self.error = "Search is unavailable: \(error.localizedDescription)"
        }
    }

    /// One Library's rows for a query: Quick Open's recents for empty text.
    private static func hits(
        _ text: String, quick: Bool, scope: UUID?, index: SearchIndex, root: URL?, knowledge: LibraryKnowledge?,
        metadata: LibraryMetadata?
    ) async throws -> [SearchResult] {
        if quick && text.isEmpty { return try await index.recentResults() }
        var ranking: KnowledgeTermStatistics?
        if !quick, let knowledge = knowledge?.index, knowledge.root == root?.standardizedFileURL {
            ranking = await knowledge.termStatistics(for: ParsedSearchQuery(text).rankingTerms)
        }
        return try await index.query(
            SearchQuery(
                text,
                scope: scope.map { .folder($0, includeSubfolders: true) } ?? .library,
                mode: quick ? .quickOpen : .library, limit: quick ? 12 : Int.max, ranking: ranking,
                metadata: quick ? nil : metadata))
    }

    /// Each list's first row in turn, then each second row, and so on: the first list wins ties.
    static func interleave<Element>(_ lists: [[Element]], limit: Int) -> [Element] {
        var result: [Element] = []
        var rank = 0
        while result.count < limit, lists.contains(where: { $0.count > rank }) {
            for list in lists where list.count > rank && result.count < limit { result.append(list[rank]) }
            rank += 1
        }
        return result
    }

    static func resultCount(_ count: Int) -> String {
        CountPresentation.label(count, unit: .result)
    }

    func toggleQuickOpen() {
        if showsQuickOpen { dismissQuickOpen(); return }
        // #226: the panel's field takes focus from this responder; dismissing gives it back.
        previousWindow = window() ?? NSApplication.shared.keyWindow
        previousResponder = previousWindow?.firstResponder
        quickCompleted = nil
        quickText = ""
        quickResults = []
        quickAllLibraries = false
        showsQuickOpen = true
    }

    func dismissQuickOpen(restoreFocus: Bool = true) {
        showsQuickOpen = false
        if restoreFocus, let previousResponder, let previousWindow {
            DispatchQueue.main.async { [weak previousWindow, weak previousResponder] in
                previousWindow?.makeFirstResponder(previousResponder)
            }
        }
        previousResponder = nil
        previousWindow = nil
    }
}

extension LibraryWorkspace {
    /// Return in Search Library or Quick Open: the selected row, else the first, of the current query's results.
    /// A pending query is awaited first; nothing opens when it has no results.
    func openSearchSelection(_ selected: UUID?, quick: Bool, pinned: Bool = false) async {
        guard await search.settle(quick: quick) else { return }
        let results = quick ? search.quickResults : filteredSearchResults
        guard let result = results.first(where: { $0.id == selected }) ?? results.first else { return }
        // A filter-only query selects nothing in the editor (#179).
        await openSearchResult(result, findText: quick ? nil : ParsedSearchQuery(search.text).findText, pinned: pinned)
    }

    func openSearchResult(_ result: SearchResult, findText: String? = nil, pinned: Bool = false) async {
        if let foreign = search.foreignResult(result.id) {
            // #197: another Library's row makes that Library current and opens the document there, as its own
            // search would; this Library's search ends as an open does.
            guard let shell, let other = shell.workspace(for: foreign.root), other !== self else { return }
            search.dismissQuickOpen(restoreFocus: false)
            search.text = ""
            shell.focus(other)
            await other.openSearchResult(foreign.result, findText: findText, pinned: pinned)
            return
        }
        guard let snapshot, let document = snapshot.documents.first(where: { $0.id == result.id }) else { return }
        let url = snapshot.rootURL.appendingPathComponent(document.relativePath)
        let folder = snapshot.folders.first { $0.id == document.folderID }?.relativePath
        navigate(folder: folder, documents: [document.relativePath], pinned: pinned)
        // Judge the open inside the navigation queue, so anyone awaiting navigation sees Quick Open
        // already dismissed and no other navigation can land in between (#81).
        var opened = false
        await afterNavigation { [self] in
            guard editor.url == url, session.selectedDocuments == [document.relativePath] else { return }
            opened = true
            search.dismissQuickOpen(restoreFocus: false)
            search.text = ""
            revision += 1
            focus(2)
        }
        guard opened else { return }
        if let findText, !findText.isEmpty {
            NSPasteboard(name: .find).clearContents()
            NSPasteboard(name: .find).setString(findText, forType: .string)
            // Hosting updates the NSTextView after navigation publishes. Never select
            // a range against the previous document's text.
            for _ in 0..<50 {
                guard editor.url == url else { return }
                if let view = preview.editor, view.string == editor.text {
                    let literal = (view.string as NSString).range(
                        of: findText, options: [.caseInsensitive, .diacriticInsensitive])
                    let range =
                        literal.location != NSNotFound
                        ? literal
                        : SearchNavigation.matchRanges(in: view.string, query: findText).min {
                            $0.location < $1.location
                        } ?? literal
                    if range.location != NSNotFound {
                        NSPasteboard(name: .find).clearContents()
                        NSPasteboard(name: .find).setString(
                            (view.string as NSString).substring(with: range), forType: .string)
                        view.setSelectedRange(range)
                        view.scrollRangeToVisible(range)
                        view.showFindIndicator(for: range)
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
    }
}

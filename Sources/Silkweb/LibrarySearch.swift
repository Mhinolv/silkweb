import AppKit
import SwiftUI
import SilkwebCore

/// Owns cancellable work for both search surfaces; the index actor owns all disk IO.
@MainActor @Observable
final class LibrarySearch {
    var text = "" {
        didSet { if text.isEmpty { completed = nil } }
    }
    var folderScope: UUID?
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
    var hasPendingQuery: Bool { completed?.text != text || completed?.scope != folderScope }
    var quickHasPendingQuery: Bool { quickCompleted?.text != quickText }
    var quickText = ""
    var quickResults: [SearchResult] = []
    var showsQuickOpen = false
    var focusRequest = 0
    var revision = 0
    var state: SearchIndexState = .ready
    var error: String?
    @ObservationIgnored private(set) var index: SearchIndex?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var stateTask: Task<Void, Never>?
    @ObservationIgnored private weak var previousResponder: NSResponder?
    @ObservationIgnored private weak var previousWindow: NSWindow?

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
        text = ""; quickText = ""; results = []; quickResults = []
        folderScope = nil
        error = nil
        dismissQuickOpen(restoreFocus: false)
    }

    func install(_ snapshot: LibrarySnapshot) {
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
            } catch is CancellationError { } catch {
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
        let scope = quick ? nil : folderScope
        let identity = SearchRequestIdentity(text: queryText, scope: scope, revision: revision)
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
            let hits = quick && queryText.isEmpty ? try await index.recentResults() : try await index.query(SearchQuery(queryText,
                scope: scope.map { .folder($0, includeSubfolders: true) } ?? .library,
                mode: quick ? .quickOpen : .library, limit: quick ? 12 : Int.max))
            try Task.checkCancellation()
            guard self.index === index, queryText == (quick ? quickText : text),
                  quick || scope == folderScope, identity.revision == revision else { return }
            let previous = quick ? quickCompleted : completed
            let countChanged = hits.count != (quick ? quickResults.count : results.count)
            if quick {
                if quickResults != hits { quickResults = hits }
                if quickResultText != queryText { quickResultText = queryText }
                quickCompleted = identity
            } else {
                if results != hits { results = hits }
                if resultText != queryText { resultText = queryText }
                completed = identity
            }
            if countChanged || previous?.text != queryText {
                NSAccessibility.post(element: NSApplication.shared.keyWindow as Any, notification: .announcementRequested,
                                     userInfo: [.announcement: Self.resultCount(hits.count), .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            }
        } catch is CancellationError { } catch {
            self.error = "Search is unavailable: \(error.localizedDescription)"
        }
    }

    static func resultCount(_ count: Int) -> String {
        CountPresentation.label(count, unit: .result)
    }

    func toggleQuickOpen() {
        if showsQuickOpen { dismissQuickOpen(); return }
        previousWindow = NSApplication.shared.keyWindow
        previousResponder = previousWindow?.firstResponder
        quickCompleted = nil
        quickText = ""
        quickResults = []
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
        await openSearchResult(result, findText: quick ? nil : search.text, pinned: pinned)
    }

    func openSearchResult(_ result: SearchResult, findText: String? = nil, pinned: Bool = false) async {
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
                    let literal = (view.string as NSString).range(of: findText, options: [.caseInsensitive, .diacriticInsensitive])
                    let range = literal.location != NSNotFound ? literal :
                        SearchNavigation.matchRanges(in: view.string, query: findText).min { $0.location < $1.location } ?? literal
                    if range.location != NSNotFound {
                        NSPasteboard(name: .find).clearContents()
                        NSPasteboard(name: .find).setString((view.string as NSString).substring(with: range), forType: .string)
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

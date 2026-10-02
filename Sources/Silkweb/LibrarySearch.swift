import AppKit
import SwiftUI
import SilkwebCore

/// Owns cancellable work for both search surfaces; the index actor owns all disk IO.
@MainActor @Observable
final class LibrarySearch {
    var text = ""
    var folderScope: UUID?
    var results: [SearchResult] = []
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
            root = snapshot.rootURL
            index = SearchIndex(root: snapshot.rootURL)
            text = ""; quickText = ""; results = []; quickResults = []
            folderScope = nil
            dismissQuickOpen(restoreFocus: false)
            let index = index!
            stateTask = Task { [weak self] in
                for await state in await index.states() {
                    guard !Task.isCancelled, let self else { return }
                    self.state = state
                    self.revision += 1
                }
            }
        }
        buildTask?.cancel()
        guard let index else { return }
        buildTask = Task { [weak self] in
            do {
                try await index.reconcile(snapshot)
                guard !Task.isCancelled else { return }
                self?.error = nil
                self?.revision += 1
            } catch is CancellationError { } catch {
                self?.error = "Search is unavailable: \(error.localizedDescription)"
            }
        }
    }

    func waitForIndex() async { await buildTask?.value }

    func query(quick: Bool) async {
        guard let index else { return }
        let queryText = quick ? quickText : text
        let scope = folderScope
        do {
            try await Task.sleep(for: .milliseconds(150))
            let hits = quick && queryText.isEmpty ? try await index.recentResults() : try await index.query(SearchQuery(queryText,
                scope: quick ? .library : scope.map { .folder($0, includeSubfolders: true) } ?? .library,
                mode: quick ? .quickOpen : .library, limit: quick ? 12 : Int.max))
            try Task.checkCancellation()
            guard self.index === index, queryText == (quick ? quickText : text), quick || scope == folderScope else { return }
            if quick { quickResults = hits } else { results = hits }
            NSAccessibility.post(element: NSApp.keyWindow as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: "\(hits.count) results", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        } catch is CancellationError { } catch {
            self.error = "Search is unavailable: \(error.localizedDescription)"
        }
    }

    func toggleQuickOpen() {
        if showsQuickOpen { dismissQuickOpen(); return }
        previousWindow = NSApp.keyWindow
        previousResponder = previousWindow?.firstResponder
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
    func openSearchResult(_ result: SearchResult, findText: String? = nil) async {
        guard let snapshot, let document = snapshot.documents.first(where: { $0.id == result.id }) else { return }
        let url = snapshot.rootURL.appendingPathComponent(document.relativePath)
        let folder = snapshot.folders.first { $0.id == document.folderID }?.relativePath
        navigate(folder: folder, documents: [document.relativePath])
        await waitForNavigation()
        guard editor.url == url, session.selectedDocuments == [document.relativePath] else { return }
        search.dismissQuickOpen(restoreFocus: false)
        search.text = ""
        revision += 1
        focus(2)
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

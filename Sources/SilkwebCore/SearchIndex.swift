import Foundation

/// One per library. Consumers reconcile each scanner snapshot and call update after a
/// successful save. Disk IO and queries never execute on the main actor.
public actor SearchIndex {
    private struct Record: Codable, Equatable, Sendable {
        var id: UUID
        var folderID: UUID
        var path: String
        var name: String
        var modified: Date?
        var identity: String?
        var body: String
    }
    /// Envelope fields the query filters read (#179).
    private struct Envelope: Sendable {
        var type: String?
        var status: String?
        var project: String?
        var created: Date?
    }
    private struct Entry: Sendable {
        var record: Record
        var title: String
        var body: String
        var envelope: Envelope?
        init(_ record: Record) {
            self.record = record
            // Native UTF-8 once, so byte matching never transcodes a bridged string per query.
            title = searchFold(record.name)
            title.makeContiguousUTF8()
            body = searchFold(record.body)
            body.makeContiguousUTF8()
            if case .envelope(let parsed, _) = MemoryEnvelope.parse(record.body) {
                envelope = Envelope(
                    type: parsed.string("type"), status: parsed.string("status"), project: parsed.string("project"),
                    created: parsed.string("created_at").flatMap(AgentMemorySearchRequest.date))
            }
        }
    }
    private struct Cache: Codable {
        var formatVersion = 1
        var records: [Record] = []
        enum CodingKeys: String, CodingKey { case formatVersion, records }
        init(records: [Record]) { self.records = records }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
            records = try values.decodeIfPresent([Record].self, forKey: .records) ?? []
        }
    }
    private struct Recents: Codable {
        var formatVersion = 1
        var opened: [UUID: Date] = [:]
        enum CodingKeys: String, CodingKey { case formatVersion, opened }
        init() {}
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try values.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
            guard formatVersion == 1 else { throw LibraryError.unsupportedMetadataVersion(formatVersion) }
            opened = try values.decodeIfPresent([UUID: Date].self, forKey: .opened) ?? [:]
        }
    }

    private let root: URL
    private var entries: [UUID: Entry] = [:]
    private var folders: [UUID: LibraryFolder] = [:]
    private var recents = Recents()
    private var loaded = false
    private var generation = 0
    private var mutationSerial = 0
    private var mutations: [UUID: Int] = [:]
    private var observers: [UUID: AsyncStream<SearchIndexState>.Continuation] = [:]
    private let cacheWriteDelay: Duration
    private var cacheReadOnly = false
    private var cacheDirty = false
    private var cacheWrite: Task<Void, Never>?
    private var cacheWriting: Task<Void, Never>?
    public private(set) var state: SearchIndexState = .building(indexed: 0, total: 0)

    /// Cache writes are coalesced: one write `cacheWriteDelay` after the last change.
    public init(root: URL, cacheWriteDelay: Duration = .seconds(2)) {
        self.root = root.standardizedFileURL
        self.cacheWriteDelay = cacheWriteDelay
    }

    public func states() -> AsyncStream<SearchIndexState> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            observers[id] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        }
    }

    /// Reuses scan dates and identities, without enumerating or stat-ing every file again.
    /// Superseded reconciliations stop before installing any stale body.
    @discardableResult
    public func reconcile(_ snapshot: LibrarySnapshot) async throws -> Bool {
        guard snapshot.rootURL.standardizedFileURL == root else { throw LibraryError.invalidRoot }
        generation += 1
        let token = generation
        let initialMutation = mutationSerial
        if !loaded { try load(); loaded = true }
        let previousRecords = entries.mapValues(\.record)
        let previousFolders = folders
        folders = Dictionary(uniqueKeysWithValues: snapshot.folders.map { ($0.id, $0) })
        let live = Set(snapshot.documents.map(\.id))
        entries = entries.filter { live.contains($0.key) }
        recents.opened = recents.opened.filter { live.contains($0.key) }
        let changed = snapshot.documents.filter {
            guard let old = entries[$0.id]?.record else { return true }
            return old.modified != $0.modified || old.identity != $0.fileIdentity
                || $0.modified == nil
        }
        // Remove outdated bodies immediately; searches while building never return stale text.
        for document in changed { entries[document.id] = nil }
        for document in snapshot.documents {
            if var entry = entries[document.id] {
                if entry.record.name != (document.name as NSString).deletingPathExtension {
                    entry.title = searchFold((document.name as NSString).deletingPathExtension)
                    entry.title.makeContiguousUTF8()
                }
                entry.record = record(document, body: entry.record.body)
                entries[document.id] = entry
            }
        }
        // A cache write feeds FSEvents. Unchanged scans must neither write nor publish.
        if changed.isEmpty, previousRecords == entries.mapValues(\.record), previousFolders == folders { return false }
        publish(.building(indexed: entries.count, total: snapshot.documents.count))
        var lastProgress = Date()
        for document in changed {
            try Task.checkCancellation()
            guard token == generation else { throw CancellationError() }
            if (mutations[document.id] ?? 0) > initialMutation { continue }
            do {
                let body = try await LibraryScanner.readDocument(document, root: root)
                try Task.checkCancellation()
                guard token == generation else { throw CancellationError() }
                if (mutations[document.id] ?? 0) <= initialMutation {
                    entries[document.id] = Entry(record(document, body: body))
                }
            } catch is CancellationError { throw CancellationError() } catch
            { /* Unreadable/removed documents remain absent, retried on next scan. */  }
            guard token == generation else { throw CancellationError() }
            if Date().timeIntervalSince(lastProgress) >= 0.1 {
                publish(.building(indexed: entries.count, total: snapshot.documents.count))
                lastProgress = Date()
            }
        }
        guard token == generation else { throw CancellationError() }
        try Task.checkCancellation()
        // A derived cache failure must not prevent searching a read-only library.
        let recordsChanged = previousRecords != entries.mapValues(\.record)
        cacheReadOnly = snapshot.isReadOnly
        if recordsChanged { scheduleCacheWrite() }
        mutations = mutations.filter { live.contains($0.key) }
        publish(.ready)
        return recordsChanged || previousFolders != folders
    }

    /// Pass the refreshed scan-time document after save. An in-flight rebuild cannot overwrite it.
    public func update(_ document: LibraryDocument, body: String) {
        mutationSerial += 1
        mutations[document.id] = mutationSerial
        entries[document.id] = Entry(record(document, body: body))
        scheduleCacheWrite()
    }

    public func remove(_ id: UUID) {
        mutationSerial += 1
        mutations[id] = mutationSerial
        entries[id] = nil
        recents.opened[id] = nil
        scheduleCacheWrite()
    }

    /// Writes a pending cache change now (library close, tests).
    public func flushCache() async {
        cacheWrite?.cancel()
        await writeCacheIfNeeded()
    }

    public func recordOpened(_ id: UUID, at date: Date = Date(), persist: Bool = true) throws {
        recents.opened[id] = date
        // Bound persisted navigation history, independently of the derived cache.
        if recents.opened.count > 200 {
            recents.opened = Dictionary(
                uniqueKeysWithValues: recents.opened.sorted { $0.value > $1.value }.prefix(200).map {
                    ($0.key, $0.value)
                })
        }
        if persist { try write(recents, name: "search-recents.json") }
    }

    /// Only documents actually opened, ranked by their persisted open time.
    public func recentResults(limit: Int = 12) async throws -> [SearchResult] {
        let recentEntries = entries.values.filter { recents.opened[$0.record.id] != nil }
        let folders = folders, opened = recents.opened
        let worker = Task.detached(priority: .userInitiated) {
            try Self.search(
                SearchQuery("", mode: .quickOpen, limit: limit), entries: recentEntries, folders: folders,
                opened: opened)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    public func query(_ query: SearchQuery) async throws -> [SearchResult] {
        let entries = Array(entries.values), folders = folders, opened = recents.opened
        let worker = Task.detached(priority: .userInitiated) {
            try Self.search(query, entries: entries, folders: folders, opened: opened)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func search(
        _ query: SearchQuery, entries: [Entry], folders: [UUID: LibraryFolder], opened: [UUID: Date]
    ) throws -> [SearchResult] {
        try Task.checkCancellation()
        guard query.limit > 0 else { return [] }
        if query.mode == .library { return try searchLibrary(query, entries: entries, folders: folders) }
        let text = searchFold(query.text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let terms = text.split(separator: " ").map(String.init)
        let allowed = allowedFolders(query.scope, folders: folders)
        var hits: [(Entry, Int)] = []
        for entry in entries {
            try Task.checkCancellation()
            if let allowed, !allowed.contains(entry.record.folderID) { continue }
            let titleMatch = terms.allSatisfy { entry.title.contains($0) }
            let matches = terms.allSatisfy {
                entry.title.contains($0) || (query.mode == .library && entry.body.contains($0))
            }
            guard matches else { continue }
            let rank: Int
            if text.isEmpty {
                rank = 0
            } else if entry.title == text {
                rank = 0
            } else if entry.title.hasPrefix(text) {
                rank = 1
            } else if terms.allSatisfy({ term in
                entry.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(term) }
            }) {
                rank = 2
            } else if titleMatch {
                rank = 3
            } else {
                rank = 4
            }
            hits.append((entry, rank))
        }
        hits.sort {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            let a = $0.0.record, b = $1.0.record
            if text.isEmpty && query.mode == .quickOpen, opened[a.id] != opened[b.id] {
                return (opened[a.id] ?? .distantPast) > (opened[b.id] ?? .distantPast)
            }
            if a.modified != b.modified { return (a.modified ?? .distantPast) > (b.modified ?? .distantPast) }
            if a.name != b.name { return a.name < b.name }
            return a.id.uuidString < b.id.uuidString
        }
        try Task.checkCancellation()
        return try hits.prefix(query.limit).map { entry, rank in
            try Task.checkCancellation()
            return result(entry, matchKind: rank == 4 ? .body : .title, terms: terms, folders: folders)
        }
    }

    /// Search Library (#179): words, phrases and filters from the shared `ParsedSearchQuery`. An exact title
    /// match comes first; then BM25 with scope-local statistics (the title tiers when the query carries no
    /// statistics); then newest, then name.
    private static func searchLibrary(
        _ query: SearchQuery, entries: [Entry], folders: [UUID: LibraryFolder]
    ) throws -> [SearchResult] {
        let parsed = ParsedSearchQuery(query.text)
        let text = parsed.foldedText
        let terms = parsed.foldedWords + parsed.foldedPhrases
        let allowed = allowedFolders(query.scope, folders: folders)
        let tagNames = Dictionary(
            (query.metadata?.tags ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Scope and filters first: they decide the Documents the statistics come from.
        var candidates: [Entry] = []
        for entry in entries {
            try Task.checkCancellation()
            let record = entry.record
            if let allowed, !allowed.contains(record.folderID) { continue }
            if !parsed.tags.isEmpty {
                let ids = query.metadata?.tagsByDocument[record.id.uuidString] ?? []
                guard parsed.admits(tags: Set(ids.compactMap { tagNames[$0] })) else { continue }
            }
            guard
                parsed.admits(
                    type: entry.envelope?.type, status: entry.envelope?.status, project: entry.envelope?.project,
                    path: record.path, date: entry.envelope?.created ?? record.modified)
            else { continue }
            candidates.append(entry)
        }
        let scores = query.ranking.map {
            KnowledgeBM25.scores(terms: parsed.rankingTerms, candidates: candidates.map(\.record.path), statistics: $0)
        }
        // Small sort keys, not whole entries: a common word can match every Document.
        struct Hit {
            let index: Int
            let rank: Int
            let score: Double
            let title: Bool
            let modified: Date
            let name: String
            let id: UUID
        }
        var hits: [Hit] = []
        for (position, entry) in candidates.enumerated() {
            try Task.checkCancellation()
            guard parsed.matchesText(title: entry.title, body: entry.body) else { continue }
            let titleMatch = parsed.matchesTitle(entry.title)
            let rank: Int
            if !parsed.hasText || entry.title == text {
                rank = 0
            } else if scores != nil {
                rank = 1
            } else if entry.title.hasPrefix(text) {
                rank = 1
            } else if terms.allSatisfy({ term in
                entry.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(term) }
            }) {
                rank = 2
            } else {
                rank = titleMatch ? 3 : 4
            }
            let record = entry.record
            hits.append(
                Hit(
                    index: position, rank: rank, score: scores?[record.path] ?? 0, title: titleMatch,
                    modified: record.modified ?? .distantPast, name: record.name, id: record.id))
        }
        hits.sort { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            if a.score != b.score { return a.score > b.score }
            if a.modified != b.modified { return a.modified > b.modified }
            if a.name != b.name { return a.name < b.name }
            return a.id.uuidString < b.id.uuidString
        }
        try Task.checkCancellation()
        return try hits.prefix(query.limit).map { hit in
            try Task.checkCancellation()
            return result(
                candidates[hit.index], matchKind: parsed.hasText && !hit.title ? .body : .title,
                terms: parsed.highlightTerms, folders: folders)
        }
    }

    private static func allowedFolders(_ scope: SearchQuery.Scope, folders: [UUID: LibraryFolder]) -> Set<UUID>? {
        guard case .folder(let id, let descendants) = scope else { return nil }
        var allowed: Set<UUID> = [id]
        if descendants, let path = folders[id]?.relativePath {
            for folder in folders.values where path.isEmpty || folder.relativePath.hasPrefix(path + "/") {
                allowed.insert(folder.id)
            }
        }
        return allowed
    }

    private static func result(
        _ entry: Entry, matchKind: SearchResult.MatchKind, terms: [String], folders: [UUID: LibraryFolder]
    ) -> SearchResult {
        let record = entry.record
        let (snippet, ranges) = searchSnippet(record.body, terms: terms)
        return SearchResult(
            id: record.id, displayName: record.name,
            folderPathComponents: folders[record.folderID]?.relativePath.split(separator: "/").map(String.init) ?? [],
            modified: record.modified, matchKind: matchKind, snippet: snippet, matchRanges: ranges)
    }

    private func record(_ document: LibraryDocument, body: String) -> Record {
        Record(
            id: document.id, folderID: document.folderID, path: document.relativePath,
            name: (document.name as NSString).deletingPathExtension, modified: document.modified,
            identity: document.fileIdentity, body: body)
    }

    private func file(_ name: String) throws -> URL {
        try LibraryMetadataStore.rejectLink(root)
        let directory = root.appendingPathComponent(".silkweb")
        try LibraryMetadataStore.rejectLink(directory)
        let file = directory.appendingPathComponent(name)
        try LibraryMetadataStore.rejectLink(file)
        return file
    }

    private func load() throws {
        let cacheFile = try file("search-index.json")
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            do {
                let cache = try JSONDecoder().decode(Cache.self, from: Data(contentsOf: cacheFile))
                if cache.formatVersion == 1 {
                    for record in cache.records { entries[record.id] = Entry(record) }
                } else {
                    publish(.rebuilding(reason: .unsupportedVersion))
                }
            } catch { publish(.rebuilding(reason: .corrupt)) }
        }
        let recentFile = try file("search-recents.json")
        if let data = try? Data(contentsOf: recentFile),
            let recent = try? JSONDecoder().decode(Recents.self, from: data)
        {
            recents = recent
        }
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        let file = try file(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    /// Saves and reconciles never encode the whole library inline; bursts produce one write.
    private func scheduleCacheWrite() {
        cacheDirty = true
        cacheWrite?.cancel()
        let delay = cacheWriteDelay
        cacheWrite = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            await self.writeCacheIfNeeded()
        }
    }

    private func writeCacheIfNeeded() async {
        guard cacheDirty else { return }
        cacheDirty = false
        guard !cacheReadOnly, let file = try? file("search-index.json") else { return }
        let cache = Cache(records: entries.values.map(\.record))
        // Encode off the actor so searches never wait on the write; writes land in order.
        let previous = cacheWriting
        let writing = Task.detached(priority: .utility) {
            await previous?.value
            // A late write must never recreate a library that was moved or deleted meanwhile.
            try? FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: false)
            if let data = try? JSONEncoder().encode(cache) { try? data.write(to: file, options: .atomic) }
        }
        cacheWriting = writing
        await writing.value
    }
    private func publish(_ state: SearchIndexState) {
        self.state = state
        for observer in observers.values { observer.yield(state) }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
}

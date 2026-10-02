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
    private struct Entry: Sendable {
        var record: Record
        var title: String
        var body: String
        init(_ record: Record) {
            self.record = record
            title = searchFold(record.name)
            body = searchFold(record.body)
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
    public private(set) var state: SearchIndexState = .building(indexed: 0, total: 0)

    public init(root: URL) { self.root = root.standardizedFileURL }

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
            } catch is CancellationError { throw CancellationError() }
            catch { /* Unreadable/removed documents remain absent, retried on next scan. */ }
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
        if recordsChanged, !snapshot.isReadOnly { try? saveCache() }
        mutations = mutations.filter { live.contains($0.key) }
        publish(.ready)
        return recordsChanged || previousFolders != folders
    }

    /// Pass the refreshed scan-time document after save. An in-flight rebuild cannot overwrite it.
    public func update(_ document: LibraryDocument, body: String) {
        mutationSerial += 1
        mutations[document.id] = mutationSerial
        entries[document.id] = Entry(record(document, body: body))
    }

    public func remove(_ id: UUID) {
        mutationSerial += 1
        mutations[id] = mutationSerial
        entries[id] = nil
        recents.opened[id] = nil
    }

    public func recordOpened(_ id: UUID, at date: Date = Date(), persist: Bool = true) throws {
        recents.opened[id] = date
        // Bound persisted navigation history, independently of the derived cache.
        if recents.opened.count > 200 {
            recents.opened = Dictionary(uniqueKeysWithValues: recents.opened.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) })
        }
        if persist { try write(recents, name: "search-recents.json") }
    }

    /// Only documents actually opened, ranked by their persisted open time.
    public func recentResults(limit: Int = 12) async throws -> [SearchResult] {
        let recentEntries = entries.values.filter { recents.opened[$0.record.id] != nil }
        let folders = folders, opened = recents.opened
        let worker = Task.detached(priority: .userInitiated) {
            try Self.search(SearchQuery("", mode: .quickOpen, limit: limit), entries: recentEntries, folders: folders, opened: opened)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    public func query(_ query: SearchQuery) async throws -> [SearchResult] {
        let entries = Array(entries.values), folders = folders, opened = recents.opened
        let worker = Task.detached(priority: .userInitiated) {
            try Self.search(query, entries: entries, folders: folders, opened: opened)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func search(_ query: SearchQuery, entries: [Entry], folders: [UUID: LibraryFolder], opened: [UUID: Date]) throws -> [SearchResult] {
        try Task.checkCancellation()
        guard query.limit > 0 else { return [] }
        let text = searchFold(query.text).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let terms = text.split(separator: " ").map(String.init)
        var allowed: Set<UUID>?
        if case .folder(let id, let descendants) = query.scope {
            allowed = [id]
            if descendants, let path = folders[id]?.relativePath {
                for folder in folders.values where path.isEmpty || folder.relativePath.hasPrefix(path + "/") { allowed?.insert(folder.id) }
            }
        }
        var hits: [(Entry, Int)] = []
        for entry in entries {
            try Task.checkCancellation()
            if let allowed, !allowed.contains(entry.record.folderID) { continue }
            let titleMatch = terms.allSatisfy { entry.title.contains($0) }
            let matches = terms.allSatisfy { entry.title.contains($0) || (query.mode == .library && entry.body.contains($0)) }
            guard matches else { continue }
            let rank: Int
            if text.isEmpty { rank = 0 }
            else if entry.title == text { rank = 0 }
            else if entry.title.hasPrefix(text) { rank = 1 }
            else if terms.allSatisfy({ term in entry.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains { $0.hasPrefix(term) } }) { rank = 2 }
            else if titleMatch { rank = 3 }
            else { rank = 4 }
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
            let record = entry.record
            let (snippet, ranges) = searchSnippet(record.body, terms: terms)
            return SearchResult(id: record.id, displayName: record.name,
                folderPathComponents: folders[record.folderID]?.relativePath.split(separator: "/").map(String.init) ?? [],
                modified: record.modified, matchKind: rank == 4 ? .body : .title, snippet: snippet, matchRanges: ranges)
        }
    }

    private func record(_ document: LibraryDocument, body: String) -> Record {
        Record(id: document.id, folderID: document.folderID, path: document.relativePath,
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
                } else { publish(.rebuilding(reason: .unsupportedVersion)) }
            } catch { publish(.rebuilding(reason: .corrupt)) }
        }
        let recentFile = try file("search-recents.json")
        if let data = try? Data(contentsOf: recentFile), let recent = try? JSONDecoder().decode(Recents.self, from: data) { recents = recent }
    }

    private func write<T: Encodable>(_ value: T, name: String) throws {
        let file = try file(name)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: .atomic)
    }

    private func saveCache() throws { try write(Cache(records: entries.values.map(\.record)), name: "search-index.json") }
    private func publish(_ state: SearchIndexState) {
        self.state = state
        for observer in observers.values { observer.yield(state) }
    }
    private func removeObserver(_ id: UUID) { observers[id] = nil }
}

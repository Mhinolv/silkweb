import Darwin
import Foundation
import os

/// Disposable on-disk checkpoints of a `KnowledgeGraph` (#177), outside the Library. One folder per Library
/// (app) or grant (helper):
///
/// - `manifest.json` names the current checkpoint and its `generation`. It is replaced atomically.
/// - `checkpoint-<generation>.json` holds the records. It is written to a staging file and renamed into place
///   before the manifest names it, and never changes after that.
/// - `publish.lock` serialises publishers with `flock`, which the kernel drops when a process dies.
///
/// A crash at any step leaves the previous manifest naming a complete checkpoint, so a reader always gets one
/// whole generation or none. The next publisher removes staging files and unnamed checkpoints. A missing,
/// corrupt, newer or foreign cache is discarded and rebuilt; the store never writes into the Library.
/// Folders are 0700 and files 0600.
public struct KnowledgeCacheStore: Sendable {
    public static let version = 1
    static let log = Logger(subsystem: "com.silkweb.app", category: "knowledge")

    public enum Discard: String, Sendable, Equatable {
        case missing, corrupt, unsupportedVersion = "unsupported-version", otherLibrary = "other-library"
    }

    public enum Loaded: Sendable, Equatable {
        case restored(generation: Int, records: [KnowledgeRecord])
        case discarded(Discard)
    }

    /// Test seam: a publication stops after this step, as if the process died there.
    enum Step: CaseIterable { case checkpointStaged, checkpointPublished, manifestStaged }
    struct SimulatedCrash: Error {}

    struct Manifest: Codable {
        var version = KnowledgeCacheStore.version
        var library: String
        var generation: Int
        var checkpoint: String

        init(library: String, generation: Int, checkpoint: String) {
            self.library = library
            self.generation = generation
            self.checkpoint = checkpoint
        }

        private enum CodingKeys: String, CodingKey { case version, library, generation, checkpoint }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            library = try values.decodeIfPresent(String.self, forKey: .library) ?? ""
            generation = try values.decodeIfPresent(Int.self, forKey: .generation) ?? 0
            checkpoint = try values.decodeIfPresent(String.self, forKey: .checkpoint) ?? ""
        }
    }

    struct Checkpoint: Codable {
        var version = KnowledgeCacheStore.version
        var library: String
        var generation: Int
        var records: [KnowledgeRecord]

        init(library: String, generation: Int, records: [KnowledgeRecord]) {
            self.library = library
            self.generation = generation
            self.records = records
        }

        private enum CodingKeys: String, CodingKey { case version, library, generation, records }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
            library = try values.decodeIfPresent(String.self, forKey: .library) ?? ""
            generation = try values.decodeIfPresent(Int.self, forKey: .generation) ?? 0
            records =
                version > KnowledgeCacheStore.version
                ? [] : try values.decodeIfPresent([KnowledgeRecord].self, forKey: .records) ?? []
        }
    }

    public let directory: URL
    /// Identifies what the cache was built from (a Library path, plus the project for a grant). A cache for
    /// anything else is a fresh start.
    public let library: String

    public init(directory: URL, library: String) {
        self.directory = directory
        self.library = library
    }

    var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var lockURL: URL { directory.appendingPathComponent("publish.lock") }

    // MARK: Load

    public func load() -> Loaded {
        let result = loadOnce()
        if case .discarded(let reason) = result, reason != .missing {
            Self.log.info("Knowledge cache discarded (\(reason.rawValue, privacy: .public)); rebuilding")
        }
        return result
    }

    private func loadOnce() -> Loaded {
        guard (try? LibraryMetadataStore.rejectLink(directory)) != nil,
            FileManager.default.fileExists(atPath: directory.path)
        else { return .discarded(.missing) }
        // A shared lock keeps a publisher from removing the checkpoint between the two reads.
        let descriptor = open(lockURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor >= 0 { _ = flock(descriptor, LOCK_SH) }
        defer { if descriptor >= 0 { close(descriptor) } }
        guard let data = try? Data(contentsOf: manifestURL) else {
            return .discarded(FileManager.default.fileExists(atPath: manifestURL.path) ? .corrupt : .missing)
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { return .discarded(.corrupt) }
        guard manifest.version <= Self.version else { return .discarded(.unsupportedVersion) }
        guard manifest.library == library else { return .discarded(.otherLibrary) }
        guard Self.isCheckpointName(manifest.checkpoint),
            let contents = try? Data(contentsOf: directory.appendingPathComponent(manifest.checkpoint)),
            let checkpoint = try? JSONDecoder().decode(Checkpoint.self, from: contents)
        else { return .discarded(.corrupt) }
        guard checkpoint.version <= Self.version else { return .discarded(.unsupportedVersion) }
        guard checkpoint.library == library, checkpoint.generation == manifest.generation else {
            return .discarded(.corrupt)
        }
        return .restored(generation: checkpoint.generation, records: checkpoint.records)
    }

    // MARK: Publish

    /// Writes `records` as the next generation and returns it. Concurrent publishers (other windows, other
    /// processes) take turns; the last one to finish is current.
    @discardableResult
    public func publish(_ records: [KnowledgeRecord]) throws -> Int {
        try publish(records, crashAfter: nil)
    }

    func publish(_ records: [KnowledgeRecord], crashAfter crash: Step?) throws -> Int {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try LibraryMetadataStore.rejectLink(directory)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        // Closing the descriptor releases the lock, on success, failure or a simulated crash alike.
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        let previous = (try? Data(contentsOf: manifestURL)).flatMap {
            try? JSONDecoder().decode(Manifest.self, from: $0)
        }
        let generation = max(previous?.generation ?? 0, 0) + 1
        let name = "checkpoint-\(generation).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let checkpoint = try encoder.encode(
            Checkpoint(
                library: library, generation: generation,
                records: records.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }))
        let stagedCheckpoint = try stage(checkpoint, for: name)
        if crash == .checkpointStaged { throw SimulatedCrash() }
        try replace(directory.appendingPathComponent(name), with: stagedCheckpoint)
        if crash == .checkpointPublished { throw SimulatedCrash() }
        let manifest = try encoder.encode(Manifest(library: library, generation: generation, checkpoint: name))
        let stagedManifest = try stage(manifest, for: manifestURL.lastPathComponent)
        if crash == .manifestStaged { throw SimulatedCrash() }
        try replace(manifestURL, with: stagedManifest)
        // Everything else is a staging file or checkpoint left by a publisher that died; none is in use.
        for entry in (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        where entry != name && (entry.hasSuffix(".tmp") || Self.isCheckpointName(entry)) {
            try? fileManager.removeItem(at: directory.appendingPathComponent(entry))
        }
        return generation
    }

    /// Deletes the whole cache (a revoked grant).
    public func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    static func isCheckpointName(_ name: String) -> Bool {
        name.hasPrefix("checkpoint-") && name.hasSuffix(".json") && !name.contains("/")
    }

    private func stage(_ data: Data, for name: String) throws -> URL {
        let staging = directory.appendingPathComponent(".\(name).\(UUID().uuidString).tmp")
        guard
            FileManager.default.createFile(atPath: staging.path, contents: data, attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
        return staging
    }

    private func replace(_ destination: URL, with staging: URL) throws {
        try LibraryMetadataStore.rejectLink(destination)
        guard rename(staging.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

import Foundation

/// File ▸ Open Recent ▸ and the welcome screen's Recent Libraries (#195): app preferences only, most recent first.
/// Each entry is a `LibraryLocation` (bookmark + path); its canonical path is the key, as for open sections.
public struct RecentLibraries: Codable, Equatable, Sendable {
    public static let limit = 10

    public var version = 1
    public private(set) var entries: [LibraryLocation] = []

    public init(entries: [LibraryLocation] = []) {
        for entry in entries.reversed() { record(entry) }
    }

    private enum CodingKeys: String, CodingKey { case version, entries }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        // A bad entry list (an earlier or later build's shape) starts over rather than failing the launch.
        let decoded = (try? values.decodeIfPresent([LibraryLocation].self, forKey: .entries)) ?? []
        self.init(entries: decoded)
        self.version = version
    }

    /// Before #195 only the last Library was saved (`libraryLocation`); it becomes the first recent entry.
    public static func seeded(from legacy: LibraryLocation?) -> RecentLibraries {
        RecentLibraries(entries: [legacy].compactMap { $0 })
    }

    public static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// A successful open moves its folder to the top; the oldest entry beyond `limit` drops off.
    public mutating func record(_ location: LibraryLocation) {
        guard let path = location.path, !path.isEmpty else { return }
        let key = Self.canonicalPath(path)
        entries.removeAll { $0.path.map(Self.canonicalPath) == key }
        entries.insert(location, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    public mutating func remove(path: String) {
        let key = Self.canonicalPath(path)
        entries.removeAll { $0.path.map(Self.canonicalPath) == key }
    }

    public mutating func clear() { entries = [] }

    public func entry(path: String) -> LibraryLocation? {
        let key = Self.canonicalPath(path)
        return entries.first { $0.path.map(Self.canonicalPath) == key }
    }

    /// Menu and welcome rows: folder names, with the parent folder added where two names collide
    /// (“Writing — Documents”), and a ✓ for Libraries open as sections (canonical paths).
    public func items(openPaths: Set<String> = []) -> [RecentLibraryItem] {
        let open = Set(openPaths.map(Self.canonicalPath))
        let paths = entries.compactMap(\.path)
        var names: [String: Int] = [:]
        for path in paths { names[URL(fileURLWithPath: path).lastPathComponent, default: 0] += 1 }
        return paths.map { path in
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            let parent = url.deletingLastPathComponent().lastPathComponent
            let title = (names[name] ?? 0) > 1 && !parent.isEmpty && parent != "/" ? "\(name) — \(parent)" : name
            return RecentLibraryItem(
                path: path, name: name, title: title, isOpen: open.contains(Self.canonicalPath(path)))
        }
    }
}

public struct RecentLibraryItem: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    /// The folder name alone (alerts, accessibility labels).
    public let name: String
    /// The menu title: the name, disambiguated by its parent when another entry has the same name.
    public let title: String
    public let isOpen: Bool
}

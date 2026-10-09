import Foundation

/// The library window's open Libraries (#196): app preferences only, saved whenever a section opens, closes,
/// collapses or becomes current, and once more at quit before any window closes. Each Library's tabs, scroll and
/// caret stay in its own `WindowSessionMetadata`, and its remembered scope in its `LibrarySession`.
public struct AppSession: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    /// One sidebar section, in sidebar order.
    public struct Section: Codable, Equatable, Sendable {
        public var location: LibraryLocation
        public var collapsed: Bool

        public init(location: LibraryLocation, collapsed: Bool = false) {
            self.location = location
            self.collapsed = collapsed
        }

        public var path: String? { location.path.flatMap { $0.isEmpty ? nil : $0 } }

        private enum CodingKeys: String, CodingKey { case location, libraryPath, collapsed }
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            // `libraryPath` alone is the #194 per-window shape.
            location =
                (try? values.decodeIfPresent(LibraryLocation.self, forKey: .location))
                ?? LibraryLocation(path: try? values.decodeIfPresent(String.self, forKey: .libraryPath))
            collapsed = (try? values.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(location, forKey: .location)
            try values.encode(collapsed, forKey: .collapsed)
        }
    }

    public var version = Self.currentVersion
    public var sections: [Section] = []
    /// The current Library's path: it loads first and holds the selection.
    public var currentPath: String?
    /// The column that had keyboard focus: 0 sidebar, 1 list, 2 editor.
    public var focusColumn: Int?

    public init(sections: [Section] = [], currentPath: String? = nil, focusColumn: Int? = nil) {
        self.sections = sections
        self.currentPath = currentPath
        self.focusColumn = focusColumn
    }

    /// A #194 window: its Library, front-to-back in `windows`.
    private struct Window: Decodable {
        var sections: [Section]
        var isKey: Bool

        private enum CodingKeys: String, CodingKey { case location, libraryPath, collapsed, sections, isKey }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            isKey = (try? values.decodeIfPresent(Bool.self, forKey: .isKey)) ?? false
            if let nested = try? values.decodeIfPresent([Section].self, forKey: .sections) {
                sections = nested
            } else {
                sections = [try Section(from: decoder)]
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case version, sections, currentPath, focusColumn, windows, keyWindow }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? values.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        guard version <= Self.currentVersion else { throw AppSessionError.newerVersion(version) }
        version = Self.currentVersion
        currentPath = try? values.decodeIfPresent(String.self, forKey: .currentPath)
        focusColumn = try? values.decodeIfPresent(Int.self, forKey: .focusColumn)
        if values.contains(.sections) {
            sections = try values.decode([Section].self, forKey: .sections)
        } else if values.contains(.windows) {
            // #194 kept one Library per window: the windows merge into one window's sections, front to back. The
            // key window (`isKey`, else the `keyWindow` index, else the front one) holds the current Library.
            let windows = try values.decode([Window].self, forKey: .windows)
            let keyIndex =
                windows.firstIndex { $0.isKey } ?? (try? values.decodeIfPresent(Int.self, forKey: .keyWindow)) ?? 0
            sections = windows.flatMap(\.sections)
            if currentPath == nil, windows.indices.contains(keyIndex) {
                currentPath = windows[keyIndex].sections.first?.path
            }
        }
        sections = Self.deduplicated(sections)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(version, forKey: .version)
        try values.encode(sections, forKey: .sections)
        try values.encodeIfPresent(currentPath, forKey: .currentPath)
        try values.encodeIfPresent(focusColumn, forKey: .focusColumn)
    }

    /// Sections without a path are dropped; a folder listed twice keeps its first place (canonical paths).
    static func deduplicated(_ sections: [Section]) -> [Section] {
        var seen: Set<String> = []
        return sections.filter { section in
            guard let path = section.path else { return false }
            return seen.insert(RecentLibraries.canonicalPath(path)).inserted
        }
    }

    /// The index of the current section: `currentPath`'s section, else the first.
    public var currentIndex: Int? {
        guard !sections.isEmpty else { return nil }
        let key = currentPath.map(RecentLibraries.canonicalPath)
        return sections.firstIndex { $0.path.map(RecentLibraries.canonicalPath) == key } ?? 0
    }

    /// Settings ▸ “Reopen windows and tabs from the last session” off (owner decision on #196): only the last current
    /// Library, expanded; the caller opens it without tabs.
    public func reduced(reopensSession: Bool) -> AppSession {
        guard !reopensSession else { return self }
        guard let index = currentIndex else { return AppSession() }
        var section = sections[index]
        section.collapsed = false
        return AppSession(sections: [section], currentPath: section.path)
    }
}

public enum AppSessionError: Error, Equatable {
    case newerVersion(Int)
}

/// What launch restores from the saved app session (#196).
public enum AppSessionLaunch: Equatable, Sendable {
    /// Restore these sections. An empty session is the welcome screen.
    case sections(AppSession)
    /// No usable app session: restore the single legacy `libraryLocation` as before #196 (or the welcome screen).
    /// `canSave` is false for a newer build's session, which must not be overwritten.
    case legacy(canSave: Bool)

    /// `data` is the saved app session, if any. A corrupt one falls back to the legacy Library and may be replaced.
    public static func plan(_ data: Data?, reopensSession: Bool) -> AppSessionLaunch {
        guard let data else { return .legacy(canSave: true) }
        do {
            let session = try JSONDecoder().decode(AppSession.self, from: data)
            return .sections(session.reduced(reopensSession: reopensSession))
        } catch AppSessionError.newerVersion {
            return .legacy(canSave: false)
        } catch {
            return .legacy(canSave: true)
        }
    }
}

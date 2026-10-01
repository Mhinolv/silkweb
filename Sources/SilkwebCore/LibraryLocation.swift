import Foundation

/// App preferences only; the library itself remains a directory of plain files.
public struct LibraryLocation: Codable, Equatable, Sendable {
    public var version = 1
    public var bookmark: Data?
    public var path: String?

    public init(bookmark: Data? = nil, path: String? = nil) {
        self.bookmark = bookmark
        self.path = path
    }

    private enum CodingKeys: String, CodingKey { case version, bookmark, path }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
        path = try values.decodeIfPresent(String.self, forKey: .path)
    }

    public static func saving(_ url: URL) -> LibraryLocation {
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        // A path remains usable even if bookmark creation fails.
        return LibraryLocation(bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), path: url.path)
    }
}

public enum LibraryLocationError: Error, Equatable {
    case notFound
    case unreadable

    public var title: String {
        self == .notFound ? "Library Not Found" : "Can’t Open Library"
    }
}

public struct ResolvedLibraryLocation: Sendable {
    public let url: URL
    public let usesSecurityScope: Bool
    public let refreshedLocation: LibraryLocation?
}

public enum LibraryLocationRestore {
    public struct BookmarkResolution {
        public let url: URL
        public let stale: Bool

        public init(url: URL, stale: Bool) {
            self.url = url
            self.stale = stale
        }
    }

    /// Injected filesystem/bookmark operations make migration and failure paths deterministic in tests.
    public static func restore(
        _ location: LibraryLocation?, legacyBookmark: Data? = nil,
        resolve: (Data, Bool) throws -> BookmarkResolution = resolveBookmark,
        validate: (URL, Bool) throws -> Void = validateDirectory,
        save: (URL) -> LibraryLocation = LibraryLocation.saving
    ) throws -> ResolvedLibraryLocation? {
        guard location != nil || legacyBookmark != nil else { return nil }
        let legacy = location == nil
        let bookmark = location?.bookmark ?? (legacy ? legacyBookmark : nil)
        var resolution: BookmarkResolution?
        var scoped = false
        if let bookmark {
            resolution = try? resolve(bookmark, false)
            if resolution == nil, legacy {
                resolution = try? resolve(bookmark, true)
                scoped = resolution != nil
            }
        }
        let fallback = location?.path.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        guard let url = (resolution?.url ?? fallback)?.standardizedFileURL else {
            throw LibraryLocationError.notFound
        }
        try validate(url, scoped)
        let refresh = legacy || resolution == nil || resolution?.stale == true || location?.path != url.path
        return ResolvedLibraryLocation(url: url, usesSecurityScope: scoped,
                                       refreshedLocation: refresh ? save(url) : nil)
    }

    public static func resolveBookmark(_ data: Data, scoped: Bool) throws -> BookmarkResolution {
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: scoped ? [.withSecurityScope, .withoutUI] : [.withoutUI], bookmarkDataIsStale: &stale)
        return BookmarkResolution(url: url, stale: stale)
    }

    public static func validateDirectory(_ url: URL, scoped: Bool) throws {
        let accessing = scoped && url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw LibraryLocationError.notFound
            }
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw LibraryLocationError.unreadable
            }
            // Detect directory traversal permission failures, too.
            _ = try FileManager.default.contentsOfDirectory(atPath: url.path)
        } catch let error as LibraryLocationError {
            throw error
        } catch {
            let cocoa = error as NSError
            if cocoa.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(cocoa.code) {
                throw LibraryLocationError.notFound
            }
            throw LibraryLocationError.unreadable
        }
    }
}

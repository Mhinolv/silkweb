import XCTest

@testable import SilkwebCore

/// #195: File ▸ Open Recent ▸ and the welcome screen's Recent Libraries.
final class RecentLibrariesTests: XCTestCase {
    private func location(_ path: String) -> LibraryLocation { LibraryLocation(bookmark: Data(path.utf8), path: path) }

    func testRecordsMostRecentFirstWithoutDuplicates() {
        var recents = RecentLibraries()
        recents.record(location("/Users/a/Writing"))
        recents.record(location("/Users/a/Kyoto"))
        recents.record(location("/Users/a/Notes"))
        XCTAssertEqual(recents.entries.compactMap(\.path), ["/Users/a/Notes", "/Users/a/Kyoto", "/Users/a/Writing"])
        // Reopening moves the entry to the top and keeps its newest bookmark.
        recents.record(LibraryLocation(bookmark: Data("new".utf8), path: "/Users/a/Writing"))
        XCTAssertEqual(recents.entries.compactMap(\.path), ["/Users/a/Writing", "/Users/a/Notes", "/Users/a/Kyoto"])
        XCTAssertEqual(recents.entries.first?.bookmark, Data("new".utf8))
        // The same folder spelled differently is still one entry (canonical path, as for sections).
        recents.record(location("/Users/a/Notes/../Kyoto/"))
        XCTAssertEqual(recents.entries.count, 3)
        XCTAssertEqual(recents.entries.first?.path, "/Users/a/Notes/../Kyoto/")
        // Entries without a path are never recorded.
        recents.record(LibraryLocation(bookmark: Data(), path: nil))
        recents.record(LibraryLocation(bookmark: Data(), path: ""))
        XCTAssertEqual(recents.entries.count, 3)
    }

    func testCapsAtTenDroppingTheOldest() {
        var recents = RecentLibraries()
        for index in 0..<12 { recents.record(location("/L/\(index)")) }
        XCTAssertEqual(recents.entries.count, RecentLibraries.limit)
        XCTAssertEqual(recents.entries.first?.path, "/L/11")
        XCTAssertEqual(recents.entries.last?.path, "/L/2")
        // Exactly at the cap nothing drops; one entry is the smallest list.
        var one = RecentLibraries()
        one.record(location("/L/only"))
        XCTAssertEqual(one.items().map(\.title), ["only"])
        XCTAssertEqual(RecentLibraries(entries: (0..<10).map { location("/L/\($0)") }).entries.count, 10)
    }

    func testRemoveAndClear() {
        var recents = RecentLibraries(entries: [location("/a/One"), location("/a/Two")])
        XCTAssertEqual(recents.entries.compactMap(\.path), ["/a/One", "/a/Two"], "init keeps the given order")
        recents.remove(path: "/a/./Two")
        XCTAssertEqual(recents.entries.compactMap(\.path), ["/a/One"])
        XCTAssertNotNil(recents.entry(path: "/a/One/"))
        XCTAssertNil(recents.entry(path: "/a/Two"))
        recents.clear()
        XCTAssertTrue(recents.entries.isEmpty)
        XCTAssertTrue(recents.items().isEmpty)
    }

    func testCollidingNamesAddTheParentAndOpenSectionsAreChecked() {
        let recents = RecentLibraries(entries: [
            location("/Users/a/Documents/Writing"), location("/Volumes/Backup/Writing"), location("/Users/a/Kyoto"),
        ])
        let items = recents.items(openPaths: ["/Users/a/Kyoto/", "/Volumes/Backup/Writing"])
        XCTAssertEqual(items.map(\.title), ["Writing — Documents", "Writing — Backup", "Kyoto"])
        XCTAssertEqual(items.map(\.name), ["Writing", "Writing", "Kyoto"])
        XCTAssertEqual(items.map(\.isOpen), [false, true, true])
        XCTAssertEqual(recents.items().map(\.isOpen), [false, false, false])
    }

    func testDecodesTolerantlyAndSeedsFromTheLegacyLocation() throws {
        let saved = RecentLibraries(entries: [location("/a/One"), location("/a/Two")])
        let decoded = try JSONDecoder().decode(RecentLibraries.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(decoded, saved)
        // Missing keys, a missing version and an unreadable entry list all load as defaults.
        XCTAssertEqual(try JSONDecoder().decode(RecentLibraries.self, from: Data("{}".utf8)), RecentLibraries())
        let odd = try JSONDecoder().decode(
            RecentLibraries.self, from: Data(#"{"version":7,"entries":"nope"}"#.utf8))
        XCTAssertTrue(odd.entries.isEmpty)
        XCTAssertEqual(odd.version, 7)
        let partial = try JSONDecoder().decode(
            RecentLibraries.self, from: Data(#"{"entries":[{"path":"/a/One"},{}]}"#.utf8))
        XCTAssertEqual(partial.entries.compactMap(\.path), ["/a/One"], "an entry without a path is dropped")

        XCTAssertEqual(RecentLibraries.seeded(from: nil).entries, [])
        XCTAssertEqual(RecentLibraries.seeded(from: location("/a/Legacy")).entries.compactMap(\.path), ["/a/Legacy"])
    }
}

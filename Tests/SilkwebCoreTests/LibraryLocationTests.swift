import XCTest

@testable import SilkwebCore

final class LibraryLocationTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/Silkweb Library 日本語")
    private let old = Data([1])
    private let fresh = Data([2])

    func testRegularBookmarkAndStaleRefresh() throws {
        for stale in [false, true] {
            var saved = 0
            let result = try XCTUnwrap(
                LibraryLocationRestore.restore(
                    LibraryLocation(bookmark: old, path: root.path),
                    resolve: { data, scoped in
                        XCTAssertEqual(data, self.old)
                        XCTAssertFalse(scoped)
                        return .init(url: self.root, stale: stale)
                    },
                    validate: { url, scoped in
                        XCTAssertEqual(url, self.root)
                        XCTAssertFalse(scoped)
                    },
                    save: { url in
                        saved += 1
                        return LibraryLocation(bookmark: self.fresh, path: url.path)
                    }))
            XCTAssertEqual(result.url, root)
            XCTAssertFalse(result.usesSecurityScope)
            XCTAssertEqual(saved, stale ? 1 : 0)
            XCTAssertEqual(result.refreshedLocation?.bookmark, stale ? fresh : nil)
        }
    }

    func testLegacyBookmarkTriedAndMigratedWithEitherResolutionMode() throws {
        for needsScope in [false, true] {
            var attempts: [Bool] = []
            let result = try XCTUnwrap(
                LibraryLocationRestore.restore(
                    nil, legacyBookmark: old,
                    resolve: { data, scoped in
                        XCTAssertEqual(data, self.old)
                        attempts.append(scoped)
                        if needsScope && !scoped { throw LibraryLocationError.unreadable }
                        return .init(url: self.root, stale: false)
                    }, validate: { _, scoped in XCTAssertEqual(scoped, needsScope) },
                    save: { LibraryLocation(bookmark: self.fresh, path: $0.path) }))
            XCTAssertEqual(attempts, needsScope ? [false, true] : [false])
            XCTAssertEqual(result.usesSecurityScope, needsScope)
            XCTAssertEqual(result.refreshedLocation, LibraryLocation(bookmark: fresh, path: root.path))
        }
    }

    func testFallbackAndFolderErrors() throws {
        for bookmark in [nil, Data(), old] as [Data?] {
            for failure in [nil, .notFound, .unreadable] as [LibraryLocationError?] {
                let restore = {
                    try LibraryLocationRestore.restore(
                        LibraryLocation(bookmark: bookmark, path: self.root.path),
                        resolve: { _, scoped in
                            XCTAssertFalse(scoped)
                            throw LibraryLocationError.notFound
                        },
                        validate: { url, scoped in
                            XCTAssertEqual(url, self.root)
                            XCTAssertFalse(scoped)
                            if let failure { throw failure }
                        }, save: { LibraryLocation(bookmark: self.fresh, path: $0.path) })
                }
                if let failure {
                    XCTAssertThrowsError(try restore()) { XCTAssertEqual($0 as? LibraryLocationError, failure) }
                } else {
                    XCTAssertEqual(try restore()?.refreshedLocation?.path, root.path)
                }
            }
        }
        XCTAssertEqual(LibraryLocationError.notFound.title, "Library Not Found")
        XCTAssertEqual(LibraryLocationError.unreadable.title, "Can’t Open Library")
        XCTAssertNil(try LibraryLocationRestore.restore(nil))
        for path in [nil, ""] as [String?] {
            XCTAssertThrowsError(try LibraryLocationRestore.restore(LibraryLocation(path: path))) {
                XCTAssertEqual($0 as? LibraryLocationError, .notFound)
            }
        }
        var attempts: [Bool] = []
        XCTAssertThrowsError(
            try LibraryLocationRestore.restore(
                nil, legacyBookmark: old,
                resolve: { _, scoped in
                    attempts.append(scoped)
                    throw LibraryLocationError.notFound
                }))
        XCTAssertEqual(attempts, [false, true])
    }

    func testRealBookmarksPersistenceFallbackMovedFolderAndPermissions() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = parent.appendingPathComponent("Library 日本語")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let saved = LibraryLocation.saving(root)
        XCTAssertEqual(saved.path, root.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertNotNil(saved.bookmark)
        let persisted = try JSONDecoder().decode(LibraryLocation.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(persisted, saved)
        XCTAssertEqual(try LibraryLocationRestore.restore(persisted)?.url, URL(fileURLWithPath: saved.path!))
        let fallback = LibraryLocation(bookmark: Data([0, 1, 2]), path: root.path)
        XCTAssertEqual(try LibraryLocationRestore.restore(fallback)?.url, root.standardizedFileURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try LibraryLocationRestore.restore(fallback)) {
            XCTAssertEqual($0 as? LibraryLocationError, .unreadable)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let moved = parent.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: root, to: moved)
        let restored = try XCTUnwrap(LibraryLocationRestore.restore(persisted))
        XCTAssertEqual(restored.url.path, moved.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(restored.refreshedLocation?.path, restored.url.path)
        try FileManager.default.removeItem(at: moved)
        XCTAssertThrowsError(try LibraryLocationRestore.restore(fallback)) {
            XCTAssertEqual($0 as? LibraryLocationError, .notFound)
        }
        let file = parent.appendingPathComponent("file.md")
        try Data().write(to: file)
        XCTAssertThrowsError(try LibraryLocationRestore.restore(LibraryLocation(path: file.path))) {
            XCTAssertEqual($0 as? LibraryLocationError, .notFound)
        }
    }

    func testTolerantDecodingAndMovedBookmarkPreference() throws {
        XCTAssertEqual(try JSONDecoder().decode(LibraryLocation.self, from: Data("{}".utf8)), LibraryLocation())
        let result = try LibraryLocationRestore.restore(
            LibraryLocation(bookmark: old, path: "/missing"),
            resolve: { _, _ in .init(url: self.root, stale: false) }, validate: { _, _ in },
            save: { LibraryLocation(bookmark: self.fresh, path: $0.path) })
        XCTAssertEqual(result?.refreshedLocation?.path, root.path)
    }
}

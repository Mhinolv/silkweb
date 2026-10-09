import Foundation
import XCTest

@testable import SilkwebCore

/// #196: the library window's open sections, saved for relaunch.
final class AppSessionTests: XCTestCase {
    private func decode(_ json: String) throws -> AppSession {
        try JSONDecoder().decode(AppSession.self, from: Data(json.utf8))
    }

    private func section(_ path: String, collapsed: Bool = false) -> AppSession.Section {
        AppSession.Section(location: LibraryLocation(bookmark: Data([1, 2, 3]), path: path), collapsed: collapsed)
    }

    func testRoundTripKeepsOrderCollapseCurrentAndFocus() throws {
        let session = AppSession(
            sections: [section("/Libraries/Writing"), section("/Libraries/Archive", collapsed: true)],
            currentPath: "/Libraries/Archive", focusColumn: 2)
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(AppSession.self, from: data)
        XCTAssertEqual(decoded, session)
        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.currentIndex, 1)
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["version", "sections", "currentPath", "focusColumn"], "no #194 keys written")
    }

    func testMissingKeysDecodeWithDefaults() throws {
        let empty = try decode("{}")
        XCTAssertEqual(empty, AppSession())
        XCTAssertNil(empty.currentIndex, "no sections: the welcome screen")

        let sparse = try decode(#"{"version":1,"sections":[{"location":{"path":"/A"}},{"libraryPath":"/B"}]}"#)
        XCTAssertEqual(sparse.sections.map(\.path), ["/A", "/B"])
        XCTAssertEqual(sparse.sections.map(\.collapsed), [false, false])
        XCTAssertNil(sparse.focusColumn)
        XCTAssertEqual(sparse.currentIndex, 0, "no current path: the first section")

        let unknownCurrent = try decode(#"{"sections":[{"location":{"path":"/A"}}],"currentPath":"/Gone"}"#)
        XCTAssertEqual(unknownCurrent.currentIndex, 0)
        // Keys of the wrong type fall back to their defaults.
        let wrongTypes = try decode(
            #"{"sections":[{"location":{"path":"/A"},"collapsed":"yes"}],"currentPath":7,"focusColumn":"x"}"#)
        XCTAssertEqual(wrongTypes.sections.map(\.collapsed), [false])
        XCTAssertNil(wrongTypes.currentPath)
        XCTAssertNil(wrongTypes.focusColumn)
    }

    func testDuplicateAndPathlessSectionsAreDropped() throws {
        let session = try decode(
            #"""
            {"sections":[{"location":{"path":"/Libraries/Writing"}},{"location":{"path":""}},{"collapsed":true},
            {"location":{"path":"/Libraries/Notes/../Writing"},"collapsed":true},{"location":{"path":"/Libraries/B"}}]}
            """#)
        XCTAssertEqual(session.sections.map(\.path), ["/Libraries/Writing", "/Libraries/B"])
        XCTAssertEqual(session.sections.map(\.collapsed), [false, false], "the first entry for a folder wins")
    }

    /// #194 kept one Library per window. Mapping: the windows merge front to back into one window's sections,
    /// deduplicated by canonical path; the key window's Library is current.
    func testMultiWindowSessionMergesIntoSections() throws {
        let marked = try decode(
            #"""
            {"version":1,"windows":[{"libraryPath":"/B"},{"location":{"path":"/A"},"isKey":true},
            {"libraryPath":"/B"},{"libraryPath":"/C","collapsed":true}]}
            """#)
        XCTAssertEqual(marked.sections.map(\.path), ["/B", "/A", "/C"])
        XCTAssertEqual(marked.sections.map(\.collapsed), [false, false, true])
        XCTAssertEqual(marked.currentPath, "/A")
        XCTAssertEqual(marked.currentIndex, 1)

        let indexed = try decode(#"{"windows":[{"libraryPath":"/A"},{"libraryPath":"/B"}],"keyWindow":1}"#)
        XCTAssertEqual(indexed.currentPath, "/B")
        let unmarked = try decode(#"{"windows":[{"libraryPath":"/A"},{"libraryPath":"/A"}]}"#)
        XCTAssertEqual(unmarked.sections.map(\.path), ["/A"], "same Library in two windows: one section")
        XCTAssertEqual(unmarked.currentPath, "/A", "no key window: the front one")
        let nested = try decode(
            #"{"windows":[{"sections":[{"location":{"path":"/A"}},{"location":{"path":"/B"}}]},{"libraryPath":"/C"}]}"#)
        XCTAssertEqual(nested.sections.map(\.path), ["/A", "/B", "/C"])
        XCTAssertEqual(nested.currentPath, "/A")
        // Saving it again writes the current shape.
        let resaved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(marked)) as? [String: Any]
        XCTAssertNil(resaved?["windows"])
        XCTAssertNotNil(resaved?["sections"])
    }

    func testPlanFallsBackToLegacyForMissingCorruptOrNewerSessions() throws {
        XCTAssertEqual(AppSessionLaunch.plan(nil, reopensSession: true), .legacy(canSave: true))
        XCTAssertEqual(AppSessionLaunch.plan(Data("not json".utf8), reopensSession: true), .legacy(canSave: true))
        XCTAssertEqual(AppSessionLaunch.plan(Data("[1,2]".utf8), reopensSession: true), .legacy(canSave: true))
        XCTAssertEqual(
            AppSessionLaunch.plan(Data(#"{"sections":"bad"}"#.utf8), reopensSession: true), .legacy(canSave: true))
        let newer = Data(#"{"version":2,"sections":[{"location":{"path":"/A"}}]}"#.utf8)
        XCTAssertEqual(AppSessionLaunch.plan(newer, reopensSession: true), .legacy(canSave: false))
        XCTAssertEqual(AppSessionLaunch.plan(newer, reopensSession: false), .legacy(canSave: false))
        XCTAssertThrowsError(try JSONDecoder().decode(AppSession.self, from: newer)) {
            XCTAssertEqual($0 as? AppSessionError, .newerVersion(2))
        }
        // An empty but valid session is the welcome screen, not the legacy Library.
        let empty = try JSONEncoder().encode(AppSession())
        XCTAssertEqual(AppSessionLaunch.plan(empty, reopensSession: true), .sections(AppSession()))
    }

    /// Owner decision on #196: with “Reopen windows and tabs” off only the last current Library comes back.
    func testReopenOffKeepsOnlyTheCurrentSectionExpanded() throws {
        let session = AppSession(
            sections: [section("/A"), section("/B", collapsed: true), section("/C")], currentPath: "/B",
            focusColumn: 1)
        XCTAssertEqual(session.reduced(reopensSession: true), session)
        let reduced = session.reduced(reopensSession: false)
        XCTAssertEqual(reduced.sections.map(\.path), ["/B"])
        XCTAssertEqual(reduced.sections.map(\.collapsed), [false])
        XCTAssertEqual(reduced.sections.first?.location.bookmark, Data([1, 2, 3]))
        XCTAssertEqual(reduced.currentPath, "/B")
        XCTAssertNil(reduced.focusColumn)
        XCTAssertEqual(AppSession().reduced(reopensSession: false), AppSession())
        // A current path that's gone: the first section.
        var stale = session
        stale.currentPath = "/Gone"
        XCTAssertEqual(stale.reduced(reopensSession: false).sections.map(\.path), ["/A"])
        let data = try JSONEncoder().encode(session)
        XCTAssertEqual(AppSessionLaunch.plan(data, reopensSession: false), .sections(reduced))
        XCTAssertEqual(AppSessionLaunch.plan(data, reopensSession: true), .sections(session))
    }
}

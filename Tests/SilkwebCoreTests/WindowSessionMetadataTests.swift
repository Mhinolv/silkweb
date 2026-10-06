import XCTest

@testable import SilkwebCore

final class WindowSessionMetadataTests: XCTestCase {
    func testSidebarsVisibilityBackwardCompatibility() throws {
        for version in [1, 2] {
            for flag in [
                "", ",\"sidebarsHidden\":false", ",\"sidebarsHidden\":true", ",\"sidebarsHidden\":null",
                ",\"sidebarsHidden\":\"bad\"",
            ] {
                let json = "{\"formatVersion\":\(version)\(flag)}"
                let value = try JSONDecoder().decode(WindowSessionMetadata.self, from: Data(json.utf8))
                XCTAssertEqual(value.sidebarsHidden, flag.contains(":true"))
                XCTAssertEqual(value.formatVersion, 3)
                XCTAssertEqual(
                    try JSONDecoder().decode(WindowSessionMetadata.self, from: JSONEncoder().encode(value)), value)
            }
        }
    }

    func testTagsExpansionVersionAndTolerantDecodeSweep() throws {
        for version in [1, 2, 3] {
            for flag in [
                "", ",\"tagsExpanded\":true", ",\"tagsExpanded\":false", ",\"tagsExpanded\":null",
                ",\"tagsExpanded\":\"bad\"",
            ] {
                let json = "{\"formatVersion\":\(version)\(flag)}"
                let value = try JSONDecoder().decode(WindowSessionMetadata.self, from: Data(json.utf8))
                XCTAssertEqual(value.tagsExpanded, !flag.contains(":false"))
                XCTAssertEqual(value.formatVersion, 3)
                XCTAssertEqual(
                    try JSONDecoder().decode(WindowSessionMetadata.self, from: JSONEncoder().encode(value)), value)
            }
        }
    }

    /// silkweb-1.27: per-window Focus/Typewriter flags. Files from earlier builds (no keys) load
    /// with both off; bad values fall back to off; every combination round-trips.
    func testWritingModesBackwardCompatibilityAndRoundTrip() throws {
        let values = ["", ":true", ":false", ":null", ":\"bad\"", ":1"]
        for version in [1, 2, 3] {
            for focus in values {
                for typewriter in values {
                    var json = "{\"formatVersion\":\(version),\"viewMode\":\"split\""
                    if !focus.isEmpty { json += ",\"focusMode\"" + focus }
                    if !typewriter.isEmpty { json += ",\"typewriterMode\"" + typewriter }
                    json += "}"
                    let value = try JSONDecoder().decode(WindowSessionMetadata.self, from: Data(json.utf8))
                    XCTAssertEqual(value.focusMode, focus == ":true", json)
                    XCTAssertEqual(value.typewriterMode, typewriter == ":true", json)
                    XCTAssertEqual(value.viewMode, "split")
                    XCTAssertEqual(value.formatVersion, 3)
                    XCTAssertEqual(
                        try JSONDecoder().decode(WindowSessionMetadata.self, from: JSONEncoder().encode(value)), value)
                }
            }
        }
        XCTAssertFalse(WindowSessionMetadata().focusMode)
        XCTAssertFalse(WindowSessionMetadata().typewriterMode)
        for (focus, typewriter) in [(false, false), (true, false), (false, true), (true, true)] {
            var value = WindowSessionMetadata()
            value.focusMode = focus
            value.typewriterMode = typewriter
            let decoded = try JSONDecoder().decode(WindowSessionMetadata.self, from: JSONEncoder().encode(value))
            XCTAssertEqual(decoded.focusMode, focus)
            XCTAssertEqual(decoded.typewriterMode, typewriter)
        }
    }

    func testDefaultsAndPositionModeSweep() throws {
        XCTAssertEqual(
            try JSONDecoder().decode(WindowSessionMetadata.self, from: Data("{}".utf8)), WindowSessionMetadata())
        let id = UUID()
        let partial = try JSONDecoder().decode(DocumentTabMetadata.self, from: Data("{\"documentID\":\"\(id)\"}".utf8))
        XCTAssertFalse(partial.isPreview)
        XCTAssertEqual(partial.selectionLocation, 0)
        for count in [0, 1, 2, 1000] {
            for mode in ["editor", "split", "preview"] {
                for preview in [false, true] {
                    for location in [0, 1, Int.max] {
                        var value = WindowSessionMetadata()
                        value.viewMode = mode
                        value.selectedFolder = nil
                        value.tabs = (0..<count).map { index in
                            var tab = DocumentTabMetadata(
                                documentID: UUID(), relativePath: "Folder/\(index).md", isPreview: preview && index == 0
                            )
                            tab.selectionLocation = location; tab.selectionLength = location
                            tab.scrollY = 1_000_000
                            return tab
                        }
                        value.activeDocumentID = value.tabs.last?.documentID
                        XCTAssertEqual(
                            try JSONDecoder().decode(WindowSessionMetadata.self, from: JSONEncoder().encode(value)),
                            value)
                    }
                }
            }
        }
        let negative = try JSONDecoder().decode(
            DocumentTabMetadata.self,
            from: Data(
                "{\"documentID\":\"\(id)\",\"selectionLocation\":-5,\"selectionLength\":-1,\"scrollY\":-10}".utf8))
        XCTAssertEqual(negative.selectionLocation, 0)
        XCTAssertEqual(negative.selectionLength, 0)
        XCTAssertEqual(negative.scrollY, 0)
        XCTAssertThrowsError(
            try JSONDecoder().decode(WindowSessionMetadata.self, from: Data("{\"formatVersion\":999}".utf8)))
    }

    func testLossyTabDecodeAndActiveFallbackSweep() throws {
        let first = UUID(), last = UUID(), dropped = UUID(), folder = UUID()
        let invalid = [
            "{}", "null", "42", "[]", "\"tab\"",
            "{\"documentID\":\"invalid\"}",
            "{\"documentID\":\"\(dropped)\",\"isPreview\":1}",
            "{\"documentID\":\"\(dropped)\",\"selectionLocation\":\"bad\"}",
        ]
        let valid = [
            "{\"documentID\":\"\(first)\",\"relativePath\":\"A.md\"}",
            "{\"documentID\":\"\(last)\",\"relativePath\":\"B.md\",\"isPreview\":true}",
        ]
        for mode in ["editor", "split", "preview"] {
            for bad in invalid {
                for position in 0...2 {
                    var entries = valid
                    entries.insert(bad, at: position)
                    for active in ["\"\(last)\"", "\"\(dropped)\"", "\"invalid\"", "42", "null"] {
                        let json = """
                            {"tabs":[\(entries.joined(separator: ","))],"activeDocumentID":\(active),
                             "selectedFolderID":"\(folder)","selectedFolder":"Notes","viewMode":"\(mode)"}
                            """
                        let value = try JSONDecoder().decode(WindowSessionMetadata.self, from: Data(json.utf8))
                        XCTAssertEqual(value.tabs.map(\.documentID), [first, last])
                        XCTAssertEqual(value.tabs.map(\.isPreview), [false, true])
                        XCTAssertEqual(value.activeDocumentID, active == "\"\(last)\"" ? last : first)
                        XCTAssertEqual(value.selectedFolderID, folder)
                        XCTAssertEqual(value.selectedFolder, "Notes")
                        XCTAssertEqual(value.viewMode, mode)
                    }
                }
            }
        }
        for entries in ["", invalid.joined(separator: ",")] {
            let value = try JSONDecoder().decode(
                WindowSessionMetadata.self,
                from: Data("{\"tabs\":[\(entries)],\"activeDocumentID\":\"\(dropped)\"}".utf8))
            XCTAssertTrue(value.tabs.isEmpty)
            XCTAssertNil(value.activeDocumentID)
        }
    }

    func testVersionOneFixtureStillRestoresUnchanged() throws {
        let id = UUID(), folder = UUID()
        // Literal schema from before lossy decoding (not encoded by the new implementation).
        let json = """
            {"formatVersion":1,"tabs":[{"documentID":"\(id)","relativePath":"Notes/A.md",
             "isPreview":true,"selectionLocation":7,"selectionLength":2,"scrollY":120}],
             "activeDocumentID":"\(id)","selectedFolderID":"\(folder)","selectedFolder":"Notes","viewMode":"split"}
            """
        let value = try JSONDecoder().decode(WindowSessionMetadata.self, from: Data(json.utf8))
        var tab = DocumentTabMetadata(documentID: id, relativePath: "Notes/A.md", isPreview: true)
        tab.selectionLocation = 7; tab.selectionLength = 2; tab.scrollY = 120
        XCTAssertEqual(value.formatVersion, 3)
        XCTAssertEqual(value.tabs, [tab])
        XCTAssertEqual(value.activeDocumentID, id)
        XCTAssertEqual(value.selectedFolderID, folder)
        XCTAssertEqual(value.selectedFolder, "Notes")
        XCTAssertEqual(value.viewMode, "split")
    }

    func testMalformedOptionalSessionFieldsUseDefaults() throws {
        for json in [
            "{\"tabs\":42}", "{\"tabs\":null}",
            "{\"formatVersion\":\"bad\",\"selectedFolderID\":\"bad\",\"selectedFolder\":42,\"viewMode\":false}",
        ] {
            let value = try JSONDecoder().decode(WindowSessionMetadata.self, from: Data(json.utf8))
            XCTAssertTrue(value.tabs.isEmpty)
            XCTAssertNil(value.activeDocumentID)
            XCTAssertNil(value.selectedFolderID)
            XCTAssertEqual(value.viewMode, "editor")
        }
    }

    func testDiskRoundTripMissingDocumentsStableIDRebindAndOldSession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("a".utf8).write(to: root.appendingPathComponent("A.md"))
        try Data("b".utf8).write(to: root.appendingPathComponent("B.md"))
        let first = try await LibraryScanner.scan(root: root)
        let a = try XCTUnwrap(first.documents.first { $0.relativePath == "A.md" })
        let b = try XCTUnwrap(first.documents.first { $0.relativePath == "B.md" })
        let initial = try await WindowSessionMetadata.load(root: root)
        XCTAssertNil(initial)
        var value = WindowSessionMetadata()
        value.tabs = [
            DocumentTabMetadata(documentID: a.id, relativePath: a.relativePath, isPreview: false),
            DocumentTabMetadata(documentID: b.id, relativePath: b.relativePath, isPreview: true),
        ]
        value.activeDocumentID = b.id
        value.selectedFolderID = first.folders[0].id
        try await value.save(root: root)
        let saved = try await WindowSessionMetadata.load(root: root)
        XCTAssertEqual(saved, value)
        let engine = try LibraryMutations(root: root)
        _ = try await engine.rename("A.md", to: "Moved.md")
        try FileManager.default.removeItem(at: root.appendingPathComponent("B.md"))
        let changed = try await LibraryScanner.scan(root: root)
        let rebound = value.resolving(in: changed)
        XCTAssertEqual(rebound.tabs.map(\.relativePath), ["Moved.md"])
        XCTAssertEqual(rebound.activeDocumentID, a.id)
        // A new document occupying a stale path must never receive the old buffer.
        try Data("replacement".utf8).write(to: root.appendingPathComponent("B.md"))
        let replaced = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(value.resolving(in: replaced).tabs.map(\.documentID), [a.id])
        var duplicate = value
        duplicate.tabs = [value.tabs[0], value.tabs[0]]
        XCTAssertEqual(duplicate.resolving(in: replaced).tabs.count, 1)
        // Pre-tab navigation JSON remains readable and its schema remains unchanged.
        let old = try JSONDecoder().decode(
            LibrarySession.self, from: Data("{\"formatVersion\":1,\"selectedDocuments\":[\"Moved.md\"]}".utf8))
        XCTAssertEqual(old.selectedDocuments, ["Moved.md"])
        try await old.save(root: root)
        let oldReloaded = try await LibrarySession.load(root: root)
        XCTAssertEqual(oldReloaded, old)
    }
}

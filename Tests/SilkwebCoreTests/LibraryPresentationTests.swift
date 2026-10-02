import XCTest
@testable import SilkwebCore

final class LibraryPresentationTests: XCTestCase {
    func testSidebarInlineSuffixUsesOnlyDirectCountIncludingZero() {
        for direct in [0, 1, 2, 999, 1_204, 10_000, Int.max] {
            for recursive in [direct, Int.max] {
                let count = FolderDocumentCount(direct: direct, recursive: recursive)
                XCTAssertEqual(count.inlineSuffix, " (\(direct.formatted()))")
                XCTAssertTrue(count.tooltip.contains(recursive.formatted() + " including subfolders"))
                XCTAssertTrue(count.accessibilityValue.contains(recursive.formatted() + " including subfolders"))
            }
        }
        XCTAssertEqual(FolderDocumentCount().inlineSuffix, " (0)")
        XCTAssertEqual(FolderDocumentCount(direct: 2, recursive: 8).inlineSuffix, " (2)")
        XCTAssertEqual(FolderDocumentCount(direct: 1_204).inlineSuffix, " (1,204)")
    }

    func testCountsNaturalFoldersAndRecursiveBoundary() {
        let root = LibraryFolder(id: UUID(), parentID: nil, relativePath: "", name: "Library")
        let two = LibraryFolder(id: UUID(), parentID: root.id, relativePath: "Chapter 2", name: "Chapter 2")
        let ten = LibraryFolder(id: UUID(), parentID: root.id, relativePath: "chapter 10", name: "chapter 10")
        let nested = LibraryFolder(id: UUID(), parentID: two.id, relativePath: "Chapter 2/Drafts", name: "Drafts")
        let prefix = LibraryFolder(id: UUID(), parentID: root.id, relativePath: "Chapter 20", name: "Chapter 20")
        let folders = [root, ten, two, nested, prefix]
        let documents = [root, two, nested, prefix].map {
            LibraryDocument(id: UUID(), folderID: $0.id, relativePath: $0.relativePath.isEmpty ? "Note.md" : $0.relativePath + "/Note.md", name: "Note.md")
        }
        let presentation = LibraryPresentation(folders: folders, documents: documents)
        XCTAssertEqual(presentation.counts[root.id], FolderDocumentCount(direct: 1, recursive: 4))
        XCTAssertEqual(presentation.counts[two.id], FolderDocumentCount(direct: 1, recursive: 2))
        XCTAssertEqual(presentation.counts[ten.id]?.badge, "")
        XCTAssertEqual(presentation.children[root.id]?.map(\.name), ["Chapter 2", "chapter 10", "Chapter 20"])
        var preference = LibraryListPreference()
        XCTAssertEqual(presentation.documents(in: two, preference: preference).count, 1)
        preference.includeSubfolders = true
        XCTAssertEqual(presentation.documents(in: two, preference: preference).count, 2)
        XCTAssertEqual(presentation.documents(in: root, preference: preference).count, 4)
        XCTAssertEqual(presentation.documents(in: nil, preference: preference).count, 4)
        XCTAssertNil(LibraryPresentation.breadcrumb(for: documents[1], in: two.relativePath))
        XCTAssertEqual(LibraryPresentation.breadcrumb(for: documents[2], in: two.relativePath), "Drafts")
        XCTAssertEqual(LibraryPresentation.breadcrumb(for: documents[2], in: ""), "Chapter 2 › Drafts")
    }

    func testEverySortModeAndDeterministicTiesAtScale() {
        let folder = LibraryFolder(id: UUID(), parentID: nil, relativePath: "", name: "Library")
        for count in [0, 1, 10_000] {
            let documents = (0..<count).map { index in
                LibraryDocument(id: UUID(), folderID: folder.id, relativePath: "Folder \(index)/Note \(index % 10).md", name: "Note \(index % 10).md",
                                created: index % 4 == 0 ? nil : Date(timeIntervalSince1970: Double(index % 3)),
                                modified: index % 5 == 0 ? nil : Date(timeIntervalSince1970: Double(index % 7)))
            }
            let presentation = LibraryPresentation(folders: [folder], documents: documents)
            let reversed = LibraryPresentation(folders: [folder], documents: documents.reversed())
            for key in DocumentSortKey.allCases {
                for descending in [false, true] {
                    for recursive in [false, true] {
                        var preference = LibraryListPreference()
                        preference.key = key; preference.descending = descending; preference.includeSubfolders = recursive
                        let sorted = presentation.documents(in: folder, preference: preference)
                        XCTAssertEqual(sorted.count, count)
                        XCTAssertEqual(sorted, reversed.documents(in: folder, preference: preference))
                        for (a, b) in zip(sorted, sorted.dropFirst()) {
                            if key == .name {
                                let result = a.name.localizedStandardCompare(b.name)
                                XCTAssertNotEqual(result, descending ? .orderedAscending : .orderedDescending)
                            } else {
                                let aDate = (key == .created ? a.created : a.modified) ?? .distantPast
                                let bDate = (key == .created ? b.created : b.modified) ?? .distantPast
                                XCTAssertTrue(descending ? aDate >= bDate : aDate <= bDate)
                                if aDate == bDate {
                                    XCTAssertTrue(LibraryPresentation.naturalOrder(a.name, b.name, pathA: a.relativePath, pathB: b.relativePath))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    func testScanDatesAndCreationDateSurvivesAtomicSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Old.md")
        try Data("original".utf8).write(to: url)
        let created = Date(timeIntervalSince1970: 1_500_000_000)
        let modified = Date(timeIntervalSince1970: 1_600_000_000)
        try FileManager.default.setAttributes([.creationDate: created, .modificationDate: modified], ofItemAtPath: url.path)
        let before = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(before.documents[0].created, created)
        XCTAssertEqual(before.documents[0].modified, modified)
        let store = DocumentStore(root: root)
        let revision = try store.load(url).revision
        _ = try store.save("edited", to: url, expectedRevision: revision)
        let after = try await LibraryScanner.refreshingDates(in: before, documentID: before.documents[0].id)
        XCTAssertEqual(after.documents[0].created, created)
        XCTAssertGreaterThan(try XCTUnwrap(after.documents[0].modified), modified)
    }

    func testOlderSessionsAndPreferenceIdentityThroughMoves() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".silkweb"), withIntermediateDirectories: false)
        try Data(#"{"formatVersion":1,"selectedFolder":"","expandedFolders":[""]}"#.utf8).write(to: root.appendingPathComponent(".silkweb/session.json"))
        var session = try await LibrarySession.load(root: root)
        XCTAssertEqual(session.listPreferences, [:])
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createFolder(named: "Chapter 2")
        let before = try await LibraryScanner.scan(root: root)
        let id = try XCTUnwrap(before.folders.first { $0.relativePath == "Chapter 2" }?.id)
        var preference = LibraryListPreference()
        preference.select(.name)
        XCTAssertFalse(preference.descending)
        preference.includeSubfolders = true
        session.listPreferences["folder:" + id.uuidString] = preference
        session.listPreferences["all"] = LibraryListPreference()
        try await session.save(root: root)
        _ = try await engine.rename("Chapter 2", to: "Chapter 3")
        let after = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(after.folders.first { $0.relativePath == "Chapter 3" }?.id, id)
        let restored = try await LibrarySession.load(root: root)
        XCTAssertEqual(restored.listPreferences["folder:" + id.uuidString], preference)
        XCTAssertEqual(restored.listPreferences["all"], LibraryListPreference())
        let partial = try JSONDecoder().decode(LibraryListPreference.self, from: Data(#"{"key":"name"}"#.utf8))
        XCTAssertFalse(partial.descending)
        XCTAssertFalse(partial.includeSubfolders)
        preference.select(.created)
        XCTAssertTrue(preference.descending)
        preference.descending = false
        preference.select(.created)
        XCTAssertFalse(preference.descending)
    }
}

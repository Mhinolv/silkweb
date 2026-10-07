import XCTest

@testable import SilkwebCore

final class LibraryScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, text: String = "# Café 日本語\n") throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testNestedEmptyFoldersExtensionsAndUTF8() async throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Nested/Empty"), withIntermediateDirectories: true)
        for name in [
            "Top.md", "Nested/Note.markdown", "Nested/UPPER.MD", "ignored.txt", ".hidden.md",
            ".hidden/ignored.md", ".silkweb/ignored.md", "Nested/Empty/fake.md/ignored.txt",
        ] {
            try write(name)
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(
            Set(snapshot.folders.map(\.relativePath)), ["", "Nested", "Nested/Empty", "Nested/Empty/fake.md"])
        XCTAssertEqual(
            Set(snapshot.documents.map(\.relativePath)), ["Top.md", "Nested/Note.markdown", "Nested/UPPER.MD"])
        for document in snapshot.documents {
            XCTAssertTrue(snapshot.folders.contains { $0.id == document.folderID })
            let text = try await LibraryScanner.readDocument(document, root: root)
            XCTAssertEqual(text, "# Café 日本語\n")
        }
        let again = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(snapshot.metadata, again.metadata)
        XCTAssertNil(again.recoveredMetadataURL)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Top.md"))
        let afterDelete = try await LibraryScanner.scan(root: root)
        XCTAssertNil(afterDelete.metadata.IDsByPath["Top.md"])
    }

    func testEmptyLibraryAndOldMetadata() async throws {
        try write(".silkweb/index.json", text: "{}")
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(snapshot.folders.count, 1)
        XCTAssertTrue(snapshot.documents.isEmpty)
        XCTAssertEqual(snapshot.metadata.formatVersion, LibraryMetadata.currentVersion)
        XCTAssertNil(snapshot.recoveredMetadataURL)
    }

    func testMalformedMetadataIsPreservedAndRebuilt() async throws {
        // #107: only wholly undecodable files (or a field of the wrong shape) are set aside.
        for malformed in [
            "not JSON", "[]", "{\"IDsByPath\":[\"Note.md\"]}", "{\"tags\":{}}", "{\"formatVersion\":\"3\"}",
        ] {
            try write("Note.md")
            try write(".silkweb/index.json", text: malformed)
            let snapshot = try await LibraryScanner.scan(root: root)
            let recovered = try XCTUnwrap(snapshot.recoveredMetadataURL, malformed)
            XCTAssertTrue(snapshot.metadataWasReset)
            XCTAssertTrue(recovered.lastPathComponent.hasPrefix("index.corrupt-"))
            XCTAssertEqual(try String(contentsOf: recovered, encoding: .utf8), malformed)
            XCTAssertEqual(snapshot.documents.count, 1)
            let saved = try JSONDecoder().decode(
                LibraryMetadata.self, from: Data(contentsOf: root.appendingPathComponent(".silkweb/index.json")))
            XCTAssertEqual(saved, snapshot.metadata)
            // The rebuilt index is healthy: the next scan reports nothing.
            let again = try await LibraryScanner.scan(root: root)
            XCTAssertNil(again.recoveredMetadataURL)
            XCTAssertFalse(again.metadataWasReset)
        }
    }

    /// #107: one bad tag, tag set or ID drops only that entry; nothing is set aside and nothing is reported.
    func testPartiallyInvalidMetadataKeepsValidEntries() async throws {
        try write("Keep.md")
        try write("Other.md")
        let keep = UUID()
        let other = UUID()
        let tag = UUID()
        let second = UUID()
        let json = """
            {"formatVersion":3,
             "tags":[{"id":"\(tag.uuidString)","name":"Travel"},{"id":"bad","name":"Broken"},{"name":"No ID"},
                     {"id":"\(second.uuidString)","name":"Coffee"}],
             "tagRecency":["\(second.uuidString)","bad"],
             "tagsByDocument":{"\(keep.uuidString)":["\(tag.uuidString)","bad","\(second.uuidString)"],
                               "\(other.uuidString)":"bad"},
             "IDsByPath":{"Keep.md":"\(keep.uuidString)","Other.md":"invalid UUID","":42}}
            """
        try write(".silkweb/index.json", text: json)
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertNil(snapshot.recoveredMetadataURL)
        XCTAssertFalse(snapshot.metadataWasReset)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(".silkweb").path)
        XCTAssertEqual(files, ["index.json"])
        XCTAssertEqual(snapshot.metadata.tags.map(\.name), ["Travel", "Coffee"])
        XCTAssertEqual(snapshot.metadata.tagRecency, [second])
        XCTAssertEqual(snapshot.metadata.tagsByDocument, [keep.uuidString: [tag, second]])
        XCTAssertEqual(snapshot.documents.first { $0.relativePath == "Keep.md" }?.id, keep)
        // The bad ID is replaced by a fresh one; the folder root's bad ID too.
        XCTAssertNotNil(snapshot.metadata.IDsByPath["Other.md"])
        XCTAssertNotEqual(snapshot.metadata.IDsByPath["Other.md"], other)
        let again = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(again.metadata, snapshot.metadata)
    }

    /// #107: an unwritable `.silkweb` can't hold a copy; the reset is still reported and the file is left alone.
    func testUnreadableIndexInUnwritableFolderReportsResetWithoutCopy() async throws {
        try write("Note.md")
        try write(".silkweb/index.json", text: "not JSON")
        let directory = root.appendingPathComponent(".silkweb")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        for _ in 0..<2 {
            let snapshot = try await LibraryScanner.scan(root: root)
            XCTAssertTrue(snapshot.metadataWasReset)
            XCTAssertNil(snapshot.recoveredMetadataURL)
            XCTAssertTrue(snapshot.isReadOnly)
            XCTAssertEqual(snapshot.documents.count, 1)
            XCTAssertEqual(
                try String(contentsOf: directory.appendingPathComponent("index.json"), encoding: .utf8), "not JSON")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["index.json"])
        }
    }

    func testNewerFormatIsNotOverwritten() async throws {
        let json = "{\"formatVersion\":999}"
        try write(".silkweb/index.json", text: json)
        do {
            _ = try await LibraryScanner.scan(root: root)
            XCTFail("Expected unsupported version")
        } catch {
            XCTAssertEqual(error as? LibraryError, .unsupportedMetadataVersion(999))
        }
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent(".silkweb/index.json"), encoding: .utf8), json)
    }

    func testSymlinkCycleFilesAndDanglingLinksAreSkipped() async throws {
        try write("Folder/real.md")
        for (path, destination) in [
            ("Folder/cycle", root.path), ("linked.md", root.appendingPathComponent("Folder/real.md").path),
            ("dangling.md", root.appendingPathComponent("missing").path),
        ] {
            try FileManager.default.createSymbolicLink(
                atPath: root.appendingPathComponent(path).path, withDestinationPath: destination)
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(snapshot.folders.count, 2)
        XCTAssertEqual(snapshot.documents.map(\.relativePath), ["Folder/real.md"])
        // A file swapped for a symlink after scanning must not be read.
        let url = root.appendingPathComponent("Folder/real.md")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(
            atPath: url.path, withDestinationPath: root.appendingPathComponent("missing").path)
        do {
            _ = try await LibraryScanner.readDocument(snapshot.documents[0], root: root)
            XCTFail("Expected symlink rejection")
        } catch {
            XCTAssertEqual(error as? LibraryError, .symbolicLink(url))
        }
    }

    func testMetadataSymlinksAreRejected() async throws {
        for path in [".silkweb", ".silkweb/index.json"] {
            if path.contains("/") {
                try FileManager.default.createDirectory(
                    at: root.appendingPathComponent(".silkweb"), withIntermediateDirectories: false)
            }
            let url = root.appendingPathComponent(path)
            try FileManager.default.createSymbolicLink(
                atPath: url.path, withDestinationPath: root.appendingPathComponent("missing").path)
            do {
                _ = try await LibraryScanner.scan(root: root)
                XCTFail("Expected symlink rejection")
            } catch {
                guard case let LibraryError.symbolicLink(rejected) = error else {
                    return XCTFail("Expected symlink rejection, got \(error)")
                }
                XCTAssertEqual(rejected.path, url.path)
            }
            try FileManager.default.removeItem(at: root.appendingPathComponent(".silkweb"))
        }
    }

    func testDuplicateMetadataIDsAreRepaired() async throws {
        try write("Note.md")
        let id = UUID()
        try LibraryMetadataStore.save(LibraryMetadata(IDsByPath: ["": id, "Note.md": id]), root: root)
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertNotEqual(snapshot.folders[0].id, snapshot.documents[0].id)
    }

    func testMissingAndNonDirectoryRootsThrow() async throws {
        do {
            _ = try await LibraryScanner.scan(root: root.appendingPathComponent("missing"))
            XCTFail("Missing roots must throw")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
        }
        try write("File.md")
        do {
            _ = try await LibraryScanner.scan(root: root.appendingPathComponent("File.md"))
            XCTFail("A document cannot be a library root")
        } catch {
            XCTAssertEqual(error as? LibraryError, .invalidRoot)
        }
    }

    func testUnchangedScanDoesNotRewriteIndex() async throws {
        try write("Note.md")
        _ = try await LibraryScanner.scan(root: root)
        let index = root.appendingPathComponent(".silkweb/index.json")
        let oldDate = Date(timeIntervalSince1970: 1_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: index.path)
        _ = try await LibraryScanner.scan(root: root)
        let attributes = try FileManager.default.attributesOfItem(atPath: index.path)
        XCTAssertEqual(attributes[.modificationDate] as? Date, oldDate)
    }

    func testReadOnlyRootWithoutIndexStillOpens() async throws {
        try write("Nested/Note.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        XCTAssertFalse(FileManager.default.isWritableFile(atPath: root.path))
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertTrue(snapshot.isReadOnly)
        XCTAssertEqual(snapshot.documents.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".silkweb").path))
        let text = try await LibraryScanner.readDocument(snapshot.documents[0], root: root)
        XCTAssertEqual(text, "# Café 日本語\n")
    }

    func testUnreadableSubfoldersStillScanWithReadableSiblings() async throws {
        try write("Locked/Nested/Hidden.md")
        try write("Parent/Locked/Hidden.md")
        try write("Parent/Readable/Note.md")
        try write("Readable/Note.markdown")
        try write("Top.md")
        let blocked = ["Locked", "Parent/Locked"].map { root.appendingPathComponent($0) }
        defer {
            for url in blocked {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
        }
        for url in blocked {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(Set(snapshot.folders.filter(\.isUnreadable).map(\.relativePath)), ["Locked", "Parent/Locked"])
        XCTAssertEqual(
            Set(snapshot.folders.map(\.relativePath)),
            ["", "Locked", "Parent", "Parent/Locked", "Parent/Readable", "Readable"])
        XCTAssertEqual(
            Set(snapshot.documents.map(\.relativePath)),
            ["Parent/Readable/Note.md", "Readable/Note.markdown", "Top.md"])
        XCTAssertFalse(snapshot.isReadOnly)
    }

    func testUnreadableFolderPreservesDescendantIDsUntilPermissionsReturn() async throws {
        try write("Locked/Nested/Hidden.md")
        try write("Locked/Hidden.md")
        try write("Locked-Sibling/Deleted.md")
        let before = try await LibraryScanner.scan(root: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Locked-Sibling/Deleted.md"))
        let blocked = root.appendingPathComponent("Locked")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        for _ in 0..<2 {
            let snapshot = try await LibraryScanner.scan(root: root)
            XCTAssertTrue(try XCTUnwrap(snapshot.folders.first { $0.relativePath == "Locked" }).isUnreadable)
            XCTAssertTrue(snapshot.documents.isEmpty)
            for path in ["Locked", "Locked/Nested", "Locked/Hidden.md", "Locked/Nested/Hidden.md"] {
                XCTAssertEqual(snapshot.metadata.IDsByPath[path], before.metadata.IDsByPath[path])
            }
            // A similarly named readable sibling must still have deletions pruned.
            XCTAssertNil(snapshot.metadata.IDsByPath["Locked-Sibling/Deleted.md"])
            let saved = try LibraryMetadataStore.load(root: root).0
            XCTAssertEqual(saved, snapshot.metadata)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        let restored = try await LibraryScanner.scan(root: root)
        XCTAssertTrue(restored.folders.allSatisfy { !$0.isUnreadable })
        XCTAssertEqual(Set(restored.documents.map(\.relativePath)), ["Locked/Hidden.md", "Locked/Nested/Hidden.md"])
        for path in ["Locked", "Locked/Nested", "Locked/Hidden.md", "Locked/Nested/Hidden.md"] {
            XCTAssertEqual(restored.metadata.IDsByPath[path], before.metadata.IDsByPath[path])
        }
        try FileManager.default.removeItem(at: blocked)
        let deleted = try await LibraryScanner.scan(root: root)
        XCTAssertFalse(deleted.metadata.IDsByPath.keys.contains { $0 == "Locked" || $0.hasPrefix("Locked/") })
    }

    func testUnreadableRootStillThrowsPermissionError() async throws {
        try write("Note.md")
        let before = try await LibraryScanner.scan(root: root)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path) }
        // Execute-only access can load the index, but root enumeration must still fail.
        for mode in [0o000, 0o100] {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: root.path)
            do {
                _ = try await LibraryScanner.scan(root: root)
                XCTFail("Unreadable roots must fail to open")
            } catch {
                XCTAssertEqual((error as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual((error as NSError).code, NSFileReadNoPermissionError)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        XCTAssertEqual(try LibraryMetadataStore.load(root: root).0, before.metadata)
    }

    func testReadOnlyIndexAndCorruptIndexStillOpen() async throws {
        try write("Note.md")
        _ = try await LibraryScanner.scan(root: root)
        let directory = root.appendingPathComponent(".silkweb")
        let index = directory.appendingPathComponent("index.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: index.path)
        let indexed = try await LibraryScanner.scan(root: root)
        XCTAssertTrue(indexed.isReadOnly)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: index.path)
        try Data("broken".utf8).write(to: index)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        let recovered = try await LibraryScanner.scan(root: root)
        XCTAssertTrue(recovered.isReadOnly)
        XCTAssertEqual(recovered.documents.count, 1)
        XCTAssertEqual(try String(contentsOf: index, encoding: .utf8), "broken")
    }

    @MainActor
    func testLargeLibraryOffMainThreadWithinBudget() async throws {
        for folder in 0..<1_000 {
            let directory = root.appendingPathComponent("Folder-\(folder)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            for document in 0..<10 {
                try Data("# Note\n".utf8).write(to: directory.appendingPathComponent("Note-\(document).md"))
            }
        }
        // Called from the main actor; the scanner asserts its worker is not on the main thread.
        let start = Date()
        let snapshot = try await LibraryScanner.scan(root: root)
        let elapsed = Date().timeIntervalSince(start)
        print("Library scan: 10,000 documents / 1,000 folders in \(elapsed)s (budget: 10s)")
        XCTAssertEqual(snapshot.documents.count, 10_000)
        XCTAssertEqual(snapshot.folders.count, 1_001)
        XCTAssertLessThan(elapsed, 10)
    }
}

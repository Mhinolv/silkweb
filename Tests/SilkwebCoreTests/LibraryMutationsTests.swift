import XCTest
@testable import SilkwebCore

final class LibraryMutationsTests: XCTestCase {
    private var root: URL!
    private var engine: LibraryMutations!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        engine = try LibraryMutations(root: root)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func contents(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    private func rejects(_ expected: LibraryMutationError? = nil, _ operation: () async throws -> LibraryChangeSet) async {
        do {
            _ = try await operation()
            XCTFail("Expected rejection")
        } catch {
            if let expected { XCTAssertEqual(error as? LibraryMutationError, expected) }
        }
    }

    private func rejectsCollision(_ path: String, _ operation: () async throws -> LibraryChangeSet) async {
        do {
            _ = try await operation()
            XCTFail("Expected collision")
        } catch let LibraryMutationError.collision(actual, _, _) {
            XCTAssertEqual(actual, path)
        } catch { XCTFail("Expected collision, got \(error)") }
    }

    func testValidationTrimmingAndSharedErrorMessages() async throws {
        let failures: [(String, LibraryNameFailure, String)] = [
            (" ", .empty, "A name can’t be empty."),
            (".a/b", .separator, "Names can’t contain “/” or “:”."),
            (".silkweb-assets", .leadingPeriod, "Names can’t begin with a period."),
            (String(repeating: "é", count: 128), .tooLong, "That name is too long.")
        ]
        for (name, reason, message) in failures {
            XCTAssertThrowsError(try LibraryMutations.validateName(name)) { error in
                XCTAssertEqual(error as? LibraryMutationError, .invalidName(reason))
                XCTAssertEqual(error.localizedDescription, message)
            }
        }
        XCTAssertEqual(try LibraryMutations.validateName(String(repeating: "a", count: 255)).utf8.count, 255)
        let created = try await engine.createDocument(named: "  Draft.md  ")
        XCTAssertEqual(created.changes[0].newPath, "Draft.md")
        _ = try await engine.rename("Draft.md", to: "  Plan.md  ")
        XCTAssertEqual(try contents("Plan.md"), "")
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(created.changes[0].id, snapshot.documents[0].id)
        do {
            _ = try await engine.createDocument(named: " Plan.md ")
            XCTFail("Expected collision")
        } catch let error as LibraryMutationError {
            XCTAssertEqual(error.errorDescription, "A document named “Plan” already exists in “\(root.lastPathComponent)”.")
        }
        await rejects(.libraryRoot) { try await self.engine.rename("", to: "Renamed") }
        await rejects(.outsideRoot) { try await self.engine.move("Plan.md", toFolder: "../escape") }
        await rejects(.sourceVanished("Missing")) { try await self.engine.rename("Missing.md", to: "New.md") }
        XCTAssertEqual(LibraryMutationError.libraryRoot.recoverySuggestion, "Use Finder to rename the library folder.")
        XCTAssertEqual(LibraryMutationError.sourceVanished("Missing").recoverySuggestion, "It may have been moved or deleted in Finder.")
    }

    func testUniqueNamesUseSpaceNumberAndKeepExtensions() async throws {
        let initial = try await engine.uniqueName(base: " Untitled ")
        XCTAssertEqual(initial, "Untitled")
        _ = try await engine.createFolder(named: initial)
        _ = try await engine.createFolder(named: "Untitled 2")
        let next = try await engine.uniqueName(base: "Untitled")
        XCTAssertEqual(next, "Untitled 3")
        _ = try await engine.createDocument(named: "Untitled.md")
        _ = try await engine.createDocument(named: "Untitled 2.md")
        let document = try await engine.uniqueName(base: "Untitled.md")
        XCTAssertEqual(document, "Untitled 3.md")
        let available = try await engine.uniqueName(base: "Free.markdown", in: "Untitled")
        XCTAssertEqual(available, "Free.markdown")
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Dangling").path, withDestinationPath: root.appendingPathComponent("missing").path)
        let dangling = try await engine.uniqueName(base: "Dangling")
        XCTAssertEqual(dangling, "Dangling 2")
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("UNTITLED.md").path) {
            let folded = try await engine.uniqueName(base: "UNTITLED.md")
            XCTAssertEqual(folded, "UNTITLED 3.md")
        }
    }

    @MainActor
    func testCreateMoveRenameAndStableDescendantIDs() async throws {
        _ = try await engine.createFolder(named: "Parent")
        _ = try await engine.createFolder(named: "Child", in: "Parent")
        _ = try await engine.createFolder(named: "Empty", in: "Parent/Child")
        let created = try await engine.createDocument(named: "Note.markdown", in: "Parent/Child", text: "# 日本語 Café\n")
        XCTAssertEqual(created.changes.first?.newPath, "Parent/Child/Note.markdown")
        XCTAssertNil(created.changes.first?.oldPath)
        let before = try await LibraryScanner.scan(root: root)
        let renamed = try await engine.rename("Parent", to: "Renamed")
        XCTAssertEqual(renamed.changes, [LibraryPathChange(id: before.metadata.IDsByPath["Parent"]!, oldPath: "Parent", newPath: "Renamed", isFolder: true)])
        _ = try await engine.move("Renamed/Child", toFolder: "")
        let after = try await LibraryScanner.scan(root: root)
        for suffix in ["", "/Empty", "/Note.markdown"] {
            XCTAssertEqual(before.metadata.IDsByPath["Parent/Child" + suffix], after.metadata.IDsByPath["Child" + suffix])
        }
        XCTAssertEqual(try contents("Child/Note.markdown"), "# 日本語 Café\n")
        let unchanged = try await engine.rename("Child/Note.markdown", to: "Note.markdown")
        XCTAssertTrue(unchanged.changes.isEmpty)
        _ = try await engine.rename("Child/Note.markdown", to: "Changed.MD")
        XCTAssertEqual(try contents("Child/Changed.MD"), "# 日本語 Café\n")
    }

    func testCollisionsPreserveFilesFoldersAndMetadata() async throws {
        _ = try await engine.createFolder(named: "Folder")
        _ = try await engine.createDocument(named: "A.md", text: "original A")
        _ = try await engine.createDocument(named: "B.md", text: "original B")
        _ = try await engine.createDocument(named: "A.md", in: "Folder", text: "nested A")
        _ = try await engine.createFolder(named: "Other")
        _ = try await engine.createFolder(named: "Folder", in: "Other")
        _ = try await engine.createFolder(named: "Directory.md")
        let index = try Data(contentsOf: root.appendingPathComponent(".silkweb/index.json"))
        await rejectsCollision("A.md") { try await self.engine.createDocument(named: "A.md", text: "replacement") }
        await rejectsCollision("Folder") { try await self.engine.createFolder(named: "Folder") }
        await rejectsCollision("B.md") { try await self.engine.rename("A.md", to: "B.md") }
        await rejectsCollision("Folder/A.md") { try await self.engine.move("A.md", toFolder: "Folder") }
        await rejectsCollision("A.md") { try await self.engine.createFolder(named: "A.md") }
        await rejectsCollision("Directory.md") { try await self.engine.createDocument(named: "Directory.md") }
        await rejectsCollision("Directory.md") { try await self.engine.rename("A.md", to: "Directory.md") }
        await rejectsCollision("Other/Folder") { try await self.engine.move("Folder", toFolder: "Other") }
        await rejectsCollision("Other") { try await self.engine.rename("Folder", to: "Other") }
        XCTAssertEqual(try contents("A.md"), "original A")
        XCTAssertEqual(try contents("B.md"), "original B")
        XCTAssertEqual(try contents("Folder/A.md"), "nested A")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(".silkweb/index.json")), index)
    }

    func testInvalidNamesPathsCyclesAndUnsupportedItems() async throws {
        _ = try await engine.createFolder(named: "Parent")
        _ = try await engine.createFolder(named: "Child", in: "Parent")
        for name in ["", " ", ".", "..", ".silkweb", ".hidden", "a/b", "a:b", "a\0b", "a\nb", "a\rb"] {
            await rejects { try await self.engine.createFolder(named: name) }
            await rejects { try await self.engine.createDocument(named: name) }
            await rejects { try await self.engine.rename("Parent", to: name) }
        }
        for path in ["..", "../outside", "/absolute", "Parent/../Child", "Parent//Child", "Parent/", ".silkweb"] {
            await rejects { try await self.engine.move("Parent", toFolder: path) }
            await rejects { try await self.engine.rename(path, to: "Valid") }
        }
        await rejects { try await self.engine.move("", toFolder: "Parent") }
        await rejects(.folderCycle("Parent")) { try await self.engine.move("Parent", toFolder: "Parent") }
        await rejects(.folderCycle("Parent")) { try await self.engine.move("Parent", toFolder: "Parent/Child") }
        await rejects { try await self.engine.createDocument(named: "note.txt") }
        await rejects { try await self.engine.createDocument(named: "note.md", in: "Missing") }
        _ = try await engine.createDocument(named: "Note.md")
        await rejects { try await self.engine.rename("Note.md", to: "Note.txt") }
        await rejects { try await self.engine.createFolder(named: "No", in: "Note.md") }
        XCTAssertEqual(try contents("Note.md"), "")
    }

    func testSymlinksIncludingDanglingDestinationsAreRejectedWithoutTraversal() async throws {
        _ = try await engine.createDocument(named: "Note.md", text: "safe")
        for (name, target) in [("Alias", root.path), ("Dangling.md", root.appendingPathComponent("Missing").path)] {
            try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent(name).path, withDestinationPath: target)
        }
        await rejects { try await self.engine.move("Note.md", toFolder: "Alias") }
        await rejects { try await self.engine.rename("Alias", to: "Changed") }
        await rejectsCollision("Dangling.md") { try await self.engine.rename("Note.md", to: "Dangling.md") }
        await rejectsCollision("Dangling.md") { try await self.engine.createDocument(named: "Dangling.md") }
        XCTAssertEqual(try contents("Note.md"), "safe")
        XCTAssertThrowsError(try LibraryMutations(root: root.appendingPathComponent("Alias")))
    }

    func testCaseOnlyRenameAndCaseConflictsOnCurrentVolume() async throws {
        _ = try await engine.createDocument(named: "Case.md", text: "case contents")
        let insensitive = FileManager.default.fileExists(atPath: root.appendingPathComponent("CASE.md").path)
        print("Mutation fixture volume case-insensitive: \(insensitive)")
        let before = try await LibraryScanner.scan(root: root)
        _ = try await engine.rename("Case.md", to: "CASE.md")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("CASE.md"))
        let after = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(before.metadata.IDsByPath["Case.md"], after.metadata.IDsByPath["CASE.md"])
        XCTAssertEqual(try contents("CASE.md"), "case contents")
        if insensitive {
            await rejectsCollision("case.md") { try await self.engine.createDocument(named: "case.md") }
            _ = try await engine.createFolder(named: "Parent")
            _ = try await engine.createFolder(named: "Child", in: "Parent")
            await rejects(.folderCycle("Parent")) { try await self.engine.move("Parent", toFolder: "PARENT/Child") }
        } else {
            _ = try await engine.createDocument(named: "case.md", text: "distinct")
            await rejectsCollision("case.md") { try await self.engine.rename("CASE.md", to: "case.md") }
            XCTAssertEqual(try contents("case.md"), "distinct")
        }
        _ = try await engine.createFolder(named: "Folder")
        _ = try await engine.rename("Folder", to: "FOLDER")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("FOLDER"))
    }

    func testHardLinkCollisionIsNotMistakenForCaseAlias() async throws {
        _ = try await engine.createDocument(named: "Source.md", text: "original")
        try FileManager.default.linkItem(at: root.appendingPathComponent("Source.md"), to: root.appendingPathComponent("Target.md"))
        await rejectsCollision("Target.md") { try await self.engine.rename("Source.md", to: "Target.md") }
        XCTAssertEqual(try contents("Source.md"), "original")
        XCTAssertEqual(try contents("Target.md"), "original")
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("TARGET.md").path) {
            await rejectsCollision("TARGET.md") { try await self.engine.rename("Source.md", to: "TARGET.md") }
            XCTAssertEqual(try contents("Source.md"), "original")
        }
    }

    func testConcurrentCreatesHaveExactlyOneWinner() async throws {
        let engine = self.engine!
        let successes = await withTaskGroup(of: Bool.self) { group in
            for index in 0..<20 {
                group.addTask {
                    do {
                        _ = try await engine.createDocument(named: "Contended.md", text: "writer-\(index)")
                        return true
                    } catch {
                        return false
                    }
                }
            }
            var count = 0
            for await succeeded in group { if succeeded { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        XCTAssertTrue(try contents("Contended.md").hasPrefix("writer-"))
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(snapshot.documents.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), [".silkweb", "Contended.md"])
    }

    func testMetadataFailureRollsBackCreateAndMove() async throws {
        _ = try await engine.createDocument(named: "Source.md", text: "safe")
        let directory = root.appendingPathComponent(".silkweb")
        let index = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        await rejects { try await self.engine.createFolder(named: "New") }
        await rejects { try await self.engine.createDocument(named: "New.md") }
        await rejects { try await self.engine.rename("Source.md", to: "Moved.md") }
        await rejects { try await self.engine.rename("Source.md", to: "SOURCE.md") }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("Source.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("New").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("New.md").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Moved.md").path))
        XCTAssertEqual(try contents("Source.md"), "safe")
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), index)
    }
}

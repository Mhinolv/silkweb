import Foundation
import XCTest

@testable import SilkwebCore

final class MovePlanTests: XCTestCase {
    private func fixture() async throws -> (URL, LibraryMutations) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let engine = try LibraryMutations(root: root)
        _ = try await engine.createFolder(named: "A")
        _ = try await engine.createFolder(named: "Child", in: "A")
        _ = try await engine.createFolder(named: "B")
        _ = try await engine.createDocument(
            named: "One.md", in: "A/Child", text: "[two](../../Two.md#title)\n![image](../asset.png)\n")
        _ = try await engine.createDocument(
            named: "Two.md", text: "[one](A/Child/One.md)\n[ref]: <A/Child/One.md> \"Title\"\n[bad](A/Child/a(b).md)\n")
        try Data([0, 1, 255]).write(to: root.appendingPathComponent("A/asset.png"))
        return (root, engine)
    }
    private func text(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testFolderDescendantsLinksIDsAndExactUndo() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await LibraryScanner.scan(root: root)
        let one = try text(root, "A/Child/One.md")
        let two = try text(root, "Two.md")
        let plan = try await engine.planMove(["A", "A/Child/One.md"], toFolder: "B")
        XCTAssertEqual(plan.changes.changes.count, 1)
        // #176: `a(b).md` is a balanced destination the preview opens, so it is rewritten rather than listed.
        XCTAssertEqual(plan.unsupportedLinks.count, 0)
        _ = try await engine.executeMove(plan)
        XCTAssertEqual(try text(root, "B/A/Child/One.md"), "[two](../../../Two.md#title)\n![image](../asset.png)\n")
        XCTAssertEqual(try text(root, "Two.md"), two.replacingOccurrences(of: "A/Child/", with: "B/A/Child/"))
        let after = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(before.metadata.IDsByPath["A/Child/One.md"], after.metadata.IDsByPath["B/A/Child/One.md"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("B/A/asset.png")), Data([0, 1, 255]))
        _ = try await engine.executeMove(plan.reversed)
        XCTAssertEqual(try text(root, "A/Child/One.md"), one)
        XCTAssertEqual(try text(root, "Two.md"), two)
        let restored = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(restored.metadata, before.metadata)
    }

    /// #103: a stale exact undo falls back to a fresh restore of original folders, names, links and IDs.
    func testPlanRestoreAfterStaleUndoIsAllOrNothing() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await LibraryScanner.scan(root: root)
        let one = try text(root, "A/Child/One.md")
        _ = try await engine.createFolder(named: "A", in: "B")
        let plan = try await engine.planMove(["A", "Two.md"], toFolder: "B", keepBoth: true)
        _ = try await engine.executeMove(plan)
        XCTAssertTrue(try text(root, "B/Two.md").contains("A%202/Child/One.md"))
        try Data((try text(root, "B/Two.md") + "edited\n").utf8).write(
            to: root.appendingPathComponent("B/Two.md"), options: .atomic)
        do { _ = try await engine.executeMove(plan.reversed); XCTFail("Expected stale undo") } catch {
            XCTAssertEqual(error as? MovePlanError, .changed)
        }
        // An occupied original path blocks every item, including the free one.
        try Data("blocker".utf8).write(to: root.appendingPathComponent("Two.md"))
        let blocked = try await engine.planRestore(plan.reversed.changes)
        do { _ = try await engine.executeMove(blocked); XCTFail("Expected collision") } catch {
            guard case .collision(let path, _, _)? = error as? LibraryMutationError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(path, "Two.md")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/A 2").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Two.md"))
        let restore = try await engine.planRestore(plan.reversed.changes)
        XCTAssertEqual(restore.changes.changes.map(\.newPath), ["A", "Two.md"])
        _ = try await engine.executeMove(restore)
        XCTAssertEqual(try text(root, "A/Child/One.md"), one)
        XCTAssertTrue(try text(root, "Two.md").hasPrefix("[one](A/Child/One.md)\n"))
        XCTAssertTrue(try text(root, "Two.md").hasSuffix("edited\n"))
        let restored = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(before.metadata.IDsByPath["A/Child/One.md"], restored.metadata.IDsByPath["A/Child/One.md"])
        XCTAssertEqual(before.metadata.IDsByPath["Two.md"], restored.metadata.IDsByPath["Two.md"])
        // A moved item deleted outside Silkweb, or a vanished original folder, can't be restored.
        let again = try await engine.planMove(["A/Child/One.md"], toFolder: "B")
        _ = try await engine.executeMove(again)
        try FileManager.default.removeItem(at: root.appendingPathComponent("A/Child"))
        do { _ = try await engine.planRestore(again.reversed.changes); XCTFail("Expected missing folder") } catch {
            XCTAssertEqual(error as? LibraryMutationError, .sourceVanished("Child"))
        }
        try FileManager.default.removeItem(at: root.appendingPathComponent("B/One.md"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("A/Child"), withIntermediateDirectories: false)
        do { _ = try await engine.planRestore(again.reversed.changes); XCTFail("Expected missing item") } catch {
            XCTAssertEqual(error as? LibraryMutationError, .sourceVanished("One"))
        }
    }

    func testCollisionsKeepBothBatchAndChangedPreflight() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await engine.createFolder(named: "A", in: "B")
        let stopped = try await engine.planMove(["A"], toFolder: "B")
        XCTAssertEqual(stopped.collisions, ["A"])
        do { _ = try await engine.executeMove(stopped); XCTFail("Expected collision") } catch {}
        let plan = try await engine.planMove(["A", "Two.md"], toFolder: "B", keepBoth: true)
        XCTAssertEqual(plan.changes.changes.map(\.newPath), ["B/A 2", "B/Two.md"])
        _ = try await engine.executeMove(plan)
        XCTAssertTrue(try text(root, "B/Two.md").contains("A%202/Child/One.md"))
        try Data("changed".utf8).write(to: root.appendingPathComponent("B/Two.md"), options: .atomic)
        do { _ = try await engine.executeMove(plan.reversed); XCTFail("Expected stale undo") } catch {}
        XCTAssertEqual(try text(root, "B/Two.md"), "changed")
    }

    func testRootCycleNoOpInvalidPathsAndSymlinks() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (paths, destination) in [
            ([""], "B"), (["A"], "A"), (["A"], "A/Child"), (["A"], ""), (["A"], "../B"), (["Missing.md"], "B"),
        ] {
            do {
                _ = try await engine.planMove(paths, toFolder: destination);
                XCTFail("Expected refusal: \(paths) → \(destination)")
            } catch {}
        }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Alias").path,
            withDestinationPath: root.appendingPathComponent("B").path)
        do { _ = try await engine.planMove(["A"], toFolder: "Alias"); XCTFail("Expected symlink refusal") } catch {}
        XCTAssertEqual(MoveSelection.topLevel(["A/Child", "A", "A", "Two.md"]), ["A", "Two.md"])
        for destination in ["", "A", "A/Child"] {
            XCTAssertFalse(MoveSelection.permits(["A"], destination: destination))
        }
        XCTAssertTrue(MoveSelection.permits(["A", "Two.md"], destination: "B"))
    }

    /// silkweb-1.73: one on-disk name that predates the new-name rules must not block other
    /// moves, and the legacy item itself can be moved, renamed and restored.
    func testLegacyColonNameDoesNotBlockMovesOrRenames() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("[two](Two.md)\n".utf8).write(to: root.appendingPathComponent("Meeting 10:04.md"))
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes 9:30"), withIntermediateDirectories: false)
        _ = try await LibraryScanner.scan(root: root)
        // Unrelated move and rename.
        let plan = try await engine.planMove(["Two.md"], toFolder: "B")
        _ = try await engine.executeMove(plan)
        XCTAssertEqual(try text(root, "Meeting 10:04.md"), "[two](B/Two.md)\n")
        _ = try await engine.executeMove(plan.reversed)
        let renamed = try await engine.rename("A", to: "Archive")
        XCTAssertEqual(renamed.changes.map(\.newPath), ["Archive"])
        // The legacy items themselves: move, Keep Both, rename, unchanged rename, undo rename.
        let legacy = try await engine.planMove(["Meeting 10:04.md", "Notes 9:30"], toFolder: "B")
        _ = try await engine.executeMove(legacy)
        XCTAssertEqual(try text(root, "B/Meeting 10:04.md"), "[two](../Two.md)\n")
        _ = try await engine.executeMove(legacy.reversed)
        try Data().write(to: root.appendingPathComponent("B/Meeting 10:04.md"))
        let both = try await engine.planMove(["Meeting 10:04.md"], toFolder: "B", keepBoth: true)
        XCTAssertEqual(both.changes.changes.map(\.newPath), ["B/Meeting 10:04 2.md"])
        try await engine.validateRename("Meeting 10:04.md", to: "Meeting 10:04.md")
        let unchanged = try await engine.rename("Meeting 10:04.md", to: "Meeting 10:04.md")
        XCTAssertTrue(unchanged.changes.isEmpty)
        XCTAssertEqual(
            try LibraryMutations.renameFilename(" Meeting 10:04 ", for: "Meeting 10:04.md", isFolder: false),
            "Meeting 10:04.md")
        XCTAssertEqual(
            try LibraryMutations.renameFilename("Notes 9:30", for: "Notes 9:30", isFolder: true), "Notes 9:30")
        let fixed = try await engine.rename("Meeting 10:04.md", to: "Meeting 10-04.md")
        XCTAssertEqual(fixed.changes.map(\.newPath), ["Meeting 10-04.md"])
        try FileManager.default.moveItem(
            at: root.appendingPathComponent("Meeting 10-04.md"), to: root.appendingPathComponent("Meeting 10:04.md"))
        // New names keep the 1.6 rules, including renaming a legacy item to another ':' name.
        for (path, name) in [
            ("Meeting 10:04.md", "a:b.md"), ("Archive", "a:b"), ("Notes 9:30", ".hidden"), ("Archive", "x/y"),
        ] {
            do { _ = try await engine.rename(path, to: name); XCTFail("Accepted \(name)") } catch {
                guard case LibraryMutationError.invalidName = error else { return XCTFail("Unexpected \(error)") }
            }
            do { try await engine.validateRename(path, to: name); XCTFail("Accepted \(name)") } catch {
                guard case LibraryMutationError.invalidName = error else { return XCTFail("Unexpected \(error)") }
            }
        }
        for input in ["a:b", "Meeting 10:05"] {
            do {
                _ = try LibraryMutations.renameFilename(input, for: "Meeting 10:04.md", isFolder: false);
                XCTFail("Accepted \(input)")
            } catch {
                guard case LibraryMutationError.invalidName(.separator) = error else {
                    return XCTFail("Unexpected \(error)")
                }
            }
        }
        do { _ = try await engine.createFolder(named: "a:b"); XCTFail("Accepted a:b") } catch {
            guard case LibraryMutationError.invalidName(.separator) = error else {
                return XCTFail("Unexpected \(error)")
            }
        }
        // Structural checks still refuse escaping and hidden paths.
        for (paths, destination) in [
            (["Meeting 10:04.md/.."], "B"), ([".silkweb"], "B"), (["./Two.md"], "B"), (["Two.md"], ".silkweb"),
        ] {
            do {
                _ = try await engine.planMove(paths, toFolder: destination);
                XCTFail("Expected refusal: \(paths) → \(destination)")
            } catch {}
        }
    }

    /// silkweb-1.73: Undo Rename puts back a legacy on-disk name that new names may not use.
    func testUndoRenameRestoresLegacyColonName() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Meeting 10:04.md"))
        _ = try await LibraryScanner.scan(root: root)
        let fixed = try await engine.rename("Meeting 10:04.md", to: "Meeting 10-04.md")
        let restored = try await engine.restoreName("Meeting 10-04.md", to: "Meeting 10:04.md")
        XCTAssertEqual(restored.changes.map(\.newPath), ["Meeting 10:04.md"])
        XCTAssertEqual(restored.changes.first?.id, fixed.changes.first?.id)
        for name in ["../x.md", ".hidden.md", "", "a/b.md"] {
            do { _ = try await engine.restoreName("Meeting 10:04.md", to: name); XCTFail("Accepted \(name)") } catch {}
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meeting 10:04.md").path))
    }

    func testMetadataFailureRollsBackAllMovesAndRewrites() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try text(root, "A/Child/One.md")
        let two = try text(root, "Two.md")
        let plan = try await engine.planMove(["A", "Two.md"], toFolder: "B")
        let directory = root.appendingPathComponent(".silkweb")
        let index = try Data(contentsOf: directory.appendingPathComponent("index.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path) }
        do { _ = try await engine.executeMove(plan); XCTFail("Expected failed commit") } catch {}
        XCTAssertEqual(try text(root, "A/Child/One.md"), one)
        XCTAssertEqual(try text(root, "Two.md"), two)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/A").path))
    }

    func testCaseAliasLinksAndUnrelatedSymlinks() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent("Alias.md").path,
            withDestinationPath: root.appendingPathComponent("Two.md").path)
        let insensitive = FileManager.default.fileExists(atPath: root.appendingPathComponent("a/child/one.md").path)
        if insensitive {
            try Data("[alias](a/child/one.md)".utf8).write(to: root.appendingPathComponent("Two.md"), options: .atomic)
        }
        let plan = try await engine.planMove(["A"], toFolder: "B")
        _ = try await engine.executeMove(plan)
        if insensitive { XCTAssertEqual(try text(root, "Two.md"), "[alias](B/A/Child/One.md)") }
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Alias.md").path),
            root.appendingPathComponent("Two.md").path)
    }

    func testUndecodableDocumentsAreReportedPreservedAndGuarded() async throws {
        let samples = [
            Data([0xFF, 0xFE, 0]), Data([0x63, 0x61, 0x66, 0xE9]), Data([0xC3]),
            Data(repeating: 0xFF, count: 65_536),
        ]
        for bytes in samples {
            for path in ["bad.md", "A/Child/bad.MARKDOWN"] {
                let (root, engine) = try await fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                try bytes.write(to: root.appendingPathComponent(path))
                let plan = try await engine.planMove(["A"], toFolder: "B")
                XCTAssertTrue(plan.unsupportedLinks.contains { $0.document == path && $0.syntax.contains("UTF-8") })
                XCTAssertNotNil(plan.fingerprints[path])
                XCTAssertEqual(plan.fingerprints[path], plan.newFingerprints[path])
                XCTAssertNil(plan.before[path])
                XCTAssertNil(plan.after[path])
                _ = try await engine.executeMove(plan)
                let movedPath = plan.changes.remapping(path)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(movedPath)), bytes)
                XCTAssertTrue(try text(root, "Two.md").contains("B/A/Child/One.md"))
                _ = try await engine.executeMove(plan.reversed)
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(path)), bytes)

                // A same-size raw-byte edit must invalidate both preflight and undo.
                let stale = try await engine.planMove(["A"], toFolder: "B")
                var edited = bytes
                edited[edited.startIndex] = 0xFE
                try edited.write(to: root.appendingPathComponent(path))
                do { _ = try await engine.executeMove(stale); XCTFail("Expected stale preflight") } catch {
                    XCTAssertEqual(error as? MovePlanError, .changed)
                }
                let fresh = try await engine.planMove(["A"], toFolder: "B")
                _ = try await engine.executeMove(fresh)
                try bytes.write(to: root.appendingPathComponent(movedPath))
                do { _ = try await engine.executeMove(fresh.reversed); XCTFail("Expected stale undo") } catch {
                    XCTAssertEqual(error as? MovePlanError, .changed)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
            }
        }
    }

    func testUnreadableDocumentsDoNotBlockMovesOrUndo() async throws {
        for path in ["bad.md", "A/Child/bad.md"] {
            let (root, engine) = try await fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            let url = root.appendingPathComponent(path)
            let bytes = Data("[one](A/Child/One.md)".utf8)
            try bytes.write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            XCTAssertThrowsError(try Data(contentsOf: url))
            let plan = try await engine.planMove(["A"], toFolder: "B")
            XCTAssertTrue(
                plan.unsupportedLinks.contains { $0.document == path && $0.syntax.contains("couldn’t be read") })
            XCTAssertNotNil(plan.unreadableDocuments[path])
            XCTAssertNil(plan.before[path])
            _ = try await engine.executeMove(plan)
            _ = try await engine.executeMove(plan.reversed)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            XCTAssertEqual(try Data(contentsOf: url), bytes)

            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            let stale = try await engine.planMove(["A"], toFolder: "B")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            do { _ = try await engine.executeMove(stale); XCTFail("Expected refusal after readability changes") } catch
            { XCTAssertEqual(error as? MovePlanError, .changed) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("A").path))
        }
    }

    func testIgnoredEntriesAddedAfterPreflightOrMoveDoNotBlockTransactions() async throws {
        for movingFolder in [false, true] {
            for afterMove in [false, true] {
                let (root, engine) = try await fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                let one = try text(root, "A/Child/One.md")
                let two = try text(root, "Two.md")
                let plan = try await engine.planMove([movingFolder ? "A" : "A/Child/One.md"], toFolder: "B")
                if afterMove { _ = try await engine.executeMove(plan) }
                let parents = ["", "A", "A/Child", "B"].map {
                    afterMove ? plan.changes.remapping($0) : $0
                }
                let names = [".DS_Store", "._file", "._note.md", "Icon\r", "asset.dat"]
                let bytes = Data([0, 1, 255])
                for parent in parents {
                    let directory = root.appendingPathComponent(parent)
                    for name in names { try bytes.write(to: directory.appendingPathComponent(name)) }
                    let hidden = directory.appendingPathComponent(".ignored")
                    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: false)
                    try bytes.write(to: hidden.appendingPathComponent("note.md"))
                    let flagged = directory.appendingPathComponent("Hidden.md")
                    try bytes.write(to: flagged)
                    var values = URLResourceValues()
                    values.isHidden = true
                    var flaggedURL = flagged
                    try flaggedURL.setResourceValues(values)
                    try FileManager.default.createSymbolicLink(
                        at: directory.appendingPathComponent("Alias.md"),
                        withDestinationURL: root.appendingPathComponent("Two.md"))
                }
                if !afterMove { _ = try await engine.executeMove(plan) }
                _ = try await engine.executeMove(plan.reversed)
                XCTAssertEqual(try text(root, "A/Child/One.md"), one)
                XCTAssertEqual(try text(root, "Two.md"), two)
                for parent in ["", "A", "A/Child", "B"] {
                    for name in names + [".ignored/note.md", "Hidden.md"] {
                        XCTAssertEqual(
                            try Data(contentsOf: root.appendingPathComponent(parent).appendingPathComponent(name)),
                            bytes)
                    }
                }
            }
        }
    }

    func testFolderMoveCarriesExistingIgnoredContentsAndPreservesAssetAliases() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data([255, 0, 127])
        for name in [".DS_Store", "._file", "Icon\r"] {
            try bytes.write(to: root.appendingPathComponent("A/" + name))
        }
        let alias = FileManager.default.fileExists(atPath: root.appendingPathComponent("A/ASSET.PNG").path)
        if alias { try Data("![asset](a/ASSET.PNG)".utf8).write(to: root.appendingPathComponent("Two.md")) }
        let plan = try await engine.planMove(["A"], toFolder: "B")
        _ = try await engine.executeMove(plan)
        if alias { XCTAssertEqual(try text(root, "Two.md"), "![asset](B/A/asset.png)") }
        for name in [".DS_Store", "._file", "Icon\r"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("B/A/" + name)), bytes)
        }
        _ = try await engine.executeMove(plan.reversed)
        for name in [".DS_Store", "._file", "Icon\r"] {
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("A/" + name)), bytes)
        }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("A/asset.png")), Data([0, 1, 255]))
    }

    func testManagedInventoryAndBodiesStillInvalidatePreflightAndUndo() async throws {
        for afterMove in [false, true] {
            for change in ["rewrittenBody", "unchangedBody", "newDocument", "newFolder", "removedDocument"] {
                let (root, engine) = try await fixture()
                defer { try? FileManager.default.removeItem(at: root) }
                _ = try await engine.createDocument(named: "Unchanged.md", text: "original")
                let plan = try await engine.planMove(["A"], toFolder: "B")
                if afterMove { _ = try await engine.executeMove(plan) }
                switch change {
                case "rewrittenBody": try Data("edited".utf8).write(to: root.appendingPathComponent("Two.md"))
                case "unchangedBody": try Data("modified".utf8).write(to: root.appendingPathComponent("Unchanged.md"))
                case "newDocument": try Data().write(to: root.appendingPathComponent("New.md"))
                case "newFolder":
                    try FileManager.default.createDirectory(
                        at: root.appendingPathComponent("New"), withIntermediateDirectories: false)
                default: try FileManager.default.removeItem(at: root.appendingPathComponent("Unchanged.md"))
                }
                do {
                    _ = try await engine.executeMove(afterMove ? plan.reversed : plan)
                    XCTFail("Expected refusal for \(change), afterMove=\(afterMove)")
                } catch { XCTAssertEqual(error as? MovePlanError, .changed) }
                XCTAssertTrue(
                    FileManager.default.fileExists(atPath: root.appendingPathComponent(afterMove ? "B/A" : "A").path))
            }
        }
    }

    func testFolderLinkTrailingSlashAndSuffixSweep() {
        let changes = LibraryChangeSet(changes: [.init(id: UUID(), oldPath: "A", newPath: "B/A", isFolder: true)])
        // Incoming, outgoing, unchanged, self-directory, root, and encoded slash.
        let cases = [
            ("Two.md", "A/", "B/A/"), ("A/One.md", "../B/", "../"),
            ("A/One.md", "./", "./"), ("A/One.md", "../", "../../"),
            ("Two.md", "B/", "B/"), ("Two.md", "A%2F", "B/A/"),
        ]
        for (source, destination, expected) in cases {
            for suffix in ["", "#heading", "?mode=1", "?mode=1#heading", "#heading?mode=1"] {
                for angle in [false, true] {
                    for title in ["", " \"Title\"", " 'Title'"] {
                        for reference in [false, true] {
                            func link(_ path: String) -> String {
                                let token = angle ? "<\(path)\(suffix)>" : path + suffix
                                return reference ? "[ref]: \(token)\(title)" : "[dir](\(token)\(title))"
                            }
                            let result = MarkdownDestinations.rewrite(
                                link(destination), source: source, changes: changes)
                            XCTAssertEqual(result.text, link(expected))
                            XCTAssertTrue(result.unsupported.isEmpty)
                        }
                    }
                }
            }
        }
    }

    func testGrammarSweepCodeUnsupportedAndSuffixes() throws {
        let changes = LibraryChangeSet(changes: [.init(id: UUID(), oldPath: "A", newPath: "B/A", isFolder: true)])
        for source in ["A/One.md", "Two.md", "B/Other.md"] {
            for destination in ["Two.md", "A/One.md", "A/space%20name.md", "One.md", ".", "./"] {
                for suffix in ["", "#heading", "?mode=1#heading"] {
                    for angle in [false, true] {
                        for title in ["", " \"Title\""] {
                            let path = destination + suffix
                            let text = "[label](\(angle ? "<" + path + ">" : path)\(title))"
                            let result = MarkdownDestinations.rewrite(text, source: source, changes: changes)
                            XCTAssertTrue(result.unsupported.isEmpty, text)
                            func target(_ value: String, _ sourcePath: String) -> String {
                                let start = value.firstIndex(of: "(")!
                                let end = value[start...].firstIndex(of: ")")!
                                let token = String(value[value.index(after: start)..<end]).split(separator: " ").first!
                                    .trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
                                let path = token.split(whereSeparator: { $0 == "#" || $0 == "?" }).first!
                                let url = URL(fileURLWithPath: "/silkweb-root/" + sourcePath)
                                    .deletingLastPathComponent()
                                    .appendingPathComponent(String(path).removingPercentEncoding!).standardizedFileURL
                                return String(url.path.dropFirst("/silkweb-root/".count))
                            }
                            XCTAssertEqual(
                                target(result.text, changes.remapping(source)), changes.remapping(target(text, source)))
                            XCTAssertTrue(suffix.isEmpty || result.text.contains(suffix))
                        }
                    }
                }
            }
        }
        for text in [
            "", "plain 📝", "[^1]: A/One.md", "`[a](A/One.md)`", "`` [a](A/One.md) ``", "```md\n[a](A/One.md)\n```",
            "~~~\n[a](A/One.md)\n~~~",
        ] {
            XCTAssertEqual(MarkdownDestinations.rewrite(text, source: "Two.md", changes: changes).text, text)
        }
        // #176: balanced parentheses are part of the destination the renderer opens, so both links move.
        let mixed = MarkdownDestinations.rewrite("[ok](A/One.md) [bad](A/a(b).md)", source: "Two.md", changes: changes)
        XCTAssertEqual(mixed.text, "[ok](B/A/One.md) [bad](B/A/a(b).md)")
        XCTAssertEqual(mixed.unsupported.count, 0)
        let unbalanced = MarkdownDestinations.rewrite(
            "[ok](A/One.md) [bad](A/a(b.md)", source: "Two.md", changes: changes)
        XCTAssertEqual(unbalanced.text, "[ok](B/A/One.md) [bad](A/a(b.md)")
        XCTAssertEqual(unbalanced.unsupported.count, 1)
        for text in [
            "[[A/One.md]]", "[a](../outside.md)", "[a](A/a(b.md)", "[a](A/a\\ b.md)", "<img src=\"A/a.png\">",
        ] {
            let result = MarkdownDestinations.rewrite(text, source: "Two.md", changes: changes)
            XCTAssertEqual(result.text, text)
            XCTAssertFalse(result.unsupported.isEmpty)
        }
    }
    /// #176: the rewrite reads links with the renderer's grammar. Whatever the preview would open is rewritten
    /// (in the author's form), and escaped or code syntax is neither rewritten nor listed.
    func testRewriteFollowsRendererGrammar() {
        let changes = LibraryChangeSet(changes: [.init(id: UUID(), oldPath: "A", newPath: "B/A", isFolder: true)])
        let rewritten = [
            // An escaped `!` leaves an ordinary link; balanced parentheses and Unicode spaces are bare destinations.
            ("\\![a](A/One.md)", "\\![a](B/A/One.md)"),
            ("[x](A/a(b).md)", "[x](B/A/a(b).md)"),
            ("[x](<A/a(b c).md>)", "[x](<B/A/a(b c).md>)"),
            ("![s](A/Shot_9.41\u{202F}AM.png)", "![s](B/A/Shot_9.41\u{202F}AM.png)"),
            // Four-space fences aren't fences (no indented code), so the preview renders this link.
            ("    ```\n    [a](A/One.md)\n    ```", "    ```\n    [a](B/A/One.md)\n    ```"),
            // Readable destinations stay readable; encoded ones stay encoded.
            ("[c](<A/Café note.md>)", "[c](<B/A/Café note.md>)"),
            ("[c](A/Café.md)", "[c](B/A/Café.md)"),
            ("[c](A/Caf%C3%A9%20note.md)", "[c](B/A/Caf%C3%A9%20note.md)"),
            // A link in a label-less quote or in a list item under a quote.
            ("> - [q](A/One.md \"T\")", "> - [q](B/A/One.md \"T\")"),
            // Table cells, headings and footnote definitions are rendered as links.
            (
                "| a | b |\n| --- | --- |\n| [t](A/One.md) | x \\| [u](A/Two.md) |",
                "| a | b |\n| --- | --- |\n| [t](B/A/One.md) | x \\| [u](B/A/Two.md) |"
            ),
            ("## See [h](A/One.md#part) ##", "## See [h](B/A/One.md#part) ##"),
            ("x[^1]\n\n[^1]: Note [f](A/One.md)", "x[^1]\n\n[^1]: Note [f](B/A/One.md)"),
        ]
        for (text, expected) in rewritten {
            let result = MarkdownDestinations.rewrite(text, source: "Two.md", changes: changes)
            XCTAssertEqual(result.text, expected, text)
            XCTAssertEqual(result.unsupported, [], text)
        }
        for text in [
            "\\[a](A/One.md)", "[a\\](A/One.md)", "``x` [a](A/One.md) ``", "> ```\n> [a](A/One.md)\n> ```",
            "- x\n\n  ~~~\n  [a](A/One.md) ](\n  ~~~",
        ] {
            let result = MarkdownDestinations.rewrite(text, source: "Two.md", changes: changes)
            XCTAssertEqual(result.text, text, text)
            XCTAssertEqual(result.unsupported, [], text)
        }
    }

    /// silkweb-1.72: renames use the same link rewrite as moves; restoring the name restores the links.
    func testRenameRewritesIncomingLinksAndRestoreNameRevertsThem() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try text(root, "A/Child/One.md")
        let two = try text(root, "Two.md")
        let before = try await LibraryScanner.scan(root: root)
        _ = try await engine.rename("A/Child/One.md", to: "Renamed.md")
        XCTAssertEqual(
            try text(root, "Two.md"), two.replacingOccurrences(of: "A/Child/One.md", with: "A/Child/Renamed.md"))
        XCTAssertEqual(try text(root, "A/Child/Renamed.md"), one)
        _ = try await engine.restoreName("A/Child/Renamed.md", to: "One.md")
        XCTAssertEqual(try text(root, "Two.md"), two)
        _ = try await engine.rename("A", to: "Z Folder")
        // #176: each destination keeps its form; an angle-bracketed path stays readable.
        XCTAssertEqual(
            try text(root, "Two.md"),
            "[one](Z%20Folder/Child/One.md)\n[ref]: <Z Folder/Child/One.md> \"Title\"\n[bad](Z%20Folder/Child/a(b).md)\n"
        )
        XCTAssertEqual(try text(root, "Z Folder/Child/One.md"), one)
        _ = try await engine.restoreName("Z Folder", to: "A")
        XCTAssertEqual(try text(root, "Two.md"), two)
        XCTAssertEqual(try text(root, "A/Child/One.md"), one)
        let restored = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(restored.metadata.IDsByPath, before.metadata.IDsByPath)
    }

    /// silkweb-1.72: the parser renders links on 4-space/tab-indented lines (nested list items), so they are rewritten.
    func testIndentedNestedListLinksAreRewritten() {
        let changes = LibraryChangeSet(changes: [.init(id: UUID(), oldPath: "A", newPath: "B/A", isFolder: true)])
        for indent in ["    ", "\t", "        ", "\t\t", "  \t"] {
            let text =
                "- parent\n\(indent)- [one](A/One.md)\n\(indent)![image](A/pic.png \"Title\")\n\(indent)text [two](<A/Two.md#x>)"
            let result = MarkdownDestinations.rewrite(text, source: "Two.md", changes: changes)
            XCTAssertEqual(result.text, text.replacingOccurrences(of: "A/", with: "B/A/"), indent.debugDescription)
            XCTAssertTrue(result.unsupported.isEmpty)
            let unsupported = MarkdownDestinations.rewrite(
                "- parent\n\(indent)- [bad](A/a\\ b.md)", source: "Two.md", changes: changes)
            XCTAssertEqual(unsupported.unsupported.count, 1, indent.debugDescription)
        }
        // Indented fences and inline code stay protected.
        let fenced = "- item\n    ```\n    [a](A/One.md)\n    ```\n    `[b](A/One.md)`"
        XCTAssertEqual(MarkdownDestinations.rewrite(fenced, source: "Two.md", changes: changes).text, fenced)
    }

    /// silkweb-1.72: CRLF and CR documents split into lines like LF, and every terminator is preserved.
    func testCRLFAndCRDocumentsSplitLikeLFAndKeepTerminators() {
        let changes = LibraryChangeSet(changes: [.init(id: UUID(), oldPath: "A", newPath: "B/A", isFolder: true)])
        let lines = [
            "[one](A/One.md)", "```", "[code](A/One.md)", "```", "[ref]: A/One.md", "    - [nested](A/One.md)", "~~~",
            "[tilde](A/One.md)", "~~~", "end [two](A/Two.md)",
        ]
        let expected = [
            "[one](B/A/One.md)", "```", "[code](A/One.md)", "```", "[ref]: B/A/One.md", "    - [nested](B/A/One.md)",
            "~~~", "[tilde](A/One.md)", "~~~", "end [two](B/A/Two.md)",
        ]
        for newline in ["\n", "\r\n", "\r"] {
            for trailing in ["", newline, newline + newline] {
                let text = lines.joined(separator: newline) + trailing
                let result = MarkdownDestinations.rewrite(text, source: "Two.md", changes: changes)
                XCTAssertEqual(result.text, expected.joined(separator: newline) + trailing, newline.debugDescription)
                XCTAssertTrue(result.unsupported.isEmpty, newline.debugDescription)
            }
        }
        let mixed = "a [x](A/One.md)\r\nb\nc [y](A/One.md)\r\r\n\n"
        XCTAssertEqual(
            MarkdownDestinations.rewrite(mixed, source: "Two.md", changes: changes).text,
            "a [x](B/A/One.md)\r\nb\nc [y](B/A/One.md)\r\r\n\n")
        for text in ["", "\n", "\r\n", "\r\n\r\n", "plain\r\n"] {
            XCTAssertEqual(MarkdownDestinations.rewrite(text, source: "Two.md", changes: changes).text, text)
        }
        XCTAssertEqual(
            Array(
                MarkdownDestinations.rewrite("[a](A/x.md)\r\n", source: "Two.md", changes: changes).text.utf8.suffix(2)),
            [13, 10])
        // Sweep: every 3-line combination gives the same rewrite under LF, CRLF and CR; no-op changes are identity.
        let pool = [
            "", "[a](A/One.md)", "    - [b](A/One.md)", "\t![c](A/c.png)", "```", "~~~", "[r]: A/One.md",
            "`[d](A/One.md)`", "[bad](A/a(b).md)", "📝 [e](<A/e f.md>)",
        ]
        for a in pool {
            for b in pool {
                for c in pool {
                    let lf = MarkdownDestinations.rewrite(
                        [a, b, c].joined(separator: "\n") + "\n", source: "Two.md", changes: changes)
                    for newline in ["\r\n", "\r"] {
                        let other = MarkdownDestinations.rewrite(
                            [a, b, c].joined(separator: newline) + newline, source: "Two.md", changes: changes)
                        XCTAssertEqual(other.text, lf.text.replacingOccurrences(of: "\n", with: newline))
                        XCTAssertEqual(other.unsupported, lf.unsupported)
                    }
                    let identity = [a, b, c].joined(separator: "\r\n")
                    XCTAssertEqual(
                        MarkdownDestinations.rewrite(identity, source: "Two.md", changes: LibraryChangeSet(changes: []))
                            .text, identity)
                }
            }
        }
    }

    /// silkweb-1.72: nested changes (ancestor and descendant both renamed) remap to the most specific match in any order.
    func testRemappingPrefersMostSpecificChange() {
        let parent = LibraryPathChange(id: UUID(), oldPath: "a:b", newPath: "a_b", isFolder: true)
        let child = LibraryPathChange(id: UUID(), oldPath: "a:b/c:d.md", newPath: "a_b/c_d.md", isFolder: false)
        let folder = LibraryPathChange(id: UUID(), oldPath: "a:b/e:f", newPath: "a_b/e_f", isFolder: true)
        for changes in [[parent, child, folder], [folder, child, parent], [child, parent, folder]] {
            let set = LibraryChangeSet(changes: changes)
            XCTAssertEqual(set.remapping("a:b/c:d.md"), "a_b/c_d.md")
            XCTAssertEqual(set.remapping("a:b/e:f/g.md"), "a_b/e_f/g.md")
            XCTAssertEqual(set.remapping("a:b/e:f"), "a_b/e_f")
            XCTAssertEqual(set.remapping("a:b/plain.md"), "a_b/plain.md")
            XCTAssertEqual(set.remapping("a:b"), "a_b")
            XCTAssertEqual(set.remapping("a:bc/x.md"), "a:bc/x.md")
            XCTAssertEqual(set.remapping("other.md"), "other.md")
        }
    }

    private static func reverse(_ changes: LibraryChangeSet) -> LibraryChangeSet {
        .init(
            changes: changes.changes.map {
                .init(id: $0.id, oldPath: $0.newPath, newPath: $0.oldPath!, isFolder: $0.isFolder)
            })
    }
}

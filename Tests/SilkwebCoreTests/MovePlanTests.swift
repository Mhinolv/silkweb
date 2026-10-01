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
        _ = try await engine.createDocument(named: "One.md", in: "A/Child", text: "[two](../../Two.md#title)\n![image](../asset.png)\n")
        _ = try await engine.createDocument(named: "Two.md", text: "[one](A/Child/One.md)\n[ref]: <A/Child/One.md> \"Title\"\n[bad](A/Child/a(b).md)\n")
        try Data([0, 1, 255]).write(to: root.appendingPathComponent("A/asset.png"))
        return (root, engine)
    }
    private func text(_ root: URL, _ path: String) throws -> String { try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) }

    func testFolderDescendantsLinksIDsAndExactUndo() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await LibraryScanner.scan(root: root)
        let one = try text(root, "A/Child/One.md")
        let two = try text(root, "Two.md")
        let plan = try await engine.planMove(["A", "A/Child/One.md"], toFolder: "B")
        XCTAssertEqual(plan.changes.changes.count, 1)
        XCTAssertEqual(plan.unsupportedLinks.count, 1)
        _ = try await engine.executeMove(plan)
        XCTAssertEqual(try text(root, "B/A/Child/One.md"), "[two](../../../Two.md#title)\n![image](../asset.png)\n")
        XCTAssertEqual(try text(root, "Two.md"), two.replacingOccurrences(of: "A/Child/One.md", with: "B/A/Child/One.md"))
        let after = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(before.metadata.IDsByPath["A/Child/One.md"], after.metadata.IDsByPath["B/A/Child/One.md"])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("B/A/asset.png")), Data([0, 1, 255]))
        _ = try await engine.executeMove(plan.reversed)
        XCTAssertEqual(try text(root, "A/Child/One.md"), one)
        XCTAssertEqual(try text(root, "Two.md"), two)
        let restored = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(restored.metadata, before.metadata)
    }

    func testCollisionsKeepBothBatchAndChangedPreflight() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try await engine.createFolder(named: "A", in: "B")
        let stopped = try await engine.planMove(["A"], toFolder: "B")
        XCTAssertEqual(stopped.collisions, ["A"])
        do { _ = try await engine.executeMove(stopped); XCTFail("Expected collision") } catch { }
        let plan = try await engine.planMove(["A", "Two.md"], toFolder: "B", keepBoth: true)
        XCTAssertEqual(plan.changes.changes.map(\.newPath), ["B/A 2", "B/Two.md"])
        _ = try await engine.executeMove(plan)
        XCTAssertTrue(try text(root, "B/Two.md").contains("A%202/Child/One.md"))
        try Data("changed".utf8).write(to: root.appendingPathComponent("B/Two.md"), options: .atomic)
        do { _ = try await engine.executeMove(plan.reversed); XCTFail("Expected stale undo") } catch { }
        XCTAssertEqual(try text(root, "B/Two.md"), "changed")
    }

    func testRootCycleNoOpInvalidPathsAndSymlinks() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        for (paths, destination) in [([""], "B"), (["A"], "A"), (["A"], "A/Child"), (["A"], ""), (["A"], "../B"), (["Missing.md"], "B")] {
            do { _ = try await engine.planMove(paths, toFolder: destination); XCTFail("Expected refusal: \(paths) → \(destination)") } catch { }
        }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Alias").path, withDestinationPath: root.appendingPathComponent("B").path)
        do { _ = try await engine.planMove(["A"], toFolder: "Alias"); XCTFail("Expected symlink refusal") } catch { }
        XCTAssertEqual(MoveSelection.topLevel(["A/Child", "A", "A", "Two.md"]), ["A", "Two.md"])
        for destination in ["", "A", "A/Child"] { XCTAssertFalse(MoveSelection.permits(["A"], destination: destination)) }
        XCTAssertTrue(MoveSelection.permits(["A", "Two.md"], destination: "B"))
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
        do { _ = try await engine.executeMove(plan); XCTFail("Expected failed commit") } catch { }
        XCTAssertEqual(try text(root, "A/Child/One.md"), one)
        XCTAssertEqual(try text(root, "Two.md"), two)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("index.json")), index)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("B/A").path))
    }

    func testCaseAliasLinksAndUnrelatedSymlinks() async throws {
        let (root, engine) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Alias.md").path, withDestinationPath: root.appendingPathComponent("Two.md").path)
        let insensitive = FileManager.default.fileExists(atPath: root.appendingPathComponent("a/child/one.md").path)
        if insensitive {
            try Data("[alias](a/child/one.md)".utf8).write(to: root.appendingPathComponent("Two.md"), options: .atomic)
        }
        let plan = try await engine.planMove(["A"], toFolder: "B")
        _ = try await engine.executeMove(plan)
        if insensitive { XCTAssertEqual(try text(root, "Two.md"), "[alias](B/A/Child/One.md)") }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: root.appendingPathComponent("Alias.md").path), root.appendingPathComponent("Two.md").path)
    }

    func testUndecodableDocumentsAreReportedPreservedAndGuarded() async throws {
        let samples = [Data([0xFF, 0xFE, 0]), Data([0x63, 0x61, 0x66, 0xE9]), Data([0xC3]),
                       Data(repeating: 0xFF, count: 65_536)]
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
                do { _ = try await engine.executeMove(stale); XCTFail("Expected stale preflight") }
                catch { XCTAssertEqual(error as? MovePlanError, .changed) }
                let fresh = try await engine.planMove(["A"], toFolder: "B")
                _ = try await engine.executeMove(fresh)
                try bytes.write(to: root.appendingPathComponent(movedPath))
                do { _ = try await engine.executeMove(fresh.reversed); XCTFail("Expected stale undo") }
                catch { XCTAssertEqual(error as? MovePlanError, .changed) }
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
            XCTAssertTrue(plan.unsupportedLinks.contains { $0.document == path && $0.syntax.contains("couldn’t be read") })
            XCTAssertNotNil(plan.unreadableDocuments[path])
            XCTAssertNil(plan.before[path])
            _ = try await engine.executeMove(plan)
            _ = try await engine.executeMove(plan.reversed)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            XCTAssertEqual(try Data(contentsOf: url), bytes)

            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
            let stale = try await engine.planMove(["A"], toFolder: "B")
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            do { _ = try await engine.executeMove(stale); XCTFail("Expected refusal after readability changes") }
            catch { XCTAssertEqual(error as? MovePlanError, .changed) }
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
                    try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("Alias.md"),
                                                              withDestinationURL: root.appendingPathComponent("Two.md"))
                }
                if !afterMove { _ = try await engine.executeMove(plan) }
                _ = try await engine.executeMove(plan.reversed)
                XCTAssertEqual(try text(root, "A/Child/One.md"), one)
                XCTAssertEqual(try text(root, "Two.md"), two)
                for parent in ["", "A", "A/Child", "B"] {
                    for name in names + [".ignored/note.md", "Hidden.md"] {
                        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(parent).appendingPathComponent(name)), bytes)
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
                case "newFolder": try FileManager.default.createDirectory(at: root.appendingPathComponent("New"), withIntermediateDirectories: false)
                default: try FileManager.default.removeItem(at: root.appendingPathComponent("Unchanged.md"))
                }
                do {
                    _ = try await engine.executeMove(afterMove ? plan.reversed : plan)
                    XCTFail("Expected refusal for \(change), afterMove=\(afterMove)")
                } catch { XCTAssertEqual(error as? MovePlanError, .changed) }
                XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(afterMove ? "B/A" : "A").path))
            }
        }
    }

    func testFolderLinkTrailingSlashAndSuffixSweep() {
        let changes = LibraryChangeSet(changes: [.init(id: UUID(), oldPath: "A", newPath: "B/A", isFolder: true)])
        // Incoming, outgoing, unchanged, self-directory, root, and encoded slash.
        let cases = [("Two.md", "A/", "B/A/"), ("A/One.md", "../B/", "../"),
                     ("A/One.md", "./", "./"), ("A/One.md", "../", "../../"),
                     ("Two.md", "B/", "B/"), ("Two.md", "A%2F", "B/A/")]
        for (source, destination, expected) in cases {
            for suffix in ["", "#heading", "?mode=1", "?mode=1#heading", "#heading?mode=1"] {
                for angle in [false, true] {
                    for title in ["", " \"Title\"", " 'Title'"] {
                        for reference in [false, true] {
                            func link(_ path: String) -> String {
                                let token = angle ? "<\(path)\(suffix)>" : path + suffix
                                return reference ? "[ref]: \(token)\(title)" : "[dir](\(token)\(title))"
                            }
                            let result = MarkdownDestinations.rewrite(link(destination), source: source, changes: changes)
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
                                let url = URL(fileURLWithPath: "/silkweb-root/" + sourcePath).deletingLastPathComponent()
                                    .appendingPathComponent(String(path).removingPercentEncoding!).standardizedFileURL
                                return String(url.path.dropFirst("/silkweb-root/".count))
                            }
                            XCTAssertEqual(target(result.text, changes.remapping(source)), changes.remapping(target(text, source)))
                            XCTAssertTrue(suffix.isEmpty || result.text.contains(suffix))
                        }
                    }
                }
            }
        }
        for text in ["", "plain 📝", "[^1]: A/One.md", "`[a](A/One.md)`", "`` [a](A/One.md) ``", "```md\n[a](A/One.md)\n```", "~~~\n[a](A/One.md)\n~~~"] {
            XCTAssertEqual(MarkdownDestinations.rewrite(text, source: "Two.md", changes: changes).text, text)
        }
        let mixed = MarkdownDestinations.rewrite("[ok](A/One.md) [bad](A/a(b).md)", source: "Two.md", changes: changes)
        XCTAssertEqual(mixed.text, "[ok](B/A/One.md) [bad](A/a(b).md)")
        XCTAssertEqual(mixed.unsupported.count, 1)
        for text in ["[[A/One.md]]", "[a](../outside.md)", "[a](A/a(b).md)", "[a](A/a\\ b.md)", "<img src=\"A/a.png\">"] {
            let result = MarkdownDestinations.rewrite(text, source: "Two.md", changes: changes)
            XCTAssertEqual(result.text, text)
            XCTAssertFalse(result.unsupported.isEmpty)
        }
    }
    private static func reverse(_ changes: LibraryChangeSet) -> LibraryChangeSet {
        .init(changes: changes.changes.map { .init(id: $0.id, oldPath: $0.newPath, newPath: $0.oldPath!, isFolder: $0.isFolder) })
    }
}

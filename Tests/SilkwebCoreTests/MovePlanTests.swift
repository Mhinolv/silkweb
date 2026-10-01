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

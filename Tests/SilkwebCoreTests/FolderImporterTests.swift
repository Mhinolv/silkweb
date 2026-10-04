import Foundation
import XCTest
@testable import SilkwebCore

final class FolderImporterTests: XCTestCase {
    private let fm = FileManager.default
    private func fixture() throws -> (URL, URL, URL) {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = base.appendingPathComponent("Research Notes")
        let library = base.appendingPathComponent("Library")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try fm.createDirectory(at: library, withIntermediateDirectories: true)
        return (base, source, library)
    }
    private func put(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func testNestedEmptyFoldersAssetsAndReportsSourceUnchanged() throws {
        let (base, source, library) = try fixture()
        defer { try? fm.removeItem(at: base) }
        let text = "![image](../assets/pic%20one.png)\n[attachment](../assets/report.pdf)\n[reference][p]\n[p]: ../assets/other.jpg\n[outside](../../private.png)\n![html](bad(path).png)\n`![code](../assets/unused.png)`"
        try put(text, "Writing/One.MARKDOWN", in: source)
        for path in ["assets/pic one.png", "assets/report.pdf", "assets/other.jpg", "assets/unused.png", "unsupported.txt", ".hidden.md"] { try put(path, path, in: source) }
        try fm.createDirectory(at: source.appendingPathComponent("Empty/Child"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: source.appendingPathComponent("link.md"), withDestinationURL: source.appendingPathComponent("Writing/One.MARKDOWN"))
        let before = try fm.subpathsOfDirectory(atPath: source.path).sorted()
        let plan = try FolderImporter.plan(source: source, library: library, destination: "")
        XCTAssertEqual(plan.documentCount, 1)
        XCTAssertEqual(plan.assetCount, 3)
        XCTAssertEqual(plan.emptyFolders, 1)
        XCTAssertEqual(plan.folderCount, 4)
        XCTAssertEqual(plan.outsideLinks.count, 1)
        for reason in ["Symbolic link", "Hidden item", "Unsupported link", "Not a Markdown"] { XCTAssertTrue(plan.skipped.contains { $0.contains(reason) }) }
        let result = try FolderImporter.copy(plan)
        let copy = library.appendingPathComponent(result)
        XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent("Empty/Child").path))
        for path in ["assets/pic one.png", "assets/report.pdf", "assets/other.jpg"] { XCTAssertEqual(try Data(contentsOf: copy.appendingPathComponent(path)), try Data(contentsOf: source.appendingPathComponent(path))) }
        XCTAssertFalse(fm.fileExists(atPath: copy.appendingPathComponent("assets/unused.png").path))
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("Writing/One.MARKDOWN"), encoding: .utf8), text)
        XCTAssertEqual(try fm.subpathsOfDirectory(atPath: source.path).sorted(), before)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("Writing/One.MARKDOWN"), encoding: .utf8), text)
    }
    func testDestinationCollisionInvalidNamesAndLinkRewrite() throws {
        let (base, source, library) = try fixture()
        defer { try? fm.removeItem(at: base) }
        try put("[image](assets/pic:one.png)", "one.md", in: source)
        // A colon is unsupported as a relative URL; use percent encoding for a supported link.
        try put("![image](assets/pic%3Aone.png)", "one.md", in: source)
        try put("bytes", "assets/pic:one.png", in: source)
        try fm.createDirectory(at: library.appendingPathComponent("Research Notes"), withIntermediateDirectories: false)
        let plan = try FolderImporter.plan(source: source, library: library, destination: "")
        XCTAssertEqual(plan.folderName, "Research Notes 2")
        XCTAssertEqual(plan.renamed, ["assets/pic:one.png → assets/pic_one.png"])
        let path = try FolderImporter.copy(plan)
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent(path + "/one.md"), encoding: .utf8), "![image](assets/pic_one.png)")
        XCTAssertThrowsError(try FolderImporter.copy(plan))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: library.path).sorted(), ["Research Notes", "Research Notes 2"])
    }
    func testSanitizedSiblingCollisionsAndLongMarkdownName() throws {
        let (base, source, library) = try fixture()
        defer { try? fm.removeItem(at: base) }
        for name in ["a:b.md", "a_b.md", String(repeating: "x", count: 240) + ".markdown"] {
            try put("[other](a_b.md)", name, in: source)
        }
        let plan = try FolderImporter.plan(source: source, library: library, destination: "")
        XCTAssertEqual(plan.documentCount, 3)
        XCTAssertEqual(Set(plan.entries.map(\.copyPath)).count, 3)
        XCTAssertTrue(plan.entries.contains { $0.copyPath == "a_b 2.md" })
        XCTAssertTrue(plan.entries.allSatisfy { $0.copyPath.utf8.count <= 255 })
        XCTAssertTrue(plan.entries.contains { $0.copyPath.hasSuffix(".markdown") })
        let path = try FolderImporter.copy(plan)
        XCTAssertEqual(try String(contentsOf: library.appendingPathComponent(path + "/a_b 2.md"), encoding: .utf8), "[other](a_b%202.md)")
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("a_b.md"), encoding: .utf8), "[other](a_b.md)")
    }
    func testCaseInsensitiveAssetLookupAndReferenceSyntaxSweep() throws {
        let (base, source, library) = try fixture()
        defer { try? fm.removeItem(at: base) }
        try put("image", "Images/Photo.png", in: source)
        try put("image", "Images/space image.jpg", in: source)
        let links = ["![p](images/photo.png)", "[p](Images/Photo.png?x=1#fragment)", "![p](<Images/space image.jpg>)", "[p]: Images/Photo.png", "![p](Images/Photo.png \"title\")"]
        for (n, link) in links.enumerated() { try put(link, "\(n).md", in: source) }
        let plan = try FolderImporter.plan(source: source, library: library, destination: "")
        XCTAssertEqual(plan.assetCount, 2)
        XCTAssertEqual(plan.documentCount, links.count)
        XCTAssertTrue(plan.skipped.isEmpty)
        XCTAssertTrue(plan.outsideLinks.isEmpty)
        _ = try FolderImporter.copy(plan)
    }
    func testEmptyAndOverlappingRootsAndTraversal() throws {
        let (base, source, library) = try fixture()
        defer { try? fm.removeItem(at: base) }
        let empty = try FolderImporter.plan(source: source, library: library, destination: "")
        XCTAssertEqual(empty.documentCount, 0)
        XCTAssertThrowsError(try FolderImporter.copy(empty))
        XCTAssertThrowsError(try FolderImporter.plan(source: library, library: library, destination: ""))
        XCTAssertThrowsError(try FolderImporter.plan(source: base, library: library, destination: ""))
        XCTAssertThrowsError(try FolderImporter.plan(source: source, library: library, destination: "../escape"))
        try fm.createDirectory(at: library.appendingPathComponent("Inside"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try FolderImporter.plan(source: library.appendingPathComponent("Inside"), library: library, destination: ""))
    }
    func testChangedSourceSymlinkAndCopyFailureCleanStaging() throws {
        let (base, source, library) = try fixture()
        defer { try? fm.removeItem(at: base) }
        try put("original", "one.md", in: source)
        let plan = try FolderImporter.plan(source: source, library: library, destination: "")
        try fm.removeItem(at: source.appendingPathComponent("one.md"))
        XCTAssertThrowsError(try FolderImporter.copy(plan))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: library.path), [])
        try put("private", "external.md", in: base)
        try fm.createSymbolicLink(at: source.appendingPathComponent("one.md"), withDestinationURL: base.appendingPathComponent("external.md"))
        XCTAssertThrowsError(try FolderImporter.copy(plan))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: library.path), [])
    }
    func testCancellationRemovesStaging() async throws {
        let (base, source, library) = try fixture()
        defer { try? fm.removeItem(at: base) }
        for n in 0..<128 { try put("document \(n)", "\(n).md", in: source) }
        let plan = try FolderImporter.plan(source: source, library: library, destination: "")
        let started = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let worker = Task.detached {
            try FolderImporter.copy(plan) { count, _ in
                if count == 1 { started.signal(); resume.wait() }
            }
        }
        XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        worker.cancel(); resume.signal()
        do { _ = try await worker.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: library.path), [])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: source.path).count, 128)
    }
    /// silkweb-1.72: links into renamed folders and renamed children resolve to the most specific copy path.
    func testNestedRenamedPathsRemapToMostSpecificDestination() throws {
        let (base, source, library) = try fixture()
        defer { try? fm.removeItem(at: base) }
        try put("child", "a:b/c:d.md", in: source)
        try put("grandchild", "a:b/e:f/g:h.md", in: source)
        try put("plain", "a:b/plain.md", in: source)
        try put("[child](a%3Ab/c%3Ad.md)\n[deep](a%3Ab/e%3Af/g%3Ah.md)\n[plain](a%3Ab/plain.md)", "index.md", in: source)
        try put("[up](../index.md)\n[sibling](e%3Af/g%3Ah.md)", "a:b/links.md", in: source)
        let plan = try FolderImporter.plan(source: source, library: library, destination: "")
        let path = try FolderImporter.copy(plan)
        let copy = library.appendingPathComponent(path)
        for file in ["a_b/c_d.md", "a_b/e_f/g_h.md", "a_b/plain.md"] {
            XCTAssertTrue(fm.fileExists(atPath: copy.appendingPathComponent(file).path), file)
        }
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("index.md"), encoding: .utf8),
                       "[child](a_b/c_d.md)\n[deep](a_b/e_f/g_h.md)\n[plain](a_b/plain.md)")
        XCTAssertEqual(try String(contentsOf: copy.appendingPathComponent("a_b/links.md"), encoding: .utf8),
                       "[up](../index.md)\n[sibling](e_f/g_h.md)")
    }
}

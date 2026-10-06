import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #87: a note switch or turning on the Outline skips the typing debounce; the previous outline stays up until
/// the next one is ready, and a note too large to parse within a frame leaves it dimmed (pending) meanwhile.
final class OutlineFollowTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("OutlineFollow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func note(_ name: String, _ text: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    @MainActor private func headings(_ preview: PreviewCoordinator) -> [String] { preview.headings.map(\.text) }

    @MainActor
    func testNoteSwitchAndShowingTheOutlineSkipTheDebounceButTypingKeepsIt() throws {
        let preview = PreviewCoordinator(defaults: disposableDefaults("OutlineFollow"))
        preview.mode = .editor
        let a = try note("A.md", "# Alpha\n## One")
        let b = try note("B.md", "# Beta")
        // Hidden: nothing to show. Turning it on (⌘7) parses at once.
        preview.schedule(text: "# Alpha\n## One", document: a, root: folder)
        XCTAssertEqual(headings(preview), [])
        preview.showsOutline = true
        preview.schedule(text: "# Alpha\n## One", document: a, root: folder)
        XCTAssertEqual(headings(preview), ["Alpha", "One"])
        XCTAssertEqual(preview.outlineURL, a)
        // Typing keeps the debounce.
        preview.schedule(text: "# Alpha\n## One\n## Two", document: a, root: folder)
        XCTAssertEqual(headings(preview), ["Alpha", "One"])
        // A switch swaps rows and document in one update, with no empty step.
        preview.schedule(text: "# Beta", document: b, root: folder)
        XCTAssertEqual(headings(preview), ["Beta"])
        XCTAssertEqual(preview.outlineURL, b)
        XCTAssertFalse(preview.outlinePending)
    }

    @MainActor
    func testListClickFollowsAtOnceAndARefusedSwitchGoesBack() throws {
        let preview = PreviewCoordinator(defaults: disposableDefaults("OutlineFollow"))
        preview.mode = .editor
        preview.showsOutline = true
        let a = try note("A.md", "# Alpha")
        let b = try note("B.md", "# Beta\n## Two")
        preview.schedule(text: "# Alpha", document: a, root: folder)
        preview.followDocument(b)
        XCTAssertEqual(headings(preview), ["Beta", "Two"], "a list click shows the clicked note before the editor")
        XCTAssertEqual(preview.outlineURL, b)
        // An editor render of the old note (still loading the click) leaves the followed outline alone.
        preview.schedule(text: "# Alpha edited", document: a, root: folder)
        XCTAssertEqual(preview.outlineURL, b)
        // The editor refused the switch: the Outline describes its note again.
        preview.stopFollowing(text: "# Alpha edited", document: a)
        XCTAssertEqual(headings(preview), ["Alpha edited"])
        XCTAssertEqual(preview.outlineURL, a)
        // An open tab's buffer wins over the file on disk.
        preview.followDocument(b, text: "# Unsaved")
        XCTAssertEqual(headings(preview), ["Unsaved"])
        // Hidden Outline: a click does no work.
        preview.showsOutline = false
        preview.followDocument(a)
        XCTAssertEqual(preview.outlineURL, b)
    }

    @MainActor
    func testLargeNoteKeepsThePreviousOutlinePendingUntilItParses() async throws {
        let preview = PreviewCoordinator(defaults: disposableDefaults("OutlineFollow"))
        preview.mode = .editor
        preview.showsOutline = true
        let small = try note("Small.md", "# Small")
        var text = "# Large\n\n"
        while text.utf8.count <= PreviewCoordinator.immediateOutlineLimit {
            text += "## Section\n\n" + String(repeating: "Words in a long paragraph. ", count: 200) + "\n\n"
        }
        let large = try note("Large.md", text)
        preview.schedule(text: "# Small", document: small, root: folder)
        preview.followDocument(large)
        // Never blank, never looking current: the old rows stay up, pending.
        XCTAssertTrue(preview.outlinePending)
        XCTAssertEqual(headings(preview), ["Small"])
        XCTAssertEqual(preview.outlineURL, small)
        try await waitUntil("the large note's outline") { !preview.outlinePending }
        XCTAssertEqual(headings(preview).first, "Large")
        XCTAssertGreaterThan(preview.headings.count, 1)
        XCTAssertEqual(preview.outlineURL, large)
        // A newer click cancels a pending parse: the Outline settles on the last note.
        preview.followDocument(small)
        XCTAssertEqual(headings(preview), ["Small"])
        preview.followDocument(large)
        XCTAssertTrue(preview.outlinePending)
        preview.followDocument(small)
        XCTAssertFalse(preview.outlinePending)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(headings(preview), ["Small"], "the cancelled large parse never lands")
        XCTAssertEqual(preview.outlineURL, small)
        XCTAssertFalse(preview.outlinePending)
    }
}

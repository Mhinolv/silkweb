import AppKit
import SilkwebCore
import XCTest

@testable import Silkweb

/// #208: opening a note reads only that note's recovery draft, never the whole recovery folder.
@MainActor
final class RecoveryDraftLookupTests: XCTestCase {
    private var container: URL!
    private var root: URL { container.appendingPathComponent("Library") }
    private var recovery: URL { container.appendingPathComponent("Recovery") }

    override func setUp() async throws {
        _ = NSApplication.shared
        container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Notes"), withIntermediateDirectories: true)
        try Data("healthy on disk".utf8).write(to: root.appendingPathComponent("Notes/Healthy.md"))
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: container) }

    /// Writes a draft exactly as a previous launch would have on quit.
    private func writeDraft(for url: URL, text: String) async throws {
        try Data("on disk".utf8).write(to: url)
        let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: recovery)
        _ = try await coordinator.open(url)
        try await coordinator.edit(text, at: url)
        try await coordinator.preserveUnsavedDrafts()
    }

    /// Valid drafts for other notes, then files that can't be decoded (each would be set aside if read).
    private func writeDecoys(valid: Int, unreadable: Int) throws -> [URL] {
        try FileManager.default.createDirectory(at: recovery, withIntermediateDirectories: true)
        var decoys: [URL] = []
        for index in 0..<valid {
            let note = container.appendingPathComponent("Elsewhere/\(index).md")
            let json = try JSONSerialization.data(withJSONObject: [
                "formatVersion": 1, "documentURL": note.absoluteString, "text": "decoy \(index)",
            ])
            let file = recovery.appendingPathComponent(String(format: "decoy-valid-%04d.json", index))
            try json.write(to: file)
            decoys.append(file)
        }
        for index in 0..<unreadable {
            let file = recovery.appendingPathComponent(String(format: "decoy-unreadable-%04d.json", index))
            try Data("{ not json".utf8).write(to: file)
            decoys.append(file)
        }
        return decoys
    }

    func testOpeningANoteDoesNotReadThousandsOfUnrelatedDrafts() async throws {
        let url = root.appendingPathComponent("Notes/Drafted.md")
        try await writeDraft(for: url, text: "recovered text")
        let decoys = try writeDecoys(valid: 1_500, unreadable: 1_500)

        let editor = DocumentSession()
        await editor.configure(root: root, recoveryDirectory: recovery)
        let opened = await editor.open(url, readOnly: false)
        XCTAssertTrue(opened)
        XCTAssertTrue(editor.recovered, "The note's own draft is still offered")
        XCTAssertEqual(editor.text, "recovered text")
        XCTAssertEqual(editor.banner, "Silkweb recovered unsaved changes to this document.")
        XCTAssertEqual(editor.unreadableRecovery, [], "Other notes' drafts are never read when this note opens")
        let untouched = decoys.filter { FileManager.default.fileExists(atPath: $0.path) }
        XCTAssertEqual(untouched.count, decoys.count, "Opening one note must not decode every recovery file")

        // A note without a draft opens from disk with no strip.
        let plain = DocumentSession()
        await plain.configure(root: root, recoveryDirectory: recovery)
        let healthy = root.appendingPathComponent("Notes/Healthy.md")
        let openedPlain = await plain.open(healthy, readOnly: false)
        XCTAssertTrue(openedPlain)
        XCTAssertFalse(plain.recovered)
        XCTAssertNil(plain.banner)
        XCTAssertEqual(plain.text, "healthy on disk")
        await editor.didCloseWindow()
        await plain.didCloseWindow()
    }

    /// The opened note's own corrupt draft is still set aside and reported; the note opens from disk.
    func testOpenedNotesUnreadableDraftIsSetAsideAndReported() async throws {
        let url = root.appendingPathComponent("Notes/Drafted.md")
        try await writeDraft(for: url, text: "recovered text")
        let own = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil).first)
        try Data("{ corrupt".utf8).write(to: own)
        let decoys = try writeDecoys(valid: 10, unreadable: 10)

        let editor = DocumentSession()
        await editor.configure(root: root, recoveryDirectory: recovery)
        let opened = await editor.open(url, readOnly: false)
        XCTAssertTrue(opened)
        XCTAssertFalse(editor.recovered)
        XCTAssertFalse(editor.readOnly)
        XCTAssertEqual(editor.text, "on disk")
        let quarantined = recovery.appendingPathComponent("Unreadable/" + own.lastPathComponent)
        XCTAssertEqual(editor.unreadableRecovery.map(\.lastPathComponent), [own.lastPathComponent])
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantined.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: own.path))
        XCTAssertTrue(decoys.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        await editor.didCloseWindow()
    }

    /// A draft saved under the `/private/var` spelling is still offered when the note opens as `/var`, and the
    /// reverse; Keep then clears it so it never comes back.
    func testDraftSavedUnderTheOtherTemporaryPathSpellingIsStillOffered() async throws {
        XCTAssertTrue(root.path.hasPrefix("/var/"), "Test fixtures live under the /var symlink: \(root.path)")
        let variants = [
            (written: "Notes/Private.md", private: true),
            (written: "Notes/Plain.md", private: false),
        ]
        for variant in variants {
            let url = root.appendingPathComponent(variant.written)
            try Data("on disk".utf8).write(to: url)
            let privateURL = URL(fileURLWithPath: "/private" + url.path)
            let coordinator = SaveCoordinator(store: DocumentStore(root: root), recoveryDirectory: recovery)
            let writtenURL = variant.private ? privateURL : url
            _ = try await coordinator.open(writtenURL)
            try await coordinator.edit("recovered \(variant.written)", at: writtenURL)
            try await coordinator.preserveUnsavedDrafts()

            let opensAs = variant.private ? url : privateURL
            let editor = DocumentSession()
            await editor.configure(root: root, recoveryDirectory: recovery)
            let opened = await editor.open(opensAs, readOnly: false)
            XCTAssertTrue(opened)
            XCTAssertTrue(editor.recovered, variant.written)
            XCTAssertEqual(editor.text, "recovered \(variant.written)")
            editor.keepRecovery()
            for _ in 0..<300 where editor.state != .clean { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(editor.state, .clean)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "recovered \(variant.written)")
            await editor.didCloseWindow()

            let again = DocumentSession()
            await again.configure(root: root, recoveryDirectory: recovery)
            _ = await again.open(opensAs, readOnly: false)
            XCTAssertFalse(again.recovered, "A kept draft is never offered again: \(variant.written)")
            await again.didCloseWindow()
        }
        let remaining = try await SaveCoordinator(recoveryDirectory: recovery).pendingRecoveryDrafts()
        XCTAssertEqual(remaining, [])
    }

    /// Tests never read or write the user's real recovery folder (the default when none is given).
    func testDefaultRecoveryFolderIsDisposableUnderTests() {
        let real = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Silkweb/Recovery", isDirectory: true)
        let directory = SaveCoordinator.defaultRecoveryDirectory
        XCTAssertNotEqual(directory.standardizedFileURL.path, real.standardizedFileURL.path)
        XCTAssertTrue(
            directory.standardizedFileURL.path.hasPrefix(
                FileManager.default.temporaryDirectory.standardizedFileURL.path),
            directory.path)
    }
}

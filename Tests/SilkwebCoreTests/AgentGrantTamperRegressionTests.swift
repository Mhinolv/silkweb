import CryptoKit
import XCTest

@testable import SilkwebCore

/// #205 regression: an owner-signed `agent-grants.json` widened by a raw JSON edit (Read Only → Read and Create plus an
/// extra read folder) must not authorize anything. Before #205 the helper trusted any decodable JSON, so the edited
/// grant created a document. Uses only APIs that existed before #205, so it also builds against the pre-fix sources.
/// The keyed variants (signature mismatch with this Mac's key, unsigned after adoption) are in `AgentGrantSigningTests`.
final class AgentGrantTamperRegressionTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentGrantTamper-\(UUID().uuidString)")
        library = root.appendingPathComponent("Writing")
        grantsURL = root.appendingPathComponent("agent-grants.json")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Memory/Projects/Silkweb/Memories"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Notes/Private"), withIntermediateDirectories: true)
        try Data("# Diary\n\nprivate words\n".utf8).write(to: library.appendingPathComponent("Notes/Private/Diary.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The owner's Read Only grant as a signed file writes it, then edited by hand outside Silkweb.
    private func writeSignedThenWiden() throws {
        let file = AgentGrantFile(grants: [
            AgentGrant(project: "Silkweb", library: LibraryLocation(path: library.path), access: .read)
        ])
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(file)) as? [String: Any])
        let key = P256.Signing.PrivateKey()
        let signature = try key.signature(for: Data("payload".utf8))
        json["signature"] = [
            "algorithm": "ecdsa-p256-sha256", "key_id": "0011223344556677",
            "value": signature.rawRepresentation.base64EncodedString(),
        ]
        // The hand edit: widen access and add a read folder outside the project.
        var grants = try XCTUnwrap(json["grants"] as? [[String: Any]])
        grants[0]["access"] = "read-create"
        grants[0]["extra_read_folders"] = ["Notes/Private"]
        json["grants"] = grants
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: grantsURL)
    }

    private func run(_ arguments: [String], stdin: String = "") -> AgentHelper.Output {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(stdin.utf8))
        try? pipe.fileHandleForWriting.close()
        return AgentHelper.run(
            arguments + ["--grants", grantsURL.path], home: root, environment: [:],
            standardInput: pipe.fileHandleForReading)
    }

    func testHandWidenedSignedGrantsFileAuthorizesNothing() throws {
        try writeSignedThenWiden()

        let read = run(["memory", "read", "Notes/Private/Diary.md", "--grant", "Silkweb"])
        XCTAssertEqual(read.status, 77, "the widened read folder must not be readable: " + read.stdout)
        XCTAssertFalse(read.stdout.contains("private words"), read.stdout)

        let create = run(
            [
                "memory", "create", "--grant", "Silkweb", "--folder", "memories", "--title", "Widened",
                "--body-file", "-", "--agent", "codex", "--session", "s-1",
            ],
            stdin: "Created through a hand-widened grant.")
        XCTAssertEqual(create.status, 77, "the widened access must not create: " + create.stdout)
        let created = try FileManager.default.contentsOfDirectory(
            atPath: library.appendingPathComponent("Memory/Projects/Silkweb/Memories").path)
        XCTAssertEqual(created, [], "nothing may be created")

        let capabilities = run(["memory", "capabilities", "--grant", "Silkweb"])
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(capabilities.stdout.utf8)) as? [String: Any], capabilities.stdout)
        XCTAssertEqual(json["ok"] as? Bool, false, capabilities.stdout)
        let code = (json["error"] as? [String: Any])?["code"] as? String
        XCTAssertTrue(["invalid_grants_signature", "grants_key_missing"].contains(code ?? ""), capabilities.stdout)
    }
}

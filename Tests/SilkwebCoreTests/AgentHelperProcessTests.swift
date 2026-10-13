import XCTest

@testable import SilkwebCore

/// #248: tests that launch the helper as a process verify grants with a test key, so they pass the same on a Mac whose
/// grants are protected (a keychain key exists) and on one whose aren't, and the shipped helper keeps the keychain.
final class AgentHelperProcessTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private var root: URL!
    private var library: URL!
    private var grantsURL: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentHelperProcess-\(UUID().uuidString)")
        library = root.appendingPathComponent("Library")
        grantsURL = root.appendingPathComponent("agent-grants.json")
        let progress = library.appendingPathComponent("Memory/Projects/Silkweb/Progress")
        try FileManager.default.createDirectory(at: progress, withIntermediateDirectories: true)
        try Data("# Spike".utf8).write(to: progress.appendingPathComponent("Spike.md"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var grantJSON: String {
        #"{"version":1,"grants":[{"project":"Silkweb","library":{"path":"\#(library.path)"},"access":"read-create"}]}"#
    }

    private func list(_ helper: BuiltHelper) throws -> (status: Int32, stdout: String) {
        let process = helper.process(["memory", "list", "--grant", "Silkweb", "--grants", grantsURL.path])
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        try process.run()
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func errorCode(_ stdout: String) -> String? {
        let envelope = try? JSONSerialization.jsonObject(with: Data(stdout.utf8)) as? [String: Any]
        return (envelope?["error"] as? [String: Any])?["code"] as? String
    }

    /// Grants signed with the test key load in the launched helper, whatever this Mac's keychain holds.
    func testLaunchedHelperLoadsGrantsSignedWithTheTestKey() throws {
        let helper = try BuiltHelper(nextTo: Self.self)
        try helper.writeSignedGrants(grantJSON, to: grantsURL)
        let output = try list(helper)
        XCTAssertEqual(output.status, 0, output.stdout)
        XCTAssertNil(errorCode(output.stdout), output.stdout)
    }

    /// The launched helper still fails closed like the shipped one (#205): an unsigned file, or a signed one changed
    /// afterwards, while a key exists is refused with exit 77 and `invalid_grants_signature`.
    func testLaunchedHelperFailsClosedOnUnsignedOrChangedGrants() throws {
        let helper = try BuiltHelper(nextTo: Self.self)
        try Data(grantJSON.utf8).write(to: grantsURL)
        let unsigned = try list(helper)
        XCTAssertEqual(unsigned.status, 77, unsigned.stdout)
        XCTAssertEqual(errorCode(unsigned.stdout), "invalid_grants_signature")

        try helper.writeSignedGrants(grantJSON, to: grantsURL)
        let signed = try String(contentsOf: grantsURL, encoding: .utf8)
        try Data(signed.replacingOccurrences(of: "read-create", with: "read-write").utf8).write(to: grantsURL)
        let changed = try list(helper)
        XCTAssertEqual(changed.status, 77, changed.stdout)
        XCTAssertEqual(errorCode(changed.stdout), "invalid_grants_signature")
    }

    /// A different key (another Mac's, or this Mac's keychain key) doesn't verify the test-signed file.
    func testLaunchedHelperRefusesGrantsSignedWithAnotherKey() throws {
        try BuiltHelper(nextTo: Self.self).writeSignedGrants(grantJSON, to: grantsURL)
        let output = try list(try BuiltHelper(nextTo: Self.self))
        XCTAssertEqual(output.status, 77, output.stdout)
        XCTAssertEqual(errorCode(output.stdout), "invalid_grants_signature")
    }

    /// The test key is honored by the test host only: the shipped helper's sources, the shared entry and the bundling
    /// script never mention it, and the installed `build/helper/silkweb` is copied from `SilkwebHelper`.
    func testShippedHelperHasNoTestKeyHook() throws {
        let sources = Self.repository.appendingPathComponent("Sources")
        for folder in ["SilkwebHelper", "SilkwebCore", "Silkweb"] {
            let walker = try XCTUnwrap(
                FileManager.default.enumerator(atPath: sources.appendingPathComponent(folder).path))
            while let path = walker.nextObject() as? String {
                guard path.hasSuffix(".swift") else { continue }
                let text = try String(
                    contentsOf: sources.appendingPathComponent(folder).appendingPathComponent(path), encoding: .utf8)
                XCTAssertFalse(text.contains(BuiltHelper.keyVariable), "\(folder)/\(path)")
                XCTAssertFalse(text.contains(BuiltHelper.productName), "\(folder)/\(path)")
            }
        }
        let main = try String(contentsOf: sources.appendingPathComponent("SilkwebHelper/main.swift"), encoding: .utf8)
        XCTAssertTrue(main.contains("verifier: AgentGrantKeychain()"), main)
        let bundle = try String(
            contentsOf: Self.repository.appendingPathComponent("scripts/bundle_app.sh"), encoding: .utf8)
        XCTAssertTrue(bundle.contains("cp .build/debug/SilkwebHelper \"$HELPER\""), bundle)
        XCTAssertFalse(bundle.contains(BuiltHelper.productName), bundle)
    }
}

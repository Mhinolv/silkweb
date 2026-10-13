import CryptoKit
import XCTest

@testable import SilkwebCore

/// #248: the helper binary for tests that launch it as a process. That's `SilkwebHelperTestHost`, the same commands as
/// the shipped helper, verifying grants with a key from `environment` instead of this Mac's keychain. So these tests
/// pass whether or not this Mac's grants are protected, and never read or write the "Silkweb Agent Grants" item.
struct BuiltHelper {
    static let productName = "SilkwebHelperTestHost"
    static let keyVariable = "SILKWEB_TEST_GRANTS_KEY"

    let binary: URL
    /// Signs grants for, and is passed to, every launch.
    let key = P256.Signing.PrivateKey()

    /// The test host built next to `test`'s bundle; skips when it isn't there.
    init(nextTo test: AnyClass) throws {
        binary = Bundle(for: test).bundleURL.deletingLastPathComponent().appendingPathComponent(Self.productName)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("\(Self.productName) isn't built next to the test bundle")
        }
    }

    /// This process's environment plus the test verify key, for `Process.environment`.
    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment[Self.keyVariable] = key.publicKey.rawRepresentation.base64EncodedString()
        return environment
    }

    /// Writes `json` to `url` signed with the test key, as `grant init` would on a protected Mac.
    func writeSignedGrants(_ json: String, to url: URL) throws {
        try writeSignedGrants(JSONDecoder().decode(AgentGrantFile.self, from: Data(json.utf8)), to: url)
    }

    func writeSignedGrants(_ file: AgentGrantFile, to url: URL) throws {
        try AgentGrantSigning.signed(file, with: TestSigner(key: key)).write(to: url)
    }

    /// A `Process` for the test host with the test key; the caller sets arguments and pipes.
    func process(_ arguments: [String]) -> Process {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.environment = environment
        return process
    }

    private struct TestSigner: AgentGrantSigner {
        let key: P256.Signing.PrivateKey
        func verificationKey() throws -> P256.Signing.PublicKey? { key.publicKey }
        func sign(_ payload: Data) throws -> (signature: P256.Signing.ECDSASignature, key: P256.Signing.PublicKey) {
            (try key.signature(for: payload), key.publicKey)
        }
    }
}

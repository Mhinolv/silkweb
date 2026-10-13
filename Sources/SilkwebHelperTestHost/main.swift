import CryptoKit
import Foundation
import SilkwebCore

// #248: the `silkweb` helper for tests that launch it as a process. Never installed: scripts/bundle_app.sh copies
// SilkwebHelper only, which always verifies with the keychain. This one runs the same commands but verifies
// agent-grants.json with the public key in SILKWEB_TEST_GRANTS_KEY (raw P-256, base64), or sees no key without it, so
// the tests behave the same on every Mac and never read the keychain. It never signs.
struct TestGrantKey: AgentGrantVerifier {
    let key: P256.Signing.PublicKey?
    func verificationKey() throws -> P256.Signing.PublicKey? { key }
}

let encoded = ProcessInfo.processInfo.environment["SILKWEB_TEST_GRANTS_KEY"]
let key = encoded.flatMap { Data(base64Encoded: $0) }.flatMap { try? P256.Signing.PublicKey(rawRepresentation: $0) }
if encoded != nil, key == nil {
    FileHandle.standardError.write(Data("SilkwebHelperTestHost: SILKWEB_TEST_GRANTS_KEY isn't a P-256 key\n".utf8))
    exit(64)
}
AgentHelperEntry.main(
    Array(CommandLine.arguments.dropFirst()), executable: CommandLine.arguments.first,
    verifier: TestGrantKey(key: key), signer: nil)

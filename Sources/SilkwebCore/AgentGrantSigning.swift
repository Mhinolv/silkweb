import CryptoKit
import Foundation
import Security

/// #205: tamper-evident `agent-grants.json`. Once the owner protects their grants, the file carries an ECDSA P-256
/// signature over its grants, made with a key in this Mac's login keychain. The helper and the app verify every load
/// with the same key and fail closed when the file was changed outside Silkweb, when the key is gone, or when an
/// unsigned file appears after a key exists. Only the owner's paths sign: `grant init` and `grant approve` with a
/// terminal on stdin, and the app after owner authentication (or for a pure narrowing of a verified file). The memory
/// commands and the MCP server get a verifier only, never a signer.
///
/// The verify key never comes from the grants file: the keychain item keeps the public key in its attributes, which
/// any process reads without a prompt, and the private key in its secret data, which only the app or the helper that
/// made it reads without the keychain asking the owner.
public struct AgentGrantSignature: Codable, Equatable, Sendable {
    public static let algorithmName = "ecdsa-p256-sha256"

    public var algorithm: String
    /// The first 8 bytes of the public key's SHA-256, in hex. Informational: verification uses this Mac's key.
    public var keyId: String
    /// The raw (r ‖ s) signature, base64.
    public var value: String

    public init(algorithm: String = algorithmName, keyId: String, value: String) {
        self.algorithm = algorithm
        self.keyId = keyId
        self.value = value
    }

    private enum CodingKeys: String, CodingKey {
        case algorithm, value
        case keyId = "key_id"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        algorithm = (try? values.decodeIfPresent(String.self, forKey: .algorithm)) ?? ""
        keyId = (try? values.decodeIfPresent(String.self, forKey: .keyId)) ?? ""
        value = (try? values.decodeIfPresent(String.self, forKey: .value)) ?? ""
    }

    /// A `signature` value that isn't an object: kept as a signature that can't verify, never read as unsigned.
    static let unreadable = AgentGrantSignature(algorithm: "", keyId: "", value: "")
}

/// Where the grants key lives, for checking. The app and the helper use the keychain; tests use memory.
public protocol AgentGrantVerifier: Sendable {
    /// This Mac's verify key, or nil when there's none yet (grants were never protected here). Throws when the store
    /// can't be read.
    func verificationKey() throws -> P256.Signing.PublicKey?
}

/// A verifier that may also sign. Only the owner's paths hold one.
public protocol AgentGrantSigner: AgentGrantVerifier {
    /// Signs `payload` with this Mac's key, making the key first when there's none.
    func sign(_ payload: Data) throws -> (signature: P256.Signing.ECDSASignature, key: P256.Signing.PublicKey)
}

/// The process-wide verifier for `AgentGrantStore`. The app and the helper set the keychain at launch; anything else
/// (tests, tools) sees no key, so unsigned files load as they always have and signed ones fail closed.
public enum AgentGrantKeys {
    nonisolated(unsafe) public static var verifier: any AgentGrantVerifier = AgentGrantNoKey()

    /// “3f9a1c2b4d5e6f70”.
    public static func keyId(_ key: P256.Signing.PublicKey) -> String {
        SHA256.hash(data: key.rawRepresentation).prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// No key anywhere: what every process sees until the app or the helper sets the keychain.
public struct AgentGrantNoKey: AgentGrantVerifier {
    public init() {}
    public func verificationKey() throws -> P256.Signing.PublicKey? { nil }
}

/// A key held in memory, for tests. `fails` makes every call throw, like a keychain that can't be read.
public final class AgentGrantMemoryKeys: AgentGrantSigner, @unchecked Sendable {
    private let lock = NSLock()
    private var key: P256.Signing.PrivateKey?
    private var failing = false
    private var signings = 0

    public init(hasKey: Bool = false) {
        if hasKey { key = P256.Signing.PrivateKey() }
    }

    /// How many times `sign` ran.
    public var signCount: Int { lock.withLock { signings } }

    public var fails: Bool {
        get { lock.withLock { failing } }
        set { lock.withLock { failing = newValue } }
    }

    /// Forgets the key, like a Keychain reset or a new Mac.
    public func removeKey() { lock.withLock { key = nil } }

    public func verificationKey() throws -> P256.Signing.PublicKey? {
        try lock.withLock {
            if failing { throw AgentGrantKeychain.Failure(status: errSecInteractionNotAllowed) }
            return key?.publicKey
        }
    }

    public func sign(_ payload: Data) throws -> (signature: P256.Signing.ECDSASignature, key: P256.Signing.PublicKey) {
        try lock.withLock {
            if failing { throw AgentGrantKeychain.Failure(status: errSecInteractionNotAllowed) }
            let key = self.key ?? P256.Signing.PrivateKey()
            self.key = key
            signings += 1
            return (try key.signature(for: payload), key.publicKey)
        }
    }
}

/// The login keychain item “Silkweb Agent Grants”: a generic password whose secret data is the private key and whose
/// `generic` attribute is the public key. Made on the first signature.
public struct AgentGrantKeychain: AgentGrantSigner {
    public static let service = "Silkweb Agent Grants"
    public static let account = "agent-grants-signing-key"

    public struct Failure: Error, Equatable {
        public var status: OSStatus
    }

    public init() {}

    private var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    /// Attributes only, so reading the public key never asks the owner.
    public func verificationKey() throws -> P256.Signing.PublicKey? {
        var query = item
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let attributes = result as? [String: Any],
            let raw = attributes[kSecAttrGeneric as String] as? Data
        else { throw Failure(status: status) }
        return try P256.Signing.PublicKey(rawRepresentation: raw)
    }

    public func sign(_ payload: Data) throws -> (signature: P256.Signing.ECDSASignature, key: P256.Signing.PublicKey) {
        let key = try privateKey() ?? makeKey()
        return (try key.signature(for: payload), key.publicKey)
    }

    private func privateKey() throws -> P256.Signing.PrivateKey? {
        var query = item
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let raw = result as? Data else { throw Failure(status: status) }
        return try P256.Signing.PrivateKey(rawRepresentation: raw)
    }

    private func makeKey() throws -> P256.Signing.PrivateKey {
        let key = P256.Signing.PrivateKey()
        var attributes = item
        attributes[kSecValueData as String] = key.rawRepresentation
        attributes[kSecAttrGeneric as String] = key.publicKey.rawRepresentation
        attributes[kSecAttrLabel as String] = Self.service
        attributes[kSecAttrDescription as String] = "Silkweb signing key"
        attributes[kSecAttrComment as String] = "Protects agent-grants.json. Removing it stops every agent grant."
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
        return key
    }
}

/// How far the grants file on disk can be trusted.
public enum AgentGrantProtection: String, Equatable, Sendable {
    /// Unsigned and this Mac has no key: grants load as they always have (not tamper-protected).
    case unprotected
    /// Signed with this Mac's key and unchanged since. Also a missing file once a key exists.
    case protected
    /// Signed but changed since, or unsigned although a key exists. Every grant fails closed.
    case changedOutside
    /// Signed, but this Mac has no key (a new Mac, a keychain reset). Every grant fails closed.
    case keyMissing
    /// The key store can't be read (an agent sandbox, SSH, a locked keychain), so Silkweb can't tell whether grants
    /// are protected. Signed or unsigned, every grant fails closed.
    case keyUnreadable

    /// Whether helpers may use the grants.
    public var isUsable: Bool { self == .unprotected || self == .protected }
}

/// The grants file as read, with how far it can be trusted. `exists` is false for a missing file (no grants).
public struct AgentGrantInspection: Equatable, Sendable {
    public var file: AgentGrantFile
    public var protection: AgentGrantProtection
    public var exists: Bool

    public init(file: AgentGrantFile, protection: AgentGrantProtection, exists: Bool = true) {
        self.file = file
        self.protection = protection
        self.exists = exists
    }
}

extension AgentGrantFile {
    /// The bytes a signature covers: `{"grants":[…],"version":N}`, compact with sorted keys and unescaped slashes, of
    /// the grants as Silkweb decodes them (unknown keys dropped, values normalized). Formatting and key order don't
    /// matter; every change a reader would see does.
    public func signedPayload() throws -> Data {
        struct Payload: Encodable {
            var grants: [AgentGrant]
            var version: Int
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // One decode normalizes the grants exactly as the next reader of the file sees them.
        let grants = try JSONDecoder().decode([AgentGrant].self, from: encoder.encode(grants))
        return try encoder.encode(Payload(grants: grants, version: version))
    }
}

extension AgentAccessError {
    /// #205: the grants file doesn't match its signature, or is unsigned although a key exists.
    public static let grantsChangedOutside = AgentAccessError(
        code: "invalid_grants_signature", title: noAccess,
        message: "Agent grants failed verification, so no grant is in effect. Ask the owner to review them in Silkweb.")

    /// #205: the grants file is signed, but this Mac has no key to check it with.
    public static let grantsKeyMissing = AgentAccessError(
        code: "grants_key_missing", title: noAccess,
        message: "Silkweb can’t find the key that protects agent grants on this Mac, so no grant is in effect. Ask "
            + "the owner to review them in Silkweb.")

    /// #205: the key store can't be read, so an unsigned file may have been stripped of its signature.
    public static let grantsKeyUnreadable = AgentAccessError(
        code: "grants_key_unreadable", title: noAccess,
        message: "Silkweb can’t check whether agent grants are protected. Run it from your normal login session.")

    /// #205: a write to protected grants from a path that can't sign (no terminal, not the app).
    public static let grantsNeedOwner = AgentAccessError(
        code: "grants_signing_required", title: noAccess,
        message: "Agent grants are protected, so only the owner can change them, in Silkweb’s Agent Access window or "
            + "with “silkweb grant init” in Terminal. Nothing was saved.")

    /// #205: the keychain couldn't sign. Nothing was written.
    public static let grantsSigningFailed = AgentAccessError(
        code: "grants_signing_failed", title: noAccess,
        message: "Silkweb couldn’t use the key that protects agent grants. Nothing was saved.")

    /// #205: an unauthenticated change to protected grants that isn't a pure narrowing.
    public static let grantsNeedAuthentication = AgentAccessError(
        code: "needs_authentication", title: noAccess,
        message: "This change gives agents more access, so it needs the owner’s authentication. Nothing was saved.")
}

/// Verifying, signing and saving `agent-grants.json` (#205).
public enum AgentGrantSigning {
    /// How far `file` can be trusted with this Mac's key. When the key store can't be read (anything but “no key
    /// yet”), every file fails closed (`keyUnreadable`): an unsigned one may be a protected file with its signature
    /// stripped. An unsigned file loads as it always has only when the store says there's no key.
    public static func protection(of file: AgentGrantFile, keys: any AgentGrantVerifier) -> AgentGrantProtection {
        let key: P256.Signing.PublicKey?
        do {
            key = try keys.verificationKey()
        } catch {
            return .keyUnreadable
        }
        guard let signature = file.signature else { return key == nil ? .unprotected : .changedOutside }
        guard let key else { return .keyMissing }
        return verifies(file, signature: signature, key: key) ? .protected : .changedOutside
    }

    static func verifies(_ file: AgentGrantFile, signature: AgentGrantSignature, key: P256.Signing.PublicKey) -> Bool {
        guard signature.algorithm == AgentGrantSignature.algorithmName,
            let raw = Data(base64Encoded: signature.value),
            let decoded = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
            let payload = try? file.signedPayload()
        else { return false }
        return key.isValidSignature(decoded, for: payload)
    }

    /// `file` with a fresh signature from `signer` (which makes this Mac's key if there's none).
    public static func signed(_ file: AgentGrantFile, with signer: any AgentGrantSigner) throws -> AgentGrantFile {
        var file = file
        file.signature = nil
        let result: (signature: P256.Signing.ECDSASignature, key: P256.Signing.PublicKey)
        do {
            result = try signer.sign(file.signedPayload())
        } catch {
            throw AgentAccessError.grantsSigningFailed
        }
        file.signature = AgentGrantSignature(
            keyId: AgentGrantKeys.keyId(result.key), value: result.signature.rawRepresentation.base64EncodedString())
        return file
    }

    /// The grants file at `url` and how far it can be trusted; a missing file is an empty one (protected once a key
    /// exists, `keyUnreadable` when the key store can't be read). A broken or newer file throws `AgentAccessError`.
    public static func inspect(_ url: URL, keys: any AgentGrantVerifier) throws -> AgentGrantInspection {
        do {
            return try AgentGrantStore(url: url, keys: keys).inspect()
        } catch let error as AgentAccessError where error.code == "no_grants_file" {
            let protection: AgentGrantProtection
            do {
                protection = try keys.verificationKey() == nil ? .unprotected : .protected
            } catch {
                protection = .keyUnreadable
            }
            return AgentGrantInspection(file: AgentGrantFile(), protection: protection, exists: false)
        }
    }

    /// Saves `file` over the grants file the caller read as `current`:
    /// - grants changed outside Silkweb or a missing key refuse every write, except `adopt` (the owner's review);
    /// - `adopt` signs with `signer`, making this Mac's key if needed (protecting the grants);
    /// - once a key exists every write is signed: it needs `signer`, and without `authenticated` the new file must be a
    ///   pure narrowing of the verified one;
    /// - without a key the file stays unsigned.
    public static func save(
        _ file: AgentGrantFile, to url: URL, current: AgentGrantInspection, signer: (any AgentGrantSigner)?,
        authenticated: Bool, adopt: Bool = false
    ) throws {
        var file = file
        file.signature = nil
        switch current.protection {
        case .changedOutside where !adopt: throw AgentAccessError.grantsChangedOutside
        case .keyMissing where !adopt: throw AgentAccessError.grantsKeyMissing
        case .keyUnreadable where !adopt: throw AgentAccessError.grantsKeyUnreadable
        default: break
        }
        if adopt || current.protection == .protected {
            guard let signer else { throw AgentAccessError.grantsNeedOwner }
            if !adopt, !authenticated, !isNarrowing(from: current.file, to: file) {
                throw AgentAccessError.grantsNeedAuthentication
            }
            file = try signed(file, with: signer)
        }
        try file.write(to: url)
    }

    /// Whether `new` gives agents nothing `old` didn't: every grant in it was in `old` and only narrowed, paused or
    /// relabelled (`AgentGrantOwner.widenings`). Removing grants is a narrowing.
    public static func isNarrowing(from old: AgentGrantFile, to new: AgentGrantFile) -> Bool {
        new.grants.allSatisfy { grant in
            old.grant(for: grant.project).map { AgentGrantOwner.widenings(from: $0, to: grant).isEmpty } ?? false
        }
    }
}

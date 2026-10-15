import Foundation
import Security

/// #12: custom HTTP integrations for image upload (#14) and document send (#15). The definitions live in
/// `~/Library/Application Support/Silkweb/integrations.json`, app-wide and versioned, decoded tolerantly. Secret header
/// and field values never go into that file: it keeps a reference, and the value lives in the login keychain item
/// service “Silkweb Integrations” (separate from “Silkweb Agent Grants”, #205). Export (#43) can copy the file as is.
///
/// The app's send flows need the `com.apple.security.network.client` entitlement once the app is sandboxed.
public struct Integration: Codable, Equatable, Identifiable, Sendable {
    public enum Purpose: String, Codable, CaseIterable, Sendable {
        case imageUpload, sendDocument
        public var title: String {
            switch self {
            case .imageUpload: "Image Upload";
            case .sendDocument: "Send Document"
            }
        }
    }

    public enum BodyFormat: String, Codable, CaseIterable, Sendable {
        case multipart, json, form
        public var title: String {
            switch self {
            case .multipart: "Multipart";
            case .json: "JSON";
            case .form: "Form"
            }
        }
    }

    public static let defaultName = "New Integration"
    /// Fixed; the UI doesn't show it.
    public static let timeout: TimeInterval = 30

    public var id = UUID()
    public var name = defaultName
    public var purpose = Purpose.imageUpload
    public var url = ""
    public var allowsInsecureHTTP = false
    public var bodyFormat = BodyFormat.multipart
    public var headers: [IntegrationParameter] = []
    public var fields: [IntegrationParameter] = []
    /// Dot path into the JSON response, for example `data.url` or `items.0.id`. Empty uses the whole response text.
    public var responsePath = ""
    public var prefix = ""
    public var suffix = ""
    /// Send Document only: with a `{{remoteID}}` from an earlier send, POST here instead of `url`. Empty always creates.
    public var updateURL = ""

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case id, name, purpose, url, allowsInsecureHTTP, bodyFormat, headers, fields, responsePath, prefix, suffix,
            updateURL
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? values.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = Integration()
        id = value(.id, defaults.id)
        name = value(.name, defaults.name)
        purpose = value(.purpose, defaults.purpose)
        url = value(.url, defaults.url)
        allowsInsecureHTTP = value(.allowsInsecureHTTP, defaults.allowsInsecureHTTP)
        bodyFormat = value(.bodyFormat, defaults.bodyFormat)
        headers = value(.headers, [LossyParameter]()).compactMap(\.parameter)
        fields = value(.fields, [LossyParameter]()).compactMap(\.parameter)
        responsePath = value(.responsePath, defaults.responsePath)
        prefix = value(.prefix, defaults.prefix)
        suffix = value(.suffix, defaults.suffix)
        updateURL = value(.updateURL, defaults.updateURL)
    }

    /// The secret references this integration holds, for removal with the integration.
    public var secretReferences: [String] { (headers + fields).compactMap(\.secretReference) }
}

/// A row that doesn't decode is dropped, not the whole integration.
private struct LossyParameter: Decodable {
    var parameter: IntegrationParameter?
    init(from decoder: Decoder) throws { parameter = try? IntegrationParameter(from: decoder) }
}

/// One header or body field. A secret row keeps only `secretReference` here; its value lives in the keychain.
public struct IntegrationParameter: Codable, Equatable, Sendable {
    /// Shown instead of a secret value in previews, logs and errors.
    public static let redacted = "••••••"

    public var key: String
    /// Empty for a secret row.
    public var value: String
    public var isSecret: Bool
    /// The keychain account for a secret row's value.
    public var secretReference: String?

    public init(key: String, value: String) {
        self.key = key
        self.value = value
        isSecret = false
    }

    /// Stores `value` in `secrets` under a new reference; the row keeps only the reference.
    public static func secret(key: String, value: String, in secrets: any IntegrationSecretStore) throws -> Self {
        var parameter = Self(key: key, value: "")
        parameter.isSecret = true
        let reference = UUID().uuidString
        try secrets.setSecret(value, for: reference)
        parameter.secretReference = reference
        return parameter
    }

    /// The value for previews and logs: secrets show as `••••••`.
    public var displayValue: String { isSecret ? Self.redacted : value }

    private enum CodingKeys: String, CodingKey { case key, value, isSecret, secretReference }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        key = try values.decode(String.self, forKey: .key)
        isSecret = (try? values.decodeIfPresent(Bool.self, forKey: .isSecret)) ?? false
        secretReference = isSecret ? (try? values.decodeIfPresent(String.self, forKey: .secretReference)) ?? nil : nil
        // A secret value on disk is never read back into memory as plain text.
        value = isSecret ? "" : (try? values.decodeIfPresent(String.self, forKey: .value)) ?? ""
    }

    /// Secret rows write no `value` key, so the file never holds secret bytes.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(key, forKey: .key)
        if isSecret {
            try values.encode(true, forKey: .isSecret)
            try values.encodeIfPresent(secretReference, forKey: .secretReference)
        } else {
            try values.encode(value, forKey: .value)
        }
    }
}

/// `integrations.json`: every integration, in the order the owner sees them.
public struct IntegrationFile: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = currentVersion
    public var integrations: [Integration]

    public init(integrations: [Integration] = []) { self.integrations = integrations }

    private enum CodingKeys: String, CodingKey { case version, integrations }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // Older files are migrated in memory; the next save writes the current version.
        version = Self.currentVersion
        let rows = (try? values.decodeIfPresent([LossyIntegration].self, forKey: .integrations)) ?? nil
        integrations = (rows ?? []).compactMap(\.integration)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        try values.encode(integrations, forKey: .integrations)
    }

    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Silkweb/integrations.json")
    }

    /// A missing or unreadable file is no integrations. Reading never rewrites the file.
    public static func load(from url: URL = defaultURL()) -> IntegrationFile {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return file
    }

    /// Atomic replace with sorted keys, so the owner can diff it.
    public func write(to url: URL = defaultURL()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

private struct LossyIntegration: Decodable {
    var integration: Integration?
    init(from decoder: Decoder) throws { integration = try? Integration(from: decoder) }
}

/// Where secret values live. The app uses the keychain; tests use memory.
public protocol IntegrationSecretStore: Sendable {
    /// The value, or nil when there's none for `reference`.
    func secret(for reference: String) throws -> String?
    func setSecret(_ value: String, for reference: String) throws
    /// No error when there's nothing to remove.
    func removeSecret(for reference: String) throws
}

/// Secret values held in memory, for tests.
public final class IntegrationMemorySecrets: IntegrationSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public var count: Int { lock.withLock { values.count } }

    public func secret(for reference: String) throws -> String? { lock.withLock { values[reference] } }
    public func setSecret(_ value: String, for reference: String) throws { lock.withLock { values[reference] = value } }
    public func removeSecret(for reference: String) throws {
        lock.withLock { _ = values.removeValue(forKey: reference) }
    }
}

/// Login keychain generic passwords, service “Silkweb Integrations”, one account per secret reference.
public struct IntegrationKeychain: IntegrationSecretStore {
    public static let service = "Silkweb Integrations"

    public struct Failure: Error, Equatable {
        public var status: OSStatus
    }

    public init() {}

    private func item(_ reference: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference,
        ]
    }

    public func secret(for reference: String) throws -> String? {
        var query = item(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Failure(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func setSecret(_ value: String, for reference: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(item(reference) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw Failure(status: status) }
        var attributes = item(reference)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = Self.service
        attributes[kSecAttrDescription as String] = "Silkweb integration secret"
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw Failure(status: added) }
    }

    public func removeSecret(for reference: String) throws {
        let status = SecItemDelete(item(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

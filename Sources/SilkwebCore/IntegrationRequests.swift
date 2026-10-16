import Foundation

/// #12: what one send fills into an integration's URL, headers and fields.
public struct IntegrationContext: Sendable {
    public var title = ""
    public var markdown = ""
    public var html = ""
    /// Library-relative, for example `Projects/Silkweb`.
    public var folderPath = ""
    public var tags: [String] = []
    public var filename = ""
    public var createdAt: Date?
    public var modifiedAt: Date?
    /// Image Upload: the bytes `{{file}}` sends.
    public var file: IntegrationUpload?
    /// Send Document: the ID an earlier send returned, for `updateURL`.
    public var remoteID: String?

    public init() {}

    /// Every placeholder's text. `{{file}}` is Base64 here; a multipart field that is only `{{file}}` sends raw bytes.
    var values: [String: String] {
        func date(_ value: Date?) -> String { value.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
        return [
            "title": title, "markdown": markdown, "html": html, "folderPath": folderPath,
            "tags": tags.joined(separator: ", "), "filename": file?.filename ?? filename, "createdAt": date(createdAt),
            "modifiedAt": date(modifiedAt), "file": file?.data.base64EncodedString() ?? "", "remoteID": remoteID ?? "",
        ]
    }
}

/// A file part for `{{file}}`.
public struct IntegrationUpload: Equatable, Sendable {
    public var data: Data
    public var filename: String
    public var mimeType: String

    public init(data: Data, filename: String, mimeType: String) {
        self.data = data
        self.filename = filename
        self.mimeType = mimeType
    }
}

/// `{{name}}` substitution in one pass: text that a value brings in is never substituted again, and unknown
/// placeholders stay as written.
public enum IntegrationTemplate {
    public static let placeholders = [
        "title", "markdown", "html", "folderPath", "tags", "filename", "createdAt", "modifiedAt", "file", "remoteID",
    ]

    public static func fill(_ template: String, _ values: [String: String], encode: (String) -> String = { $0 })
        -> String
    {
        var result = ""
        var rest = template[...]
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            let after = rest[open.upperBound...]
            guard let close = after.range(of: "}}") else {
                rest = rest[open.lowerBound...]
                break
            }
            let name = String(after[..<close.lowerBound])
            if let value = values[name] {
                result += encode(value)
                rest = after[close.upperBound...]
            } else {
                // Keep the braces and look for the next placeholder after them.
                result += "{{"
                rest = after
            }
        }
        return result + rest
    }
}

/// The errors a send shows. `message` is the copy the app shows unchanged. No case holds a secret, a header value or
/// the request body.
public enum IntegrationError: Error, Equatable, LocalizedError, Sendable {
    case offline
    case timeout
    case untrustedCertificate
    case http(Int)
    case insecureURL
    case invalidURL
    /// The Value Path found nothing. Empty path: the response was empty.
    case missingValue(path: String)
    /// The keychain has no value for the secret row with this key, or can't be read.
    case secretUnavailable(key: String)
    case requestFailed

    public init(_ error: URLError) {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            self = .offline
        case .timedOut: self = .timeout
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected,
            .clientCertificateRequired:
            self = .untrustedCertificate
        case .appTransportSecurityRequiresSecureConnection: self = .insecureURL
        default: self = .requestFailed
        }
    }

    public var message: String {
        switch self {
        case .offline: "You’re offline. Connect to the internet and try again."
        case .timeout: "The server didn’t respond within \(Int(Integration.timeout)) seconds."
        case .untrustedCertificate: "The server’s certificate isn’t trusted. Check the URL."
        case .http(let status):
            "The server returned \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)."
        case .insecureURL: "http:// URLs are blocked. Use https://, or turn on Allow Insecure HTTP."
        case .invalidURL: "The URL isn’t valid. Check URL."
        case .missingValue(let path):
            path.isEmpty ? "The response is empty." : "The response has no value at “\(path)”. Check Value Path."
        case .secretUnavailable(let key): "Silkweb can’t read the secret for “\(key)”. Enter it again."
        case .requestFailed: "The request failed. Check the URL and try again."
        }
    }

    public var errorDescription: String? { message }
}

extension Integration {
    /// Send Document with a remote ID and an Update URL updates; everything else creates at `url`.
    public func endpoint(for context: IntegrationContext) -> String {
        let updates = purpose == .sendDocument && !(context.remoteID ?? "").isEmpty && !updateURL.isEmpty
        return updates ? updateURL : url
    }

    /// https always; http only with Allow Insecure HTTP. Anything else, or no host, is not valid.
    public func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty
        else { throw IntegrationError.invalidURL }
        switch scheme {
        case "https": return url
        case "http":
            guard allowsInsecureHTTP else { throw IntegrationError.insecureURL }
            return url
        default: throw IntegrationError.invalidURL
        }
    }

    /// The POST for one send. Placeholder values in the URL are percent-encoded; secret rows read `secrets`.
    public func request(
        for context: IntegrationContext, secrets: any IntegrationSecretStore,
        boundary: String = "Silkweb-\(UUID().uuidString)"
    ) throws -> URLRequest {
        let values = context.values
        let address = IntegrationTemplate.fill(endpoint(for: context), values, encode: Self.urlComponent)
        var request = URLRequest(url: try validatedURL(address), timeoutInterval: Self.timeout)
        request.httpMethod = "POST"

        func resolve(_ parameter: IntegrationParameter) throws -> String {
            guard parameter.isSecret else { return IntegrationTemplate.fill(parameter.value, values) }
            guard let secret = try? parameter.secretReference.flatMap({ try secrets.secret(for: $0) }) else {
                throw IntegrationError.secretUnavailable(key: parameter.key)
            }
            return secret
        }

        var setsContentType = false
        for header in headers where !header.key.isEmpty {
            // A line break in a header value would start a new header.
            let value = try resolve(header).components(separatedBy: .newlines).joined(separator: " ")
            request.addValue(value, forHTTPHeaderField: header.key)
            if header.key.caseInsensitiveCompare("Content-Type") == .orderedSame { setsContentType = true }
        }

        let rows = fields.filter { !$0.key.isEmpty }
        switch bodyFormat {
        case .multipart:
            var body = Data()
            for field in rows {
                body += Data("--\(boundary)\r\n".utf8)
                let name = Self.quoted(field.key)
                if !field.isSecret, field.value.trimmingCharacters(in: .whitespaces) == "{{file}}",
                    let file = context.file
                {
                    body += Data(
                        "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(Self.quoted(file.filename))\"\r\n"
                            .utf8)
                    body += Data("Content-Type: \(file.mimeType)\r\n\r\n".utf8)
                    body += file.data
                } else {
                    body += Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8)
                    body += Data(try resolve(field).utf8)
                }
                body += Data("\r\n".utf8)
            }
            body += Data("--\(boundary)--\r\n".utf8)
            request.httpBody = body
            // The boundary has to match the body, so a header row never replaces it.
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        case .json:
            var object: [String: String] = [:]
            for field in rows { object[field.key] = try resolve(field) }
            request.httpBody = try JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
            if !setsContentType {
                request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        case .form:
            let pairs = try rows.map { "\(Self.formComponent($0.key))=\(Self.formComponent(try resolve($0)))" }
            request.httpBody = Data(pairs.joined(separator: "&").utf8)
            if !setsContentType {
                request.setValue(
                    "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            }
        }
        return request
    }

    /// The text a send returns: `prefix` + the value at `responsePath` + `suffix`. Non-2xx statuses throw.
    public func result(from data: Data, response: URLResponse) throws -> String {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw IntegrationError.http(http.statusCode)
        }
        return prefix + (try Self.value(at: responsePath, in: data)) + suffix
    }

    /// Dot path with numeric array indexes: `data.url`, `items.0.id`. Strings, numbers and booleans are values;
    /// objects, arrays and null are not. An empty path returns the whole response, trimmed.
    public static func value(at path: String, in data: Data) throws -> String {
        let path = path.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else {
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw IntegrationError.missingValue(path: "") }
            return text
        }
        guard var node = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else {
            throw IntegrationError.missingValue(path: path)
        }
        for segment in path.split(separator: ".", omittingEmptySubsequences: false).map(String.init) {
            if let object = node as? [String: Any], let next = object[segment] {
                node = next
            } else if let array = node as? [Any], let index = Int(segment), array.indices.contains(index) {
                node = array[index]
            } else {
                throw IntegrationError.missingValue(path: path)
            }
        }
        switch node {
        case let text as String: return text
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            return number.stringValue
        default: throw IntegrationError.missingValue(path: path)
        }
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// A placeholder value inside a URL: everything but unreserved characters is percent-encoded.
    static func urlComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// `application/x-www-form-urlencoded`: spaces become `+`.
    static func formComponent(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._* ")
        return (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "").replacingOccurrences(
            of: " ", with: "+")
    }

    /// A multipart name or filename: quotes are percent-encoded and line breaks dropped.
    static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "%22").components(separatedBy: .newlines).joined()
    }
}

/// Sends integrations. The app passes `URLSession.shared`; tests pass a session with a stub `URLProtocol`.
public struct IntegrationClient: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    /// The mapped result text, or an `IntegrationError`.
    public func send(_ integration: Integration, context: IntegrationContext, secrets: any IntegrationSecretStore)
        async throws -> String
    {
        let request = try integration.request(for: context, secrets: secrets)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw IntegrationError(error)
        } catch {
            throw IntegrationError.requestFailed
        }
        return try integration.result(from: data, response: response)
    }
}

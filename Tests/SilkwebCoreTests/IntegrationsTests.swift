import Foundation
import XCTest

@testable import SilkwebCore

final class IntegrationsTests: XCTestCase {
    private let boundary = "TEST-BOUNDARY"
    private let created = Date(timeIntervalSince1970: 1_791_000_000) // 2026-10-03T04:00:00Z
    private let modified = Date(timeIntervalSince1970: 1_791_086_400) // 2026-10-04T04:00:00Z

    private func decode(_ json: String) throws -> Integration {
        try JSONDecoder().decode(Integration.self, from: Data(json.utf8))
    }

    private func body(_ request: URLRequest) -> String { String(decoding: request.httpBody ?? Data(), as: UTF8.self) }

    private var context: IntegrationContext {
        var context = IntegrationContext()
        context.title = "Trip & Notes"
        context.markdown = "# Trip\n\nDay 1"
        context.html = "<h1>Trip</h1>"
        context.folderPath = "Travel/2026"
        context.tags = ["travel", "draft"]
        context.filename = "Trip.md"
        context.createdAt = created
        context.modifiedAt = modified
        return context
    }

    // MARK: Builders

    func testMultipartBuilderMatchesFixture() throws {
        let secrets = IntegrationMemorySecrets()
        try secrets.setSecret("Bearer s3cr3t", for: "ref-auth")
        let integration = try decode(
            """
            {"name":"Images","purpose":"imageUpload","url":"https://img.example.com/upload","bodyFormat":"multipart",
             "headers":[{"key":"Authorization","isSecret":true,"secretReference":"ref-auth"},
                        {"key":"X-Title","value":"{{title}}"}],
             "fields":[{"key":"image","value":"{{file}}"},{"key":"name","value":"{{filename}}"},
                       {"key":"say \\"hi\\"","value":"a\\r\\nb"}],
             "responsePath":"data.url"}
            """)
        var context = context
        context.file = IntegrationUpload(
            data: Data([0x89, 0x50, 0x4E, 0x47]), filename: "pic.png", mimeType: "image/png")
        let request = try integration.request(for: context, secrets: secrets, boundary: boundary)

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://img.example.com/upload")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer s3cr3t")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "Trip & Notes")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=TEST-BOUNDARY")
        var expected = Data(
            ("--TEST-BOUNDARY\r\nContent-Disposition: form-data; name=\"image\"; filename=\"pic.png\"\r\n"
                + "Content-Type: image/png\r\n\r\n").utf8)
        expected += Data([0x89, 0x50, 0x4E, 0x47])
        expected += Data(
            ("\r\n--TEST-BOUNDARY\r\nContent-Disposition: form-data; name=\"name\"\r\n\r\npic.png\r\n"
                + "--TEST-BOUNDARY\r\nContent-Disposition: form-data; name=\"say %22hi%22\"\r\n\r\na\r\nb\r\n"
                + "--TEST-BOUNDARY--\r\n").utf8)
        XCTAssertEqual(request.httpBody, expected)
    }

    func testMultipartHeaderRowNeverReplacesTheBoundary() throws {
        var integration = Integration()
        integration.url = "https://example.com"
        integration.headers = [IntegrationParameter(key: "content-type", value: "text/plain")]
        let request = try integration.request(for: context, secrets: IntegrationMemorySecrets(), boundary: boundary)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=TEST-BOUNDARY")
        XCTAssertEqual(body(request), "--TEST-BOUNDARY--\r\n")
    }

    func testMultipartFileFieldWithoutAFileSendsText() throws {
        var integration = Integration()
        integration.url = "https://example.com"
        integration.fields = [IntegrationParameter(key: "image", value: "{{file}}")]
        let request = try integration.request(for: context, secrets: IntegrationMemorySecrets(), boundary: boundary)
        XCTAssertEqual(
            body(request),
            "--TEST-BOUNDARY\r\nContent-Disposition: form-data; name=\"image\"\r\n\r\n\r\n--TEST-BOUNDARY--\r\n")
    }

    func testJSONBuilderMatchesFixture() throws {
        let integration = try decode(
            """
            {"name":"Blog","purpose":"sendDocument","url":"https://blog.example.com/api/posts","bodyFormat":"json",
             "fields":[{"key":"title","value":"{{title}}"},{"key":"body","value":"{{markdown}}"},
                       {"key":"tags","value":"{{tags}}"},{"key":"path","value":"/{{folderPath}}/"},
                       {"key":"","value":"dropped"}]}
            """)
        let request = try integration.request(for: context, secrets: IntegrationMemorySecrets())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")
        XCTAssertEqual(
            body(request),
            ##"{"body":"# Trip\n\nDay 1","path":"/Travel/2026/","tags":"travel, draft","title":"Trip & Notes"}"##)
    }

    func testJSONKeepsAUserContentType() throws {
        var integration = Integration()
        integration.url = "https://example.com"
        integration.bodyFormat = .json
        integration.headers = [IntegrationParameter(key: "Content-Type", value: "application/vnd.api+json")]
        let request = try integration.request(for: context, secrets: IntegrationMemorySecrets())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/vnd.api+json")
        XCTAssertEqual(body(request), "{}")
    }

    func testFormBuilderMatchesFixture() throws {
        let secrets = IntegrationMemorySecrets()
        let token = try IntegrationParameter.secret(key: "token", value: "a+b=c&d", in: secrets)
        var integration = Integration()
        integration.url = "https://forms.example.com/submit"
        integration.bodyFormat = .form
        integration.fields = [
            IntegrationParameter(key: "title", value: "{{title}}"), token,
            IntegrationParameter(key: "when", value: "{{createdAt}}"),
            IntegrationParameter(key: "naïve key", value: "x y"),
        ]
        let request = try integration.request(for: context, secrets: secrets)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded; charset=utf-8")
        XCTAssertEqual(
            body(request), "title=Trip+%26+Notes&token=a%2Bb%3Dc%26d&when=2026-10-03T04%3A00%3A00Z&na%C3%AFve+key=x+y")
    }

    func testHeaderLineBreaksBecomeSpaces() throws {
        var integration = Integration()
        integration.url = "https://example.com"
        integration.headers = [IntegrationParameter(key: "X-Body", value: "{{markdown}}")]
        let request = try integration.request(for: context, secrets: IntegrationMemorySecrets())
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Body"), "# Trip  Day 1")
    }

    // MARK: Templates

    func testTemplateFillsEveryDocumentedPlaceholder() {
        var context = context
        context.file = IntegrationUpload(data: Data("hi".utf8), filename: "pic.png", mimeType: "image/png")
        context.remoteID = "42"
        let template = IntegrationTemplate.placeholders.map { "\($0)=[{{\($0)}}]" }.joined(separator: " ")
        XCTAssertEqual(
            IntegrationTemplate.fill(template, context.values),
            "title=[Trip & Notes] markdown=[# Trip\n\nDay 1] html=[<h1>Trip</h1>] folderPath=[Travel/2026] "
                + "tags=[travel, draft] filename=[pic.png] createdAt=[2026-10-03T04:00:00Z] "
                + "modifiedAt=[2026-10-04T04:00:00Z] file=[aGk=] remoteID=[42]")
        XCTAssertEqual(
            Set(IntegrationTemplate.placeholders),
            [
                "title", "markdown", "html", "folderPath", "tags", "filename", "createdAt", "modifiedAt", "file",
                "remoteID",
            ])
    }

    func testTemplateWithoutValuesIsEmptyAndFilenameFallsBack() {
        let values = IntegrationContext().values
        XCTAssertEqual(
            IntegrationTemplate.fill("[{{createdAt}}][{{file}}][{{remoteID}}][{{tags}}]", values), "[][][][]")
        XCTAssertEqual(IntegrationTemplate.fill("{{filename}}", context.values), "Trip.md")
    }

    func testTemplateIsOnePassAndKeepsUnknownText() {
        let values = ["title": "{{markdown}}", "markdown": "M"]
        XCTAssertEqual(IntegrationTemplate.fill("{{title}}/{{markdown}}", values), "{{markdown}}/M")
        XCTAssertEqual(IntegrationTemplate.fill("{{nope}} {{title", values), "{{nope}} {{title")
        XCTAssertEqual(IntegrationTemplate.fill("{{a {{markdown}}}}", values), "{{a M}}")
        XCTAssertEqual(IntegrationTemplate.fill("", values), "")
        XCTAssertEqual(IntegrationTemplate.fill("{{}}", values), "{{}}")
    }

    func testURLPlaceholdersArePercentEncoded() throws {
        var integration = Integration()
        integration.url = "https://example.com/{{folderPath}}?t={{title}}"
        let request = try integration.request(for: context, secrets: IntegrationMemorySecrets())
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/Travel%2F2026?t=Trip%20%26%20Notes")
    }

    func testUpdateURLOnlyForSendDocumentWithARemoteID() throws {
        var integration = Integration()
        integration.purpose = .sendDocument
        integration.url = "https://example.com/posts"
        integration.updateURL = "https://example.com/posts/{{remoteID}}"
        var context = context
        XCTAssertEqual(integration.endpoint(for: context), integration.url)
        context.remoteID = ""
        XCTAssertEqual(integration.endpoint(for: context), integration.url)
        context.remoteID = "a/b 1"
        let request = try integration.request(for: context, secrets: IntegrationMemorySecrets())
        XCTAssertEqual(request.url?.absoluteString, "https://example.com/posts/a%2Fb%201")
        integration.purpose = .imageUpload
        XCTAssertEqual(integration.endpoint(for: context), integration.url)
        integration.purpose = .sendDocument
        integration.updateURL = ""
        XCTAssertEqual(integration.endpoint(for: context), integration.url)
    }

    // MARK: URL policy

    func testHTTPFailsUnlessAllowInsecureIsOn() throws {
        var integration = Integration()
        integration.url = "http://localhost:8080/upload"
        XCTAssertThrowsError(try integration.request(for: context, secrets: IntegrationMemorySecrets())) {
            XCTAssertEqual($0 as? IntegrationError, .insecureURL)
        }
        integration.url = "HTTP://example.com"
        XCTAssertThrowsError(try integration.validatedURL(integration.url)) {
            XCTAssertEqual($0 as? IntegrationError, .insecureURL)
        }
        integration.allowsInsecureHTTP = true
        XCTAssertEqual(try integration.validatedURL(" http://localhost:8080/upload ").port, 8080)
        // The toggle is per integration.
        XCTAssertThrowsError(try Integration().validatedURL("http://example.com"))
        XCTAssertEqual(try Integration().validatedURL("https://example.com").host, "example.com")
    }

    func testInvalidURLs() {
        let integration = Integration()
        for text in ["", "example.com", "ftp://example.com", "https://", "file:///tmp/x", "https:///path"] {
            XCTAssertThrowsError(try integration.validatedURL(text), text) {
                XCTAssertEqual($0 as? IntegrationError, .invalidURL, text)
            }
        }
    }

    // MARK: Response mapping

    func testValuePathReturnsURLOrRemoteIDWithPrefixAndSuffix() throws {
        let json = Data(
            #"{"data":{"url":"https://cdn.example.com/a.png","id":12345,"ok":true},"items":[{"id":"x1"},{"id":"x2"}],"1":"key"}"#
                .utf8)
        let ok = HTTPURLResponse(
            url: URL(string: "https://e.com")!, statusCode: 201, httpVersion: nil, headerFields: nil)!
        var integration = Integration()
        integration.responsePath = "data.url"
        XCTAssertEqual(try integration.result(from: json, response: ok), "https://cdn.example.com/a.png")
        integration.prefix = "!["
        integration.suffix = "]"
        XCTAssertEqual(try integration.result(from: json, response: ok), "![https://cdn.example.com/a.png]")
        integration.prefix = "https://cms.example.com/p/"
        integration.suffix = ""
        integration.responsePath = "items.1.id"
        XCTAssertEqual(try integration.result(from: json, response: ok), "https://cms.example.com/p/x2")

        XCTAssertEqual(try Integration.value(at: "data.id", in: json), "12345")
        XCTAssertEqual(try Integration.value(at: "data.ok", in: json), "true")
        XCTAssertEqual(try Integration.value(at: "1", in: json), "key")
        XCTAssertEqual(try Integration.value(at: " items.0.id ", in: json), "x1")
        XCTAssertEqual(try Integration.value(at: "", in: Data(" https://x.example/a \n".utf8)), "https://x.example/a")
        XCTAssertEqual(try Integration.value(at: "", in: Data(#""quoted""#.utf8)), #""quoted""#)
        XCTAssertEqual(try Integration.value(at: "u", in: Data(#"{"u":1.5}"#.utf8)), "1.5")
    }

    func testValuePathMissesThrowThePathError() {
        let json = Data(#"{"data":{"url":null,"list":[1],"obj":{}}}"#.utf8)
        for path in [
            "data.nope", "data.url", "data.list", "data.obj", "data.list.1", "data.list.-1", "data..url",
            "data.list.x", ".data",
        ] {
            XCTAssertThrowsError(try Integration.value(at: path, in: json), path) {
                XCTAssertEqual($0 as? IntegrationError, .missingValue(path: path), path)
            }
        }
        XCTAssertThrowsError(try Integration.value(at: "data.url", in: Data("<html>".utf8))) {
            XCTAssertEqual(
                ($0 as? IntegrationError)?.message, "The response has no value at “data.url”. Check Value Path.")
        }
        XCTAssertThrowsError(try Integration.value(at: "", in: Data(" \n".utf8))) {
            XCTAssertEqual($0 as? IntegrationError, .missingValue(path: ""))
        }
    }

    func testNon2xxStatusThrowsHTTPError() {
        let forbidden = HTTPURLResponse(
            url: URL(string: "https://e.com")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        XCTAssertThrowsError(try Integration().result(from: Data("{}".utf8), response: forbidden)) {
            XCTAssertEqual($0 as? IntegrationError, .http(403))
        }
    }

    // MARK: Errors

    func testErrorCopyMatchesTheDesignNotes() {
        XCTAssertEqual(IntegrationError.offline.message, "You’re offline. Connect to the internet and try again.")
        XCTAssertEqual(IntegrationError.timeout.message, "The server didn’t respond within 30 seconds.")
        XCTAssertEqual(
            IntegrationError.untrustedCertificate.message, "The server’s certificate isn’t trusted. Check the URL.")
        XCTAssertEqual(IntegrationError.http(403).message, "The server returned 403 Forbidden.")
        XCTAssertEqual(IntegrationError.http(404).message, "The server returned 404 Not Found.")
        XCTAssertEqual(
            IntegrationError.insecureURL.message,
            "http:// URLs are blocked. Use https://, or turn on Allow Insecure HTTP.")
        XCTAssertEqual(
            IntegrationError.missingValue(path: "data.url").message,
            "The response has no value at “data.url”. Check Value Path.")
        XCTAssertEqual(IntegrationError.offline.localizedDescription, IntegrationError.offline.message)
    }

    func testURLErrorsMapToTheSharedCases() {
        XCTAssertEqual(IntegrationError(URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(IntegrationError(URLError(.networkConnectionLost)), .offline)
        XCTAssertEqual(IntegrationError(URLError(.timedOut)), .timeout)
        XCTAssertEqual(IntegrationError(URLError(.serverCertificateUntrusted)), .untrustedCertificate)
        XCTAssertEqual(IntegrationError(URLError(.secureConnectionFailed)), .untrustedCertificate)
        XCTAssertEqual(IntegrationError(URLError(.appTransportSecurityRequiresSecureConnection)), .insecureURL)
        XCTAssertEqual(IntegrationError(URLError(.cannotFindHost)), .requestFailed)
    }

    // MARK: Secrets

    func testSecretsRoundTripThroughReferencesOnly() throws {
        let secrets = IntegrationMemorySecrets()
        let secret = "Bearer TOP-SECRET-VALUE"
        var integration = Integration()
        integration.url = "https://example.com"
        integration.bodyFormat = .json
        integration.headers = [try IntegrationParameter.secret(key: "Authorization", value: secret, in: secrets)]
        integration.fields = [try IntegrationParameter.secret(key: "api_key", value: "KEY-123", in: secrets)]
        XCTAssertEqual(secrets.count, 2)
        XCTAssertEqual(integration.headers[0].value, "")
        XCTAssertEqual(integration.headers[0].displayValue, "••••••")
        XCTAssertEqual(integration.secretReferences.count, 2)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("integrations.json")
        try IntegrationFile(integrations: [integration]).write(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("TOP-SECRET"), text)
        XCTAssertFalse(text.contains("KEY-123"), text)
        XCTAssertTrue(text.contains(integration.headers[0].secretReference!), text)

        let loaded = IntegrationFile.load(from: url)
        XCTAssertEqual(loaded.integrations, [integration])
        let request = try loaded.integrations[0].request(for: context, secrets: secrets)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), secret)
        XCTAssertEqual(body(request), #"{"api_key":"KEY-123"}"#)
    }

    func testASecretValueOnDiskIsNeverRead() throws {
        let integration = try decode(
            #"{"headers":[{"key":"Authorization","value":"leaked","isSecret":true,"secretReference":"r"}]}"#)
        XCTAssertEqual(integration.headers[0].value, "")
        let text = String(decoding: try JSONEncoder().encode(integration), as: UTF8.self)
        XCTAssertFalse(text.contains("leaked"), text)
    }

    func testMissingSecretThrowsWithoutAnyValue() throws {
        let secrets = IntegrationMemorySecrets()
        var integration = Integration()
        integration.url = "https://example.com"
        integration.headers = [try IntegrationParameter.secret(key: "Authorization", value: "Bearer zzz", in: secrets)]
        try secrets.removeSecret(for: integration.headers[0].secretReference!)
        try secrets.removeSecret(for: "never-set")
        XCTAssertThrowsError(try integration.request(for: context, secrets: secrets)) {
            XCTAssertEqual($0 as? IntegrationError, .secretUnavailable(key: "Authorization"))
            XCTAssertFalse(($0 as? IntegrationError)?.message.contains("zzz") ?? true)
        }
        integration.headers[0].secretReference = nil
        XCTAssertThrowsError(try integration.request(for: context, secrets: secrets))
    }

    func testKeychainServiceIsSeparateFromAgentGrants() {
        XCTAssertEqual(IntegrationKeychain.service, "Silkweb Integrations")
        XCTAssertNotEqual(IntegrationKeychain.service, AgentGrantKeychain.service)
    }

    // MARK: Persistence

    func testMissingKeysUseSafeDefaults() throws {
        for json in ["{}", #"{"purpose":"video","bodyFormat":7,"headers":"x","fields":null,"name":3}"#] {
            let integration = try decode(json)
            XCTAssertEqual(integration.name, "New Integration", json)
            XCTAssertEqual(integration.purpose, .imageUpload, json)
            XCTAssertEqual(integration.url, "", json)
            XCTAssertFalse(integration.allowsInsecureHTTP, json)
            XCTAssertEqual(integration.bodyFormat, .multipart, json)
            XCTAssertEqual(integration.headers, [], json)
            XCTAssertEqual(integration.fields, [], json)
            XCTAssertEqual(integration.responsePath, "", json)
            XCTAssertEqual(integration.prefix, "", json)
            XCTAssertEqual(integration.suffix, "", json)
            XCTAssertEqual(integration.updateURL, "", json)
        }
        XCTAssertEqual(Integration.timeout, 30)
        XCTAssertEqual(Integration.Purpose.allCases.map(\.title), ["Image Upload", "Send Document"])
        XCTAssertEqual(Integration.BodyFormat.allCases.map(\.title), ["Multipart", "JSON", "Form"])
    }

    func testOlderAndDamagedFilesStillLoad() throws {
        let id = UUID()
        let old = """
            {"version":0,"integrations":[
              {"id":"\(id.uuidString)","name":"Old","url":"https://old.example.com",
               "fields":[{"key":"a","value":"1"},{"value":"no key"},{"key":"b"}]},
              "not an object",
              {"name":"Second","unknown":{"nested":true}}
            ]}
            """
        let file = try JSONDecoder().decode(IntegrationFile.self, from: Data(old.utf8))
        XCTAssertEqual(file.version, IntegrationFile.currentVersion)
        XCTAssertEqual(file.integrations.map(\.name), ["Old", "Second"])
        XCTAssertEqual(file.integrations[0].id, id)
        XCTAssertEqual(
            file.integrations[0].fields,
            [IntegrationParameter(key: "a", value: "1"), IntegrationParameter(key: "b", value: "")])
        for json in ["{}", #"{"integrations":null}"#, #"{"integrations":{}}"#] {
            XCTAssertEqual(
                try JSONDecoder().decode(IntegrationFile.self, from: Data(json.utf8)), IntegrationFile(), json)
        }
    }

    func testLoadAndWrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Silkweb/integrations.json")
        XCTAssertEqual(IntegrationFile.load(from: url), IntegrationFile())
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(IntegrationFile.load(from: url), IntegrationFile())
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "not json", "Reading never rewrites the file")

        var integration = Integration()
        integration.name = "Blog"
        integration.purpose = .sendDocument
        integration.url = "https://blog.example.com/{{title}}"
        integration.allowsInsecureHTTP = true
        integration.bodyFormat = .form
        integration.headers = [IntegrationParameter(key: "X-A", value: "1")]
        integration.fields = [IntegrationParameter(key: "t", value: "{{title}}")]
        integration.responsePath = "id"
        integration.prefix = "<"
        integration.suffix = ">"
        integration.updateURL = "https://blog.example.com/{{remoteID}}"
        let saved = IntegrationFile(integrations: [integration, Integration()])
        try saved.write(to: url)
        XCTAssertEqual(IntegrationFile.load(from: url), saved)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(#""version" : 1"#), text)
        XCTAssertTrue(text.contains("https://blog.example.com/{{title}}"), text)
        XCTAssertEqual(
            IntegrationFile.defaultURL(home: URL(fileURLWithPath: "/Users/x")).path,
            "/Users/x/Library/Application Support/Silkweb/integrations.json")
    }

    // MARK: Client with a stub URLProtocol (no network)

    private func client(_ host: String, _ reply: @escaping @Sendable (URLRequest) -> IntegrationStubProtocol.Reply)
        -> IntegrationClient
    {
        IntegrationStubProtocol.set(host, reply)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IntegrationStubProtocol.self]
        return IntegrationClient(session: URLSession(configuration: configuration))
    }

    private func integration(_ host: String) -> Integration {
        var integration = Integration()
        integration.url = "https://\(host)/upload"
        integration.responsePath = "data.url"
        integration.prefix = "!["
        integration.suffix = "]"
        integration.fields = [IntegrationParameter(key: "image", value: "{{file}}")]
        return integration
    }

    func testClientSendsAndMapsTheResponse() async throws {
        let host = "ok.stub.invalid"
        let client = client(host) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
            return .response(200, Data(#"{"data":{"url":"https://cdn.example.com/1.png"}}"#.utf8))
        }
        let secrets = IntegrationMemorySecrets()
        var integration = integration(host)
        integration.headers = [try IntegrationParameter.secret(key: "Authorization", value: "Bearer k", in: secrets)]
        var context = context
        context.file = IntegrationUpload(data: Data([1, 2, 3]), filename: "1.png", mimeType: "image/png")
        let result = try await client.send(integration, context: context, secrets: secrets)
        XCTAssertEqual(result, "![https://cdn.example.com/1.png]")
    }

    func testClientMapsFailures() async throws {
        let cases: [(String, IntegrationStubProtocol.Reply, IntegrationError)] = [
            ("forbidden.stub.invalid", .response(403, Data("denied".utf8)), .http(403)),
            ("nopath.stub.invalid", .response(200, Data(#"{"data":{}}"#.utf8)), .missingValue(path: "data.url")),
            ("offline.stub.invalid", .failure(.notConnectedToInternet), .offline),
            ("slow.stub.invalid", .failure(.timedOut), .timeout),
            ("tls.stub.invalid", .failure(.serverCertificateUntrusted), .untrustedCertificate),
        ]
        for (host, reply, expected) in cases {
            let client = client(host) { _ in reply }
            do {
                _ = try await client.send(integration(host), context: context, secrets: IntegrationMemorySecrets())
                XCTFail("\(host) should fail")
            } catch {
                XCTAssertEqual(error as? IntegrationError, expected, host)
            }
        }
    }

    func testClientBlocksHTTPBeforeAnyRequest() async {
        let host = "plain.stub.invalid"
        let client = client(host) { _ in
            XCTFail("No request may leave for a blocked URL")
            return .response(200, Data())
        }
        var integration = integration(host)
        integration.url = "http://\(host)/upload"
        do {
            _ = try await client.send(integration, context: context, secrets: IntegrationMemorySecrets())
            XCTFail("http:// should fail")
        } catch {
            XCTAssertEqual(error as? IntegrationError, .insecureURL)
        }
    }
}

/// Answers by host, so parallel tests never share a reply. Unknown hosts fail as offline; nothing reaches the network.
final class IntegrationStubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case response(Int, Data)
        case failure(URLError.Code)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: @Sendable (URLRequest) -> Reply] = [:]

    static func set(_ host: String, _ reply: @escaping @Sendable (URLRequest) -> Reply) {
        lock.withLock { replies[host] = reply }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.lock.withLock { Self.replies[request.url?.host ?? ""] }
        switch handler?(request) ?? .failure(.notConnectedToInternet) {
        case .response(let status, let data):
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        }
    }

    override func stopLoading() {}
}

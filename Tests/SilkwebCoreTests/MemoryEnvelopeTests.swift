import XCTest

@testable import SilkwebCore

final class MemoryEnvelopeTests: XCTestCase {
    private static let created = Date(timeIntervalSince1970: 1_791_365_400) // 2026-10-07T09:30:00Z

    private func envelope() -> MemoryEnvelope {
        MemoryEnvelope(
            memoryID: "mem_01", type: "progress", project: "Silkweb", agent: "claude-code", session: "s-1",
            createdAt: Self.created)
    }

    private func parsed(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> (
        MemoryEnvelope, Substring
    )? {
        guard case .envelope(let envelope, let body) = MemoryEnvelope.parse(text) else {
            XCTFail("no envelope in \(text.debugDescription)", file: file, line: line)
            return nil
        }
        return (envelope, text[body])
    }

    /// The contract's v1 examples (`docs/agent-memory.md` › Envelope) parse, and writing the parsed
    /// envelope in front of the parsed body reproduces every byte.
    func testContractExamplesRoundTrip() throws {
        let doc = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../docs/agent-memory.md"), encoding: .utf8)
        let section = try XCTUnwrap(
            doc.components(separatedBy: "\n## Envelope\n").last?
                .components(separatedBy: "\n## ").first)
        let examples = section.components(separatedBy: "```markdown\n").dropFirst()
            .compactMap { $0.components(separatedBy: "\n```").first.map { $0 + "\n" } }
        XCTAssertFalse(examples.isEmpty)
        for example in examples {
            let (envelope, body) = try XCTUnwrap(parsed(example))
            XCTAssertEqual(envelope.string("schema"), MemoryEnvelope.schemaV1)
            XCTAssertNoThrow(try envelope.validateForCreate())
            XCTAssertTrue(body.hasPrefix("# "))
            XCTAssertEqual(envelope.text + "\n" + body, example)
            XCTAssertEqual(try envelope.document(body: String(body)), example)
            XCTAssertEqual(envelope.unknownFields.map(\.key), ["x-source-ticket"])
        }
    }

    /// Create-time insertion is the only change: the body that follows is byte for byte the input.
    func testCreateKeepsBodyBytes() throws {
        let bodies = [
            "", "# Title\n", "# Title", "---\nA leading thematic break\n", "\n\nStarts with blank lines\n",
            "# Windows\r\n\r\nCRLF body\r\n", "# 日本語 👩🏽‍💻\n\ncafé\u{301} ☕️\n", "No trailing newline",
            "---\nschema: \"silkweb-memory/v1\"\n---\nA body that looks like an envelope\n",
        ]
        for body in bodies {
            let document = try envelope().document(body: body)
            XCTAssertTrue(document.hasPrefix(envelope().text + "\n"))
            let (parsedEnvelope, parsedBody) = try XCTUnwrap(parsed(document))
            XCTAssertEqual(Array(parsedBody.utf8), Array(body.utf8), body.debugDescription)
            XCTAssertEqual(parsedEnvelope, envelope())
            XCTAssertEqual(MemoryEnvelope.bodyRange(in: document).map { document[$0] }, parsedBody)
        }
    }

    func testWritesFixedKeyOrderAndUnknownKeysByteForByte() throws {
        let source = """
            ---
            x-first:   'kept as written'  \r
            supersedes:
              - "mem_00"
              - mem_000
            type: progress
            created_at: 2026-10-07T09:30:00Z
            nested:
              owner: "someone"
              depth: 2
            schema: "silkweb-memory/v1"

            memory_id: 'mem_01'
            project: "Silkweb"
            agent: "claude-code"
            session: "s-1"
            x-last: ["a", b]
            ---

            Body

            """
        let (envelope, body) = try XCTUnwrap(parsed(source))
        XCTAssertEqual(body, "Body\n")
        XCTAssertEqual(envelope["supersedes"], .list(["mem_00", "mem_000"]))
        XCTAssertEqual(envelope["nested"], .unparsed)
        XCTAssertEqual(envelope["x-first"], .string("kept as written"))
        XCTAssertEqual(envelope["x-last"], .list(["a", "b"]))
        XCTAssertEqual(
            envelope.text,
            """
            ---
            schema: "silkweb-memory/v1"
            memory_id: "mem_01"
            type: "progress"
            project: "Silkweb"
            agent: "claude-code"
            session: "s-1"
            created_at: "2026-10-07T09:30:00Z"
            supersedes: ["mem_00", "mem_000"]
            x-first:   'kept as written'  \r
            nested:
              owner: "someone"
              depth: 2
            x-last: ["a", b]
            ---

            """)
        XCTAssertNoThrow(try envelope.validateForCreate())
        // The re-exported envelope reads back to the same fields.
        let (again, _) = try XCTUnwrap(parsed(try envelope.document(body: "Body\n")))
        XCTAssertEqual(again.text, envelope.text)
        XCTAssertEqual(again.unknownFields, envelope.unknownFields)
    }

    func testUnknownFieldsSurviveTheCreatePath() throws {
        var built = envelope()
        built["x-tool"] = .string("codex")
        built["x-refs"] = .list(["#129", "#132"])
        built["status"] = .string("done")
        let document = try built.document(body: "# Title\n")
        XCTAssertEqual(
            document,
            """
            ---
            schema: "silkweb-memory/v1"
            memory_id: "mem_01"
            type: "progress"
            project: "Silkweb"
            agent: "claude-code"
            session: "s-1"
            created_at: "2026-10-07T09:30:00Z"
            status: "done"
            x-tool: "codex"
            x-refs: ["#129", "#132"]
            ---

            # Title

            """)
        let (envelope, _) = try XCTUnwrap(parsed(document))
        XCTAssertEqual(envelope.unknownFields.map(\.key), ["x-tool", "x-refs"])
        XCTAssertEqual(envelope.string("x-tool"), "codex")
        XCTAssertEqual(envelope["x-refs"], .list(["#129", "#132"]))
    }

    func testQuotedStringsRoundTrip() throws {
        for value in [
            "", "plain", "with \"quotes\" and \\backslash\\", "line\nbreak\ttab\rreturn", "\u{0}\u{1F}\u{7F}",
            "日本語 👩🏽‍💻 café\u{301}", "\u{301}starts with a combining mark", "a: b # c", "[not, a, list]", "'single'", "---",
        ] {
            var built = envelope()
            built["status"] = .string(value)
            built["supersedes"] = .list([value, "x"])
            let (envelope, _) = try XCTUnwrap(parsed(try built.document(body: "")))
            XCTAssertEqual(envelope.string("status"), value, value.debugDescription)
            XCTAssertEqual(envelope["supersedes"], .list([value, "x"]), value.debugDescription)
        }
    }

    func testSubsetValueForms() throws {
        let cases: [(String, MemoryEnvelope.Value)] = [
            ("\"a\\/b \\u00e9\"", .string("a/b é")),
            ("'it''s'", .string("it's")),
            ("in-progress", .string("in-progress")),
            ("2026-10-07T09:30:00Z", .string("2026-10-07T09:30:00Z")),
            ("done, verified", .string("done, verified")),
            ("", .string("")),
            ("[]", .list([])),
            ("[ ]", .list([])),
            ("[\"a, b\", 'c', d]", .list(["a, b", "c", "d"])),
        ]
        for (value, expected) in cases {
            let source = "---\nschema: \"silkweb-memory/v1\"\nstatus: \(value)\n---\n"
            let (envelope, body) = try XCTUnwrap(parsed(source))
            XCTAssertEqual(envelope["status"], expected, value)
            XCTAssertEqual(body, "")
        }
    }

    func testDocumentsWithoutAnEnvelopeAreOrdinary() {
        for text in [
            "", "# Title\n\nBody", "Body\n---\nschema: \"silkweb-memory/v1\"\n---\n", "---\n",
            "---\nA thematic break\n",
            "---\ntitle: \"Jekyll\"\nlayout: post\n---\n\n# Post", "---\nschema: \"other/v1\"\n---\n",
            "---\nschema: [\"silkweb-memory/v1\"]\n---\n", "  ---\nschema: \"silkweb-memory/v1\"\n---\n",
            "\u{FEFF}---\nschema: \"silkweb-memory/v1\"\n---\n",
        ] {
            XCTAssertEqual(MemoryEnvelope.parse(text), .missing, text.debugDescription)
            XCTAssertNil(MemoryEnvelope.bodyRange(in: text))
        }
    }

    func testMalformedEnvelopesReportTheLine() {
        let cases: [(String, Int)] = [
            ("---\nschema: \"silkweb-memory/v1\"\ntype: \"memory\"\n", 1),
            ("---\nschema: \"silkweb-memory/v1\"\n# a comment\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\n  indented: x\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\nschema: \"silkweb-memory/v1\"\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\nkey:value\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\n9key: x\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\ntype: \"memory\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\ntype: \"bad \\q escape\"\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\ntype: \"memory\" trailing\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\nagent: {name: x}\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\nagent: a: b\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\nsupersedes: [\"a\", [b]]\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\nsupersedes: [a,]\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v1\"\nproject:\n  name: x\n---\n", 4),
            ("---\nschema: \"silkweb-memory/v1\"\nsupersedes:\n  - a\n  -\n---\n", 4),
            ("---\ntype: \"memory\"\nschema: \"silkweb-memory/vX\"\n---\n", 3),
            ("---\nschema: \"silkweb-memory/v0\"\n---\n", 2),
            ("---\r\nschema: \"silkweb-memory/v1\"\r\nagent: {}\r\n---\r\n", 3),
        ]
        for (text, line) in cases {
            XCTAssertEqual(MemoryEnvelope.parse(text), .failure(.malformed(line: line)), text.debugDescription)
            XCTAssertNil(MemoryEnvelope.bodyRange(in: text))
        }
        let error = MemoryEnvelopeError.malformed(line: 4)
        XCTAssertEqual(error.code, "envelope_malformed")
        XCTAssertEqual(
            error.message(name: "Helper spike"),
            "The front matter in “Helper spike” couldn’t be read (line 4). The document is unchanged.")
    }

    func testNewerSchemaIsReportedBeforeSyntax() {
        for text in [
            "---\nschema: \"silkweb-memory/v2\"\n---\n# Body",
            "---\nschema: silkweb-memory/v2\nfuture:\n  nested: {a: [1]}\n& anything\n---\n",
            "---\nschema: \"silkweb-memory/v2\"\nnever closed",
        ] {
            XCTAssertEqual(MemoryEnvelope.parse(text), .failure(.schemaNewer("silkweb-memory/v2")), text)
        }
        let error = MemoryEnvelopeError.schemaNewer("silkweb-memory/v2")
        XCTAssertEqual(error.code, "envelope_schema_newer")
        XCTAssertEqual(
            error.message(name: "Helper spike"),
            "“Helper spike” uses schema “silkweb-memory/v2”, which this version of Silkweb doesn’t support. "
                + "The document is unchanged.")
    }

    /// Malformed and newer documents are still ordinary text in the library: they scan, read back in full
    /// and keep their bytes on disk.
    func testUnreadableEnvelopesStillOpenAsText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryEnvelope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let texts = [
            "Malformed.md": "---\nschema: \"silkweb-memory/v1\"\nagent: {broken\n---\n\n# Malformed\n\nKeep me.\n",
            "Newer.md": "---\nschema: \"silkweb-memory/v9\"\nshape: {x: 1}\n---\n\n# Newer\n\nKeep me too.\n",
            "Unclosed.md": "---\nschema: \"silkweb-memory/v1\"\n# Unclosed\n\nStill here.\n",
        ]
        for (name, text) in texts {
            try Data(text.utf8).write(to: root.appendingPathComponent(name))
            if case .envelope = MemoryEnvelope.parse(text) { XCTFail(name) }
        }
        let snapshot = try await LibraryScanner.scan(root: root)
        XCTAssertEqual(snapshot.documents.count, 3)
        for document in snapshot.documents {
            let text = try await LibraryScanner.readDocument(document, root: root)
            XCTAssertEqual(text, texts[document.name])
            XCTAssertEqual(
                try String(contentsOf: root.appendingPathComponent(document.name), encoding: .utf8),
                texts[document.name])
        }
    }

    /// `memory_id` is portable identity only: the index owns native IDs and Tags, and envelope keys that
    /// look like them (`id`, `tags`, `pinned`) are kept as unknown keys and never read by the app.
    func testIndexOwnsNativeIdentityAndTags() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MemoryEnvelope-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let memoryID = UUID()
        var built = envelope()
        built["memory_id"] = .string(memoryID.uuidString)
        built["id"] = .string(memoryID.uuidString)
        built["tags"] = .list(["Travel"])
        built["pinned"] = .string("true")
        let text = try built.document(body: "# Note\n")
        let url = root.appendingPathComponent("Note.md")
        try Data(text.utf8).write(to: url)

        let snapshot = try await LibraryScanner.scan(root: root)
        let document = try XCTUnwrap(snapshot.documents.first)
        XCTAssertNotEqual(document.id, memoryID)
        XCTAssertEqual(snapshot.metadata.IDsByPath["Note.md"], document.id)
        XCTAssertTrue(snapshot.metadata.tags.isEmpty)
        XCTAssertTrue(snapshot.metadata.tagsByDocument.isEmpty)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        // A copy outside Silkweb keeps the portable identity but gets a new native ID.
        let copy = root.appendingPathComponent("Copy.md")
        try FileManager.default.copyItem(at: url, to: copy)
        let rescanned = try await LibraryScanner.scan(root: root, previousSnapshot: snapshot)
        let copied = try XCTUnwrap(rescanned.documents.first { $0.name == "Copy.md" })
        XCTAssertNotEqual(copied.id, document.id)
        let (copiedEnvelope, _) = try XCTUnwrap(parsed(try String(contentsOf: copy, encoding: .utf8)))
        XCTAssertEqual(copiedEnvelope.memoryID, memoryID.uuidString)
        XCTAssertEqual(
            Set(MemoryEnvelope.knownKeys).intersection(["id", "uuid", "tags", "pinned", "pin", "review", "archived"]),
            [])
    }

    func testCreateValidation() {
        XCTAssertNoThrow(try envelope().validateForCreate())
        XCTAssertEqual(envelope().string("created_at"), "2026-10-07T09:30:00Z")
        func check(_ key: String, _ change: (inout MemoryEnvelope) -> Void, line: UInt = #line) {
            var built = envelope()
            change(&built)
            XCTAssertThrowsError(try built.document(body: "Body"), line: line) {
                XCTAssertEqual($0 as? MemoryEnvelopeError, .invalidField(key), line: line)
            }
        }
        for key in MemoryEnvelope.requiredKeys {
            check(key) { $0[key] = nil }
            if key != "schema" { check(key) { $0[key] = .string("  ") } }
            check(key) { $0[key] = .list([]) }
        }
        check("schema") { $0["schema"] = .string("silkweb-memory/v2") }
        check("type") { $0["type"] = .string("note") }
        check("created_at") { $0["created_at"] = .string("2026-10-07 09:30") }
        check("created_at") { $0["created_at"] = .string("2026-10-07T09:30:00+02:00") }
        check("observed_at") { $0["observed_at"] = .string("yesterday") }
        check("review_after") { $0["review_after"] = .list([]) }
        check("supersedes") { $0["supersedes"] = .string("mem_00") }
        check("status") { $0["status"] = .list(["a"]) }
        check("bad key") { $0["bad key"] = .string("x") }
        var valid = envelope()
        for type in MemoryEnvelope.types {
            valid["type"] = .string(type)
            XCTAssertNoThrow(try valid.validateForCreate())
        }
        valid["observed_at"] = .string("2026-10-07T09:30:00.250Z")
        valid["review_after"] = .string("2027-01-01T00:00:00Z")
        valid["supersedes"] = .list([])
        valid["x-anything"] = .list(["a"])
        XCTAssertNoThrow(try valid.validateForCreate())
        XCTAssertEqual(
            MemoryEnvelopeError.invalidField("type").message(name: "Ignored"),
            "The front matter field “type” is missing or invalid.")
        XCTAssertEqual(MemoryEnvelopeError.invalidField("type").code, "envelope_invalid_field")
    }
}

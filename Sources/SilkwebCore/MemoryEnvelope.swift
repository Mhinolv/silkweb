import Foundation

/// Portable `silkweb-memory/v1` front matter for agent memory documents (#132, `docs/agent-memory.md` ›
/// Envelope). It's parsed with the **Silkweb envelope subset**, not a general YAML parser: a leading `---`
/// line, one `key: value` per line, a closing `---` line, a blank line, then the Markdown body. Values are
/// quoted or plain strings, flow (`["a", "b"]`) or block (`- a`) lists of strings. Nested maps aren't
/// supported: under an unknown key they're kept byte for byte and reported as `.unparsed`; under a v1 key
/// they make the envelope malformed.
///
/// Ownership:
/// - `memory_id` is the portable identity. It travels with the file, also when it's copied outside Silkweb.
/// - The app index (`.silkweb/index.json`) owns the native document UUID and Tags. Neither is an envelope
///   key; a `tags` or `id` key is an ordinary unknown key that the app never reads.
/// - Review, pin and archive state belong to the human and live in versioned app metadata, never here.
///
/// Only the create pipeline writes an envelope. Opening, editing and autosaving keep the document text as
/// it is, and a document without front matter is an ordinary library document.
public struct MemoryEnvelope: Equatable, Sendable {
    public static let schemaV1 = "silkweb-memory/v1"
    public static let currentSchemaVersion = 1
    static let schemaPrefix = "silkweb-memory/v"
    /// v1 keys in their fixed write order. Unknown keys follow in their original order.
    public static let knownKeys = [
        "schema", "memory_id", "type", "project", "agent", "session", "created_at", "observed_at", "status",
        "supersedes", "review_after",
    ]
    public static let requiredKeys = ["schema", "memory_id", "type", "project", "agent", "session", "created_at"]
    public static let types: Set<String> = ["memory", "decision", "progress", "handoff"]
    static let timestampKeys: Set<String> = ["created_at", "observed_at", "review_after"]
    static let listKeys: Set<String> = ["supersedes"]

    public enum Value: Equatable, Sendable {
        case string(String)
        case list([String])
        /// An unknown key's value outside the subset (a nested map, a multi-line scalar). Its source is kept.
        case unparsed
    }

    public struct Field: Equatable, Sendable {
        public let key: String
        public let value: Value
        /// The key's source lines, terminators included. Unknown keys are written back exactly as read.
        public let source: String
    }

    public enum Parse: Equatable, Sendable {
        /// No Silkweb envelope: no leading front matter, or front matter without a `silkweb-memory` schema.
        case missing
        case envelope(MemoryEnvelope, body: Range<String.Index>)
        case failure(MemoryEnvelopeError)
    }

    /// Fields in source order (parsed) or insertion order (built).
    public private(set) var fields: [Field] = []

    public init() {}

    /// A new v1 envelope as the create pipeline writes it. `created_at` is UTC to the second.
    public init(memoryID: String, type: String, project: String, agent: String, session: String, createdAt: Date) {
        self["schema"] = .string(Self.schemaV1)
        self["memory_id"] = .string(memoryID)
        self["type"] = .string(type)
        self["project"] = .string(project)
        self["agent"] = .string(agent)
        self["session"] = .string(session)
        self["created_at"] = .string(Self.timestamp(createdAt))
    }

    public subscript(key: String) -> Value? {
        get { fields.first { $0.key == key }?.value }
        set {
            guard let newValue else {
                fields.removeAll { $0.key == key }
                return
            }
            if case .unparsed = newValue { return }
            let field = Field(key: key, value: newValue, source: Self.line(key, newValue))
            if let index = fields.firstIndex(where: { $0.key == key }) {
                fields[index] = field
            } else {
                fields.append(field)
            }
        }
    }

    public func string(_ key: String) -> String? {
        if case .string(let value) = self[key] { return value }
        return nil
    }

    public var memoryID: String? { string("memory_id") }
    public var unknownFields: [Field] { fields.filter { !Self.knownKeys.contains($0.key) } }

    /// The envelope as written: v1 keys in the fixed order, then unknown keys byte for byte.
    public var text: String {
        var result = "---\n"
        for key in Self.knownKeys {
            if let value = self[key] { result += Self.line(key, value) }
        }
        for field in unknownFields { result += field.source }
        return result + "---\n"
    }

    /// Create-time insertion: the envelope, one blank line, then `body` unchanged.
    public func document(body: String) throws -> String {
        try validateForCreate()
        return text + "\n" + body
    }

    /// The rules a newly created envelope must meet. Parsing alone is more tolerant, so existing
    /// documents with odd values still read.
    public func validateForCreate() throws {
        guard string("schema") == Self.schemaV1 else { throw MemoryEnvelopeError.invalidField("schema") }
        for key in Self.requiredKeys {
            guard let value = string(key), !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MemoryEnvelopeError.invalidField(key)
            }
        }
        guard Self.types.contains(string("type") ?? "") else { throw MemoryEnvelopeError.invalidField("type") }
        for field in fields {
            guard Self.isKey(field.key[...]) else { throw MemoryEnvelopeError.invalidField(field.key) }
            let valid: Bool
            switch (field.value, field.key) {
            case (.string(let value), let key) where Self.timestampKeys.contains(key): valid = Self.isTimestamp(value)
            case (.list, let key): valid = Self.listKeys.contains(key) || !Self.knownKeys.contains(key)
            case (.string, let key): valid = !Self.listKeys.contains(key)
            case (.unparsed, let key): valid = !Self.knownKeys.contains(key)
            }
            guard valid else { throw MemoryEnvelopeError.invalidField(field.key) }
        }
    }

    // MARK: Parsing

    /// The body after a well-formed v1 envelope, or `nil` when there's none (missing, malformed or newer).
    public static func bodyRange(in text: String) -> Range<String.Index>? {
        if case .envelope(_, let body) = parse(text) { return body }
        return nil
    }

    public static func parse(_ text: String) -> Parse {
        guard text.hasPrefix("---") else { return .missing }
        let scalars = text.unicodeScalars
        var lines: [(content: String, range: Range<String.Index>)] = []
        var closing: Int?
        var index = text.startIndex
        while index < text.endIndex {
            let newline = scalars[index...].firstIndex(of: "\n")
            let next = newline.map { scalars.index(after: $0) } ?? text.endIndex
            var content = String(scalars[index..<(newline ?? text.endIndex)])
            if content.hasSuffix("\r") { content.unicodeScalars.removeLast() }
            if lines.isEmpty, !isDelimiter(content) { return .missing }
            if !lines.isEmpty, isDelimiter(content) {
                closing = lines.count
                lines.append((content, index..<next))
                break
            }
            lines.append((content, index..<next))
            index = next
        }
        let block = lines[1..<(closing ?? lines.count)]
        // Front matter from other tools (no `schema`, or another schema) is ordinary document text.
        guard let schemaLine = block.firstIndex(where: { $0.content.hasPrefix("schema:") }),
            case .string(let schema)? = scalar(value(after: "schema", in: block[schemaLine].content)),
            schema.hasPrefix(schemaPrefix)
        else { return .missing }
        guard let version = Int(schema.dropFirst(schemaPrefix.count)), version >= 1 else {
            return .failure(.malformed(line: schemaLine + 1))
        }
        if version > currentSchemaVersion { return .failure(.schemaNewer(schema)) }
        guard let closing else { return .failure(.malformed(line: 1)) }

        var envelope = MemoryEnvelope()
        var position = block.startIndex
        while position < block.endIndex {
            let line = block[position].content
            let start = position
            position += 1
            if line.allSatisfy(\.isWhitespace) { continue }
            guard let colon = line.firstIndex(of: ":"), isKey(line[..<colon]) else {
                return .failure(.malformed(line: start + 1))
            }
            let key = String(line[..<colon])
            let rest = line[line.index(after: colon)...]
            guard rest.isEmpty || rest.unicodeScalars.first == " " || rest.unicodeScalars.first == "\t",
                envelope[key] == nil
            else {
                return .failure(.malformed(line: start + 1))
            }
            // Continuation lines: indented, or block list items.
            while position < block.endIndex,
                block[position].content.first.map({ $0 == " " || $0 == "\t" }) == true
                    || block[position].content == "-" || block[position].content.hasPrefix("- ")
            {
                position += 1
            }
            let continuation = block[(start + 1)..<position].map(\.content)
            let inline = rest.trimmingCharacters(in: .whitespaces)
            var parsed: Value?
            if continuation.isEmpty {
                parsed = inline.isEmpty ? .string("") : scalar(inline) ?? flowList(inline)
            } else if inline.isEmpty {
                parsed = blockList(continuation)
            }
            if parsed == nil {
                guard !knownKeys.contains(key) else {
                    return .failure(.malformed(line: (continuation.isEmpty ? start : start + 1) + 1))
                }
                parsed = .unparsed
            }
            let source = String(scalars[block[start].range.lowerBound..<block[position - 1].range.upperBound])
            envelope.fields.append(Field(key: key, value: parsed!, source: source))
        }
        // The body follows the closing line and the single blank line the create pipeline writes.
        var body = lines[closing].range.upperBound
        let rest = String(scalars[body...].prefix { $0 != "\n" })
        if rest.allSatisfy({ $0 == "\r" }), let newline = scalars[body...].firstIndex(of: "\n") {
            body = scalars.index(after: newline)
        }
        return .envelope(envelope, body: body..<text.endIndex)
    }

    private static func isDelimiter(_ line: String) -> Bool {
        line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func value(after key: String, in line: String) -> String {
        String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }

    static func isKey(_ text: Substring) -> Bool {
        guard let first = text.unicodeScalars.first,
            first == "_" || ("a"..."z").contains(first)
                || ("A"..."Z").contains(first)
        else { return false }
        return text.unicodeScalars.allSatisfy {
            $0 == "_" || $0 == "-" || ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
    }

    /// A double-quoted, single-quoted or plain string, or `nil` outside the subset.
    static func scalar(_ text: String) -> Value? {
        guard let item = item(text[...], inFlow: false) else { return nil }
        return .string(item)
    }

    private static func item(_ text: Substring, inFlow: Bool) -> String? {
        let text = text.trimmingCharacters(in: .whitespaces)[...]
        // Scalars, not Characters: a combining mark after a quote must not hide the quote.
        guard let first = text.unicodeScalars.first else { return nil }
        if first == "\"" { return doubleQuoted(text) }
        if first == "'" {
            let inner = String(text.unicodeScalars.dropFirst().dropLast())
            guard text.unicodeScalars.count >= 2, text.unicodeScalars.last == "'",
                !inner.replacingOccurrences(of: "''", with: "").contains("'")
            else { return nil }
            return inner.replacingOccurrences(of: "''", with: "'")
        }
        // Plain: no indicator first, no `: ` or ` #` inside, so nothing is guessed at.
        guard !"[]{}#&*!|>%@`,?:".unicodeScalars.contains(first), text != "-", !text.hasPrefix("- "),
            !text.contains(": "), !text.contains(" #"), !text.hasSuffix(":"),
            !inFlow || !text.contains(where: { "[]{},".contains($0) })
        else { return nil }
        return String(text)
    }

    private static func doubleQuoted(_ text: Substring) -> String? {
        var result = ""
        var iterator = text.unicodeScalars.dropFirst().makeIterator()
        while let scalar = iterator.next() {
            switch scalar {
            case "\"":
                return iterator.next() == nil ? result : nil
            case "\\":
                switch iterator.next() {
                case "\"": result += "\""
                case "\\": result += "\\"
                case "/": result += "/"
                case "n": result += "\n"
                case "t": result += "\t"
                case "r": result += "\r"
                case "u":
                    var hex = ""
                    for _ in 0..<4 { if let next = iterator.next() { hex.unicodeScalars.append(next) } }
                    guard hex.count == 4, let code = UInt32(hex, radix: 16), let decoded = Unicode.Scalar(code) else {
                        return nil
                    }
                    result.unicodeScalars.append(decoded)
                default: return nil
                }
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return nil
    }

    private static func flowList(_ text: String) -> Value? {
        guard text.unicodeScalars.first == "[", text.unicodeScalars.last == "]", text.unicodeScalars.count >= 2 else {
            return nil
        }
        let inner = text.unicodeScalars.dropFirst().dropLast()
        if inner.allSatisfy({ $0 == " " || $0 == "\t" }) { return .list([]) }
        var items: [String] = []
        var current = ""
        var quote: Unicode.Scalar?
        var escaped = false
        for scalar in inner {
            if let open = quote {
                if escaped {
                    escaped = false
                } else if scalar == "\\" && open == "\"" {
                    escaped = true
                } else if scalar == open {
                    quote = nil
                }
                current.unicodeScalars.append(scalar)
            } else if scalar == "," {
                guard let item = item(current[...], inFlow: true) else { return nil }
                items.append(item)
                current = ""
            } else {
                if scalar == "\"" || scalar == "'" { quote = scalar }
                current.unicodeScalars.append(scalar)
            }
        }
        guard quote == nil, let last = item(current[...], inFlow: true) else { return nil }
        return .list(items + [last])
    }

    private static func blockList(_ lines: [String]) -> Value? {
        var items: [String] = []
        for line in lines {
            let trimmed = line.drop { $0 == " " || $0 == "\t" }
            guard trimmed.hasPrefix("- "), let item = item(trimmed.dropFirst(2), inFlow: false) else { return nil }
            items.append(item)
        }
        return .list(items)
    }

    // MARK: Writing

    static func line(_ key: String, _ value: Value) -> String {
        switch value {
        case .string(let string): return "\(key): \(quoted(string))\n"
        case .list(let items): return "\(key): [\(items.map(quoted).joined(separator: ", "))]\n"
        case .unparsed: return ""
        }
    }

    static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// `2026-10-06T15:00:00Z`.
    public static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// ISO 8601 in UTC (`Z`), with optional fractional seconds.
    static func isTimestamp(_ value: String) -> Bool {
        guard value.hasSuffix("Z") else { return false }
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value) != nil
    }
}

/// Helper and tool diagnostics with a stable `code`. Messages never include document text.
public enum MemoryEnvelopeError: Error, Equatable, Sendable {
    /// A Silkweb envelope that the subset can't read; `line` is 1-based in the document.
    case malformed(line: Int)
    /// A `silkweb-memory/vN` schema newer than this build supports.
    case schemaNewer(String)
    /// Create-time validation: a v1 key is missing or its value is invalid.
    case invalidField(String)

    public var code: String {
        switch self {
        case .malformed: return "envelope_malformed"
        case .schemaNewer: return "envelope_schema_newer"
        case .invalidField: return "envelope_invalid_field"
        }
    }

    /// `name` is the document's display name (its filename without `.md`).
    public func message(name: String) -> String {
        switch self {
        case .malformed(let line):
            return "The front matter in “\(name)” couldn’t be read (line \(line)). The document is unchanged."
        case .schemaNewer(let schema):
            return "“\(name)” uses schema “\(schema)”, which this version of Silkweb doesn’t support. "
                + "The document is unchanged."
        case .invalidField(let key):
            return "The front matter field “\(key)” is missing or invalid."
        }
    }
}

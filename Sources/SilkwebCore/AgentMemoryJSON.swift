import Foundation

/// JSON with keys in a fixed order, so search and read output stays stable for scripts
/// (`JSONSerialization` can only sort keys). Rendered like the other helper commands.
public indirect enum AgentJSON: Sendable {
    case object([(String, AgentJSON)])
    case array([AgentJSON])
    case string(String)
    case int(Int)
    case bool(Bool)
    case null

    static func optional(_ value: String?) -> Self { value.map(Self.string) ?? .null }

    /// A `JSONSerialization`-style value (dictionaries, arrays, strings, numbers, `NSNull`), with
    /// object keys sorted. Anything else becomes `null`.
    public init(sortingKeysOf value: Any) {
        switch value {
        case let object as [String: Any]:
            self = .object(object.keys.sorted().map { ($0, AgentJSON(sortingKeysOf: object[$0]!)) })
        case let array as [Any]: self = .array(array.map(AgentJSON.init(sortingKeysOf:)))
        case let string as String: self = .string(string)
        case let number as NSNumber:
            self = CFGetTypeID(number) == CFBooleanGetTypeID() ? .bool(number.boolValue) : .int(number.intValue)
        case let bool as Bool: self = .bool(bool)
        case let int as Int: self = .int(int)
        default: self = .null
        }
    }

    /// Indented like `JSONSerialization`'s pretty printing, with a final line break.
    public var rendered: String { rendered(pretty: true) }

    /// One line (`{"a":1}`) unless `pretty`, always followed by a line break.
    public func rendered(pretty: Bool) -> String {
        var output = ""
        render(into: &output, indent: pretty ? "" : nil)
        return output + "\n"
    }

    /// `indent` is `nil` for compact output.
    private func render(into output: inout String, indent: String?) {
        let inner = indent.map { $0 + "  " }
        let open = inner == nil ? "" : "\n"
        switch self {
        case .object(let pairs) where pairs.isEmpty: output += "{}"
        case .array(let items) where items.isEmpty: output += "[]"
        case .object(let pairs):
            output += "{" + open
            for (offset, pair) in pairs.enumerated() {
                output += (inner ?? "") + Self.quoted(pair.0) + (inner == nil ? ":" : " : ")
                pair.1.render(into: &output, indent: inner)
                output += (offset == pairs.count - 1 ? "" : ",") + open
            }
            output += (indent ?? "") + "}"
        case .array(let items):
            output += "[" + open
            for (offset, item) in items.enumerated() {
                output += inner ?? ""
                item.render(into: &output, indent: inner)
                output += (offset == items.count - 1 ? "" : ",") + open
            }
            output += (indent ?? "") + "]"
        case .string(let string): output += Self.quoted(string)
        case .int(let value): output += String(value)
        case .bool(let value): output += value ? "true" : "false"
        case .null: output += "null"
        }
    }

    private static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20: result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

extension AgentMemoryDocumentInfo {
    /// The documented field order: title, path, documentId, memoryId, revision, type, project, status,
    /// agent, session, createdAt, modified, review, pinned, supersededBy.
    var jsonFields: [(String, AgentJSON)] {
        [
            ("title", .string(title)), ("path", .string(path)), ("documentId", .optional(documentID?.uuidString)),
            ("memoryId", .optional(memoryID)), ("revision", .string(revision)), ("type", .optional(type)),
            ("project", .optional(project)), ("status", .optional(status)), ("agent", .optional(agent)),
            ("session", .optional(session)), ("createdAt", .optional(createdAt)),
            ("modified", .string(ISO8601DateFormatter().string(from: modified))),
            ("review", .string(review.rawValue)), ("pinned", .bool(pinned)),
            ("supersededBy", .array(supersededBy.map(AgentJSON.string))),
        ]
    }
}

extension AgentMemoryFreshness {
    /// `state`, `indexed`, `total`, then `skipped` and `reason` when they apply, then the spelled-out line.
    public var json: AgentJSON {
        var fields: [(String, AgentJSON)] = [
            ("state", .string(state.rawValue)), ("indexed", .int(indexed)), ("total", .int(total)),
        ]
        if skipped > 0 { fields.append(("skipped", .int(skipped))) }
        if let reason { fields.append(("reason", .string(reason.rawValue))) }
        fields.append(("message", .string(message)))
        return .object(fields)
    }
}

extension AgentMemorySearchResponse {
    public var json: AgentJSON {
        let rows = results.map { result in
            AgentJSON.object(
                result.document.jsonFields + [
                    ("matchKind", .string(result.matchKind.rawValue)), ("excerpt", .string(result.excerpt)),
                ])
        }
        var fields: [(String, AgentJSON)] = [("results", .array(rows)), ("total", .int(total)), ("index", index.json)]
        if let message { fields.append(("message", .string(message))) }
        return .object(fields)
    }
}

extension AgentMemoryReadResponse {
    /// The document's fields, then the envelope as structured data, then one bounded page of the body.
    public var json: AgentJSON {
        let envelope = self.envelope.map { fields in
            AgentJSON.object(
                fields.map { field in
                    switch field.value {
                    case .string(let value): return (field.key, .string(value))
                    case .list(let items): return (field.key, .array(items.map(AgentJSON.string)))
                    case .unparsed: return (field.key, .null)
                    }
                })
        }
        return .object(
            document.jsonFields + [
                ("envelope", envelope ?? .null), ("revisionChanged", .bool(revisionChanged)),
                ("offset", .int(offset)), ("body", .string(body)), ("nextCursor", .optional(nextCursor)),
            ])
    }
}

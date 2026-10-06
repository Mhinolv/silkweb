import Foundation

public enum TableAlignment: String, Codable, CaseIterable, Sendable {
    case `default`, left, center, right
    public var title: String { rawValue.capitalized }
    public var marker: String {
        switch self {
        case .default: return "---"
        case .left: return ":---"
        case .center: return ":---:"
        case .right: return "---:"
        }
    }
}

/// Versioned, tolerant defaults for the insertion sheet. Dimensions are always bounded.
public struct TableOptions: Codable, Equatable, Sendable {
    public var version = 1
    public var columns: Int
    public var rows: Int
    public var alignment: TableAlignment
    public init(columns: Int = 3, rows: Int = 2, alignment: TableAlignment = .default) {
        self.columns = min(20, max(1, columns))
        self.rows = min(100, max(1, rows))
        self.alignment = alignment
    }
    private enum CodingKeys: String, CodingKey { case version, columns, rows, alignment }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            columns: (try? values.decode(Int.self, forKey: .columns)) ?? 3,
            rows: (try? values.decode(Int.self, forKey: .rows)) ?? 2,
            alignment: (try? values.decode(TableAlignment.self, forKey: .alignment)) ?? .default)
    }
    public static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: "tableOptions"),
            let value = try? JSONDecoder().decode(Self.self, from: data)
        else { return Self() }
        return value
    }
    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: "tableOptions") }
    }
    public static func dimension(_ input: String, within bounds: ClosedRange<Int>) -> Int? {
        guard let number = Int(input.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return min(bounds.upperBound, max(bounds.lowerBound, number))
    }
}

public enum MarkdownTable {
    public static func escape(_ cell: String) -> String {
        cell.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
    public static func source(options: TableOptions, headers: [String]? = nil) -> String {
        let options = TableOptions(columns: options.columns, rows: options.rows, alignment: options.alignment)
        let cells = (0..<options.columns).map { index in
            escape(headers.flatMap { index < $0.count ? $0[index] : nil } ?? "Column \(index + 1)")
        }
        // Compact GFM: one space on each side of every pipe, no column padding (cells drift once edited).
        func row(_ values: [String]) -> String { "| " + values.joined(separator: " | ") + " |" }
        let separators = Array(repeating: options.alignment.marker, count: options.columns)
        return
            ([row(cells), row(separators)]
            + Array(repeating: row(Array(repeating: "", count: options.columns)), count: options.rows)).joined(
                separator: "\n")
    }
    public static func insertion(text: String, selection: NSRange, options: TableOptions) -> MarkdownEdit {
        let source = text as NSString
        let range = MarkdownEditing.safeRange(selection, in: source)
        let before = source.substring(to: range.location)
        let after = source.substring(from: NSMaxRange(range))
        func padding(_ value: String, before: Bool) -> String {
            if value.isEmpty { return "" }
            let edge = before ? Array(value.reversed().prefix(2)) : Array(value.prefix(2))
            return String(repeating: "\n", count: max(0, 2 - edge.prefix { $0 == "\n" }.count))
        }
        let prefix = padding(before, before: true)
        let replacement = prefix + self.source(options: options) + padding(after, before: false)
        return MarkdownEdit(
            range: range, replacement: replacement,
            selection: NSRange(location: range.location + prefix.utf16.count + 2, length: 8))
    }
}

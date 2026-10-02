import Foundation

/// Versioned settings payload for the writing preferences UI (1.24).
/// Older payloads may omit any key; explicit choices always win.
public struct WritingPreferences: Codable, Equatable, Sendable {
    public var version = 1
    public var fontFamily = "Menlo"
    public var fontSize = 15.0
    public var lineHeight = 1.6
    public var maximumWidth = 720.0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, fontFamily, fontSize, lineHeight, maximumWidth
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        fontFamily = try values.decodeIfPresent(String.self, forKey: .fontFamily) ?? "Menlo"
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 15
        lineHeight = try values.decodeIfPresent(Double.self, forKey: .lineHeight) ?? 1.6
        maximumWidth = try values.decodeIfPresent(Double.self, forKey: .maximumWidth) ?? 720
        if fontFamily.isEmpty { fontFamily = "Menlo" }
        if !fontSize.isFinite || fontSize <= 0 { fontSize = 15 }
        if !lineHeight.isFinite || lineHeight <= 0 { lineHeight = 1.6 }
        if !maximumWidth.isFinite || maximumWidth <= 0 { maximumWidth = 720 }
    }

    /// No payload existed before 1.47. Reading does not rewrite user settings.
    public static func load(from defaults: UserDefaults = .standard) -> WritingPreferences {
        guard let data = defaults.data(forKey: "writingPreferences"),
              let preferences = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return preferences
    }
}

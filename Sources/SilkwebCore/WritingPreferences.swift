import Foundation

/// Versioned settings payload for the Settings window (1.24).
/// Older payloads may omit any key; explicit choices always win. Out-of-range numbers clamp,
/// non-positive or non-finite numbers fall back to the documented default.
public struct WritingPreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public static let defaultsKey = "writingPreferences"

    public enum Indent: String, Codable, CaseIterable, Sendable {
        case twoSpaces, fourSpaces, tab
        public var text: String { switch self { case .twoSpaces: "  "; case .fourSpaces: "    "; case .tab: "\t" } }
        public var title: String { switch self { case .twoSpaces: "2 Spaces"; case .fourSpaces: "4 Spaces"; case .tab: "Tab" } }
    }

    public enum PreviewFont: String, Codable, CaseIterable, Sendable {
        case system, serif
        public var title: String { switch self { case .system: "System"; case .serif: "Serif (New York)" } }
        public var css: String { switch self { case .system: "-apple-system"; case .serif: "'New York', ui-serif, Georgia, serif" } }
    }

    public enum AppearanceMode: String, Codable, CaseIterable, Sendable {
        case system, light, dark
        public var title: String { switch self { case .system: "Match System"; case .light: "Light"; case .dark: "Dark" } }
    }

    /// Built-in editor font choices; any other value is a custom family from the font panel.
    public static let builtInFonts = ["Menlo", "Monospaced", "System", "Serif"]
    public static let fontSizes = 10.0...32
    public static let lineHeights = [1.2, 1.35, 1.6, 1.75, 2.0]
    public static let horizontalInsets = 24.0...120
    public static let maximumWidths = 480.0...1200
    public static let previewFontSizes = 12.0...24

    public var version = currentVersion
    // Editor
    public var fontFamily = "Menlo"
    public var fontSize = 15.0
    public var lineHeight = 1.6
    public var horizontalInset = 48.0
    public var maximumWidth = 660.0
    public var indent = Indent.fourSpaces
    public var checksSpelling = true
    public var smartPunctuation = false
    public var showsInlineImages = true
    public var highlightsCurrentLine = false
    public var reopensSession = true
    // Preview
    public var previewFont = PreviewFont.system
    public var previewFontSize = 16.0
    public var keepsLineBreaks = false
    public var showsTableOfContents = true
    // Appearance
    public var appearance = AppearanceMode.system
    public var colors = ColorPreferences()

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case version, fontFamily, fontSize, lineHeight, horizontalInset, maximumWidth, indent, checksSpelling,
             smartPunctuation, showsInlineImages, highlightsCurrentLine, reopensSession, previewFont,
             previewFontSize, keepsLineBreaks, showsTableOfContents, appearance, colors
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? values.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let defaults = WritingPreferences()
        // Older payloads are migrated in memory; the next save writes the current version.
        version = Self.currentVersion
        fontFamily = value(.fontFamily, defaults.fontFamily)
        if fontFamily.trimmingCharacters(in: .whitespaces).isEmpty { fontFamily = defaults.fontFamily }
        fontSize = Self.clamp(value(.fontSize, defaults.fontSize), Self.fontSizes, fallback: defaults.fontSize)
        lineHeight = Self.snapLineHeight(value(.lineHeight, defaults.lineHeight))
        horizontalInset = Self.clamp(value(.horizontalInset, defaults.horizontalInset), Self.horizontalInsets, fallback: defaults.horizontalInset)
        maximumWidth = Self.clamp(value(.maximumWidth, defaults.maximumWidth), Self.maximumWidths, fallback: defaults.maximumWidth)
        indent = value(.indent, defaults.indent)
        checksSpelling = value(.checksSpelling, defaults.checksSpelling)
        smartPunctuation = value(.smartPunctuation, defaults.smartPunctuation)
        showsInlineImages = value(.showsInlineImages, defaults.showsInlineImages)
        highlightsCurrentLine = value(.highlightsCurrentLine, defaults.highlightsCurrentLine)
        reopensSession = value(.reopensSession, defaults.reopensSession)
        previewFont = value(.previewFont, defaults.previewFont)
        previewFontSize = Self.clamp(value(.previewFontSize, defaults.previewFontSize), Self.previewFontSizes, fallback: defaults.previewFontSize)
        keepsLineBreaks = value(.keepsLineBreaks, defaults.keepsLineBreaks)
        showsTableOfContents = value(.showsTableOfContents, defaults.showsTableOfContents)
        appearance = value(.appearance, defaults.appearance)
        colors = value(.colors, defaults.colors)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        try values.encode(fontFamily, forKey: .fontFamily)
        try values.encode(fontSize, forKey: .fontSize)
        try values.encode(lineHeight, forKey: .lineHeight)
        try values.encode(horizontalInset, forKey: .horizontalInset)
        try values.encode(maximumWidth, forKey: .maximumWidth)
        try values.encode(indent, forKey: .indent)
        try values.encode(checksSpelling, forKey: .checksSpelling)
        try values.encode(smartPunctuation, forKey: .smartPunctuation)
        try values.encode(showsInlineImages, forKey: .showsInlineImages)
        try values.encode(highlightsCurrentLine, forKey: .highlightsCurrentLine)
        try values.encode(reopensSession, forKey: .reopensSession)
        try values.encode(previewFont, forKey: .previewFont)
        try values.encode(previewFontSize, forKey: .previewFontSize)
        try values.encode(keepsLineBreaks, forKey: .keepsLineBreaks)
        try values.encode(showsTableOfContents, forKey: .showsTableOfContents)
        try values.encode(appearance, forKey: .appearance)
        try values.encode(colors, forKey: .colors)
    }

    /// Non-finite or non-positive values are corrupt and use the default; others clamp to the range.
    public static func clamp(_ value: Double, _ range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite, value > 0 else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// Line spacing is one of five options; legacy values (1.5) snap to the nearest (1.6, ties go up).
    public static func snapLineHeight(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 1.6 }
        return lineHeights.min { abs($0 - value) < abs($1 - value) || (abs($0 - value) == abs($1 - value) && $0 > $1) } ?? 1.6
    }

    // MARK: Restore Defaults (one tab at a time)

    public var editorIsDefault: Bool {
        var copy = self
        copy.restoreEditorDefaults()
        return copy == self
    }

    public mutating func restoreEditorDefaults() {
        let defaults = WritingPreferences()
        fontFamily = defaults.fontFamily; fontSize = defaults.fontSize; lineHeight = defaults.lineHeight
        horizontalInset = defaults.horizontalInset; maximumWidth = defaults.maximumWidth; indent = defaults.indent
        checksSpelling = defaults.checksSpelling; smartPunctuation = defaults.smartPunctuation
        showsInlineImages = defaults.showsInlineImages; highlightsCurrentLine = defaults.highlightsCurrentLine
        reopensSession = defaults.reopensSession
    }

    public var previewIsDefault: Bool {
        var copy = self
        copy.restorePreviewDefaults()
        return copy == self
    }

    public mutating func restorePreviewDefaults() {
        let defaults = WritingPreferences()
        previewFont = defaults.previewFont; previewFontSize = defaults.previewFontSize
        keepsLineBreaks = defaults.keepsLineBreaks; showsTableOfContents = defaults.showsTableOfContents
    }

    // MARK: Persistence

    /// Reading does not rewrite user settings.
    public static func load(from defaults: UserDefaults = .standard) -> WritingPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return preferences
    }

    /// UserDefaults replaces its stored value atomically.
    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// Live preview variables only; export and print never include them, so they keep portable colours.
    /// Colour variables are emitted only for slots the user changed, per appearance.
    public var previewCSS: String {
        var css = ":root { --sw-font-family: \(previewFont.css); --sw-font-size: \(Self.number(previewFontSize))px; }\n"
            + "body { font-family: var(--sw-font-family); font-size: var(--sw-font-size); color: var(--sw-text, -apple-system-label); }"
        for dark in [false, true] {
            let set = colors[dark: dark]
            let rules = ColorSlot.allCases.compactMap { slot in set[slot].map { "--sw-\(slot.cssName): \($0.hex);" } }
            guard !rules.isEmpty else { continue }
            css += "\n@media (prefers-color-scheme: \(dark ? "dark" : "light")) { :root { \(rules.joined(separator: " ")) } }"
        }
        return css
    }

    private static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }
}

/// One user colour, stored as "#RRGGBB".
public struct HexColor: Codable, Hashable, Sendable {
    public var rgb: Int

    public init(_ rgb: Int) { self.rgb = rgb & 0xFFFFFF }

    public init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = Int(text, radix: 16) else { return nil }
        rgb = value
    }

    public var hex: String { String(format: "#%06X", rgb) }
    public var red: Double { Double((rgb >> 16) & 255) / 255 }
    public var green: Double { Double((rgb >> 8) & 255) / 255 }
    public var blue: Double { Double(rgb & 255) / 255 }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let value = HexColor(hex: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid colour \(text)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// WCAG 2 relative luminance.
    public var luminance: Double {
        func channel(_ value: Double) -> Double { value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    /// WCAG contrast ratio, 1…21.
    public static func contrast(_ a: HexColor, _ b: HexColor) -> Double {
        let (high, low) = (max(a.luminance, b.luminance), min(a.luminance, b.luminance))
        return (high + 0.05) / (low + 0.05)
    }

    /// `amount` of `other` over `self`, in sRGB.
    public func mixed(with other: HexColor, _ amount: Double) -> HexColor {
        func mix(_ a: Int, _ b: Int) -> Int { Int((Double(a) + (Double(b) - Double(a)) * amount).rounded()) }
        let shifts = [16, 8, 0]
        return HexColor(shifts.reduce(0) { $0 | (mix((rgb >> $1) & 255, (other.rgb >> $1) & 255) << $1) })
    }
}

/// User-editable colour slots (1.24). Hairline and selection capsules are derived, never edited.
public enum ColorSlot: String, Codable, CaseIterable, Sendable {
    case surface, text, headings, accent, coral

    public var cssName: String { switch self { case .surface: "surface"; case .text: "text"; case .headings: "heading"; case .accent: "accent"; case .coral: "coral" } }

    /// Defaults match the 1.62 tokens; Text approximates `labelColor` over the default surface.
    public func defaultColor(dark: Bool) -> HexColor {
        switch self {
        case .surface: HexColor(dark ? 0x1E1F21 : 0xFBFBFA)
        case .text: HexColor(dark ? 0xDCDCDC : 0x262626)
        case .headings: HexColor(dark ? 0x86BCD6 : 0x2A6A86)
        case .accent: HexColor(dark ? 0x7FC0A4 : 0x3F7D64)
        case .coral: HexColor(dark ? 0xF29A7A : 0xCC6544)
        }
    }
}

/// One appearance's overrides. `nil` keeps the built-in token (with its Increase Contrast value).
public struct ColorSet: Codable, Equatable, Sendable {
    public var surface: HexColor?
    public var text: HexColor?
    public var headings: HexColor?
    public var accent: HexColor?
    public var coral: HexColor?

    public init() {}

    private enum CodingKeys: String, CodingKey { case surface, text, headings, accent, coral }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        func color(_ key: CodingKeys) -> HexColor? { (try? values.decodeIfPresent(HexColor.self, forKey: key)) ?? nil }
        surface = color(.surface); text = color(.text); headings = color(.headings); accent = color(.accent); coral = color(.coral)
    }

    public subscript(slot: ColorSlot) -> HexColor? {
        get {
            switch slot { case .surface: surface; case .text: text; case .headings: headings; case .accent: accent; case .coral: coral }
        }
        set {
            switch slot {
            case .surface: surface = newValue
            case .text: text = newValue
            case .headings: headings = newValue
            case .accent: accent = newValue
            case .coral: coral = newValue
            }
        }
    }

    public var isDefault: Bool { self == ColorSet() }

    /// The chosen colour, or the documented default.
    public func resolved(_ slot: ColorSlot, dark: Bool) -> HexColor { self[slot] ?? slot.defaultColor(dark: dark) }

    /// Focused selection capsule: Accent at 14% (light) or 22% (dark) over Surface.
    public func selection(dark: Bool) -> HexColor {
        resolved(.surface, dark: dark).mixed(with: resolved(.accent, dark: dark), dark ? 0.22 : 0.14)
    }

    /// Inactive capsule and current-line band: Surface stepped 4% toward Text.
    public func selectionInactive(dark: Bool) -> HexColor {
        resolved(.surface, dark: dark).mixed(with: resolved(.text, dark: dark), 0.04)
    }

    /// Pane dividers and thread lines: Surface stepped 10% toward Text.
    public func hairline(dark: Bool) -> HexColor {
        resolved(.surface, dark: dark).mixed(with: resolved(.text, dark: dark), 0.10)
    }

    public enum ContrastWarning: Equatable, Sendable {
        case text(Double), headings(Double)

        public var message: String {
            switch self {
            case .text(let ratio): "Text is hard to read on this surface (\(Self.format(ratio)):1). Aim for at least 4.5:1."
            case .headings(let ratio): "Headings are hard to read on this surface (\(Self.format(ratio)):1). Aim for at least 3:1."
            }
        }

        static func format(_ ratio: Double) -> String { String(format: "%.1f", (ratio * 10).rounded(.down) / 10) }
    }

    /// Text/Surface under 4.5:1 or Headings/Surface under 3:1. Non-blocking.
    public func contrastWarning(dark: Bool) -> ContrastWarning? {
        let surface = resolved(.surface, dark: dark)
        let text = HexColor.contrast(resolved(.text, dark: dark), surface)
        if text < 4.5 { return .text(text) }
        let headings = HexColor.contrast(resolved(.headings, dark: dark), surface)
        if headings < 3 { return .headings(headings) }
        return nil
    }
}

/// Colour overrides kept separately for Light and Dark.
public struct ColorPreferences: Codable, Equatable, Sendable {
    public var light = ColorSet()
    public var dark = ColorSet()

    public init() {}

    private enum CodingKeys: String, CodingKey { case light, dark }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        light = (try? values.decodeIfPresent(ColorSet.self, forKey: .light)) ?? ColorSet()
        dark = (try? values.decodeIfPresent(ColorSet.self, forKey: .dark)) ?? ColorSet()
    }

    public subscript(dark dark: Bool) -> ColorSet {
        get { dark ? self.dark : light }
        set { if dark { self.dark = newValue } else { light = newValue } }
    }
}

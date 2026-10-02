import Foundation

/// Shared visible and spoken counts. Numbers use the current locale's grouping.
public enum CountPresentation {
    public enum Unit: String, CaseIterable, Sendable {
        case document, result, heading
    }

    public static func label(_ count: Int, unit: Unit) -> String {
        "\(count.formatted()) \(unit.rawValue)\(count == 1 ? "" : "s")"
    }
}

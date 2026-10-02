import Foundation

/// Presentation metrics for a heading miniature, independent of the UI framework.
public struct OutlineRowStyle: Equatable, Sendable {
    public let fontSize: Double
    public let isSemibold: Bool
    public let indent: Double
    public let spacingAbove: Double

    public init(level: Int, shallowest: Int, isFirst: Bool) {
        let level = min(6, max(1, level))
        let shallowest = min(6, max(1, shallowest))
        fontSize = [15, 14, 13, 12, 11, 11][level - 1]
        isSemibold = level <= 2
        indent = Double(max(0, level - shallowest)) * 12
        spacingAbove = level == 1 && !isFirst ? 6 : level == 2 ? 2 : 0
    }
}

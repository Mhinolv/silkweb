import Foundation

/// Presentation metrics for a heading miniature, independent of the UI framework.
public struct OutlineRowStyle: Equatable, Sendable {
    public static let indentStep = 10.0
    public static let maximumDepth = 4

    public let fontSize: Double
    public let isSemibold: Bool
    public let indent: Double
    public let spacingAbove: Double

    /// `depth` is the row's tree depth (`OutlineItem.depth`), not its `#` level.
    public init(level: Int, depth: Int, isFirst: Bool) {
        let level = min(6, max(1, level))
        fontSize = [15, 14, 13, 12, 11, 11][level - 1]
        isSemibold = level <= 2
        indent = Self.indent(depth: depth)
        spacingAbove = level == 1 && !isFirst ? 6 : level == 2 ? 2 : 0
    }

    /// Shared by heading and image rows so an image lines up with a child heading's text.
    public static func indent(depth: Int) -> Double {
        Double(min(maximumDepth, max(0, depth))) * indentStep
    }
}

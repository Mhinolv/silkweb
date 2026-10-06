import Foundation

/// Presentation metrics for an Outline row (#72 thread tree), independent of the UI framework.
/// Hierarchy reads through the sidebar's thread guides, so every heading uses one 13 pt size.
public struct OutlineRowStyle: Equatable, Sendable {
    public static let indentStep = 12.0
    public static let maximumDepth = 4
    public static let fontSize = 13.0
    public static let rowHeight = 28.0

    /// H1 semibold, H2 regular, H3 and deeper secondary.
    public let isSemibold: Bool
    public let isSecondary: Bool
    public let indent: Double

    /// `depth` is the row's tree depth (`OutlineItem.depth`), not its `#` level.
    public init(level: Int, depth: Int) {
        let level = min(6, max(1, level))
        isSemibold = level == 1
        isSecondary = level >= 3
        indent = Self.indent(depth: depth)
    }

    /// Shared by heading and image rows so an image hangs from the thread like a child heading.
    /// Depth 0 sits at the guide column's edge; deeper rows start 3 pt past their elbow.
    public static func indent(depth: Int) -> Double {
        let depth = min(maximumDepth, max(0, depth))
        return depth == 0 ? 0 : Double(depth) * indentStep + 4
    }

    /// Thread geometry in the row's text-column coordinates. The Outline has no disclosure slot, so the
    /// "icon" an elbow points at is the row's text at `indent(depth:)`.
    public static func threadMetrics(rowHeight: Double = rowHeight) -> ThreadGuides.Metrics {
        ThreadGuides.Metrics(leadingInset: -1, indentation: indentStep, slotWidth: 12, chevronWidth: 9, iconInset: -7, rowHeight: rowHeight)
    }

    /// One row's thread: what `ThreadGuides.segments` needs, from the depths of every visible row.
    public struct Thread: Equatable, Sendable {
        public var level: Int
        public var isLastChild: Bool
        public var ancestorContinues: [Bool]

        public func segments(rowHeight: Double = OutlineRowStyle.rowHeight) -> [ThreadGuides.Segment] {
            ThreadGuides.segments(level: level, isLastChild: isLastChild, ancestorContinues: ancestorContinues,
                                  hasChildren: false, metrics: OutlineRowStyle.threadMetrics(rowHeight: rowHeight))
        }
    }

    /// Depths are clamped to `maximumDepth` like the indent. One backward pass: a rail continues through a row
    /// while a later row at that depth follows before any shallower row closes the branch.
    public static func threads(depths: [Int]) -> [Thread] {
        var following = [Bool](repeating: false, count: maximumDepth + 1)
        var result: [Thread] = []
        result.reserveCapacity(depths.count)
        for raw in depths.reversed() {
            let depth = min(maximumDepth, max(0, raw))
            result.append(Thread(level: depth, isLastChild: !following[depth],
                                 ancestorContinues: depth > 1 ? Array(following[1..<depth]) : []))
            for k in following.indices where k > depth { following[k] = false }
            following[depth] = true
        }
        return result.reversed()
    }
}

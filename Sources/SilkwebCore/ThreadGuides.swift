import Foundation

/// Sidebar thread guides (silkweb-1.63): the geometry of one outline row, independent of the UI framework.
/// x is in outline coordinates; y is measured down from the row's top edge.
public enum ThreadGuides {
    public struct Metrics: Equatable, Sendable {
        /// x where the level-0 disclosure slot starts.
        public var leadingInset: Double
        public var indentation: Double
        public var slotWidth: Double
        /// The disclosure glyph, centred in its slot.
        public var chevronWidth: Double
        /// The row icon's offset from the end of its slot.
        public var iconInset: Double
        public var rowHeight: Double
        public var radius = 6.0
        /// Space left between a horizontal and the chevron or icon it points at.
        public var gap = 3.0

        public init(leadingInset: Double, indentation: Double = 16, slotWidth: Double = 13, chevronWidth: Double = 9,
                    iconInset: Double = 2, rowHeight: Double = 28) {
            self.leadingInset = leadingInset
            self.indentation = indentation
            self.slotWidth = slotWidth
            self.chevronWidth = chevronWidth
            self.iconInset = iconInset
            self.rowHeight = rowHeight
        }

        func slotMinX(_ level: Int) -> Double { leadingInset + Double(max(0, level)) * indentation }
    }

    public enum Segment: Equatable, Sendable {
        /// A full-height vertical.
        case rail(x: Double)
        /// Down from the row top to `cornerY − radius`, a quarter arc, then across to `endX` at `cornerY`.
        case elbow(x: Double, cornerY: Double, radius: Double, endX: Double)
    }

    /// The guide children of a row at `level` hang from: the centre of its chevron slot.
    public static func guideX(level: Int, metrics: Metrics) -> Double {
        metrics.slotMinX(level) + metrics.slotWidth / 2
    }

    public static func chevronMinX(level: Int, metrics: Metrics) -> Double {
        metrics.slotMinX(level) + (metrics.slotWidth - metrics.chevronWidth) / 2
    }

    public static func iconMinX(level: Int, metrics: Metrics) -> Double {
        metrics.slotMinX(level) + metrics.slotWidth + metrics.iconInset
    }

    /// `ancestorContinues[k]` is true when the row's ancestor at level `k + 1` has a following sibling,
    /// so the rail at `guideX(k)` passes through this row. Level-0 rows hang from nothing.
    public static func segments(level: Int, isLastChild: Bool, ancestorContinues: [Bool], hasChildren: Bool,
                                metrics: Metrics) -> [Segment] {
        guard level > 0 else { return [] }
        var result: [Segment] = []
        for k in 0..<(level - 1) where k < ancestorContinues.count && ancestorContinues[k] {
            result.append(.rail(x: guideX(level: k, metrics: metrics)))
        }
        let x = guideX(level: level - 1, metrics: metrics)
        if !isLastChild { result.append(.rail(x: x)) }
        let target = hasChildren ? chevronMinX(level: level, metrics: metrics) : iconMinX(level: level, metrics: metrics)
        result.append(.elbow(x: x, cornerY: metrics.rowHeight / 2, radius: metrics.radius,
                             endX: max(x + metrics.radius, target - metrics.gap)))
        return result
    }
}

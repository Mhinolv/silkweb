import Foundation

/// The detail status bar's three zones (#91): the path leads, the counts sit on the bar's midline, and the
/// Focus/Typewriter chip and save state trail. Widths in points, measured by the caller.
public struct StatusBarArrangement: Equatable, Sendable {
    /// The path's width from `pathLeading`; the path runs its own `…` ladder inside it.
    public var pathWidth: Double
    /// The counts' leading edge and width; a width of 0 hides them.
    public var countsX: Double
    public var countsWidth: Double
    /// Where the trailing cluster starts.
    public var trailingX: Double

    public var showsCounts: Bool { countsWidth > 0 }

    /// Applied in order until everything fits; zones never overlap and stay `gap` apart:
    /// 1. the trailing cluster never shrinks;
    /// 2. the path takes the room up to the centred counts (`…` ladder), never less than its folded minimum;
    /// 3. a path that still doesn't fit pushes the counts off-centre toward the trailing side;
    /// 4. the counts narrow (the caller drops characters, then tail-truncates) down to `countsMinimum`;
    /// 5. the counts hide, and the path takes what is left.
    /// `counts` reports the width the counts take when offered a width (their ideal for `.infinity`).
    public static func arrange(
        width: Double, pathLeading: Double, trailingEdge: Double, gap: Double,
        pathMinimum: Double, pathIdeal: Double, counts: (Double) -> Double, countsMinimum: Double,
        trailing: Double
    ) -> StatusBarArrangement {
        let trailingX = trailingEdge - trailing
        let midline = width / 2
        let ideal = counts(.infinity)
        var pathWidth = min(pathIdeal, max(pathMinimum, midline - ideal / 2 - gap - pathLeading))
        let low = pathLeading + pathWidth + gap
        let high = trailingX - gap
        var countsWidth = 0.0
        var countsX = low
        if high - low >= ideal {
            countsWidth = ideal
            countsX = min(max(midline - ideal / 2, low), high - ideal)
        } else if high - low >= countsMinimum {
            // Narrowed counts may come out shorter than offered; keep them as close to the midline as allowed.
            countsWidth = min(counts(high - low), high - low)
            countsX = min(max(midline - countsWidth / 2, low), high - countsWidth)
        } else {
            pathWidth = min(pathIdeal, max(0, trailingX - gap - pathLeading))
        }
        return StatusBarArrangement(
            pathWidth: pathWidth, countsX: countsX, countsWidth: countsWidth, trailingX: trailingX)
    }
}

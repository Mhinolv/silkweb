import Foundation

/// A line diff for the Proposal review pane (#140): which lines of the current text an edit removes and which
/// lines of the proposed text it adds. Myers' O(ND) algorithm on lines after trimming the common prefix and
/// suffix; past `maxEdits` the changed middle is reported as all removed and all added, so a huge rewrite never
/// takes long or much memory.
public struct LineDiff: Equatable, Sendable {
    /// Indices into `old.lines` that the proposal removes.
    public var removed: Set<Int>
    /// Indices into `new.lines` that the proposal adds.
    public var added: Set<Int>

    public static let maxEdits = 2_000

    public var isEmpty: Bool { removed.isEmpty && added.isEmpty }

    /// `\n`, `\r\n` and `\r` end a line, as they do for the text views.
    static func isBreak(_ character: Character) -> Bool {
        character == "\n" || character == "\r\n" || character == "\r"
    }

    /// Lines without their terminators; a trailing line break doesn't add an empty last line.
    public static func lines(_ text: String) -> [Substring] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: isBreak)
        if let last = text.last, isBreak(last) { lines.removeLast() }
        return lines
    }

    /// Each line's UTF-16 range without its terminator, in the same order and number as `lines(_:)`, for drawing.
    public static func lineRanges(_ text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        var start = 0
        var offset = 0
        var endsWithBreak = false
        for character in text {
            let length = character.utf16.count
            endsWithBreak = isBreak(character)
            if endsWithBreak {
                ranges.append(NSRange(location: start, length: offset - start))
                start = offset + length
            }
            offset += length
        }
        if !endsWithBreak { ranges.append(NSRange(location: start, length: offset - start)) }
        return ranges
    }

    public init(old: String, new: String, maxEdits: Int = LineDiff.maxEdits) {
        self.init(old: Self.lines(old), new: Self.lines(new), maxEdits: maxEdits)
    }

    public init(old: [Substring], new: [Substring], maxEdits: Int = LineDiff.maxEdits) {
        removed = []
        added = []
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix] == new[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix] == new[new.count - 1 - suffix]
        {
            suffix += 1
        }
        let a = Array(old[prefix..<(old.count - suffix)])
        let b = Array(new[prefix..<(new.count - suffix)])
        guard !a.isEmpty || !b.isEmpty else { return }
        guard !a.isEmpty, !b.isEmpty, let script = Self.myers(a, b, maxEdits: maxEdits) else {
            removed = Set(a.indices.map { $0 + prefix })
            added = Set(b.indices.map { $0 + prefix })
            return
        }
        removed = Set(script.removed.map { $0 + prefix })
        added = Set(script.added.map { $0 + prefix })
    }

    /// The shortest edit script, or `nil` when it needs more than `maxEdits` edits. Each round keeps only the
    /// diagonals it can reach (`-d - 1 ... d + 1`), so the trace stays O(D²).
    private static func myers(_ a: [Substring], _ b: [Substring], maxEdits: Int) -> (removed: [Int], added: [Int])? {
        let n = a.count
        let m = b.count
        let limit = min(n + m, maxEdits)
        let offset = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var found = false
        outer: for d in 0...limit {
            trace.append(Array(v[(offset - d - 1)...(offset + d + 1)]))
            for k in stride(from: -d, through: d, by: 2) {
                var x =
                    k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1])
                    ? v[offset + k + 1] : v[offset + k - 1] + 1
                var y = x - k
                while x < n, y < m, a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n, y >= m {
                    found = true
                    break outer
                }
            }
        }
        guard found else { return nil }
        // Walk the trace back from (n, m) to recover the edits. `trace[d]` holds round d - 1's diagonals, with
        // diagonal k at index k + d + 1.
        var removed: [Int] = []
        var added: [Int] = []
        var x = n
        var y = m
        for d in stride(from: trace.count - 1, through: 1, by: -1) {
            let v = trace[d]
            let base = d + 1
            let k = x - y
            let previousK = k == -d || (k != d && v[base + k - 1] < v[base + k + 1]) ? k + 1 : k - 1
            let previousX = v[base + previousK]
            let previousY = previousX - previousK
            while x > previousX, y > previousY {
                x -= 1
                y -= 1
            }
            if x == previousX {
                added.append(y - 1)
            } else {
                removed.append(x - 1)
            }
            x = previousX
            y = previousY
        }
        return (removed, added)
    }
}

import Foundation

/// Focus Mode's bright region (silkweb-1.27): the blank-line-delimited block around the
/// selection. A whole fenced code block, a single list item and an ATX heading line are
/// each one unit. Walks lines outward from the selection only (bounded by `lineLimit`),
/// never the whole document.
public enum FocusUnit {
    private static let heading = try! NSRegularExpression(pattern: "^[ \\t]{0,3}#{1,6}([ \\t]|$)")

    /// `fencedBefore` answers whether a line (by its start offset) begins inside a fenced
    /// block, or nil when unknown; unknown lines are derived from the nearest known line above.
    public static func range(in text: NSString, selection: NSRange, lineLimit: Int = 2_000,
                             fencedBefore known: (Int) -> Bool? = { _ in nil }) -> NSRange {
        let length = text.length
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        let start = max(0, min(selection.location, length))
        let end = max(start, min(NSMaxRange(selection), length))
        var cache: [Int: Bool] = [:]
        let fenced: (Int) -> Bool = { line in fencedBefore(line, in: text, known: known, cache: &cache) }
        let first = unit(at: start, in: text, lineLimit: lineLimit, fenced: fenced)
        guard end > start else { return first }
        let last = unit(at: end - 1, in: text, lineLimit: lineLimit, fenced: fenced)
        return NSUnionRange(first, last)
    }

    static func isFence(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("```")
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func isHeading(_ line: String) -> Bool {
        heading.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
    }

    private static func previousLine(before start: Int, in text: NSString) -> NSRange? {
        start > 0 ? text.lineRange(for: NSRange(location: start - 1, length: 0)) : nil
    }

    private static func nextLine(after line: NSRange, in text: NSString) -> NSRange? {
        let next = NSMaxRange(line)
        return next < text.length ? text.lineRange(for: NSRange(location: next, length: 0)) : nil
    }

    private static func fencedBefore(_ line: Int, in text: NSString, known: (Int) -> Bool?, cache: inout [Int: Bool]) -> Bool {
        if let value = cache[line] ?? known(line) { cache[line] = value; return value }
        // Walk up to a known line (or the start), then propagate fence toggles down.
        var cursor = line
        var state = false
        while cursor > 0 {
            cursor = text.lineRange(for: NSRange(location: cursor - 1, length: 0)).location
            if let value = cache[cursor] ?? known(cursor) { state = value; break }
        }
        var position = cursor
        while position < line {
            let range = text.lineRange(for: NSRange(location: position, length: 0))
            if isFence(text.substring(with: range)) { state.toggle() }
            position = NSMaxRange(range)
            cache[position] = state
        }
        cache[line] = state
        return state
    }

    private static func unit(at location: Int, in text: NSString, lineLimit: Int, fenced: (Int) -> Bool) -> NSRange {
        let line = text.lineRange(for: NSRange(location: location, length: 0))
        // The empty line after a final newline.
        guard line.length > 0 else { return line }
        let source = text.substring(with: line)
        let inside = fenced(line.location)
        if inside || isFence(source) {
            var first = line
            if inside {
                var steps = 0
                while fenced(first.location), let previous = previousLine(before: first.location, in: text), steps < lineLimit {
                    first = previous; steps += 1
                }
            }
            var last = line
            // A closing fence ends here; an opening fence or code line runs to the next fence.
            if !(inside && isFence(source)) {
                var steps = 0
                while let next = nextLine(after: last, in: text), steps < lineLimit {
                    last = next; steps += 1
                    if isFence(text.substring(with: next)) { break }
                }
            }
            return NSUnionRange(first, last)
        }
        if isBlank(source) || isHeading(source) { return line }
        func boundary(_ range: NSRange) -> Bool {
            let value = text.substring(with: range)
            return isBlank(value) || isFence(value) || isHeading(value) || fenced(range.location)
        }
        var first = line
        var steps = 0
        while MarkdownEditing.listPrefix(text.substring(with: first)) == nil,
              let previous = previousLine(before: first.location, in: text), !boundary(previous), steps < lineLimit {
            first = previous; steps += 1
        }
        var last = line
        steps = 0
        while let next = nextLine(after: last, in: text), !boundary(next),
              MarkdownEditing.listPrefix(text.substring(with: next)) == nil, steps < lineLimit {
            last = next; steps += 1
        }
        return NSUnionRange(first, last)
    }
}

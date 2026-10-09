import Foundation

/// The library window's one tab strip across its open Libraries (#197). Each Library keeps its own tabs in its own
/// order (saved with that Library); the strip only remembers how they interleave.
public enum TabStripOrder {
    /// Every key of `groups` exactly once, in strip order:
    /// - tabs still open keep their places from `stored`, and the slots a Library already holds are filled with its
    ///   tabs in that Library's own order (a reorder inside one Library shows in the strip);
    /// - a new tab goes right after the tab before it in its Library (a new tab opens next to the active one), else
    ///   right before the tab after it, else at the end of the strip.
    /// Closed tabs and duplicate keys in `stored` are dropped.
    public static func merge<Key: Hashable>(stored: [Key], groups: [[Key]]) -> [Key] {
        var groupOf: [Key: Int] = [:]
        for (index, group) in groups.enumerated() {
            for key in group where groupOf[key] == nil { groupOf[key] = index }
        }
        var seen: Set<Key> = []
        var result = stored.filter { groupOf[$0] != nil && seen.insert($0).inserted }
        // Each Library's own order inside the slots it holds.
        for (index, group) in groups.enumerated() {
            let slots = result.indices.filter { groupOf[result[$0]] == index }
            let ordered = group.filter { seen.contains($0) }
            for (slot, key) in zip(slots, ordered) { result[slot] = key }
        }
        for group in groups {
            for (position, key) in group.enumerated() where !seen.contains(key) {
                if position > 0, let previous = result.firstIndex(of: group[position - 1]) {
                    result.insert(key, at: previous + 1)
                } else if let next = group[(position + 1)...].lazy.compactMap({ result.firstIndex(of: $0) }).first {
                    result.insert(key, at: next)
                } else {
                    result.append(key)
                }
                seen.insert(key)
            }
        }
        return result
    }

    /// `key` moved to the gap before `gap` (0…count) of `strip`; an unknown key leaves the strip as it is.
    public static func move<Key: Equatable>(_ key: Key, toGap gap: Int, in strip: [Key]) -> [Key] {
        guard let old = strip.firstIndex(of: key) else { return strip }
        var result = strip
        result.remove(at: old)
        result.insert(key, at: min(result.count, max(0, gap > old ? gap - 1 : gap)))
        return result
    }
}

/// A tab's title and its “ · <Library>” suffix inside the tab's text budget (#197): the suffix truncates first, so
/// the title keeps its whole width while the suffix takes what is left.
public struct TabTitleWidths: Equatable, Sendable {
    public var title: Double
    public var suffix: Double

    public init(title: Double, suffix: Double) {
        self.title = title
        self.suffix = suffix
    }

    public static func fit(budget: Double, title: Double, suffix: Double) -> TabTitleWidths {
        let budget = max(0, budget)
        let titleWidth = min(budget, max(0, title))
        return TabTitleWidths(title: titleWidth, suffix: min(max(0, suffix), budget - titleWidth))
    }
}

extension SearchResult {
    /// The same row for Search Library or Quick Open across every open Library (#197): its location leads with the
    /// Library's name, and `id` keeps rows from two Libraries apart.
    public func inLibrary(_ name: String, id: UUID) -> SearchResult {
        SearchResult(
            id: id, displayName: displayName, folderPathComponents: [name] + folderPathComponents, modified: modified,
            matchKind: matchKind, snippet: snippet, matchRanges: matchRanges)
    }
}

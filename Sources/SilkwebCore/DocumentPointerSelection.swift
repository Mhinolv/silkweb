import Foundation

/// Finder-style pointer selection, using a stable path as the range anchor.
public enum DocumentPointerSelection {
    public static func selection(path: String, orderedPaths: [String], selected: Set<String>,
                                 anchor: String?, extendRange: Bool, toggle: Bool) -> Set<String> {
        if extendRange, let anchor,
           let first = orderedPaths.firstIndex(of: anchor), let last = orderedPaths.firstIndex(of: path) {
            let range = Set(orderedPaths[min(first, last)...max(first, last)])
            return toggle ? selected.union(range) : range
        }
        if toggle {
            var result = selected
            if !result.insert(path).inserted { result.remove(path) }
            return result
        }
        return [path]
    }
}

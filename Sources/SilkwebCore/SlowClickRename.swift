import Foundation

/// Tracks completed plain clicks, independently of native list selection and dragging.
public struct SlowClickRename {
    private var previous: (path: String, timestamp: TimeInterval)?

    public init() {}

    public mutating func reset() { previous = nil }

    public mutating func click(
        path: String, timestamp: TimeInterval, clickCount: Int,
        wasSingleSelected: Bool, isSingleSelected: Bool,
        hasModifiers: Bool = false
    ) -> Bool {
        guard clickCount == 1, !hasModifiers else {
            reset()
            return false
        }
        let rename =
            wasSingleSelected && isSingleSelected
            && previous.map {
                $0.path == path && (0.5...1.5).contains(timestamp - $0.timestamp)
            } == true
        previous = rename ? nil : (path, timestamp)
        return rename
    }
}

import XCTest

/// Condition-based waiting for debounced or asynchronous work (#56). Polls `condition` on the main actor every
/// 10 ms until it holds and fails with `description` after `timeout`. Use it instead of fixed sleeps sized
/// against a production debounce: a loaded CI runner can resume the debounce late, and a longer sleep only
/// moves the flake. Negative checks ("nothing happened") should follow a positive wait, not replace it.
@MainActor @discardableResult
func waitUntil(
    _ description: @autoclosure () -> String, timeout: Duration = .seconds(5),
    file: StaticString = #filePath, line: UInt = #line,
    _ condition: () throws -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while try !condition() {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out after \(timeout) waiting for \(description())", file: file, line: line)
            return false
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return true
}

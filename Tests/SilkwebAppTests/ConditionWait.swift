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

/// Awaits `work` for at most `timeout` (#124). An await that never resumes, e.g. after a system sleep, fails with
/// `description` and throws instead of hanging the suite; the abandoned work is cancelled.
@MainActor @discardableResult
func withDeadline<Value>(
    _ description: @autoclosure () -> String, timeout: Duration = .seconds(10),
    file: StaticString = #filePath, line: UInt = #line,
    _ work: @escaping @MainActor () async throws -> Value
) async throws -> Value {
    let box = DeadlineBox<Value>()
    let task = Task { @MainActor in
        do { box.result = .success(try await work()) } catch { box.result = .failure(error) }
    }
    defer { task.cancel() }
    let deadline = ContinuousClock.now + timeout
    while box.result == nil {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out after \(timeout) awaiting \(description())", file: file, line: line)
            throw DeadlineExceeded(description: description())
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    return try box.result!.get()
}

struct DeadlineExceeded: Error {
    let description: String
}

@MainActor private final class DeadlineBox<Value> {
    var result: Result<Value, Error>?
}

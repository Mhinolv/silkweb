import XCTest

/// #56: the shared condition wait returns as soon as the condition holds and names the condition on timeout.
@MainActor
final class ConditionWaitTests: XCTestCase {
    private final class Flag { var ready = false }

    func testReturnsWhenConditionBecomesTrue() async throws {
        let start = ContinuousClock.now
        let flag = Flag()
        Task {
            try await Task.sleep(for: .milliseconds(50)); flag.ready = true
        }
        let met = try await waitUntil("flag set") { flag.ready }
        XCTAssertTrue(met)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(4))
    }

    func testTimeoutFailsWithConditionName() async throws {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = {
            $0.compactDescription.contains("Timed out after") && $0.compactDescription.contains("never true")
        }
        XCTExpectFailure("The wait must fail and name the condition", options: options)
        let met = try await waitUntil("never true", timeout: .milliseconds(50)) { false }
        XCTAssertFalse(met)
    }
}

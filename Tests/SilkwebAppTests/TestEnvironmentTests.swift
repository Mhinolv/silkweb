import XCTest

/// #51: only a hosted CI runner gets a scaled scroll budget; every other environment keeps the frame budget.
final class TestEnvironmentTests: XCTestCase {
    func testFrameBudgetScalesOnlyOnHostedCI() {
        let ci = ["GITHUB_ACTIONS": "true", "CI": "true"]
        XCTAssertTrue(TestEnvironment.isHostedCI(ci))
        XCTAssertEqual(
            TestEnvironment.frameBudget(16.7, environment: ci), 16.7 * TestEnvironment.hostedCIScale, accuracy: 1e-9)
        // The 10k list p95 measured on `macos-15` fits the CI budget; it would not fit a frame.
        XCTAssertLessThan(33.86, TestEnvironment.frameBudget(16.7, environment: ci))
        XCTAssertGreaterThan(33.86, TestEnvironment.frameBudget(16.7, environment: [:]))
        for local in [[:], ["CI": "true"], ["GITHUB_ACTIONS": "false"], ["CODEX_SANDBOX": "seatbelt"]] {
            XCTAssertFalse(TestEnvironment.isHostedCI(local), "\(local)")
            for budget in [4.0, 16, 16.7] {
                XCTAssertEqual(TestEnvironment.frameBudget(budget, environment: local), budget, "\(local)")
            }
        }
        XCTAssertGreaterThan(TestEnvironment.hostedCIScale, 1)
        XCTAssertLessThanOrEqual(TestEnvironment.hostedCIScale, 3, "CI may not drift towards no budget at all")
    }
}

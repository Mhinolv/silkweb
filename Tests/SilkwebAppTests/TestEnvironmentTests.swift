import XCTest

/// #51: only a hosted CI runner gets a scaled scroll budget; every other environment keeps the frame budget.
final class TestEnvironmentTests: XCTestCase {
    func testFrameBudgetScalesOnlyOnHostedCI() {
        let ci = ["GITHUB_ACTIONS": "true", "CI": "true"]
        XCTAssertTrue(TestEnvironment.isHostedCI(ci))
        XCTAssertEqual(
            TestEnvironment.frameBudget(16.7, environment: ci, loadPerCore: 0), 16.7 * TestEnvironment.hostedCIScale,
            accuracy: 1e-9)
        // The 10k list p95 measured on `macos-15` fits the CI budget; it would not fit a frame.
        XCTAssertLessThan(33.86, TestEnvironment.frameBudget(16.7, environment: ci, loadPerCore: 0))
        XCTAssertGreaterThan(33.86, TestEnvironment.frameBudget(16.7, environment: [:], loadPerCore: 0))
        for local in [[:], ["CI": "true"], ["GITHUB_ACTIONS": "false"], ["CODEX_SANDBOX": "seatbelt"]] {
            XCTAssertFalse(TestEnvironment.isHostedCI(local), "\(local)")
            for budget in [4.0, 16, 16.7] {
                XCTAssertEqual(
                    TestEnvironment.frameBudget(budget, environment: local, loadPerCore: 0), budget, "\(local)")
            }
        }
        XCTAssertGreaterThan(TestEnvironment.hostedCIScale, 1)
        XCTAssertLessThanOrEqual(TestEnvironment.hostedCIScale, 3, "CI may not drift towards no budget at all")
    }

    /// #272: a second suite or build on the same Mac scales the budget; an idle Mac or one suite alone does not.
    func testFrameBudgetScalesOnlyWhileTheCoresAreBusy() {
        let threshold = TestEnvironment.contendedLoadPerCore
        for load in [0, 0.1, threshold - 0.01] {
            XCTAssertFalse(TestEnvironment.isContended(loadPerCore: load), "\(load)")
            XCTAssertEqual(TestEnvironment.frameBudget(4, environment: [:], loadPerCore: load), 4, "\(load)")
        }
        for load in [threshold, 1, 4] {
            XCTAssertTrue(TestEnvironment.isContended(loadPerCore: load), "\(load)")
            XCTAssertEqual(
                TestEnvironment.frameBudget(4, environment: [:], loadPerCore: load), 4 * TestEnvironment.contendedScale,
                "\(load)")
        }
        // Hosted CI keeps its own scale; the two never multiply.
        XCTAssertEqual(
            TestEnvironment.frameBudget(4, environment: ["GITHUB_ACTIONS": "true"], loadPerCore: 4),
            4 * TestEnvironment.hostedCIScale)
        XCTAssertGreaterThan(TestEnvironment.contendedScale, 1)
        XCTAssertLessThanOrEqual(
            TestEnvironment.contendedScale, TestEnvironment.hostedCIScale, "contention may not drift past CI")
        XCTAssertGreaterThanOrEqual(TestEnvironment.loadPerCore(), 0)
    }
}

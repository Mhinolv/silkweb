import Foundation

/// Environment-dependent limits shared by the timing benchmarks (#51).
enum TestEnvironment {
    /// GitHub-hosted macOS runners are shared VMs: the same main-thread work measures about twice as long as on
    /// a developer Mac (10k list scroll p95 33.9 ms on `macos-15` vs. under 16.7 ms locally).
    static let hostedCIScale = 3.0
    /// #272: a second suite or build on the same Mac. Main-thread CPU p95 rose from under 4 ms to 6.3 ms while
    /// another job ran, so a busy Mac gets twice the budget. A busy Mac has a 1-minute load average of at least
    /// half its cores; one suite alone keeps it near one.
    static let contendedScale = 2.0
    static let contendedLoadPerCore = 0.5

    /// Whether the tests run on a GitHub Actions runner.
    static func isHostedCI(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["GITHUB_ACTIONS"] == "true"
    }

    /// The 1-minute load average per active core, or 0 when the system does not report it.
    static func loadPerCore() -> Double {
        var load = [0.0, 0.0, 0.0]
        guard getloadavg(&load, 3) > 0 else { return 0 }
        return load[0] / Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    /// Whether other work on this Mac competes with the tests for the cores (#272).
    static func isContended(loadPerCore: Double = loadPerCore()) -> Bool {
        loadPerCore >= contendedLoadPerCore
    }

    /// The per-step budget: `local` milliseconds on an idle developer Mac, scaled on hosted CI or while other work
    /// contends for the cores. Functional checks (realized rows, layout counters) never go through this.
    static func frameBudget(
        _ local: Double, environment: [String: String] = ProcessInfo.processInfo.environment,
        loadPerCore: Double = loadPerCore()
    ) -> Double {
        if isHostedCI(environment) { return local * hostedCIScale }
        return isContended(loadPerCore: loadPerCore) ? local * contendedScale : local
    }
}

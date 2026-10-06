import Foundation

/// Environment-dependent limits shared by the timing benchmarks (#51).
enum TestEnvironment {
    /// GitHub-hosted macOS runners are shared VMs: the same main-thread work measures about twice as long as on
    /// a developer Mac (10k list scroll p95 33.9 ms on `macos-15` vs. under 16.7 ms locally).
    static let hostedCIScale = 3.0

    /// Whether the tests run on a GitHub Actions runner.
    static func isHostedCI(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["GITHUB_ACTIONS"] == "true"
    }

    /// The per-step scroll budget: `local` milliseconds on a developer Mac, scaled only on hosted CI.
    /// Functional checks (realized rows, layout counters) never go through this.
    static func frameBudget(_ local: Double, environment: [String: String] = ProcessInfo.processInfo.environment)
        -> Double
    {
        isHostedCI(environment) ? local * hostedCIScale : local
    }
}

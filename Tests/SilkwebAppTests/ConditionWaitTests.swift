import AppKit
import XCTest

@testable import Silkweb

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

    /// #272: the settle wait outlasts busy samples and changes, then returns once the value holds for the quiet period.
    func testSettledWaitsForBusyAndChangingSamplesThenAQuietPeriod() async throws {
        final class Counter { var samples = 0 }
        let counter = Counter()
        let start = ContinuousClock.now
        // Busy (nil) for the first samples, then a value that changes twice before it holds.
        let settled = try await waitUntilSettled("the value", quiet: .milliseconds(60)) { () -> Int? in
            counter.samples += 1
            switch counter.samples {
            case ..<4: return nil
            case 4..<8: return counter.samples / 2
            default: return 7
            }
        }
        XCTAssertTrue(settled)
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(counter.samples, 9, "eight unsettled samples, then at least one quiet one")
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(60 + 70), "the quiet period starts at the last change")
        XCTAssertLessThan(elapsed, .seconds(4))
        // Already at rest: one quiet period.
        let quick = ContinuousClock.now
        try await waitUntilSettled("a constant", quiet: .milliseconds(30)) { 1 }
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - quick, .milliseconds(30))
    }

    func testSettledTimeoutFailsWhenTheValueNeverHolds() async throws {
        let options = XCTExpectedFailure.Options()
        options.issueMatcher = {
            $0.compactDescription.contains("Timed out after") && $0.compactDescription.contains("a clock to settle")
        }
        XCTExpectFailure("The wait must fail and name what never settled", options: options)
        var busy = 0
        let changing = try await waitUntilSettled("a clock", timeout: .milliseconds(80)) { () -> Int? in
            busy += 1
            return busy
        }
        XCTAssertFalse(changing)
        XCTExpectFailure("A sample that stays busy also times out", options: options)
        let alwaysBusy = try await waitUntilSettled("a clock", timeout: .milliseconds(50)) { () -> Int? in nil }
        XCTAssertFalse(alwaysBusy)
    }

    /// #213: reusing a loaded workspace for another library must not count as open until the requested library is
    /// showing. `open(_:)` keeps the previous snapshot with `loading == false` until its task runs, which the old
    /// "any snapshot, not loading" predicate took as ready, so IndexRecoveryWorkspaceTests asserted on the previous
    /// library.
    func testSwitchIsOpenOnlyOnceTheRequestedLibraryShows() async throws {
        _ = NSApplication.shared
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebConditionWait-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: container) }
        var roots: [URL] = []
        for name in ["First", "Second"] {
            let root = container.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("# \(name)\n".utf8).write(to: root.appendingPathComponent("\(name).md"))
            roots.append(root)
        }
        let workspace = LibraryWorkspace(defaults: disposableDefaults("ConditionWait"))
        workspace.canSaveWindowSession = false
        workspace.recoveryDirectory = container.appendingPathComponent("Recovery")
        try await openLibrary(roots[0], in: workspace)
        XCTAssertTrue(libraryIsOpen(workspace, at: roots[0]))
        XCTAssertFalse(libraryIsOpen(workspace, at: roots[1]), "another library is not open")

        workspace.open(roots[1])
        XCTAssertEqual(workspace.snapshot?.rootURL.lastPathComponent, "First", "the switch has not run yet")
        XCTAssertFalse(libraryIsOpen(workspace, at: roots[1]), "the previous library still showing is not the switch")
        try await waitForLibrary(roots[1], in: workspace)
        XCTAssertEqual(workspace.snapshot?.rootURL.lastPathComponent, "Second")
        XCTAssertEqual(workspace.snapshot?.documents.map(\.relativePath), ["Second.md"])
        XCTAssertNil(workspace.error)
        await workspace.didCloseWindow()
    }
}

import XCTest

@testable import Silkweb

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

/// #272: waits until the UI is at rest instead of a fixed settle sleep. Every 10 ms it calls `sample`, which lays
/// out and returns what the next assertions read, or nil while work is still due (a debounce, a decode, a fade).
/// It returns once the same non-nil value holds for `quiet`; the quiet period covers the async hops between steps.
@MainActor @discardableResult
func waitUntilSettled<Value: Equatable>(
    _ description: @autoclosure () -> String, quiet: Duration = .milliseconds(100), timeout: Duration = .seconds(10),
    file: StaticString = #filePath, line: UInt = #line,
    _ sample: () throws -> Value?
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    var last = try sample()
    var since = ContinuousClock.now
    while last == nil || ContinuousClock.now - since < quiet {
        guard ContinuousClock.now < deadline else {
            XCTFail("Timed out after \(timeout) waiting for \(description()) to settle", file: file, line: line)
            return false
        }
        try await Task.sleep(for: .milliseconds(10))
        let next = try sample()
        if next == nil || next != last { since = ContinuousClock.now }
        last = next
    }
    return true
}

/// #213: the library `workspace` is showing once it is done opening `root`. `open(_:)` keeps the previous snapshot
/// and `loading == false` until its task runs, so "any snapshot, not loading" is true at once when an already
/// loaded workspace switches libraries. Only the requested root counts; an error also ends the wait.
@MainActor
func libraryIsOpen(_ workspace: LibraryWorkspace, at root: URL) -> Bool {
    if workspace.error != nil { return true }
    let requested = root.standardizedFileURL.resolvingSymlinksInPath().path
    return !workspace.loading && workspace.snapshot?.rootURL.standardizedFileURL.path == requested
}

/// Opens `root` in `workspace` the way the app does and waits, bounded, until `libraryIsOpen` (#213). The failure
/// names the requested library and what the workspace was showing instead.
@MainActor @discardableResult
func openLibrary(
    _ root: URL, in workspace: LibraryWorkspace, timeout: Duration = .seconds(10),
    file: StaticString = #filePath, line: UInt = #line
) async throws -> LibraryWorkspace {
    workspace.open(root)
    try await waitForLibrary(root, in: workspace, timeout: timeout, file: file, line: line)
    return workspace
}

/// Waits, bounded, until `workspace` has finished opening `root` or reported an error (#213).
@MainActor
func waitForLibrary(
    _ root: URL, in workspace: LibraryWorkspace, timeout: Duration = .seconds(10),
    file: StaticString = #filePath, line: UInt = #line
) async throws {
    try await waitUntil(
        "library \(root.lastPathComponent) to open (showing \(workspace.snapshot?.rootURL.lastPathComponent ?? "none"), "
            + "loading \(workspace.loading), error \(workspace.error ?? "none"))", timeout: timeout, file: file,
        line: line
    ) { libraryIsOpen(workspace, at: root) }
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

/// #213: names where a test is when its main thread stops turning. A bounded wait can only time out while the main
/// actor runs; a call that blocks it (or a host that sleeps) stalls the suite instead, as the real WebKit preview
/// test did for 17 minutes. A background timer pings the main queue; when a ping goes unanswered for `threshold`, it
/// logs the current phase, how long the main thread has been stuck and how much of that the host was awake, and
/// saves one `sample` of the process so the blocking call shows up.
final class MainThreadWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var phaseName = "setup"
    private var answered = ContinuousClock.now
    private var answeredAwake = SuspendingClock.now
    private var reported = false
    private let name: String
    private let threshold: Duration
    private let timer: DispatchSourceTimer

    init(_ name: String, threshold: Duration = .seconds(30)) {
        self.name = name
        self.threshold = threshold
        timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
    }

    deinit { timer.cancel() }

    func stop() { timer.cancel() }

    var phase: String {
        get { lock.withLock { phaseName } }
        set { lock.withLock { phaseName = newValue } }
    }

    private func tick() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.withLock {
                self.answered = ContinuousClock.now
                self.answeredAwake = SuspendingClock.now
            }
        }
        let (stuck, awake, phase, first) = lock.withLock {
            let stuck = ContinuousClock.now - answered
            let first = stuck > threshold && !reported
            if first { reported = true }
            return (stuck, SuspendingClock.now - answeredAwake, phaseName, first)
        }
        guard first else { return }
        print(
            "\(name): main thread unresponsive for \(stuck) in phase \"\(phase)\" (host awake for \(awake) of it; "
                + "a large difference means the Mac slept)")
        let pid = ProcessInfo.processInfo.processIdentifier
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-stall-\(pid).txt")
        let sample = Process()
        sample.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        sample.arguments = ["\(pid)", "2", "-file", file.path]
        sample.standardOutput = FileHandle.nullDevice
        sample.standardError = FileHandle.nullDevice
        do {
            try sample.run()
            sample.waitUntilExit()
            print("\(name): main thread sample saved to \(file.path)")
        } catch {
            print("\(name): could not sample the stalled process: \(error.localizedDescription)")
        }
    }
}

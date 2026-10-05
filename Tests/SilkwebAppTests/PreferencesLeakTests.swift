import AppKit
import XCTest
import SilkwebCore
@testable import Silkweb

/// Tests must leave no preference files or runner-domain split keys behind (#67).
final class PreferencesLeakTests: XCTestCase {
    private static let childReportKey = "SILKWEB_PREFERENCES_CHILD_REPORT"

    /// Silkweb test residue under ~/Library/Preferences: Silkweb-named or bare-UUID plists, never the app's own.
    static func residue() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: TestPreferences.directory.path)) ?? []
        return Set(names.filter { name in
            guard name.hasSuffix(".plist"), name != "com.silkweb.app.plist" else { return false }
            return name.lowercased().contains("silkweb") || UUID(uuidString: String(name.dropLast(6))) != nil
        })
    }

    /// Silkweb keys in the runner's persistent domain.
    static func runnerKeys() -> Set<String> {
        UserDefaults.standard.synchronize()
        let domain = UserDefaults.standard.persistentDomain(forName: TestPreferences.runnerDomain) ?? [:]
        return Set(domain.keys.filter { $0.contains("Silkweb") })
    }

    @MainActor
    func testLibraryColumnsBuiltByTestsLeaveNoFilesOrRunnerKeys() async throws {
        _ = NSApplication.shared
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.silkweb.app")
        // A previous build's default-named frames would hide a new write.
        TestPreferences.removeSplitAutosave(containing: "Silkweb.LibraryColumns")
        defer { TestPreferences.removeSplitAutosave(containing: "Silkweb.LibraryColumns") }
        let files = Self.residue(), keys = Self.runnerKeys()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("# Columns\n\nText".utf8).write(to: root.appendingPathComponent("Note.md"))
        let preferences = TestPreferences("Leak")
        do {
            // The two production construction paths: the controller default and the workspace's name.
            let workspace = LibraryWorkspace(defaults: preferences.defaults)
            workspace.canSaveWindowSession = false
            workspace.root = root
            workspace.install(try await LibraryScanner.scan(root: root))
            for controller in [LibrarySplitViewController(workspace: workspace),
                               LibrarySplitViewController(workspace: workspace, autosaveName: workspace.columnAutosaveName)] {
                let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 760))
                container.addSubview(controller.view)
                controller.view.setFrameSize(container.frame.size)
                controller.view.layoutSubtreeIfNeeded()
                controller.splitView.setPosition(700, ofDividerAt: 0)
                controller.navigationController.splitView.setPosition(250, ofDividerAt: 0)
                controller.view.setFrameSize(NSSize(width: 1400, height: 900))
                controller.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                controller.view.removeFromSuperview()
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        preferences.remove()
        XCTAssertEqual(Self.runnerKeys().subtracting(keys), [], "Test-built columns autosaved into \(TestPreferences.runnerDomain)")
        XCTAssertEqual(Self.residue().subtracting(files), [], "New Silkweb preference files")
    }

    func testHelperRemovesSuiteFileAndSplitFrames() async throws {
        let files = Self.residue()
        let preferences = TestPreferences("Helper")
        preferences.defaults.set(true, forKey: "Probe")
        preferences.defaults.synchronize()
        XCTAssertTrue(FileManager.default.fileExists(atPath: preferences.plist.path), "The suite was never written, so this test proves nothing")
        try await exerciseNamedColumns(preferences)
        XCTAssertFalse(Self.runnerKeys().filter { $0.contains(preferences.name) }.isEmpty, "Autosave name was not exercised")
        preferences.remove()
        XCTAssertNil(preferences.defaults.object(forKey: "Probe"))
        // cfprefsd rewrites an emptied domain a moment later; that write must not leave a file anywhere.
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(FileManager.default.fileExists(atPath: preferences.plist.path))
        XCTAssertEqual(Self.residue().subtracting(files), [])
        XCTAssertEqual(Self.runnerKeys().filter { $0.contains(preferences.name) }, [])
    }

    /// Where a suite's plist lives: a path suite next to itself, a named one in ~/Library/Preferences.
    private static func storeFile(_ suite: String) -> URL {
        suite.hasPrefix("/") ? URL(fileURLWithPath: suite + ".plist") : TestPreferences.plistURL(suite)
    }

    @MainActor
    private func exerciseNamedColumns(_ preferences: TestPreferences) async throws {
        _ = NSApplication.shared
        let controller = LibrarySplitViewController(workspace: LibraryWorkspace(defaults: preferences.defaults), autosaveName: preferences.name)
        controller.view.setFrameSize(NSSize(width: 1200, height: 760))
        controller.view.layoutSubtreeIfNeeded()
        controller.splitView.setPosition(700, ofDividerAt: 0)
        controller.navigationController.splitView.setPosition(250, ofDividerAt: 0)
        controller.view.layoutSubtreeIfNeeded()
        // AppKit autosaves frames on a later run-loop turn.
        try await Task.sleep(for: .milliseconds(200))
    }

    /// Runs a second XCTest runner that writes the per-process AppDefaults suite, then checks it left no plist.
    func testAppDefaultsSuiteIsDeletedWhenTheRunnerExits() throws {
        let bundle = Bundle(for: Self.self).bundleURL
        let runner = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        guard runner.lastPathComponent == "xctest" else { throw XCTSkip("Not running under the xctest runner: \(runner.path)") }
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("SilkwebPreferencesChild-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: report) }
        let process = Process()
        process.executableURL = runner
        process.arguments = ["-XCTest", "SilkwebAppTests.PreferencesLeakTests/testChildRunnerWritesAppDefaults", bundle.path]
        process.environment = ProcessInfo.processInfo.environment.merging([Self.childReportKey: report.path]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate(); XCTFail("Child runner timed out"); return }
        XCTAssertEqual(process.terminationStatus, 0)
        let lines = try String(contentsOf: report, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 2)
        let suite = try XCTUnwrap(lines.first)
        XCTAssertTrue(suite.contains("Silkweb.Tests.Preferences."))
        XCTAssertEqual(lines.last, "true", "The child never wrote its suite to disk, so this test proves nothing")
        // cfprefsd rewrites an emptied domain a moment later; give that write the chance to appear.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.storeFile(suite).path), "\(suite).plist survived the runner's exit")
    }

    /// The child half of the exit test; skipped in a normal run.
    func testChildRunnerWritesAppDefaults() throws {
        guard let report = ProcessInfo.processInfo.environment[Self.childReportKey] else {
            throw XCTSkip("Runs only as the child of testAppDefaultsSuiteIsDeletedWhenTheRunnerExits")
        }
        AppDefaults.store.set(true, forKey: "PreferencesLeakProbe")
        AppDefaults.store.synchronize()
        let written = FileManager.default.fileExists(atPath: Self.storeFile(AppDefaults.testSuiteName).path)
        try "\(AppDefaults.testSuiteName)\n\(written)".write(to: URL(fileURLWithPath: report), atomically: true, encoding: .utf8)
    }
}

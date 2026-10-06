import Foundation
import XCTest

/// A disposable preferences suite for one test (#67). The suite is a plist path in its own temporary directory:
/// cfprefsd rewrites an emptied `~/Library/Preferences/<suite>.plist` after it is deleted, but never touches a
/// removed directory. `remove()` also drops NSSplitView frames AppKit autosaved under `name` in XCTest's own domain.
/// It never touches the app's real domain (`com.silkweb.app`).
final class TestPreferences: @unchecked Sendable {
    /// Every helper suite starts with this, so a leftover file is recognisable as test residue.
    static let prefix = "Silkweb.Tests."
    /// Under XCTest `UserDefaults.standard` is the runner's domain; NSSplitView autosaves land there.
    static let runnerDomain = "com.apple.dt.xctest.tool"
    /// `Silkweb.Tests.<name>.<UUID>`: unique, usable as an autosave name.
    let name: String
    /// The suite's plist path (without `.plist`).
    let suite: String
    let defaults: UserDefaults
    private let directory: URL

    init(_ name: String = "Suite") {
        self.name = Self.prefix + name + "." + UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(self.name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = directory.appendingPathComponent(self.name).path
        defaults = UserDefaults(suiteName: suite)!
    }

    var plist: URL { URL(fileURLWithPath: suite + ".plist") }

    func remove() {
        defaults.synchronize()
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        try? FileManager.default.removeItem(at: directory)
        Self.removeSplitAutosave(containing: name)
    }

    /// The real per-user preferences directory, inspected only by the leak guard.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences", isDirectory: true)
    }

    static func plistURL(_ domain: String) -> URL { directory.appendingPathComponent(domain + ".plist") }

    /// Removes `NSSplitView …` keys containing `name` from the runner's domain only.
    static func removeSplitAutosave(containing name: String) {
        precondition(Bundle.main.bundleIdentifier != "com.silkweb.app", "Tests must never edit the app's preferences")
        let standard = UserDefaults.standard
        standard.synchronize()
        for key in standard.dictionaryRepresentation().keys where key.hasPrefix("NSSplitView") && key.contains(name) {
            standard.removeObject(forKey: key)
        }
        standard.synchronize()
    }
}

extension XCTestCase {
    /// A suite removed when the test ends (after `defer`s and before the next test).
    func disposablePreferences(_ name: String = "Suite") -> TestPreferences {
        let preferences = TestPreferences(name)
        addTeardownBlock { preferences.remove() }
        return preferences
    }

    func disposableDefaults(_ name: String = "Suite") -> UserDefaults { disposablePreferences(name).defaults }

    /// A unique column autosave name for tests that check restore. AppKit saves frames on a later run-loop turn,
    /// even after the test's own `defer`s, so its keys are removed once the test's views are gone.
    func disposableAutosaveName(_ name: String) -> String {
        let autosave = TestPreferences.prefix + name + "." + UUID().uuidString
        addTeardownBlock { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            TestPreferences.removeSplitAutosave(containing: autosave)
        }
        return autosave
    }
}

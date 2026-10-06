import Foundation
import XCTest

/// A disposable preferences suite for one core test (#67). The suite is a plist path in its own temporary
/// directory, so nothing reaches `~/Library/Preferences`; `remove()` empties it and deletes the directory.
final class TestPreferences: @unchecked Sendable {
    static let prefix = "Silkweb.Tests."
    let suite: String
    let defaults: UserDefaults
    private let directory: URL

    init(_ name: String = "Suite") {
        let name = Self.prefix + name + "." + UUID().uuidString
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suite = directory.appendingPathComponent(name).path
        defaults = UserDefaults(suiteName: suite)!
    }

    func remove() {
        defaults.synchronize()
        defaults.removePersistentDomain(forName: suite)
        defaults.synchronize()
        try? FileManager.default.removeItem(at: directory)
    }
}

extension XCTestCase {
    /// A suite removed when the test ends.
    func disposableDefaults(_ name: String = "Suite") -> UserDefaults {
        let preferences = TestPreferences(name)
        addTeardownBlock { preferences.remove() }
        return preferences.defaults
    }
}

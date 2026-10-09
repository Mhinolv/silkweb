import AppKit
import SilkwebCore
import SwiftUI

/// The app's preferences domain. Under XCTest (unit tests, snapshot harness) it is an empty suite private
/// to the process, so tests start from defaults and never read or write the runner's real domain (silkweb-1.81).
enum AppDefaults {
    static let store: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        try? FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        let suite = UserDefaults(suiteName: testSuiteName) ?? .standard
        suite.removePersistentDomain(forName: testSuiteName)
        atexit { AppDefaults.removeTestStore() }
        return suite
    }()

    /// Under XCTest the suite is a plist path in a per-process temporary directory, never `~/Library/Preferences`:
    /// cfprefsd rewrites an emptied plist there after it is deleted, leaving one file per test run (#67).
    private static let testDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "Silkweb.Tests.Preferences.\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    static let testSuiteName = testDirectory.appendingPathComponent("Preferences").path

    /// The library column autosave name. Under XCTest there is none, so test-built columns never write frames
    /// into the runner's domain (#67); tests that check restore pass their own name.
    static let columnAutosaveName: String? = NSClassFromString("XCTestCase") == nil ? "Silkweb.LibraryColumns" : nil

    /// Each library window keeps its own column widths (#194). Slot 0, the first window, keeps the legacy name so
    /// widths saved before multiple windows survive; later windows add `.Window<n>`.
    static func windowColumnAutosaveName(base: String?, slot: Int) -> String? {
        guard let base else { return nil }
        return slot == 0 ? base : base + ".Window\(slot + 1)"
    }

    /// Registered only by the XCTest branch of `store`; runs at test-process exit.
    private static func removeTestStore() {
        guard let suite = UserDefaults(suiteName: testSuiteName) else { return }
        suite.removePersistentDomain(forName: testSuiteName)
        suite.synchronize()
        try? FileManager.default.removeItem(at: testDirectory)
    }
}

/// The preferences in effect, readable from any thread: dynamic colour providers resolve off the main
/// thread, and new editors read their initial style here (silkweb-1.24).
final class LivePreferences: @unchecked Sendable {
    static let shared = LivePreferences()
    private let lock = NSLock()
    private var value = WritingPreferences.load(from: AppDefaults.store)

    var current: WritingPreferences {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    /// The colour set for one appearance; called while resolving every Silkweb colour.
    func colors(dark: Bool) -> ColorSet { lock.withLock { value.colors[dark: dark] } }
}

/// Bumped on every colour change so SwiftUI views that read a Silkweb `Color` redraw with the new value.
@MainActor @Observable final class ColorRevision {
    static let shared = ColorRevision()
    private(set) var value = 0
    func bump() { value += 1 }
}

/// Every live editor that follows Settings. Weak, so closed tabs drop out on their own.
@MainActor enum EditorRegistry {
    static let editors = NSHashTable<PlainMarkdownTextView>.weakObjects()
    static func apply(_ preferences: WritingPreferences) {
        for editor in editors.allObjects { editor.applySettings(preferences) }
    }
}

extension Notification.Name {
    /// Posted by the live `WritingSettings` after any change; `object` is the previous `WritingPreferences` box.
    static let writingSettingsDidChange = Notification.Name("Silkweb.WritingSettingsDidChange")
}

/// The Settings window's model. Changes apply live (editors, preview, colours, appearance) and are
/// saved after a 250 ms pause. A non-live instance only edits values (snapshots, previews).
@MainActor @Observable final class WritingSettings {
    static var shared = WritingSettings()

    var preferences: WritingPreferences {
        didSet { if preferences != oldValue { changed(from: oldValue) } }
    }
    /// Which colour set the Appearance tab is editing; never changes the app's appearance.
    var editingDark: Bool

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let isLive: Bool
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(defaults: UserDefaults = AppDefaults.store, live: Bool = true) {
        self.defaults = defaults
        isLive = live
        let loaded = WritingPreferences.load(from: defaults)
        preferences = loaded
        editingDark = NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        if live { LivePreferences.shared.current = loaded }
    }

    /// The colour set being edited on the Appearance tab.
    var editedColors: ColorSet {
        get { preferences.colors[dark: editingDark] }
        set { preferences.colors[dark: editingDark] = newValue }
    }

    func restoreEditedColors() { editedColors = ColorSet() }

    private func changed(from old: WritingPreferences) {
        scheduleSave()
        guard isLive else { return }
        LivePreferences.shared.current = preferences
        if preferences.colors != old.colors {
            ColorRevision.shared.bump()
            Self.redrawWindows()
        }
        if preferences.appearance != old.appearance { applyAppearance() }
        EditorRegistry.apply(preferences)
        NotificationCenter.default.post(name: .writingSettingsDidChange, object: PreferencesBox(old))
    }

    func applyAppearance() {
        guard isLive else { return }
        switch preferences.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            self?.flush()
        }
    }

    /// Writes now (debounced saves, quit).
    func flush() {
        // Nothing pending: reading or quitting never rewrites the user's settings.
        guard saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        preferences.save(to: defaults)
    }

    /// Dynamic colours resolve at draw time; views drawn with the old value need a pass.
    static func redrawWindows() {
        func redraw(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(redraw)
        }
        for window in NSApp.windows {
            window.backgroundColor = window.backgroundColor
            if let frame = window.contentView?.superview ?? window.contentView { redraw(frame) }
        }
    }
}

/// Carries the previous preferences through `NotificationCenter`.
final class PreferencesBox: @unchecked Sendable {
    let value: WritingPreferences
    init(_ value: WritingPreferences) { self.value = value }
}

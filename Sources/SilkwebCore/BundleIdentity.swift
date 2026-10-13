import Foundation

/// The app's and the helper's bundle identifiers (#249). Builds before #249 used `com.silkweb.app`.
public enum BundleIdentity {
    public static let app = "io.github.mhinolv.silkweb"
    public static let helper = "io.github.mhinolv.silkweb.helper"
    /// The preferences domain of builds before #249. Read once by `PreferencesMigration`, never written.
    public static let legacyApp = "com.silkweb.app"
}

/// Carries the preferences saved under the old bundle identifier into the new domain, once (#249). The old domain
/// is only read, so an older build still finds its own preferences. The keychain item needs nothing: its name doesn't
/// depend on the bundle identifier, and macOS asks once when the renamed app first reads its secret.
public enum PreferencesMigration {
    /// Set in the new domain after the first run, whether or not there was anything to copy.
    public static let doneKey = "Silkweb.PreferencesMigratedFromLegacyDomain"

    /// Copies every key of `legacy` that `current` (the new domain as saved) doesn't have into `defaults`, unless
    /// this ran before. Returns the keys copied, sorted.
    @discardableResult
    public static func run(legacy: [String: Any]?, current: [String: Any]?, into defaults: UserDefaults) -> [String] {
        guard current?[doneKey] as? Bool != true else { return [] }
        var copied: [String] = []
        for (key, value) in legacy ?? [:] where key != doneKey && current?[key] == nil {
            defaults.set(value, forKey: key)
            copied.append(key)
        }
        defaults.set(true, forKey: doneKey)
        return copied.sorted()
    }

    /// The app's own run at launch, on its standard domain. Does nothing for a build still named `com.silkweb.app`.
    @discardableResult
    public static func runForApp() -> [String] {
        guard let domain = Bundle.main.bundleIdentifier, domain != BundleIdentity.legacyApp else { return [] }
        let defaults = UserDefaults.standard
        return run(
            legacy: defaults.persistentDomain(forName: BundleIdentity.legacyApp),
            current: defaults.persistentDomain(forName: domain), into: defaults)
    }
}

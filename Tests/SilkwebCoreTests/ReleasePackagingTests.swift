import Foundation
import XCTest

@testable import SilkwebCore

/// #249: the new bundle identifiers, the one-time preferences carry-over from `com.silkweb.app`, and the release
/// script, notes template and workflow that publish the DMG (#271: Developer ID signed and notarized).
final class ReleasePackagingTests: XCTestCase {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func text(_ path: String) throws -> String {
        try String(contentsOf: Self.repository.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Preferences carry-over

    func testFirstRunCopiesEveryLegacyKeyWithItsType() throws {
        let defaults = disposableDefaults("Migration")
        let legacy: [String: Any] = [
            "Silkweb.FontSize": 15, "Silkweb.ShowPreview": true, "Silkweb.Theme": "Night",
            "Silkweb.Recents": ["/a", "/b"], "Silkweb.Bookmark": Data([1, 2, 3]),
            "NSWindow Frame library": "0 0 1200 760 0 0 1440 900 ",
        ]
        let copied = PreferencesMigration.run(legacy: legacy, current: nil, into: defaults)
        XCTAssertEqual(copied, legacy.keys.sorted())
        XCTAssertEqual(defaults.integer(forKey: "Silkweb.FontSize"), 15)
        XCTAssertTrue(defaults.bool(forKey: "Silkweb.ShowPreview"))
        XCTAssertEqual(defaults.string(forKey: "Silkweb.Theme"), "Night")
        XCTAssertEqual(defaults.stringArray(forKey: "Silkweb.Recents"), ["/a", "/b"])
        XCTAssertEqual(defaults.data(forKey: "Silkweb.Bookmark"), Data([1, 2, 3]))
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame library"), "0 0 1200 760 0 0 1440 900 ")
        XCTAssertTrue(defaults.bool(forKey: PreferencesMigration.doneKey))
    }

    func testRunsOnlyOnce() {
        let defaults = disposableDefaults("Migration")
        PreferencesMigration.run(legacy: ["Silkweb.Theme": "Night"], current: nil, into: defaults)
        // The owner changes a setting in the new build; the old build's value must not come back.
        defaults.set("Day", forKey: "Silkweb.Theme")
        let current: [String: Any] = ["Silkweb.Theme": "Day", PreferencesMigration.doneKey: true]
        let copied = PreferencesMigration.run(
            legacy: ["Silkweb.Theme": "Night", "Silkweb.New": 1], current: current, into: defaults)
        XCTAssertEqual(copied, [])
        XCTAssertEqual(defaults.string(forKey: "Silkweb.Theme"), "Day")
        XCTAssertNil(defaults.object(forKey: "Silkweb.New"))
    }

    func testValuesAlreadyInTheNewDomainWin() {
        let defaults = disposableDefaults("Migration")
        defaults.set("Day", forKey: "Silkweb.Theme")
        let copied = PreferencesMigration.run(
            legacy: ["Silkweb.Theme": "Night", "Silkweb.FontSize": 15], current: ["Silkweb.Theme": "Day"],
            into: defaults)
        XCTAssertEqual(copied, ["Silkweb.FontSize"])
        XCTAssertEqual(defaults.string(forKey: "Silkweb.Theme"), "Day")
        XCTAssertEqual(defaults.integer(forKey: "Silkweb.FontSize"), 15)
    }

    func testNoLegacyDomainStillMarksDone() {
        let defaults = disposableDefaults("Migration")
        XCTAssertEqual(PreferencesMigration.run(legacy: nil, current: nil, into: defaults), [])
        XCTAssertEqual(PreferencesMigration.run(legacy: [:], current: [:], into: defaults), [])
        XCTAssertTrue(defaults.bool(forKey: PreferencesMigration.doneKey))
    }

    func testALegacyDoneKeyIsNotCopied() {
        // A domain that was itself migrated (a build renamed twice) must not mark the new one done early.
        let defaults = disposableDefaults("Migration")
        let copied = PreferencesMigration.run(
            legacy: [PreferencesMigration.doneKey: false, "Silkweb.Theme": "Night"], current: nil, into: defaults)
        XCTAssertEqual(copied, ["Silkweb.Theme"])
        XCTAssertTrue(defaults.bool(forKey: PreferencesMigration.doneKey))
    }

    func testRealSuiteDomainsRoundTripAndTheLegacyOneIsUntouched() throws {
        let legacyPreferences = TestPreferences("Legacy")
        defer { legacyPreferences.remove() }
        let newPreferences = TestPreferences("New")
        defer { newPreferences.remove() }
        legacyPreferences.defaults.set("Night", forKey: "Silkweb.Theme")
        legacyPreferences.defaults.synchronize()
        let legacy = try XCTUnwrap(legacyPreferences.defaults.persistentDomain(forName: legacyPreferences.suite))
        let before = NSDictionary(dictionary: legacy)
        PreferencesMigration.run(
            legacy: legacy, current: newPreferences.defaults.persistentDomain(forName: newPreferences.suite),
            into: newPreferences.defaults)
        XCTAssertEqual(newPreferences.defaults.string(forKey: "Silkweb.Theme"), "Night")
        let after = try XCTUnwrap(legacyPreferences.defaults.persistentDomain(forName: legacyPreferences.suite))
        XCTAssertEqual(NSDictionary(dictionary: after), before)
        // The saved new domain now says done, so a later launch copies nothing.
        let saved = newPreferences.defaults.persistentDomain(forName: newPreferences.suite)
        XCTAssertEqual(
            PreferencesMigration.run(legacy: legacy, current: saved, into: newPreferences.defaults), [])
    }

    // MARK: Bundle identifiers

    func testInfoPlistAndBundleScriptUseTheNewIdentifiers() throws {
        let plist = try XCTUnwrap(
            NSDictionary(contentsOf: Self.repository.appendingPathComponent("scripts/Info.plist")) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, BundleIdentity.app)
        let bundle = try text("scripts/bundle_app.sh")
        XCTAssertTrue(bundle.contains("APP_ID=\"\(BundleIdentity.app)\""))
        XCTAssertTrue(bundle.contains("HELPER_ID=\"\(BundleIdentity.helper)\""))
        XCTAssertTrue(try text("scripts/release.sh").contains("\"\(BundleIdentity.app)\""))
        XCTAssertEqual(BundleIdentity.helper, BundleIdentity.app + ".helper")
    }

    func testNoSourceOrScriptStillNamesTheOldIdentifier() throws {
        let manager = FileManager.default
        var offenders: [String] = []
        for folder in ["Sources", "scripts", ".github"] {
            let root = Self.repository.appendingPathComponent(folder)
            let files = manager.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            for file in files where ["swift", "sh", "plist", "yml", "md"].contains(file.pathExtension) {
                guard file.lastPathComponent != "BundleIdentity.swift",
                    let content = try? String(contentsOf: file, encoding: .utf8), content.contains("com.silkweb")
                else { continue }
                offenders.append(file.path.replacingOccurrences(of: Self.repository.path + "/", with: ""))
            }
        }
        XCTAssertEqual(offenders, [])
    }

    // MARK: Release

    func testReleaseNotesTemplateSectionsInOrder() throws {
        let notes = try text("scripts/release_notes.md")
        let headings = notes.split(separator: "\n").filter { $0.hasPrefix("## ") }.map(String.init)
        // #271: a signed, notarized build needs no Open Anyway or quarantine steps.
        XCTAssertEqual(headings, ["## Install", "## Agent memory helper (not included)"])
        XCTAssertTrue(notes.contains("Silkweb-{{VERSION}}.dmg"))
        XCTAssertFalse(notes.contains("Open Anyway"))
        XCTAssertFalse(notes.contains("xattr"))
        XCTAssertFalse(notes.contains("unsigned"))
    }

    func testReleaseScriptRefusesAVersionThatDoesNotMatchInfoPlist() throws {
        let result = try runRelease(["--no-build", "v9.9.9"])
        XCTAssertEqual(result.status, 1)
        XCTAssertTrue(result.error.contains("v9.9.9 doesn't match CFBundleShortVersionString"), result.error)
    }

    func testReleaseScriptRejectsUnknownOptions() throws {
        let result = try runRelease(["--sign"])
        XCTAssertEqual(result.status, 64)
        XCTAssertTrue(result.error.contains("unknown option --sign"), result.error)
    }

    func testReleaseScriptRefusesUnsignedWithPublish() throws {
        for arguments in [["--unsigned", "--publish"], ["--publish", "--no-build", "--unsigned"]] {
            let result = try runRelease(arguments)
            XCTAssertEqual(result.status, 64, "\(arguments)")
            XCTAssertTrue(result.error.contains("--unsigned can't combine with --publish"), result.error)
        }
    }

    func testReleaseScriptStopsWhenTheSigningIdentityIsMissing() throws {
        let missing = try runRelease(
            ["--no-build"], environment: ["SILKWEB_SIGN_IDENTITY": "Developer ID Application: Nobody (TEST000000)"])
        XCTAssertEqual(missing.status, 1)
        XCTAssertTrue(
            missing.error.contains(
                "release: no Developer ID Application identity \"Developer ID Application: Nobody (TEST000000)\" "
                    + "in the keychain. See docs/release.md."), missing.error)
        let wrongKind = try runRelease(
            ["--no-build"], environment: ["SILKWEB_SIGN_IDENTITY": "Apple Development: Nobody (TEST000000)"])
        XCTAssertEqual(wrongKind.status, 1)
        XCTAssertTrue(wrongKind.error.contains("isn't a Developer ID Application identity"), wrongKind.error)
    }

    func testReleaseScriptChecksCredentialsBeforeTheBuild() throws {
        let script = try text("scripts/release.sh")
        let identityCheck = try XCTUnwrap(script.range(of: "security find-identity -v -p codesigning"))
        let profileCheck = try XCTUnwrap(script.range(of: "xcrun notarytool history --keychain-profile \"$PROFILE\""))
        let build = try XCTUnwrap(script.range(of: "./scripts/build.sh release"))
        XCTAssertLessThan(identityCheck.lowerBound, build.lowerBound)
        XCTAssertLessThan(profileCheck.lowerBound, build.lowerBound)
        // The repo names the profile and the identity only. No secret.
        XCTAssertTrue(script.contains("PROFILE=\"${SILKWEB_NOTARY_PROFILE:-silkweb-notary}\""))
        XCTAssertTrue(
            script.contains(
                "IDENTITY=\"${SILKWEB_SIGN_IDENTITY:-Developer ID Application: Mark Hinojosa (V8X3GYRTNK)}\""))
        XCTAssertFalse(script.contains("--password"))
    }

    func testReleaseScriptSignsNotarizesAndStaplesTheAppAndTheDMG() throws {
        let script = try text("scripts/release.sh")
        XCTAssertTrue(
            script.contains("codesign --force --options runtime --timestamp -s \"$IDENTITY\" -i \"$APP_ID\" \"$APP\""))
        XCTAssertTrue(script.contains("codesign --force --timestamp -s \"$IDENTITY\" \"$DMG\""))
        XCTAssertTrue(script.contains("codesign --verify --strict --deep \"$APP\""))
        XCTAssertTrue(script.contains("codesign --verify --strict \"$DMG\""))
        XCTAssertTrue(script.contains("xcrun notarytool submit \"$1\" --keychain-profile \"$PROFILE\" --wait"))
        XCTAssertTrue(script.contains("xcrun notarytool log \"$SUBMISSION\""))
        XCTAssertTrue(script.contains("xcrun stapler staple -q \"$1\""))
        XCTAssertTrue(script.contains("spctl -a -t open --context context:primary-signature \"$DMG\""))
        for stage in ["echo \"signed $APP\"", "echo \"notarized $1", "echo \"stapled $1\"", "echo \"signed $DMG\""] {
            XCTAssertTrue(script.contains(stage), stage)
        }
        // The DMG is packed from the signed, stapled app and holds only it and the Applications shortcut.
        let stapleApp = try XCTUnwrap(script.range(of: "staple \"$APP\""))
        let pack = try XCTUnwrap(script.range(of: "sh ./scripts/make_dmg.sh \"$APP\""))
        let publish = try XCTUnwrap(script.range(of: "gh release create"))
        XCTAssertLessThan(stapleApp.lowerBound, pack.lowerBound)
        XCTAssertLessThan(pack.lowerBound, publish.lowerBound)
        XCTAssertFalse(script.contains("build/helper"))
        let dmg = try text("scripts/make_dmg.sh")
        XCTAssertFalse(dmg.contains("helper"))
        XCTAssertEqual(dmg.components(separatedBy: "\"$STAGE/").count - 1, 2)
        // The everyday build stays ad hoc signed.
        let bundle = try text("scripts/bundle_app.sh")
        XCTAssertTrue(bundle.contains("codesign --force -s - -i \"$APP_ID\" \"$APP\""))
        XCTAssertFalse(bundle.contains("Developer ID Application:"))
    }

    func testReleaseWorkflowNeverPublishesOnATagPush() throws {
        let workflow = try text(".github/workflows/release.yml")
        // #271: no signing secret is in CI yet, so the owner publishes from their Mac. A manual run stops at the
        // credential check in release.sh.
        XCTAssertFalse(workflow.contains("tags:"))
        XCTAssertTrue(workflow.contains("workflow_dispatch:"))
        XCTAssertFalse(workflow.contains("--unsigned"))
        XCTAssertTrue(workflow.contains("contents: write"))
        XCTAssertTrue(workflow.contains("sh ./scripts/release.sh --publish \"$GITHUB_REF_NAME\""))
        XCTAssertTrue(workflow.contains("DEVELOPER_DIR: /Applications/Xcode_26.2.app/Contents/Developer"))
        let script = try text("scripts/release.sh")
        // Re-running for a tag that already has a Release updates it in place.
        XCTAssertTrue(script.contains("gh release upload \"$TAG\" \"$DMG\" --clobber"))
        XCTAssertTrue(script.contains("gh release edit \"$TAG\""))
        XCTAssertTrue(script.contains("./scripts/build.sh release"))
        XCTAssertTrue(script.contains("DMG=\"$OUT/Silkweb-$VERSION.dmg\""))
        let dmg = try text("scripts/make_dmg.sh")
        XCTAssertTrue(dmg.contains("-volname \"Silkweb $VERSION\""))
        XCTAssertTrue(dmg.contains("ln -s /Applications \"$STAGE/Applications\""))
    }

    func testReleaseDocsDescribeTheKeychainProfileSetup() throws {
        let docs = try text("docs/release.md")
        XCTAssertTrue(docs.contains("xcrun notarytool store-credentials silkweb-notary"))
        XCTAssertTrue(docs.contains("SILKWEB_SIGN_IDENTITY"))
        XCTAssertTrue(docs.contains("SILKWEB_NOTARY_PROFILE"))
        XCTAssertTrue(docs.contains("sh scripts/release.sh --unsigned"))
    }

    private func runRelease(_ arguments: [String], environment: [String: String] = [:]) throws -> (
        status: Int32, error: String
    ) {
        let process = Process()
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [Self.repository.appendingPathComponent("scripts/release.sh").path] + arguments
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        try process.run()
        let error = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: error, as: UTF8.self))
    }
}

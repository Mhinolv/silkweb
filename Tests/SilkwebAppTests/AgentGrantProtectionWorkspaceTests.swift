import AppKit
import SwiftUI
import XCTest

@testable import Silkweb
@testable import SilkwebCore

/// #205 in the Agent Access window: the protection strip and Settings summary for each state, the one-time Protect
/// agent grants? offer (Not Now remembered), Protect / Review Grants… with keep checkboxes and owner authentication,
/// authenticated changes on unsigned grants protecting them first under one authentication, signed saves and
/// narrowings, and the read-only window while grants changed outside Silkweb or lost their key. Keys live in memory.
@MainActor
final class AgentGrantProtectionWorkspaceTests: XCTestCase {
    private var container: URL!
    private var library: URL!
    private var grantsURL: URL!
    private var keys: AgentGrantMemoryKeys!
    private var preferences: TestPreferences!
    private var alerts: [String] = []
    private var authentications: [String] = []
    private var authenticates = true
    private var answer = NSApplication.ModalResponse.alertFirstButtonReturn
    private static let created = Date(timeIntervalSince1970: 1_791_555_240)

    override func setUp() async throws {
        container = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SilkwebGrantProtection-" + UUID().uuidString)
        library = container.appendingPathComponent("Silkweb Library")
        try FileManager.default.createDirectory(
            at: library.appendingPathComponent("Memory/Projects/Silkweb"), withIntermediateDirectories: true)
        library = library.resolvingSymlinksInPath()
        grantsURL = container.appendingPathComponent("Support/agent-grants.json")
        keys = AgentGrantMemoryKeys()
        preferences = TestPreferences("GrantProtection")
        alerts = []
        authentications = []
        authenticates = true
        answer = .alertFirstButtonReturn
    }

    override func tearDown() async throws {
        preferences.remove()
        try? FileManager.default.removeItem(at: container)
    }

    private func grant(_ project: String, access: AgentGrant.Access = .readCreate, revoked: Date? = nil) -> AgentGrant {
        AgentGrant(
            project: project, library: LibraryLocation(path: library.path), access: access, createdAt: Self.created,
            revokedAt: revoked)
    }

    private func seedUnsigned(_ grants: [AgentGrant]) throws {
        try AgentGrantFile(grants: grants).write(to: grantsURL)
    }

    private func seedSigned(_ grants: [AgentGrant]) throws {
        try FileManager.default.createDirectory(
            at: grantsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AgentGrantSigning.signed(AgentGrantFile(grants: grants), with: keys).write(to: grantsURL)
    }

    /// The hand edit outside Silkweb: raises `project`'s access in the raw JSON.
    private func widenOnDisk() throws {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: grantsURL)) as? [String: Any])
        var grants = try XCTUnwrap(object["grants"] as? [[String: Any]])
        grants[0]["access"] = "read-create-update"
        object["grants"] = grants
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]).write(to: grantsURL)
    }

    private var protectionOnDisk: AgentGrantProtection {
        get throws { try AgentGrantSigning.inspect(grantsURL, keys: keys).protection }
    }

    private func makeModel() -> AgentAccessModel {
        let model = AgentAccessModel()
        model.grantsURL = grantsURL
        model.requestStore = AgentAccessRequestStore(url: container.appendingPathComponent("Support/requests.json"))
        model.keys = keys
        model.defaults = preferences.defaults
        model.authenticate = { [weak self] reason in
            self?.authentications.append(reason)
            return self?.authenticates ?? false
        }
        model.present = { [weak self] alert, _ in
            self?.alerts.append(alert.messageText)
            return self?.answer ?? .abort
        }
        return model
    }

    // MARK: Unprotected

    func testUnsignedGrantsShowTheStripAndProtectGrantsSignsTheCheckedOnes() async throws {
        try seedUnsigned([grant("Silkweb"), grant("Coffee", access: .read)])
        let model = makeModel()
        await model.reload()
        XCTAssertEqual(model.protection, .unprotected)
        XCTAssertEqual(model.protectionStrip?.text, "Agent grants aren’t protected yet.")
        XCTAssertEqual(model.protectionStrip?.button, "Protect Grants…")
        XCTAssertEqual(model.protectionStrip?.icon, "lock.open")
        XCTAssertEqual(model.summary, "2 grants · Not protected")
        XCTAssertFalse(model.isReadOnly, "unsigned grants keep working and stay editable")

        model.beginReview()
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.title, "Protect Agent Grants")
        XCTAssertEqual(review.kept, ["Silkweb", "Coffee"], "every grant is checked")
        XCTAssertTrue(review.knowsPrevious)
        review.kept.remove("Coffee")

        // A cancelled authentication writes nothing and keeps the sheet.
        authenticates = false
        let cancelled = await model.signGrants()
        XCTAssertFalse(cancelled)
        XCTAssertNotNil(model.review)
        XCTAssertEqual(try protectionOnDisk, .unprotected)
        XCTAssertNil(try keys.verificationKey(), "no key yet")

        authenticates = true
        let signed = await model.signGrants()
        XCTAssertTrue(signed)
        XCTAssertEqual(authentications, ["protect agent grants", "protect agent grants"])
        XCTAssertNil(model.review)
        XCTAssertEqual(try protectionOnDisk, .protected)
        XCTAssertEqual(model.protection, .protected)
        XCTAssertNil(model.protectionStrip)
        XCTAssertEqual(model.summary, "1 grant")
        XCTAssertEqual(model.file.grants.map(\.project), ["Silkweb"], "the unchecked grant was removed")
    }

    func testProtectOfferAppearsOnceAndNotNowIsRemembered() async throws {
        let model = makeModel()
        // No grants: nothing to offer.
        var opened = await model.offerProtection(in: nil)
        XCTAssertFalse(opened)
        XCTAssertEqual(alerts, [])

        try seedUnsigned([grant("Silkweb")])
        let offered = makeModel()
        answer = .alertSecondButtonReturn
        opened = await offered.offerProtection(in: nil)
        XCTAssertFalse(opened)
        XCTAssertEqual(alerts, ["Protect agent grants?"])
        XCTAssertTrue(preferences.defaults.bool(forKey: AgentAccessModel.protectionDeclinedKey))
        XCTAssertNil(offered.review)
        // Not Now: never again, the strip stays and helpers keep working unsigned.
        opened = await offered.offerProtection(in: nil)
        XCTAssertFalse(opened)
        let relaunched = makeModel()
        answer = .alertFirstButtonReturn
        opened = await relaunched.offerProtection(in: nil)
        XCTAssertFalse(opened)
        XCTAssertEqual(alerts, ["Protect agent grants?"], "asked only once")
        XCTAssertEqual(relaunched.protectionStrip?.button, "Protect Grants…")
        XCTAssertNoThrow(try AgentGrantStore(url: grantsURL, keys: keys).load())

        // Review Grants… opens the sheet.
        preferences.defaults.removeObject(forKey: AgentAccessModel.protectionDeclinedKey)
        let accepting = makeModel()
        opened = await accepting.offerProtection(in: nil)
        XCTAssertTrue(opened)
        XCTAssertEqual(accepting.review?.title, "Protect Agent Grants")
    }

    func testAuthenticatedChangeOnUnsignedGrantsProtectsThemFirstWithOneAuthentication() async throws {
        try seedUnsigned([grant("Silkweb", access: .read)])
        let model = makeModel()
        await model.reload()
        await model.select(.grant("Silkweb"))
        model.draft?.access = .readCreate
        let saved = await model.save()
        XCTAssertFalse(saved, "the save waits for protection")
        XCTAssertEqual(authentications, [], "nothing asked yet")
        XCTAssertEqual(model.review?.title, "Protect Agent Grants")
        XCTAssertEqual(try AgentGrantOwner.load(grantsURL).grants.first?.access, .read)

        let signed = await model.signGrants()
        XCTAssertTrue(signed)
        XCTAssertEqual(authentications, ["protect agent grants"], "one authentication covers both")
        XCTAssertEqual(try protectionOnDisk, .protected)
        XCTAssertEqual(try AgentGrantStore(url: grantsURL, keys: keys).load().grants.first?.access, .readCreate)
        XCTAssertFalse(model.isEdited)
    }

    func testNewGrantAndApproveOnUnsignedGrantsProtectThemFirst() async throws {
        try seedUnsigned([grant("Silkweb", access: .read)])
        let model = makeModel()
        await model.reload()
        model.beginNewGrant()
        let form = try XCTUnwrap(model.newGrant)
        form.library = library.path
        form.project = "Coffee"
        form.access = .read
        let created = await model.create(form)
        XCTAssertTrue(created)
        XCTAssertNil(model.newGrant, "the New Grant sheet gives way to the review sheet")
        XCTAssertEqual(model.review?.title, "Protect Agent Grants")
        XCTAssertEqual(authentications, [])
        let signed = await model.signGrants()
        XCTAssertTrue(signed)
        XCTAssertEqual(authentications, ["protect agent grants"])
        XCTAssertEqual(try protectionOnDisk, .protected)
        XCTAssertEqual(model.file.grants.map(\.project), ["Silkweb", "Coffee"])
        XCTAssertEqual(model.selection, .grant("Coffee"))

        // Approve on unsigned grants: confirm, then the review sheet, then the signed approval.
        try FileManager.default.removeItem(at: grantsURL)
        keys.removeKey()
        try seedUnsigned([grant("Silkweb", access: .read)])
        let store = AgentAccessRequestStore(url: container.appendingPathComponent("Support/requests.json"))
        let draft = try AgentAccessRequests.draft(
            library: library.path, project: "Novel", access: "read", readFolders: [], message: nil, agent: "codex",
            session: "s", client: "cli")
        let request = try store.submit(draft).request
        await model.reload()
        authentications = []
        await model.approve(request)
        XCTAssertEqual(model.review?.title, "Protect Agent Grants")
        XCTAssertEqual(try AgentGrantOwner.load(grantsURL).grants.count, 1, "nothing approved yet")
        _ = await model.signGrants()
        XCTAssertEqual(authentications, ["protect agent grants"])
        XCTAssertEqual(try protectionOnDisk, .protected)
        XCTAssertEqual(
            try AgentGrantStore(url: grantsURL, keys: keys).load().grants.map(\.project), ["Silkweb", "Novel"])
        XCTAssertEqual(try store.load().requests.first?.status, .approved)
    }

    func testCancellingProtectionKeepsTheEditAndWritesNothing() async throws {
        try seedUnsigned([grant("Silkweb", access: .read)])
        let model = makeModel()
        await model.reload()
        await model.select(.grant("Silkweb"))
        model.draft?.access = .readCreate
        _ = await model.save()
        model.review = nil
        XCTAssertTrue(model.isEdited)
        XCTAssertEqual(try protectionOnDisk, .unprotected)
        XCTAssertEqual(try AgentGrantOwner.load(grantsURL).grants.first?.access, .read)
        // A narrowing or a pause needs no authentication and stays unsigned.
        await model.setPaused(true, project: "Silkweb")
        XCTAssertEqual(try protectionOnDisk, .unprotected)
        XCTAssertEqual(authentications, [])
    }

    // MARK: Protected

    func testProtectedSavesSignNarrowingsWithoutAuthentication() async throws {
        try seedSigned([grant("Silkweb"), grant("Coffee", access: .read)])
        let model = makeModel()
        await model.reload()
        XCTAssertEqual(model.protection, .protected)
        XCTAssertNil(model.protectionStrip)
        XCTAssertEqual(model.summary, "2 grants")

        await model.select(.grant("Silkweb"))
        model.draft?.access = .read
        let narrowed = await model.save()
        XCTAssertTrue(narrowed)
        await model.setPaused(true, project: "Coffee")
        XCTAssertEqual(authentications, [], "narrowing and Pause need no prompt")
        XCTAssertEqual(try protectionOnDisk, .protected)

        model.draft?.access = .readCreateUpdate
        let widened = await model.save()
        XCTAssertTrue(widened)
        XCTAssertEqual(authentications.count, 1)
        XCTAssertNil(model.review, "protected grants need no review first")
        XCTAssertEqual(try protectionOnDisk, .protected)
        XCTAssertEqual(try AgentGrantStore(url: grantsURL, keys: keys).load().grants.first?.access, .readCreateUpdate)
    }

    // MARK: Needs review

    func testChangedOutsideSilkwebIsReadOnlyUntilReviewed() async throws {
        try seedSigned([grant("Silkweb", access: .read), grant("Coffee", access: .read)])
        let model = makeModel()
        await model.reload()
        await model.select(.grant("Silkweb"))
        try widenOnDisk()
        await model.reload()
        XCTAssertEqual(model.protection, .changedOutside)
        XCTAssertTrue(model.isReadOnly)
        XCTAssertEqual(
            model.protectionStrip?.text,
            "Agent grants were changed outside Silkweb. Agents can’t use any grant until you review them.")
        XCTAssertEqual(model.protectionStrip?.button, "Review Grants…")
        XCTAssertEqual(model.protectionStrip?.icon, "exclamationmark.shield")
        XCTAssertEqual(model.summary, "2 grants · Needs review")
        XCTAssertEqual(model.file.grants.count, 2, "grants on disk are still listed")
        XCTAssertNil(model.loadError)

        // Nothing changes: edits, Pause, Remove, New Grant and Approve.
        model.draft?.label = "Edited"
        let saved = await model.save()
        XCTAssertFalse(saved)
        await model.setPaused(true, project: "Coffee")
        await model.remove(project: "Coffee")
        model.beginNewGrant()
        XCTAssertNil(model.newGrant)
        let request = AgentAccessRequest(
            requestId: "req_1", libraryRoot: library.path, project: "Novel", profile: .read, readFolders: [],
            message: "", agent: "codex", session: "s", client: "cli", requestedAt: Self.created,
            expiresAt: Self.created.addingTimeInterval(86_400))
        await model.approve(request)
        XCTAssertEqual(alerts, ["Can’t Approve This Request"])
        XCTAssertEqual(try protectionOnDisk, .changedOutside, "nothing was written")

        // Review: the app's last verified copy names the change.
        model.beginReview()
        let review = try XCTUnwrap(model.review)
        XCTAssertEqual(review.title, "Review Agent Grants")
        XCTAssertTrue(review.knowsPrevious)
        XCTAssertEqual(review.changes["Silkweb"], "Changed: access raised to Read, Create and Update")
        XCTAssertNil(review.changes["Coffee"])
        review.kept.remove("Silkweb")
        let signed = await model.signGrants()
        XCTAssertTrue(signed)
        XCTAssertEqual(try protectionOnDisk, .protected)
        XCTAssertEqual(model.file.grants.map(\.project), ["Coffee"])
        XCTAssertFalse(model.isReadOnly)

        // Opened after the change, the app has no earlier copy: the caption asks the owner to check each grant.
        try widenOnDisk()
        let fresh = makeModel()
        await fresh.reload()
        fresh.beginReview()
        XCTAssertEqual(fresh.review?.knowsPrevious, false)
        XCTAssertEqual(fresh.review?.changes, [:])
    }

    func testMissingKeyIsRecoveredWithANewKey() async throws {
        try seedSigned([grant("Silkweb")])
        keys.removeKey()
        let model = makeModel()
        await model.reload()
        XCTAssertEqual(model.protection, .keyMissing)
        XCTAssertEqual(
            model.protectionStrip?.text, "Silkweb can’t find the key that protects agent grants on this Mac.")
        XCTAssertEqual(model.summary, "1 grant · Needs review")
        model.beginReview()
        let signed = await model.signGrants()
        XCTAssertTrue(signed)
        XCTAssertNotNil(try keys.verificationKey(), "a new key")
        XCTAssertEqual(try protectionOnDisk, .protected)
    }

    // MARK: Offscreen hierarchy

    /// GUI rule: the real window content through every protection state with a resize sweep, the read-only detail, and
    /// the review sheet at its 480 pt width.
    func testOffscreenWindowThroughEveryProtectionState() async throws {
        _ = NSApplication.shared
        try seedUnsigned([grant("Silkweb"), grant("Coffee", access: .read, revoked: Self.created)])
        let model = makeModel()
        await model.reload()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingController(rootView: AgentAccessView(model: model))
        host.sizingOptions = []
        window.contentViewController = host
        defer {
            window.contentViewController = nil
            window.close()
        }
        func sweep() async throws {
            for size in [
                NSSize(width: 680, height: 440), NSSize(width: 1400, height: 900), NSSize(width: 780, height: 520),
            ] {
                window.setContentSize(size)
                try await Task.sleep(for: .milliseconds(1))
                host.view.layoutSubtreeIfNeeded()
            }
        }
        try await sweep()
        let minimum = NSHostingView(rootView: AgentAccessView(model: model)).fittingSize
        XCTAssertGreaterThanOrEqual(minimum.height, 439, "the strip fits in the 440 pt minimum")

        await model.select(.grant("Silkweb"))
        try await sweep()
        model.beginReview()
        let sheet = NSHostingView(rootView: GrantReviewSheet(model: model, review: try XCTUnwrap(model.review)))
        XCTAssertEqual(sheet.fittingSize.width, 480, accuracy: 1)
        _ = await model.signGrants()
        try await sweep()
        XCTAssertNil(model.protectionStrip)

        try widenOnDisk()
        await model.reload()
        XCTAssertTrue(model.isReadOnly)
        for selection: AgentAccessModel.Selection in [.requests, .grant("Coffee"), .grant("Silkweb")] {
            await model.select(selection)
            try await sweep()
        }
        keys.removeKey()
        try seedSigned([grant("Silkweb")])
        keys.removeKey()
        await model.reload()
        XCTAssertEqual(model.protection, .keyMissing)
        try await sweep()
    }
}

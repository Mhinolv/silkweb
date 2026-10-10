import AppKit
import CoreServices
import LocalAuthentication
import SilkwebCore
import SwiftUI

/// #203: agents ask for access; the owner approves or denies in the Agent Access window (#229) or in Terminal.
/// Requests and their history live in `agent-access-requests.json` in Application Support, so the app reads them off
/// the main thread, watches the file and updates rows in place. Nothing is announced and focus never moves.
extension LibraryWorkspace {
    /// The Agent Activity row (and Go ▸ Agent Activity) exists once a receipt published a Document, or once this
    /// Library has any access request.
    var hasAgentActivity: Bool { agentActivity.hasPublished || !accessRequests.isEmpty || !outsideChanges.isEmpty }

    var pendingAccessRequestCount: Int {
        let now = accessRequestClock()
        return accessRequests.count { $0.isPending(at: now) }
    }

    /// “2 access requests waiting”, or nil when none wait.
    var accessRequestsWaitingLabel: String? {
        let count = pendingAccessRequestCount
        guard count > 0 else { return nil }
        return count == 1 ? "1 access request waiting" : "\(count) access requests waiting"
    }

    /// Rereads this Library's records. A broken or newer file leaves the rows as they were.
    func reloadAccessRequests() async {
        guard let root else { return }
        let store = accessRequestStore
        let library = root.path
        let previous = accessRequestReloadTask
        let task = Task {
            await previous?.value
            let loaded = await Task.detached(priority: .utility) {
                (try? store.load())?.requests.filter { $0.libraryRoot == library }
            }.value
            guard !Task.isCancelled, self.root == root, let loaded, loaded != accessRequests else { return }
            accessRequests = loaded
        }
        accessRequestReloadTask = task
        await task.value
    }

    /// Touch ID, falling back to the account password. Fails closed when neither is available.
    static func authenticateWithLocalAuthentication(_ reason: String) async -> Bool {
        guard NSClassFromString("XCTestCase") == nil else { return false }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}

/// The alerts Approve… and Deny… show. The first button is the action.
@MainActor enum AccessRequestAlerts {
    /// “Give “claude-code” Read and Create access to “Silkweb”?”
    static func confirm(_ request: AgentAccessRequest) -> NSAlert {
        let alert = NSAlert()
        alert.messageText =
            "Give “\(request.agentName)” \(request.profile.displayName) access to “\(request.project)”?"
        let folders = ([AgentMemoryContract.projectRoot(request.project)] + request.readFolders)
            .map(AgentMemoryContract.displayPath).joined(separator: "\n")
        // #228: the create folders the approval adds, read and create, everything inside them included.
        let creates =
            request.createFolders.isEmpty
            ? "" : "\n\n" + request.createSummary + "\nAgents can read and create in these, and in any folder inside."
        alert.informativeText =
            folders + creates + "\n\n"
            + (request.profile.allowsCreate
                ? "Agents can add documents there. They never edit or delete yours."
                : "Agents can search and read there. They never change anything.")
        alert.addButton(withTitle: "Approve")
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert
    }

    static func deny(_ request: AgentAccessRequest) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Deny the Request from “\(request.agentName)”?"
        alert.informativeText = "The agent sees that the request was denied, with your note."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "Note for the agent (optional)"
        field.setAccessibilityLabel("Note for the agent (optional)")
        alert.accessoryView = field
        alert.addButton(withTitle: "Deny").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
        return alert
    }

    /// “Can’t Approve This Request” with #186's copy, or “This request was already approved in Terminal.” A widen
    /// refusal for an existing grant adds Show Grant (#229) as the second button.
    static func refusal(_ error: Error, showGrant: Bool = false) -> NSAlert {
        let alert = NSAlert()
        if let error = error as? AgentAccessError {
            if error.code == "request_decided" || error.code == "request_not_found" {
                alert.messageText = error.message
            } else {
                alert.messageText = error.title
                alert.informativeText = error.message
            }
        } else {
            alert.messageText = "Can’t Approve This Request"
            alert.informativeText = "Silkweb couldn’t save the decision. Nothing was changed."
        }
        alert.addButton(withTitle: "OK")
        if showGrant { alert.addButton(withTitle: "Show Grant") }
        return alert
    }
}

/// One request, for any Library. Waiting rows carry Deny… and Approve…; history rows say what happened, in words.
struct AccessRequestRow: View {
    let model: AgentAccessModel
    let request: AgentAccessRequest
    let now: Date

    var body: some View {
        let pending = request.isPending(at: now)
        HStack(alignment: .top, spacing: Spacing.small) {
            VStack(alignment: .leading, spacing: 3) {
                (Text(request.agentName).fontWeight(.semibold) + Text("  wants  ").foregroundStyle(.secondary)
                    + Text(request.profile.displayName).fontWeight(.semibold)
                    + Text("  for “\(request.project)”"))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(libraryName + " · " + request.folderSummary).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2)
                if !request.message.isEmpty {
                    (Text("Message from the agent: ").foregroundStyle(.secondary) + Text("“\(request.message)”"))
                        .font(.caption).lineLimit(3)
                }
                Text(detail(pending: pending)).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer(minLength: Spacing.small)
            if pending {
                Button("Deny…") { Task { await model.deny(request) } }
                Button("Approve…") { Task { await model.approve(request) } }
            }
        }
        .disabled(model.deciding != nil)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(request.accessibilityLabel(now) + ", " + libraryName)
        .accessibilityValue(request.message.isEmpty ? "" : "Message from the agent: " + request.message)
        .modifier(DecisionActions(model: model, request: request, enabled: pending))
    }

    /// The Library's folder name: requests from every Library share the list.
    private var libraryName: String { URL(fileURLWithPath: request.libraryRoot).lastPathComponent }

    private func detail(pending: Bool) -> String {
        let asked = request.requestedAt.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        return pending
            ? "\(asked) · \(request.expiryLabel(now)) · agent and session are claimed, not verified"
            : request.historyLabel(now)
    }
}

/// Approve and Deny as VoiceOver actions on a waiting row.
private struct DecisionActions: ViewModifier {
    let model: AgentAccessModel
    let request: AgentAccessRequest
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityAction(named: "Approve") { Task { await model.approve(request) } }
                .accessibilityAction(named: "Deny") { Task { await model.deny(request) } }
        } else {
            content
        }
    }
}

/// Watches the folder holding `agent-access-requests.json` and `agent-grants.json` (or, until it exists, the folder
/// above it) with FSEvents, and calls `changed` once per burst that touches either file.
@MainActor final class AccessRequestWatcher {
    private var stream: FSEventStreamRef?
    private var pending: Task<Void, Never>?
    private let folder: String
    private let names: Set<String>
    private let changed: @MainActor () async -> Void

    init(file: URL, changed: @escaping @MainActor () async -> Void) {
        folder = file.deletingLastPathComponent().resolvingSymlinksInPath().path
        names = [file.lastPathComponent, "agent-grants.json"]
        self.changed = changed
        start()
    }

    private func start() {
        let exists = FileManager.default.fileExists(atPath: folder)
        let watched = exists ? folder : (folder as NSString).deletingLastPathComponent
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        stream = FSEventStreamCreate(
            nil,
            { _, info, _, paths, _, _ in
                guard let info else { return }
                let paths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
                MainActor.assumeIsolated {
                    Unmanaged<AccessRequestWatcher>.fromOpaque(info).takeUnretainedValue().receive(paths)
                }
            }, &context, [watched] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        if !FSEventStreamStart(stream) { stop() }
        // Watching the parent until the folder appears: switch to the folder itself then.
        watchingParent = !exists
    }

    private var watchingParent = false

    private func receive(_ paths: [String]) {
        let form = LibraryWatcher.eventPathForm
        let mine = form(folder)
        let relevant =
            paths.isEmpty
            || paths.contains { path in
                let event = form(path)
                return event == mine
                    || (event.hasPrefix(mine + "/") && names.contains((event as NSString).lastPathComponent))
            }
        guard relevant else { return }
        if watchingParent, FileManager.default.fileExists(atPath: folder) {
            stop()
            start()
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await self.changed()
        }
    }

    func stop() {
        pending?.cancel()
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        pending?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

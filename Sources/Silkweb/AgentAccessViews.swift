import AppKit
import SilkwebCore
import SwiftUI

/// #229: Go ▸ Agent Access… — one window for agent trust: every grant for every Library, and the #203 access
/// requests. Owner-only: agents and the helper never reach it.
struct AgentAccessWindow: View {
    let model: AgentAccessModel
    let registry: LibraryWindowRegistry

    var body: some View {
        AgentAccessView(model: model)
            .background(AgentAccessWindowProbe(model: model))
            .onAppear {
                model.registry = registry
                model.start()
            }
    }
}

/// Hands the hosting window to the model, for sheet alerts and the open panel.
private struct AgentAccessWindowProbe: NSViewRepresentable {
    let model: AgentAccessModel

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.model = model
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {}

    final class Probe: NSView {
        weak var model: AgentAccessModel?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { model?.window = window }
        }
    }
}

/// The window's content: the grants sidebar (240 pt) beside the selection's detail.
struct AgentAccessView: View {
    @Bindable var model: AgentAccessModel

    var body: some View {
        VStack(spacing: 0) {
            if let strip = model.protectionStrip { ProtectionStrip(model: model, strip: strip) }
            HStack(spacing: 0) {
                AgentAccessSidebar(model: model).frame(width: 240)
                Divider()
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 680, minHeight: 440)
        .background(Color.silkwebPaneBackground)
        .sheet(item: $model.newGrant) { form in NewGrantSheet(model: model, form: form) }
        .sheet(item: $model.review) { review in GrantReviewSheet(model: model, review: review) }
    }

    @ViewBuilder private var detail: some View {
        switch model.selection {
        case .requests:
            AccessRequestsDetail(model: model)
        case .grant:
            if model.draft != nil, model.outside != .deleted {
                GrantDetail(model: model)
            } else {
                ContentUnavailableView(
                    "This grant no longer exists.", systemImage: "person.badge.key",
                    description: Text("It was removed outside Silkweb."))
            }
        case nil:
            if let error = model.loadError {
                ContentUnavailableView(
                    "Can’t Read Agent Grants", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if model.file.grants.isEmpty {
                ContentUnavailableView {
                    Label("No Agent Grants", systemImage: "person.badge.key")
                } description: {
                    Text("Grants let coding agents read and add to a Library through the silkweb helper.")
                } actions: {
                    Button("New Grant…") { model.beginNewGrant() }
                }
            } else {
                ContentUnavailableView(
                    "No Grant Selected", systemImage: "person.badge.key",
                    description: Text("Choose a grant to see and change what agents may do."))
            }
        }
    }
}

// MARK: Protection (#205)

/// “Agent grants aren’t protected yet.” with Protect Grants…, or the changed-outside / key-missing copy with Review
/// Grants…: 32 pt, callout, text only, across the whole window. One VoiceOver element plus its labelled button.
struct ProtectionStrip: View {
    let model: AgentAccessModel
    let strip: (icon: String, text: String, button: String)

    var body: some View {
        HStack(spacing: Spacing.xSmall) {
            HStack(spacing: Spacing.xSmall) {
                Image(systemName: strip.icon).accessibilityHidden(true)
                Text(strip.text).lineLimit(1).truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Spacing.xSmall)
            Button(strip.button) { model.beginReview() }
                .accessibilityLabel(strip.button.replacingOccurrences(of: "…", with: ""))
        }
        .font(.callout).padding(.horizontal, Spacing.small).frame(height: 32)
        .paneStrip(hairline: .bottom)
    }
}

/// Protect Agent Grants / Review Agent Grants (480 pt): every grant on disk with a keep checkbox, then Sign Grants
/// after owner authentication. Unchecked grants are removed.
struct GrantReviewSheet: View {
    let model: AgentAccessModel
    @Bindable var review: GrantReview

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(review.title).font(.headline)
            Text(
                review.protecting
                    ? "Silkweb signs the grants you keep with a key in your keychain. Agents then can’t use a grant "
                        + "changed outside Silkweb."
                    : "Keep only the grants you recognise. Silkweb signs them again, and agents can use them once more."
            )
            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !review.knowsPrevious {
                Text("Silkweb doesn’t have the previous version. Uncheck any grant you don’t recognise.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.small) {
                    ForEach(review.file.grants, id: \.project) { grant in row(grant) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.small)
            }
            .frame(maxHeight: 280)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            HStack {
                Spacer()
                Button("Cancel") { model.review = nil }.keyboardShortcut(.cancelAction)
                Button("Sign Grants") { Task { await model.signGrants() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(review.signing)
            }
        }
        .padding(Spacing.large)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.silkwebPaneBackground)
    }

    private func row(_ grant: AgentGrant) -> some View {
        Toggle(
            isOn: Binding(
                get: { review.kept.contains(grant.project) },
                set: { keep in
                    if keep { review.kept.insert(grant.project) } else { review.kept.remove(grant.project) }
                })
        ) {
            VStack(alignment: .leading, spacing: 1) {
                Text(grant.displayLabel)
                Text(Self.detail(grant)).font(.caption).foregroundStyle(.secondary)
                if let change = review.changes[grant.project] {
                    Text(change).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel("Keep “\(grant.displayLabel)”")
    }

    /// “Silkweb Library · Read and Create · Paused”.
    static func detail(_ grant: AgentGrant) -> String {
        var parts = [
            grant.library.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "No Library",
            grant.access.displayName,
        ]
        if grant.isRevoked { parts.append("Paused") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Sidebar

struct AgentAccessSidebar: View {
    let model: AgentAccessModel

    var body: some View {
        let waiting = model.waitingCount
        VStack(spacing: 0) {
            List(
                selection: Binding(
                    get: { model.selection }, set: { next in Task { await model.select(next) } })
            ) {
                Label(waiting > 0 ? "Access Requests (\(waiting))" : "Access Requests", systemImage: "hand.raised")
                    .tag(AgentAccessModel.Selection.requests)
                    .accessibilityValue(
                        waiting == 1 ? "1 request waiting" : waiting > 0 ? "\(waiting) requests waiting" : "")
                ForEach(model.groups) { group in
                    Section {
                        ForEach(group.grants, id: \.project) { grant in
                            GrantRow(model: model, grant: grant).tag(AgentAccessModel.Selection.grant(grant.project))
                        }
                    } header: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(group.name)
                            Text(model.missingLibraries.contains(group.path) ? "Not found" : group.path)
                                .font(.caption2).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            Divider()
            HStack(spacing: 0) {
                Button {
                    model.beginNewGrant()
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 20)
                }
                .help("New Grant…").accessibilityLabel("New Grant…")
                .disabled(model.isReadOnly)
                Button {
                    if case .grant(let project) = model.selection { Task { await model.remove(project: project) } }
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 20)
                }
                .help("Remove Grant…").accessibilityLabel("Remove Grant…")
                .disabled(!model.selectsGrant || model.isReadOnly)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, Spacing.xxSmall).padding(.vertical, Spacing.xxSmall)
        }
    }
}

/// “Silkweb project” over “Read and Create · active Oct 9”; a paused grant is secondary with a trailing “Paused”.
struct GrantRow: View {
    let model: AgentAccessModel
    let grant: AgentGrant

    var body: some View {
        HStack(spacing: Spacing.xSmall) {
            VStack(alignment: .leading, spacing: 1) {
                Text(grant.displayLabel).lineLimit(1)
                Text(model.rowDetail(grant)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if grant.isRevoked { Text("Paused").font(.caption).foregroundStyle(.secondary) }
        }
        .foregroundStyle(grant.isRevoked ? .secondary : .primary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.accessibilityLabel(grant))
        .accessibilityAction(named: grant.isRevoked ? "Resume Access" : "Pause Access") { togglePause() }
        .accessibilityAction(named: "Remove Grant") { Task { await model.remove(project: grant.project) } }
        .contextMenu {
            // #205: nothing changes while grants need review.
            Button(grant.isRevoked ? "Resume Access" : "Pause Access") { togglePause() }.disabled(model.isReadOnly)
            Divider()
            Button("Remove Grant…") { Task { await model.remove(project: grant.project) } }.disabled(model.isReadOnly)
        }
    }

    private func togglePause() {
        Task { await model.setPaused(!grant.isRevoked, project: grant.project) }
    }
}

// MARK: Grant detail

/// One grant as a grouped form. Edits apply with Save; widening asks for owner authentication first.
struct GrantDetail: View {
    @Bindable var model: AgentAccessModel
    @Environment(\.openWindow) private var openWindow
    /// Looked up once: `~/.local/bin/silkweb`, else the placeholder in the install lines.
    private static let helper = AgentGrantOwner.installedHelper()

    var body: some View {
        if let grant = model.draft {
            VStack(spacing: 0) {
                if model.outside == .changed {
                    HStack {
                        Text("This grant was changed outside Silkweb.")
                        Spacer()
                        Button("Reload") { model.reloadSelection() }
                    }
                    .font(.callout).padding(.horizontal, Spacing.small).frame(height: 32)
                    .paneStrip(hairline: .bottom)
                }
                Form {
                    // #205: read-only while grants need review; Client setup stays usable.
                    Group {
                        identity(grant)
                        access(grant)
                        readFolders(grant)
                        createFolders(grant)
                        agentFolder(grant)
                        status(grant)
                    }
                    .disabled(model.isReadOnly)
                    Section {
                        DisclosureGroup("Client setup") {
                            let block = AgentGrantOwner.installBlock(
                                project: grant.project, library: grant.library.path, helper: Self.helper)
                            Text(block).font(.caption.monospaced()).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Spacer()
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(block, forType: .string)
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                if !model.isReadOnly {
                    Divider()
                    HStack {
                        Spacer()
                        Button("Revert") { model.revert() }.disabled(!model.isEdited)
                        Button("Save") { Task { await model.save() } }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.isEdited || model.saving)
                    }
                    .padding(Spacing.small)
                }
            }
        }
    }

    private func identity(_ grant: AgentGrant) -> some View {
        Section {
            TextField(
                "Label",
                text: Binding(get: { model.draft?.label ?? "" }, set: { model.draft?.label = $0 }),
                prompt: Text(grant.project + " project"))
            LabeledContent("Project key") {
                Text(grant.project).font(.body.monospaced()).textSelection(.enabled)
            }
            LabeledContent("Library") {
                HStack(spacing: Spacing.xSmall) {
                    let path = grant.library.path ?? ""
                    Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if model.missingLibraries.contains(path) {
                        Text("Not found").foregroundStyle(.tertiary)
                    } else {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                }
            }
        }
    }

    private func access(_ grant: AgentGrant) -> some View {
        Section("Access") {
            Picker(
                "Access",
                selection: Binding(get: { model.draft?.access ?? .read }, set: { model.draft?.access = $0 })
            ) {
                ForEach([AgentGrant.Access.read, .readCreate, .readCreateUpdate], id: \.self) { level in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(level.displayName)
                        Text(Self.description(level)).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(level)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    /// The #186 one-line descriptions.
    static func description(_ access: AgentGrant.Access) -> String {
        switch access {
        case .read: return "Agents search and read."
        case .readCreate: return "Agents can also add documents. They never edit or delete."
        case .readCreateUpdate:
            return "Agents can also update documents an agent created. They never change yours or delete anything."
        }
    }

    private func readFolders(_ grant: AgentGrant) -> some View {
        Section("Read folders") {
            Text(AgentMemoryContract.displayPath(AgentMemoryContract.projectRoot(grant.project)))
            ForEach(grant.extraReadFolders, id: \.self) { folder in
                HStack {
                    Text(AgentMemoryContract.displayPath(folder))
                    Spacer()
                    Button {
                        model.removeReadFolder(folder)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove Folder").accessibilityLabel("Remove “\(AgentMemoryContract.displayPath(folder))”")
                }
            }
            HStack {
                Spacer()
                Button("Add Folder…") { Task { await model.chooseReadFolder() } }
                    .disabled(model.missingLibraries.contains(grant.library.path ?? ""))
            }
        }
    }

    private func createFolders(_ grant: AgentGrant) -> some View {
        Section {
            let folders = AgentGrantOwner.createFolders(grant)
            if folders.isEmpty {
                Text("None. Read Only agents can’t add documents.").foregroundStyle(.secondary)
            } else {
                ForEach(folders, id: \.self) { Text(AgentMemoryContract.displayPath($0)) }
            }
        } header: {
            Text("Create folders")
        } footer: {
            Text("Agents can add documents only in these folders.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func agentFolder(_ grant: AgentGrant) -> some View {
        Section {
            TextField(
                "Agent folder",
                text: Binding(
                    get: { model.draft?.agentFolder ?? "" },
                    set: { model.draft?.agentFolder = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }),
                prompt: Text("None"))
        } footer: {
            Text(Self.agentCaption(grant)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The #206 additions text.
    static func agentCaption(_ grant: AgentGrant) -> String {
        guard let key = grant.agentFolder else {
            return "An agent folder in \(AgentMemoryContract.displayPath(AgentMemoryContract.agentsFolder)) is shared "
                + "by every grant with the same name."
        }
        let root = AgentMemoryContract.displayPath(AgentMemoryContract.agentRoot(key))
        return grant.access.allowsCreate
            ? "Agents read all of \(root) and create memories in its \(AgentMemoryContract.agentMemoriesFolder)."
            : "Agents read all of \(root)."
    }

    private func status(_ grant: AgentGrant) -> some View {
        Section {
            Toggle("Allow access", isOn: Binding(get: { !(model.draft?.isRevoked ?? false) }, set: model.setAllowed))
            if let since = grant.revokedAt {
                Text(since == .distantPast ? "Paused" : "Paused since " + AgentAccessRequests.shortDate(since))
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Last activity") {
                if let activity = model.activity[grant.project] {
                    HStack(spacing: Spacing.xSmall) {
                        Text(
                            activity.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) + " · "
                                + activity.agent)
                        Button("Show in Agent Activity") {
                            if model.registry?.hasWindow == false { openWindow(id: LibraryWindow.sceneID) }
                            Task { await model.showInAgentActivity(grant) }
                        }
                    }
                } else {
                    Text("No activity yet").foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: Access Requests

/// The #203 rows for every Library: Waiting (oldest first), then History (newest first, at most 50).
struct AccessRequestsDetail: View {
    let model: AgentAccessModel

    var body: some View {
        let now = model.clock()
        let review = model.review(now)
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text("Access Requests").font(.headline).padding([.top, .horizontal], Spacing.large)
            if review.waiting.isEmpty && review.history.isEmpty {
                ContentUnavailableView(
                    "No Access Requests", systemImage: "hand.raised",
                    description: Text("When an agent asks for access to a Library, it appears here.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !review.waiting.isEmpty {
                        Section("Waiting") {
                            ForEach(review.waiting) { AccessRequestRow(model: model, request: $0, now: now) }
                        }
                    }
                    if !review.history.isEmpty {
                        Section("History") {
                            ForEach(review.history) { AccessRequestRow(model: model, request: $0, now: now) }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }
}

// MARK: New Grant

/// New Grant… (480 pt): Library, project key with its inline error, optional label, access and agent folder.
struct NewGrantSheet: View {
    let model: AgentAccessModel
    @Bindable var form: NewGrantForm
    @State private var creating = false

    var body: some View {
        let error = model.projectError(form.project)
        let key = AgentGrantOwner.validProject(form.project)
        VStack(alignment: .leading, spacing: 0) {
            Text("New Grant").font(.headline).padding([.top, .horizontal], Spacing.large)
            Form {
                LabeledContent("Library") {
                    HStack {
                        Picker("Library", selection: $form.library) {
                            ForEach(choices, id: \.self) { path in
                                Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                            }
                        }
                        .labelsHidden()
                        Button("Choose…") { chooseLibrary() }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Project key", text: $form.project, prompt: Text("Silkweb"))
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else if let key {
                        Text(
                            "Agents use \(AgentMemoryContract.displayPath(AgentMemoryContract.projectRoot(key))). "
                                + "Nothing is created now."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("Label", text: $form.label, prompt: Text("Optional"))
                Picker("Access", selection: $form.access) {
                    ForEach([AgentGrant.Access.read, .readCreate, .readCreateUpdate], id: \.self) {
                        Text($0.displayName).tag($0)
                    }
                }
                .pickerStyle(.radioGroup)
                TextField("Agent folder", text: $form.agentFolder, prompt: Text("None"))
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.newGrant = nil }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    creating = true
                    Task {
                        await model.create(form)
                        creating = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(creating || key == nil || error != nil || form.library.isEmpty)
            }
            .padding([.horizontal, .bottom], Spacing.large)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.silkwebPaneBackground)
    }

    private var choices: [String] {
        let paths = model.libraryChoices
        return form.library.isEmpty || paths.contains(form.library) ? paths : [form.library] + paths
    }

    private func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the Library folder agents may use."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        form.library = url.path
    }
}

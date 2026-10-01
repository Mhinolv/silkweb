import AppKit
import SwiftUI
import SilkwebCore

/// Owns the visible buffer. Actor work is ordered so a flush includes every edit.
@MainActor @Observable
final class DocumentSession {
    var text = ""
    var url: URL?
    var state: DocumentSaveState = .clean
    var readOnly = false
    var recovered = false
    var error: String?
    var loading = false
    var refusedNavigation = 0
    @ObservationIgnored var selection = NSRange(location: 0, length: 0)
    @ObservationIgnored var scroll = NSPoint.zero
    private var positions: [URL: (NSRange, NSPoint)] = [:]
    private var coordinator = SaveCoordinator()
    private var tail: Task<Void, Never>?
    private var observation: Task<Void, Never>?
    private var pendingEdits = 0

    var name: String { url?.deletingPathExtension().lastPathComponent ?? "Document" }
    var banner: String? {
        if let error { return error }
        if case .failed = state { return "Silkweb couldn’t save “\(name)”. Your text is safe in this window." }
        if case .conflict = state { return "This document changed on disk. Your text is safe in this window. Save a copy to keep it." }
        if recovered { return "Silkweb recovered unsaved changes to this document." }
        return nil
    }

    func configure(root: URL) async {
        observation?.cancel()
        coordinator = SaveCoordinator(store: DocumentStore(root: root))
        positions = [:]
        url = nil
        text = ""
        state = .clean
    }

    func open(_ destination: URL?, readOnly: Bool) async -> Bool {
        guard destination != url else { return true }
        loading = true
        defer { loading = false }
        guard await flush(), !recovered else { refusedNavigation += 1; announce(); return false }
        if let url {
            positions[url] = (selection, scroll)
            guard await coordinator.close(url) else { return false }
        }
        observation?.cancel()
        url = destination
        text = ""
        state = .clean
        error = nil
        self.readOnly = readOnly
        recovered = false
        guard let destination else { return true }
        do {
            if let draft = try await coordinator.pendingRecoveryDrafts().first(where: { $0.documentURL.standardizedFileURL == destination }) {
                await coordinator.restore(draft)
                text = draft.text
                state = .dirty
                recovered = true
                announce()
            } else {
                text = try await coordinator.open(destination).text
            }
        } catch let failure as NSError where failure.code == NSFileReadInapplicableStringEncodingError {
            self.readOnly = true
            text = (try? await Task.detached { String(decoding: try Data(contentsOf: destination), as: UTF8.self) }.value) ?? ""
            error = "This file isn’t UTF-8 text, so Silkweb opened it read-only."
            announce()
        } catch {
            self.readOnly = true
            self.error = error.localizedDescription
            announce()
        }
        (selection, scroll) = positions[destination] ?? (NSRange(location: 0, length: 0), .zero)
        let coordinator = coordinator
        observation = Task { [weak self] in
            for await value in await coordinator.states(for: destination) {
                guard !Task.isCancelled, let self, self.url == destination else { return }
                if self.pendingEdits == 0 {
                    self.state = value
                    if self.banner != nil { self.announce() }
                }
            }
        }
        return true
    }

    func edit(_ value: String) {
        guard !readOnly, let url else { return }
        text = value
        state = .dirty
        pendingEdits += 1
        let previous = tail
        let coordinator = coordinator
        tail = Task {
            await previous?.value
            do {
                try await coordinator.edit(value, at: url)
                if !recovered { await coordinator.scheduleSave(url) }
            } catch { self.error = error.localizedDescription }
            pendingEdits -= 1
        }
    }

    @discardableResult
    func flush() async -> Bool {
        await tail?.value
        guard let url, !readOnly else { return true }
        guard !recovered else { return false }
        let value = text
        let result = await coordinator.save(url) ?? .clean
        // Typing may continue while IO runs. Never mark newer text clean.
        if value == text, pendingEdits == 0 { state = result }
        if result.isDirty { announce() }
        return !result.isDirty && value == text && pendingEdits == 0
    }

    func keepRecovery() {
        recovered = false
        Task { _ = await flush() }
    }

    func discardRecovery() {
        let alert = NSAlert()
        alert.messageText = "Discard the recovered text? This can’t be undone."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Discard Recovered Text")
        guard alert.runModal() == .alertSecondButtonReturn, let url else { return }
        Task {
            await tail?.value
            do {
                try await coordinator.discardRecovery(url)
                recovered = false
                state = .clean
                text = ""
                do { text = try await coordinator.open(url).text }
                catch { readOnly = true; self.error = error.localizedDescription }
            } catch { self.error = error.localizedDescription }
        }
    }

    func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name + " copy.md"
        panel.begin { [weak self] response in
            guard response == .OK, let target = panel.url, let self else { return }
            let value = self.text
            Task {
                do { try await Task.detached { try Data(value.utf8).write(to: target, options: .atomic) }.value }
                catch { self.error = error.localizedDescription; self.announce() }
            }
        }
    }

    func prepareToExit() async -> Bool {
        loading = true
        defer { loading = false }
        if await flush() { return true }
        do { try await coordinator.preserveUnsavedDrafts() }
        catch { self.error = "Recovery draft couldn’t be saved: \(error.localizedDescription)"; announce(); return false }
        let alert = NSAlert()
        alert.messageText = "Some changes couldn’t be saved."
        alert.informativeText = "They’ll be kept as a recovery draft and offered the next time you open Silkweb."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Anyway")
        return alert.runModal() == .alertSecondButtonReturn
    }

    func didCloseWindow() async {
        if let url, !state.isDirty { _ = await coordinator.close(url) }
        observation?.cancel()
        url = nil
        text = ""
        state = .clean
        recovered = false
        error = nil
    }

    func announce() {
        guard let banner else { return }
        NSAccessibility.post(element: NSApp.mainWindow ?? NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: banner, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }
}

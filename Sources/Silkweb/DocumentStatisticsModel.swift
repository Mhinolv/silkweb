import Foundation
import Observation
import SilkwebCore

/// Debounced word/character counts for one document buffer (silkweb-1.25). Only `document`
/// and `selection` publish, and only when they change, so the status bar never re-renders per
/// keystroke or scroll tick. Large buffers are counted off the main thread.
@MainActor @Observable
final class DocumentStatisticsModel {
    private(set) var document: DocumentStatistics?
    /// Counts for a non-empty editor selection; `nil` when the selection is collapsed.
    private(set) var selection: DocumentStatistics?

    static let debounce = Duration.milliseconds(300)
    /// UTF-16 length above which counting moves off the main thread.
    static let backgroundThreshold = 50_000

    @ObservationIgnored private weak var session: DocumentSession?
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    /// How many counts ran, for tests that verify no work happens on scroll.
    @ObservationIgnored private(set) var refreshCount = 0

    init(session: DocumentSession) {
        self.session = session
        observeText()
        refreshNow()
    }

    /// Re-arms on every text or document change; the work itself is debounced.
    private func observeText() {
        withObservationTracking {
            _ = session?.text
            _ = session?.url
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.observeText()
                self.scheduleRefresh()
            }
        }
    }

    /// A caret move with no selection before or after changes nothing.
    func selectionDidChange(_ range: NSRange) {
        guard range.length > 0 || selection != nil else { return }
        scheduleRefresh()
    }

    func scheduleRefresh() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Counts immediately when the buffer is small enough for the main thread.
    func refreshNow() {
        guard let session, (session.text as NSString).length <= Self.backgroundThreshold else {
            scheduleRefresh(); return
        }
        pending?.cancel()
        generation += 1
        let (text, range) = Self.capture(session)
        publish(Self.compute(text: text, selection: range))
    }

    func refresh() async {
        guard let session else { return }
        generation += 1
        let current = generation
        let (text, range) = Self.capture(session)
        let result: (DocumentStatistics, DocumentStatistics?)
        if (text as NSString).length > Self.backgroundThreshold {
            result = await Task.detached(priority: .utility) { Self.compute(text: text, selection: range) }.value
            guard current == generation else { return }
        } else {
            result = Self.compute(text: text, selection: range)
        }
        publish(result)
    }

    private func publish(_ result: (DocumentStatistics, DocumentStatistics?)) {
        refreshCount += 1
        if document != result.0 { document = result.0 }
        if selection != result.1 { selection = result.1 }
    }

    private static func capture(_ session: DocumentSession) -> (String, NSRange) {
        let length = (session.text as NSString).length
        let location = min(session.selection.location, length)
        return (session.text, NSRange(location: location, length: min(session.selection.length, length - location)))
    }

    nonisolated private static func compute(text: String, selection: NSRange) -> (
        DocumentStatistics, DocumentStatistics?
    ) {
        let document = DocumentStatistics.count(text)
        guard selection.length > 0 else { return (document, nil) }
        return (document, DocumentStatistics.count((text as NSString).substring(with: selection)))
    }
}

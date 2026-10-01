import AppKit
import SwiftUI

struct EditorStyle: Equatable {
    var fontSize: CGFloat = 15
    var lineHeight: CGFloat = 1.5
    var maximumWidth: CGFloat = 720
    var horizontalInset: CGFloat = 40
    var topInset: CGFloat = 24
}

struct MarkdownTextView: NSViewRepresentable {
    let session: DocumentSession
    let workspace: LibraryWorkspace
    var style = EditorStyle()

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = Self.makeEditorScrollView(style: style)
        let text = scroll.documentView as! PlainMarkdownTextView
        text.delegate = context.coordinator
        text.moveFocus = { workspace.focus($0 ? 1 : 0) }
        context.coordinator.textView = text
        scroll.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main
        ) { [weak session] notification in
            MainActor.assumeIsolated {
                session?.scroll = (notification.object as? NSClipView)?.bounds.origin ?? .zero
            }
        }
        return scroll
    }

    /// Shared construction keeps offscreen regression tests on the production editor hierarchy.
    static func makeEditorScrollView(style: EditorStyle) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.automaticallyAdjustsContentInsets = false
        let text = PlainMarkdownTextView()
        text.style = style
        text.isRichText = false
        text.importsGraphics = false
        text.allowsUndo = true
        text.usesFindBar = true
        text.isContinuousSpellCheckingEnabled = true
        text.isGrammarCheckingEnabled = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.font = .systemFont(ofSize: style.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = style.lineHeight
        text.defaultParagraphStyle = paragraph
        text.typingAttributes = [.font: text.font!, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        text.textColor = .labelColor
        text.backgroundColor = .textBackgroundColor
        text.insertionPointColor = .controlAccentColor
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.heightTracksTextView = false
        text.textContainer?.lineFragmentPadding = 0
        scroll.documentView = text
        text.layoutEditor()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? PlainMarkdownTextView else { return }
        let coordinator = context.coordinator
        text.session = session
        if coordinator.url != session.url {
            let selection = session.selection
            let position = session.scroll
            coordinator.url = session.url
            text.string = session.text
            text.undoManager?.removeAllActions()
            let count = (text.string as NSString).length
            text.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - selection.location))))
            text.layoutEditor()
            scroll.contentView.scroll(to: position)
            scroll.reflectScrolledClipView(scroll.contentView)
        } else if text.string != session.text, !text.hasMarkedText() {
            text.string = session.text
            text.undoManager?.removeAllActions()
        }
        text.isEditable = !session.readOnly && !session.loading
        text.setAccessibilityLabel("Document text, \(session.name)")
        text.window?.isDocumentEdited = session.state.isDirty
        text.needsDisplay = true
        if coordinator.focusRequest != workspace.focusRequest {
            coordinator.focusRequest = workspace.focusRequest
            if workspace.focusColumn == 2 { text.window?.makeFirstResponder(text) }
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let session: DocumentSession
        weak var textView: NSTextView?
        var scrollObserver: NSObjectProtocol?
        deinit { if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) } }
        var url: URL?
        var focusRequest = 0
        init(session: DocumentSession) { self.session = session }
        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            !session.loading && !session.readOnly
        }
        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            session.edit(textView.string)
            textView.needsDisplay = true
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            session.selection = textView.selectedRange()
            session.scroll = textView.enclosingScrollView?.contentView.bounds.origin ?? .zero
        }
    }
}

/// The stock text view supplies Unicode, IME, undo and accessibility navigation.
final class PlainMarkdownTextView: NSTextView {
    var style = EditorStyle()
    weak var session: DocumentSession?
    var moveFocus: ((Bool) -> Void)?
    private var isLayingOutEditor = false

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutEditor()
    }

    func layoutEditor() {
        // NSTextView geometry setters can synchronously resize the view and call us again.
        guard !isLayingOutEditor, let scroll = enclosingScrollView else { return }
        isLayingOutEditor = true
        defer { isLayingOutEditor = false }

        // Use the scroll view's viewport, never the text view's content-driven frame.
        let viewport = scroll.contentSize
        let width = max(1, min(style.maximumWidth, viewport.width - 2 * style.horizontalInset))
        let containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let container = textContainer, container.containerSize != containerSize {
            container.containerSize = containerSize
        }
        let inset = NSSize(width: max(style.horizontalInset, (viewport.width - width) / 2), height: style.topInset)
        if textContainerInset != inset { textContainerInset = inset }
        var contentInsets = scroll.contentInsets
        contentInsets.bottom = viewport.height / 2
        if scroll.contentInsets.bottom != contentInsets.bottom { scroll.contentInsets = contentInsets }
        let minimum = NSSize(width: 0, height: viewport.height)
        if minSize != minimum { minSize = minimum }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layoutEditor()
    }

    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }
    override func pasteAsRichText(_ sender: Any?) { pasteAsPlainText(sender) }
    override func pasteAsPlainText(_ sender: Any?) {
        guard isEditable, let value = NSPasteboard.general.string(forType: .string) else { return }
        insertText(value, replacementRange: selectedRange())
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 48, !event.modifierFlags.contains(.option), !event.modifierFlags.contains(.control) {
            moveFocus?(event.modifierFlags.contains(.shift))
        } else { super.keyDown(with: event) }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty && isEditable {
            ("Start writing…" as NSString).draw(at: textContainerOrigin, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: style.fontSize), .foregroundColor: NSColor.tertiaryLabelColor
            ])
        }
    }
}

struct EditorBanner: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var opacity = 1.0
    let session: DocumentSession
    var body: some View {
        if let message = session.banner {
            HStack(spacing: 8) {
                Image(systemName: session.readOnly || session.recovered ? "info.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(session.readOnly || session.recovered ? Color.secondary : Color(nsColor: .systemOrange))
                VStack(alignment: .leading, spacing: 4) {
                    Text(message).font(.callout)
                    if case .failed(let failure, _) = session.state { Text(failure.localizedDescription).font(.subheadline).foregroundStyle(.secondary) }
                }
                Spacer()
                if session.recovered {
                    Button("Keep Recovered Text") { session.keepRecovery() }
                    Button("Discard Recovered Text") { session.discardRecovery() }
                } else if session.state.isDirty {
                    Button("Try Again") { Task { await session.flush() } }
                    Button("Save a Copy…") { session.saveCopy() }
                }
            }
            .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 36).background(.bar)
            .opacity(opacity)
            .task(id: session.refusedNavigation) {
                guard session.refusedNavigation > 0, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 0.12)) { opacity = 0.5 }
                try? await Task.sleep(for: .milliseconds(120))
                withAnimation(.easeIn(duration: 0.12)) { opacity = 1 }
            }
        }
    }
}

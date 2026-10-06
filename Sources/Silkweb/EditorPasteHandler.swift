import AppKit
import SilkwebCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorPasteContent {
    var plainText: String?
    var fileURLs: [URL] = []
    var png: Data?
    var tiff: Data?

    init(plainText: String? = nil, fileURLs: [URL] = [], png: Data? = nil, tiff: Data? = nil) {
        self.plainText = plainText; self.fileURLs = fileURLs; self.png = png; self.tiff = tiff
    }
    init(pasteboard: NSPasteboard) {
        plainText = pasteboard.string(forType: .string)
        fileURLs =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        png = pasteboard.data(forType: .init("public.png"))
        tiff = pasteboard.data(forType: .tiff)
    }
}

/// Reads pasteboard representations on main; decodes images and copies files off-main.
@MainActor final class EditorPasteHandler {
    weak var editor: PlainMarkdownTextView?
    var root: URL?
    var documentID: UUID?
    weak var workspace: LibraryWorkspace?
    private(set) var busy = false
    var readContent: (NSPasteboard) -> EditorPasteContent = { EditorPasteContent(pasteboard: $0) }

    func files(from pasteboard: NSPasteboard) -> [AssetInput] {
        Self.files(in: readContent(pasteboard), imagesOnly: false)
    }

    static func files(in content: EditorPasteContent, imagesOnly: Bool) -> [AssetInput] {
        content.fileURLs.compactMap { url in
            let image = Self.isImageExtension(url.pathExtension)
            guard !imagesOnly || image else { return nil }
            return AssetInput(name: url.lastPathComponent, isImage: image, file: url)
        }
    }

    static func isImageExtension(_ value: String) -> Bool {
        // Common formats do not need a Launch Services lookup (also works offline
        // in offscreen tests where the system type service is unavailable).
        let known: Set<String> = [
            "png", "jpg", "jpeg", "jpe", "gif", "tif", "tiff", "heic", "heif", "bmp", "webp", "avif", "svg", "ico",
            "icns",
        ]
        return known.contains(value.lowercased()) || UTType(filenameExtension: value)?.conforms(to: .image) == true
    }

    @discardableResult func paste(from pasteboard: NSPasteboard) -> Bool {
        paste(readContent(pasteboard))
    }

    @discardableResult func paste(_ content: EditorPasteContent) -> Bool {
        guard let editor, editor.isEditable, !editor.hasMarkedText(), !busy else { return false }
        let inputs = Self.files(in: content, imagesOnly: true)
        if !inputs.isEmpty { return add(inputs) }
        let png = content.png
        let raster = png ?? content.tiff
        guard let raster else {
            guard let text = content.plainText else { return false }
            editor.insertText(text, replacementRange: editor.selectedRange())
            return true
        }
        return start(count: 1) {
            let data: Data
            if let png {
                data = png
            } else {
                guard let bitmap = NSBitmapImageRep(data: raster),
                    let encoded = bitmap.representation(using: .png, properties: [:])
                else {
                    return AssetBatchFailure.invalidImage
                }
                data = encoded
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            return .inputs([
                AssetInput(name: "image-\(formatter.string(from: Date())).png", isImage: true, data: data, alt: "image")
            ])
        }
    }

    @discardableResult func add(_ inputs: [AssetInput]) -> Bool {
        guard !inputs.isEmpty else { return false }
        return start(count: inputs.count) { .inputs(inputs) }
    }

    private func start(count: Int, prepare: @escaping @Sendable () -> AssetBatchFailure) -> Bool {
        guard let editor, editor.isEditable, !editor.hasMarkedText(), !busy,
            let session = editor.session
        else { return false }
        // A restored editor can exist before the snapshot arrives. Resolve from
        // the current snapshot at insertion time rather than caching a missing ID.
        let root = workspace != nil ? workspace?.root : root
        let id: UUID?
        if let workspace {
            id =
                workspace.snapshot?.documents.first {
                    root?.appendingPathComponent($0.relativePath) == session.url
                }?.id
        } else {
            id = documentID
        }
        guard let root, let id, let document = session.url else {
            session.assetFailures = []
            session.assetMessage =
                "Silkweb couldn’t add files because this document isn’t available in the library. Try again after the library has loaded."
            NSAccessibility.post(
                element: editor, notification: .announcementRequested,
                userInfo: [
                    .announcement: session.assetMessage!, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                ])
            return false
        }
        let original = editor.string
        let selection = editor.selectedRange()
        busy = true
        editor.isEditable = false
        FormattingTarget.shared.refresh()
        session.assetMessage = nil
        session.assetFailures = []
        Task { [self, weak editor] in
            let progress = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                if session.url == document {
                    session.assetProgress = "Adding \(count) \(count == 1 ? "file" : "files")…"
                }
            }
            let prepared = await Task.detached(priority: .userInitiated, operation: prepare).value
            let result: AssetBatch
            switch prepared {
            case .inputs(let inputs):
                result = await AssetStore.shared.add(inputs, root: root, document: document, id: id)
            case .invalidImage:
                var failure = AssetBatch()
                failure.failures = [AssetFailure(name: "image", reason: "The clipboard image couldn’t be decoded.")]
                result = failure
            }
            progress.cancel()
            session.assetProgress = nil
            busy = false
            guard let editor else { return }
            editor.isEditable = !session.readOnly && !session.loading
            FormattingTarget.shared.refresh()
            guard session.url == document else { return }
            guard editor.string == original else {
                session.assetMessage =
                    "The document changed while files were being added. Try inserting again. Copied files are preserved."
                return
            }
            if let edit = AssetStore.insertion(result.assets, text: original, selection: selection) {
                editor.apply(
                    edit, name: result.assets.contains(where: \.isImage) ? "Insert Image" : "Insert Attachment")
            }
            session.assetFailures = result.failures
            if let failure = result.failures.first {
                session.assetMessage =
                    count == 1
                    ? "Silkweb couldn’t add “\(failure.name)”."
                    : "\(result.failures.count) of \(count) files couldn’t be added."
                NSAccessibility.post(
                    element: editor, notification: .announcementRequested,
                    userInfo: [
                        .announcement: session.assetMessage!, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ])
            }
        }
        return true
    }

    func chooseImages() {
        guard let editor, let window = editor.window, editor.isEditable, !busy else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            let inputs = panel.urls.map { AssetInput(name: $0.lastPathComponent, isImage: true, file: $0) }
            self?.add(inputs)
        }
    }
}

private enum AssetBatchFailure: Sendable {
    case inputs([AssetInput])
    case invalidImage
}

struct AssetErrorBanner: View {
    let session: DocumentSession
    @State private var showingDetails = false
    var body: some View {
        if session.banner == nil, let message = session.assetMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
                VStack(alignment: .leading, spacing: 4) {
                    Text(message).font(.callout)
                    if session.assetFailures.count == 1 {
                        Text(session.assetFailures[0].reason).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if !session.assetFailures.isEmpty {
                    Button("Details") { showingDetails = true }
                        .popover(isPresented: $showingDetails) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(Array(session.assetFailures.enumerated()), id: \.offset) { _, failure in
                                        Text("\(failure.name) — \(failure.reason)").textSelection(.enabled)
                                    }
                                }.padding()
                            }.frame(width: 360, height: 200)
                        }
                }
                Button {
                    session.assetMessage = nil; session.assetFailures = []
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("Dismiss message").help("Dismiss message")
            }
            .controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minHeight: 36).paneStrip(hairline: .bottom)
        }
    }
}

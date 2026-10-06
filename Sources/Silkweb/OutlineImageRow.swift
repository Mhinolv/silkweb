import SilkwebCore
import SwiftUI

struct OutlineImageRow: View {
    let item: OutlineItem
    let document: URL?
    let root: URL?
    let current: Bool
    let highlighted: Bool
    @Environment(\.displayScale) private var scale
    @State private var bitmap: CGImage?
    @State private var message: String?
    @State private var symbol: String?
    @State private var state = ""

    /// #72: a 16×12 thumbnail hanging from the thread; `OutlineRowChrome` draws the indent, capsule and guides.
    static let thumbnail = CGSize(width: 16, height: 12)

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Color(nsColor: .quaternarySystemFill)
                if let bitmap {
                    Image(decorative: bitmap, scale: scale).resizable().scaledToFit()
                } else if let symbol {
                    Image(systemName: symbol).font(.system(size: 8)).foregroundStyle(.secondary)
                }
            }
            .frame(width: Self.thumbnail.width, height: Self.thumbnail.height)
            .clipShape(.rect(cornerRadius: 2))
            .overlay { RoundedRectangle(cornerRadius: 2).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5) }
            .accessibilityHidden(true)
            Text(item.label).font(.system(size: 12))
                .foregroundStyle(Color(nsColor: highlighted || current ? .labelColor : .secondaryLabelColor))
                .lineLimit(1).truncationMode(.tail)
        }
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Image, " + item.label)
        .accessibilityValue([current ? "current" : "", state].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityIdentifier(item.id)
        .task(
            id:
                "\(document?.absoluteString ?? "")|\(root?.absoluteString ?? "")|\(reference?.destination ?? "")|\(scale)"
        ) {
            bitmap = nil; message = nil; symbol = nil; state = ""
            guard let reference, let document, let root else { return }
            let result = await Self.load(
                reference, document: document, root: root, pixels: max(1, Int(Self.thumbnail.width * scale)))
            guard !Task.isCancelled else { return }
            bitmap = result.bitmap; message = result.message; symbol = result.symbol; state = result.state
        }
    }

    private var reference: InlineImages.Reference? {
        if case .image(let reference) = item.content { return reference }
        return nil
    }
    private var tooltip: String {
        let alt = reference?.alt ?? ""
        return [alt, message ?? reference?.destination ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
    }

    struct Loaded: @unchecked Sendable {
        let bitmap: CGImage?
        let message: String?
        let symbol: String?
        let state: String
    }
    nonisolated static func load(_ reference: InlineImages.Reference, document: URL, root: URL, pixels: Int) async
        -> Loaded
    {
        await Task.detached(priority: .utility) {
            switch InlineImages.resource(reference, document: document, root: root) {
            case .remote:
                return Loaded(
                    bitmap: nil, message: "Remote image not loaded: \(reference.alt)", symbol: "photo",
                    state: "remote, not loaded")
            case .outsideLibrary:
                return Loaded(
                    bitmap: nil, message: "Image outside library: \(reference.alt)", symbol: "photo",
                    state: "outside library")
            case .unreadable:
                return Loaded(
                    bitmap: nil, message: "Can’t display image", symbol: "exclamationmark.triangle",
                    state: "can't display")
            case .local(let url):
                guard FileManager.default.fileExists(atPath: url.path) else {
                    return Loaded(
                        bitmap: nil, message: ImagePlaceholder.missing(reference.destination),
                        symbol: "exclamationmark.triangle", state: "missing")
                }
                guard let thumbnail = await ImageThumbnailCache.shared.load(url, pixels: pixels) else {
                    return Loaded(
                        bitmap: nil, message: "Can’t display image", symbol: "exclamationmark.triangle",
                        state: "can't display")
                }
                return Loaded(bitmap: thumbnail.bitmap, message: nil, symbol: nil, state: "")
            }
        }.value
    }
}

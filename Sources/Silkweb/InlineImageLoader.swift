import AppKit
import ImageIO
import SilkwebCore

struct InlineImageContent: @unchecked Sendable {
    let reference: InlineImages.Reference
    let url: URL?
    let size: NSSize
    let naturalSize: NSSize
    let bitmap: CGImage?
    let message: String?
}
struct InlineImageParagraph: @unchecked Sendable {
    let range: NSRange
    let contents: [InlineImageContent]
}

/// A serial background executor owns parsing, filesystem inspection and ImageIO decoding.
/// Cache keys include modification time and requested pixel width; the cache is bounded.
actor InlineImageLoader {
    private struct Cached {
        let modified: Date?
        let bytes: Int?
        let pixels: Int
        let size: NSSize
        let bitmap: CGImage
    }
    private var images: [URL: Cached] = [:]
    private var paragraphs: [String: [InlineImages.Reference]] = [:]

    func load(
        text: String, document: URL, root: URL, column: Double, viewport: Double, scale: Double,
        headersOnly: Bool = false
    ) async -> [InlineImageParagraph] {
        var result: [InlineImageParagraph] = []
        let source = text as NSString
        var offset = 0
        var fence: (Character, Int)?
        while offset < source.length {
            let range = source.lineRange(for: NSRange(location: offset, length: 0))
            let line = source.substring(with: range)
            offset = NSMaxRange(range)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let marker = trimmed.first
            let count = trimmed.prefix(while: { $0 == marker }).count
            if let current = fence {
                if marker == current.0, count >= current.1,
                    trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty
                {
                    fence = nil
                }
                continue
            }
            if line.prefix(while: { $0 == " " }).count <= 3, marker == "`" || marker == "~", count >= 3 {
                fence = (marker!, count); continue
            }
            guard line.contains("![") else { continue }
            let references = paragraphs[line] ?? InlineImages.paragraph(line)
            paragraphs[line] = references
            guard !references.isEmpty else { continue }
            var contents: [InlineImageContent] = []
            for reference in references {
                var url: URL?
                var message: String?
                var size = NSSize(width: min(column, 280), height: 28)
                var bitmap: CGImage?
                var naturalSize = size
                switch InlineImages.resource(reference, document: document, root: root) {
                case .remote: message = "Remote image not loaded: \(reference.alt)"
                case .outsideLibrary: message = "Image outside library: \(reference.alt)"
                case .unreadable: message = "Can’t display image"
                case .local(let file):
                    url = file
                    if !FileManager.default.fileExists(atPath: file.path) {
                        message = "Missing image: \(file.lastPathComponent)"
                    } else {
                        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                        var cached = images[file]
                        if cached?.modified != values?.contentModificationDate || cached?.bytes != values?.fileSize {
                            cached = nil; images[file] = nil
                        }
                        let imageSource =
                            cached == nil
                            ? CGImageSourceCreateWithURL(
                                file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) : nil
                        let properties = imageSource.flatMap {
                            CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any]
                        }
                        if let cached {
                            naturalSize = cached.size
                        } else if let width = properties?[kCGImagePropertyPixelWidth] as? Double,
                            let height = properties?[kCGImagePropertyPixelHeight] as? Double
                        {
                            let orientation = properties?[kCGImagePropertyOrientation] as? Int ?? 1
                            naturalSize =
                                orientation >= 5
                                ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
                        } else {
                            message = "Can’t display image"
                        }
                        if message == nil {
                            let fitted = InlineImages.fittedSize(
                                width: naturalSize.width, height: naturalSize.height, column: column, viewport: viewport
                            )
                            size = NSSize(width: fitted.width, height: fitted.height)
                            let pixels = max(1, Int(max(fitted.width, fitted.height) * scale))
                            if !headersOnly, cached == nil || Double(pixels) > Double(cached!.pixels) * 1.25 {
                                if let thumbnail = await ImageThumbnailCache.shared.load(file, pixels: pixels) {
                                    cached = Cached(
                                        modified: values?.contentModificationDate, bytes: values?.fileSize,
                                        pixels: pixels, size: thumbnail.naturalSize, bitmap: thumbnail.bitmap)
                                    images[file] = cached
                                } else {
                                    cached = nil; message = "Can’t display image";
                                    size = NSSize(width: min(column, 280), height: 28)
                                }
                            }
                            bitmap = cached?.bitmap
                        }
                    }
                }
                contents.append(
                    InlineImageContent(
                        reference: reference, url: url, size: size, naturalSize: naturalSize, bitmap: bitmap,
                        message: message))
            }
            result.append(InlineImageParagraph(range: range, contents: contents))
        }
        if paragraphs.count > 2048 { paragraphs.removeAll(keepingCapacity: true) }
        if images.count > 128 { images.removeAll(keepingCapacity: true) }
        return result
    }
}

import AppKit
import ImageIO

/// Shared by editor images and Inspector rows; all filesystem access and decoding
/// runs on this actor's background executor. No full-resolution decode is used.
actor ImageThumbnailCache {
    static let shared = ImageThumbnailCache()
    struct Thumbnail: @unchecked Sendable {
        let bitmap: CGImage
        let naturalSize: NSSize
    }
    private struct Key: Hashable {
        let url: URL
        let modified: Date?
        let bytes: Int?
        let pixels: Int
    }
    private var images: [Key: Thumbnail] = [:]
    private var cachedBytes = 0

    func load(_ url: URL, pixels: Int) -> Thumbnail? {
        var file = url
        file.removeAllCachedResourceValues()
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = Key(url: url, modified: values?.contentModificationDate, bytes: values?.fileSize, pixels: max(1, pixels))
        if let cached = images[key] { return cached }
        // A fresh mapped compressed source avoids ImageIO's URL thumbnail reuse
        // after an atomic replacement at the same path. Pixels still downsample.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Double,
              let height = properties[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let size = orientation >= 5 ? NSSize(width: height, height: width) : NSSize(width: width, height: height)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: key.pixels]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let thumbnail = Thumbnail(bitmap: bitmap, naturalSize: size)
        let cost = bitmap.bytesPerRow * bitmap.height
        if images.count >= 512 || cachedBytes + cost > 64 * 1024 * 1024 {
            images.removeAll(keepingCapacity: true)
            cachedBytes = 0
        }
        if cost <= 64 * 1024 * 1024 { images[key] = thumbnail; cachedBytes += cost }
        return thumbnail
    }
}

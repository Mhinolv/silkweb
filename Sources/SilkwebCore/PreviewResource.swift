import Foundation

/// URLs for an in-memory preview page and library-contained image resources.
public enum PreviewResource {
    public static let scheme = "silkweb-preview"

    /// Keep existing escapes intact when a readable Markdown path mixes Unicode
    /// and percent-encoded punctuation. Foundation otherwise escapes '%' again.
    public static func resolve(_ destination: String, relativeTo document: URL) -> URL? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%")
        guard let encoded = destination.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: encoded, relativeTo: document)?.absoluteURL
    }

    public static func assetURL(for file: URL, root: URL) -> URL? {
        guard file.isFileURL, root.isFileURL, HTMLRenderer.contained(file, root: root) else { return nil }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = file.standardizedFileURL.resolvingSymlinksInPath().path
        var components = URLComponents()
        components.scheme = scheme
        components.host = "asset"
        components.path = "/" + String(path.dropFirst(base == "/" ? 1 : base.count + 1))
        return components.url
    }

    public static func fileURL(for asset: URL, root: URL) -> URL? {
        guard asset.scheme == scheme, asset.host == "asset", asset.user == nil,
              asset.password == nil, asset.port == nil, asset.query == nil,
              let components = URLComponents(url: asset, resolvingAgainstBaseURL: false),
              let path = components.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard HTMLRenderer.contained(file, root: root) else { return nil }
        return file
    }

    public static func mimeType(for file: URL) -> String? {
        switch file.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "heic", "heif": return "image/heic"
        case "avif": return "image/avif"
        case "bmp": return "image/bmp"
        case "tif", "tiff": return "image/tiff"
        case "ico": return "image/x-icon"
        default: return nil
        }
    }
}

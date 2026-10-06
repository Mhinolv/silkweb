import Foundation

/// Placeholder text shared by the editor chip, the Outline and the preview (design system §5.2).
public enum ImagePlaceholder {
    /// The Markdown destination as written, percent-decoded and without `<…>`, so the user sees which
    /// reference to fix. Plain text: HTML callers escape it.
    public static func missing(_ destination: String) -> String {
        var path = destination.trimmingCharacters(in: .whitespaces)
        if path.count > 1, path.hasPrefix("<"), path.hasSuffix(">") { path = String(path.dropFirst().dropLast()) }
        return "Missing image: " + (path.removingPercentEncoding ?? path)
    }
}

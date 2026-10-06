import Foundation
import UniformTypeIdentifiers

/// Preview links only perform navigation after a user activates them.
public enum PreviewNavigation {
    public enum Action: Equatable, Sendable {
        case anchor(String)
        case document(URL)
        /// An `http(s)` page or a `mailto:` address, opened by its default app.
        case browser(URL)
        /// A library file that isn't Markdown, opened in its default app.
        case attachment(URL)
        /// A library file selected in Finder: ⌘-click, or any attachment that would run code.
        case reveal(URL)
        case blocked
    }

    /// `revealing` (⌘-click) selects an attachment in Finder instead of opening it.
    public static func action(for url: URL, document: URL, root: URL, page: URL, revealing: Bool = false) -> Action {
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false {
            return .browser(url)
        }
        // The renderer's link rules decide which addresses are live; anything else stays inert.
        if url.scheme?.lowercased() == "mailto" {
            return HTMLRenderer.allowed(url.absoluteString, image: false, options: .init()) ? .browser(url) : .blocked
        }
        if url.scheme == PreviewResource.scheme,
            var target = URLComponents(url: url, resolvingAgainstBaseURL: false),
            var current = URLComponents(url: page, resolvingAgainstBaseURL: false)
        {
            let fragment = target.fragment
            target.fragment = nil
            current.fragment = nil
            if target == current, let fragment { return .anchor(fragment) }
            return .blocked
        }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return .blocked }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == page.standardizedFileURL.path || path == document.standardizedFileURL.resolvingSymlinksInPath().path
        {
            if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment {
                return .anchor(fragment)
            }
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base == "/" ? "/" : base + "/") else { return .blocked }
        if ["md", "markdown"].contains(url.pathExtension.lowercased()) { return .document(url.standardizedFileURL) }
        return attachment(URL(fileURLWithPath: path), revealing: revealing)
    }

    /// An existing regular file, or an app bundle, which is only ever revealed.
    private static func attachment(_ file: URL, revealing: Bool) -> Action {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .contentTypeKey])
        else { return .blocked }
        let types = [values.contentType, UTType(filenameExtension: file.pathExtension)].compactMap { $0 }
        let runsCode = types.contains { type in
            [UTType.executable, .shellScript, .application, .applicationBundle].contains { type.conforms(to: $0) }
        }
        if values.isDirectory == true { return runsCode ? .reveal(file) : .blocked }
        guard values.isRegularFile == true else { return .blocked }
        return revealing || runsCode ? .reveal(file) : .attachment(file)
    }
}

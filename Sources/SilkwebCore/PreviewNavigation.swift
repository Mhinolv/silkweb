import Foundation

/// Preview links only perform navigation after a user activates them.
public enum PreviewNavigation {
    public enum Action: Equatable, Sendable {
        case anchor(String)
        case document(URL)
        case browser(URL)
        case blocked
    }

    public static func action(for url: URL, document: URL, root: URL, page: URL) -> Action {
        if ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false {
            return .browser(url)
        }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return .blocked }
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        if path == page.standardizedFileURL.path || path == document.standardizedFileURL.resolvingSymlinksInPath().path {
            if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment { return .anchor(fragment) }
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base == "/" ? "/" : base + "/"), url.pathExtension.lowercased() == "md" else { return .blocked }
        return .document(url.standardizedFileURL)
    }
}

import Foundation
import WebKit
import SilkwebCore

/// Each WebView owns one page in memory. Asset reads run off the main thread;
/// cancelled WebKit tasks never receive callbacks.
@MainActor
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    var page: URL?
    var html = Data()
    var root: URL?
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL)); return
        }
        let pageData = url == page ? html : nil
        let file = root.flatMap { PreviewResource.fileURL(for: url, root: $0) }
        let mime = pageData != nil ? "text/html" : file.flatMap { PreviewResource.mimeType(for: $0) }
        guard let mime, pageData != nil || file != nil else {
            urlSchemeTask.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        let libraryRoot = root
        tasks[id] = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<Data, Error> in
                do {
                    if let pageData { return .success(pageData) }
                    // Recheck containment immediately before reading, including symlinks.
                    guard let libraryRoot, let checked = PreviewResource.fileURL(for: url, root: libraryRoot), checked == file else {
                        throw URLError(.noPermissionsToReadFile)
                    }
                    return .success(try Data(contentsOf: checked))
                } catch { return .failure(error) }
            }.value
            guard !Task.isCancelled, let self else { return }
            self.tasks.removeValue(forKey: id)
            switch result {
            case .success(let data):
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: mime == "text/html" ? "utf-8" : nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            case .failure(let error): urlSchemeTask.didFailWithError(error)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        tasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }
}

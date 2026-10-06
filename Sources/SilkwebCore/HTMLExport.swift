import Foundation

/// Shared offline image preflight for single-document exports. Never fetches remote resources.
public enum HTMLExport {
    public struct Result: Sendable {
        public let html: String
        /// Unique local destinations that are missing, unreadable, unsupported or outside the library.
        public let missingAssets: [String]
        public var warningTitle: String {
            missingAssets.count == 1 ? "1 image couldn’t be found." : "\(missingAssets.count) images couldn’t be found."
        }
        public var warningDetail: String {
            var names = missingAssets.prefix(5).map {
                "“\((($0.removingPercentEncoding ?? $0) as NSString).lastPathComponent)”"
            }.joined(separator: "\n")
            if missingAssets.count > 5 { names += "\nand \(missingAssets.count - 5) more" }
            return names + "\n\nThe exported file will show their descriptions instead."
        }
        public func write(to destination: URL) throws {
            try Data(html.utf8).write(to: destination, options: .atomic)
        }
    }

    public static func prepare(
        markdown: String, title: String, documentURL: URL, libraryRoot: URL,
        stylesheet: String, language: String = "en",
        lineBreaks: HTMLRenderer.LineBreaks = .standard, showsTableOfContents: Bool = true, printOutput: Bool = false
    ) -> Result {
        let document = MarkdownParser.parse(markdown)
        var options = HTMLRenderer.Options(lineBreaks: lineBreaks, libraryRoot: libraryRoot, documentURL: documentURL)
        options.showsTableOfContents = showsTableOfContents
        options.printOutput = printOutput
        var sources: [String: String] = [:]
        var missing: [String] = []
        var seen: Set<String> = []
        func image(_ destination: String) {
            guard seen.insert(destination).inserted else { return }
            let scheme = URLComponents(string: destination)?.scheme?.lowercased()
            if scheme == "http" || scheme == "https" { return }
            if HTMLRenderer.allowed(destination, image: true, options: options) {
                if scheme == "data" { sources[destination] = destination; return }
                if let file = PreviewResource.resolve(destination, relativeTo: documentURL), file.isFileURL,
                    let mime = PreviewResource.mimeType(for: file), mime != "image/svg+xml",
                    let data = try? Data(contentsOf: file), !data.isEmpty
                {
                    sources[destination] = "data:\(mime);base64," + data.base64EncodedString()
                    return
                }
            }
            missing.append(destination)
        }
        func inlines(_ values: [MarkdownInline]) {
            for value in values {
                switch value {
                case .image(_, let destination, _): image(destination)
                case .emphasis(let children), .strong(let children), .strikethrough(let children),
                    .link(let children, _, _):
                    inlines(children)
                default: break
                }
            }
        }
        func blocks(_ values: [MarkdownBlock]) {
            for value in values {
                switch value {
                case .paragraph(let children), .heading(_, let children): inlines(children)
                case .quote(let children), .taskItem(_, let children): blocks(children)
                case .list(_, let items): items.forEach(blocks)
                case .table(let header, _, let rows): header.forEach(inlines); rows.forEach { $0.forEach(inlines) }
                default: break
                }
            }
        }
        blocks(document.blocks)
        for key in document.footnotes.keys.sorted() { inlines(document.footnotes[key] ?? []) }
        options.exportImages = sources
        let fragment = HTMLRenderer.render(document, options: options)
        let html = """
            <!doctype html>
            <html lang="\(HTMLRenderer.escape(language))"><head>
            <meta charset="utf-8"><meta name="viewport" content="width=device-width">
            <meta name="generator" content="Silkweb">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'none'">
            <title>\(HTMLRenderer.escape(title))</title><style>\(printOutput ? stylesheet : portableStylesheet(stylesheet))</style>
            </head><body>\(fragment)</body></html>
            """
        return Result(html: html, missingAssets: missing)
    }

    public static func portableStylesheet(_ preview: String) -> String {
        let colors = [
            "label": "text", "text-background": "background", "separator": "separator",
            "blue": "link", "secondary-label": "secondary", "tertiary-label": "secondary", "control-accent": "link",
        ]
        var css = preview
        for (name, variable) in colors {
            css = css.replacingOccurrences(of: "-apple-system-" + name, with: "var(--sw-" + variable + ")")
        }
        css = css.replacingOccurrences(
            of: "16px/1.6 -apple-system;",
            with: "16px/1.6 -apple-system, BlinkMacSystemFont, \"Segoe UI\", Helvetica, Arial, sans-serif;"
        )
        .replacingOccurrences(of: "ui-monospace, monospace", with: "ui-monospace, Menlo, Consolas, monospace")
        return """
            :root { --sw-text: #1f1f1f; --sw-background: #fff; --sw-separator: #ddd; --sw-secondary: #666; --sw-link: #0066cc; }
            @media (prefers-color-scheme: dark) { :root { --sw-text: #eee; --sw-background: #1f1f1f; --sw-separator: #555; --sw-secondary: #aaa; --sw-link: #80bfff; } }
            \(css)
            @media print { :root { color-scheme: light; --sw-text: #1f1f1f; --sw-background: #fff; --sw-separator: #ddd; --sw-secondary: #666; --sw-link: #0066cc; --sw-heading: #1f1f1f; } .sw-doc { max-width: none; padding: 0; } h1,h2,h3,h4,h5,h6 { break-after: avoid; } img,pre,tr { break-inside: avoid; } }
            """
    }
}

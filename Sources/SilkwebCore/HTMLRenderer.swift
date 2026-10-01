import Foundation

/// Escapes every source value. This renderer emits a fragment and never fetches resources.
public enum HTMLRenderer {
    public enum LineBreaks: Sendable, CaseIterable { case standard, preserve }

    public struct Options: Sendable {
        public var lineBreaks: LineBreaks
        /// Supply both URLs to allow file links, or relative paths containing parent components.
        public var libraryRoot: URL?
        public var documentURL: URL?

        public init(lineBreaks: LineBreaks = .standard, libraryRoot: URL? = nil, documentURL: URL? = nil) {
            self.lineBreaks = lineBreaks
            self.libraryRoot = libraryRoot
            self.documentURL = documentURL
        }
    }

    public static func render(_ markdown: String, options: Options = Options()) -> String {
        render(MarkdownParser.parse(markdown), options: options)
    }

    public static func render(_ document: MarkdownDocument, options: Options = Options()) -> String {
        guard !document.blocks.isEmpty else { return "<article class=\"sw-doc sw-empty\"></article>" }
        return "<article class=\"sw-doc\">\n" + blocks(document.blocks, options: options, depth: 0) + "</article>"
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "\0": result += "\u{fffd}"
            default: result.append(character)
            }
        }
        return result
    }

    private static func blocks(_ values: [MarkdownBlock], options: Options, depth: Int) -> String {
        // Also bound rendering of ASTs supplied directly by callers.
        guard depth <= MarkdownParser.maximumNesting else { return "" }
        return values.map { block in
            switch block {
            case .paragraph(let children): return "<p>" + inlines(children, options: options, depth: 0) + "</p>\n"
            case .heading(let level, let children):
                let tag = "h\(min(6, max(1, level)))"
                return "<\(tag)>" + inlines(children, options: options, depth: 0) + "</\(tag)>\n"
            case .code(let language, let text):
                let name = (language ?? "").split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                let sanitized = name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_+-".contains($0)) }
                let attribute = sanitized.isEmpty ? "" : " class=\"language-\(sanitized)\""
                return "<pre><code\(attribute)>" + escape(text) + "</code></pre>\n"
            case .quote(let children):
                return "<blockquote>\n" + blocks(children, options: options, depth: depth + 1) + "</blockquote>\n"
            case .list(let start, let items):
                let tag = start == nil ? "ul" : "ol"
                let attribute = start.map { $0 == 1 ? "" : " start=\"\($0)\"" } ?? ""
                let content = items.map { item in
                    "<li>\n" + blocks(item, options: options, depth: depth + 1) + "</li>\n"
                }.joined()
                return "<\(tag)\(attribute)>\n" + content + "</\(tag)>\n"
            case .thematicBreak: return "<hr>\n"
            }
        }.joined()
    }

    private static func inlines(_ values: [MarkdownInline], options: Options, depth: Int) -> String {
        guard depth <= MarkdownParser.maximumNesting else { return "" }
        return values.map { value in
            switch value {
            case .text(let text): return escape(text)
            case .rawHTML(let text): return "<span class=\"sw-raw-html\">" + escape(text) + "</span>"
            case .code(let text): return "<code>" + escape(text) + "</code>"
            case .emphasis(let children): return "<em>" + inlines(children, options: options, depth: depth + 1) + "</em>"
            case .strong(let children): return "<strong>" + inlines(children, options: options, depth: depth + 1) + "</strong>"
            case .softBreak: return options.lineBreaks == .preserve ? "<br>\n" : "\n"
            case .hardBreak: return "<br>\n"
            case .link(let label, let destination, let title):
                let content = inlines(label, options: options, depth: depth + 1)
                guard allowed(destination, image: false, options: options) else {
                    return "<span class=\"sw-blocked-link\" title=\"Link not opened: this kind of link isn’t allowed.\">" + content + "</span>"
                }
                return "<a href=\"" + escape(destination) + "\"" + titleAttribute(title) + ">" + content + "</a>"
            case .image(let alt, let destination, let title):
                guard allowed(destination, image: true, options: options) else {
                    return "<span class=\"sw-blocked-link\" title=\"Link not opened: this kind of link isn’t allowed.\">" + escape(alt) + "</span>"
                }
                let image = "<img src=\"" + escape(destination) + "\" alt=\"" + escape(alt) + "\"" + titleAttribute(title) + ">"
                let scheme = URLComponents(string: destination)?.scheme?.lowercased()
                return scheme == "http" || scheme == "https"
                    ? "<span class=\"sw-remote-image\">" + image + "</span>" : image
            }
        }.joined()
    }

    private static func titleAttribute(_ title: String?) -> String {
        title.map { " title=\"" + escape($0) + "\"" } ?? ""
    }

    private static func allowed(_ destination: String, image: Bool, options: Options) -> Bool {
        // Reject controls, backslashes and malformed encodings before URL interpretation.
        guard !destination.contains("\\"),
              !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let decoded = destination.removingPercentEncoding,
              !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: destination) else { return false }
        if let scheme = components.scheme?.lowercased() {
            switch scheme {
            case "https", "http": return components.host?.isEmpty == false
            case "mailto": return !image && !components.path.isEmpty
            case "data":
                guard image, let comma = destination.firstIndex(of: ",") else { return false }
                let header = destination[..<comma].lowercased()
                guard ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64",
                       "data:image/webp;base64"].contains(header) else { return false }
                let payload = destination[destination.index(after: comma)...]
                // Bound embedded images and require valid base64; SVG and arbitrary data stay blocked.
                guard !payload.isEmpty, payload.utf8.count <= 4 * 1024 * 1024 else { return false }
                return Data(base64Encoded: String(payload)) != nil
            case "file":
                guard let root = options.libraryRoot, root.isFileURL,
                      let url = components.url, url.isFileURL,
                      components.host == nil || components.host == "" || components.host == "localhost" else { return false }
                return contained(url, root: root)
            default: return false
            }
        }
        // Network-path references and encoded scheme/absolute-path lookalikes are not local assets.
        guard components.host == nil, !decoded.hasPrefix("/"),
              !decoded.hasPrefix("//"), !decoded.contains(":"), !decoded.contains("&") else { return false }
        if let root = options.libraryRoot, let document = options.documentURL {
            guard root.isFileURL, document.isFileURL, contained(document, root: root),
                  let resolved = URL(string: destination, relativeTo: document)?.absoluteURL else { return false }
            return contained(resolved, root: root)
        }
        return !decoded.split(separator: "/").contains("..")
    }

    /// Foundation may leave a symlink unresolved when the final component is missing.
    /// Resolve the nearest existing ancestor, then append the missing suffix.
    private static func resolvedPath(_ url: URL) -> String? {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
            let attributes = try? FileManager.default.attributesOfItem(atPath: ancestor.path)
            if attributes?[.type] as? FileAttributeType == .typeSymbolicLink { return nil }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in suffix.reversed() { resolved.appendPathComponent(component) }
        return resolved.path
    }

    private static func contained(_ url: URL, root: URL) -> Bool {
        guard let base = resolvedPath(root), let path = resolvedPath(url) else { return false }
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }
}

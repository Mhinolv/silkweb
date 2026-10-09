import Foundation

/// Escapes every source value. This renderer emits a fragment and never fetches resources.
public enum HTMLRenderer {
    public enum LineBreaks: Sendable, CaseIterable { case standard, preserve }

    public struct Options: Sendable {
        public var lineBreaks: LineBreaks
        /// Supply both URLs to allow file links, or relative paths containing parent components.
        public var libraryRoot: URL?
        public var documentURL: URL?
        public var offlinePreview: Bool
        /// Export sources prepared off-main; absent entries become descriptive placeholders.
        public var exportImages: [String: String]? = nil
        /// Print uses durable task glyphs and keeps short code blocks together.
        public var printOutput = false
        /// Settings (1.24): when off, `[TOC]` stays visible as its source text.
        public var showsTableOfContents = true

        public init(
            lineBreaks: LineBreaks = .standard, libraryRoot: URL? = nil, documentURL: URL? = nil,
            offlinePreview: Bool = false
        ) {
            self.lineBreaks = lineBreaks
            self.libraryRoot = libraryRoot
            self.documentURL = documentURL
            self.offlinePreview = offlinePreview
        }
    }

    public static func render(_ markdown: String, options: Options = Options()) -> String {
        render(MarkdownParser.parse(markdown), options: options)
    }

    public static func render(_ document: MarkdownDocument, options: Options = Options()) -> String {
        guard !document.blocks.isEmpty else { return "<article class=\"sw-doc sw-empty\"></article>" }
        var context = Context(headings: document.headings, definitions: document.footnotes)
        let body = blocks(document.blocks, options: options, depth: 0, context: &context)
        return "<article class=\"sw-doc\">\n" + body + footnotes(options: options, context: &context) + "</article>"
    }

    private struct Context {
        let headings: [MarkdownHeading]
        let definitions: [String: [MarkdownInline]]
        var headingIndex = 0
        var referenced: [String] = []
        var numbers: [String: Int] = [:]
        var referenceCounts: [String: Int] = [:]
    }

    static func escape(_ text: String) -> String {
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

    private static func blocks(_ values: [MarkdownBlock], options: Options, depth: Int, context: inout Context)
        -> String
    {
        // Also bound rendering of ASTs supplied directly by callers.
        guard depth <= MarkdownParser.maximumNesting else { return "" }
        return values.map { block in
            switch block {
            case .paragraph(let children):
                return "<p>" + inlines(children, options: options, depth: 0, context: &context) + "</p>\n"
            case .heading(let level, let children):
                let tag = "h\(min(6, max(1, level)))"
                let id =
                    context.headingIndex < context.headings.count
                    ? context.headings[context.headingIndex].id : "section"
                context.headingIndex += 1
                return "<\(tag) id=\"\(escape(id))\">"
                    + inlines(children, options: options, depth: 0, context: &context) + "</\(tag)>\n"
            case .code(let language, let text):
                let name = (language ?? "").split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
                let sanitized = name.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_+-".contains($0)) }
                let attribute = sanitized.isEmpty ? "" : " class=\"language-\(sanitized)\""
                let keepsTogether =
                    options.printOutput
                    && text.split(separator: "\n", omittingEmptySubsequences: false).count
                        - (text.hasSuffix("\n") ? 1 : 0) < 15
                let blockClass = keepsTogether ? " class=\"sw-short-code\"" : ""
                return "<pre\(blockClass)><code\(attribute)>" + escape(text) + "</code></pre>\n"
            case .quote(let children):
                return "<blockquote>\n" + blocks(children, options: options, depth: depth + 1, context: &context)
                    + "</blockquote>\n"
            case .list(let start, let items):
                let tag = start == nil ? "ul" : "ol"
                let tasks = items.contains { item in
                    if case .taskItem = item.first { return true }; return false
                }
                let taskClass = tasks ? " class=\"sw-task-list\"" : ""
                let attribute = start.map { $0 == 1 ? "" : " start=\"\($0)\"" } ?? ""
                let content = items.map { item in
                    if case .taskItem = item.first {
                        return blocks(item, options: options, depth: depth + 1, context: &context)
                    }
                    return "<li>\n" + blocks(item, options: options, depth: depth + 1, context: &context) + "</li>\n"
                }.joined()
                return "<\(tag)\(attribute)\(taskClass)>\n" + content + "</\(tag)>\n"
            case .thematicBreak: return "<hr>\n"
            case .taskItem(let checked, let children):
                let checkbox =
                    options.printOutput
                    ? (checked ? "☑ " : "☐ ") : "<input type=\"checkbox\" disabled" + (checked ? " checked" : "") + "> "
                var content = children
                var first = ""
                if case .paragraph(let text) = content.first {
                    first = inlines(text, options: options, depth: 0, context: &context)
                    content.removeFirst()
                }
                return "<li class=\"sw-task\">" + checkbox + first + "\n"
                    + blocks(content, options: options, depth: depth + 1, context: &context) + "</li>\n"
            case .table(let header, let alignments, let rows):
                func row(_ cells: [[MarkdownInline]], tag: String) -> String {
                    "<tr>"
                        + cells.enumerated().map { index, cell in
                            let alignment = index < alignments.count ? alignments[index] : nil
                            let attribute = alignment.map { " class=\"sw-align-\($0.rawValue)\"" } ?? ""
                            return "<\(tag)\(attribute)>" + inlines(cell, options: options, depth: 0, context: &context)
                                + "</\(tag)>"
                        }.joined() + "</tr>\n"
                }
                let head = row(header, tag: "th")
                let body = rows.map { row($0, tag: "td") }.joined()
                return "<div class=\"sw-table-wrap\"><table>\n<thead>\n" + head
                    + "</thead>\n<tbody>\n" + body + "</tbody>\n</table></div>\n"
            case .tableOfContents:
                return options.showsTableOfContents ? tableOfContents(context.headings) : "<p>[TOC]</p>\n"
            }
        }.joined()
    }

    private static func inlines(_ values: [MarkdownInline], options: Options, depth: Int, context: inout Context)
        -> String
    {
        guard depth <= MarkdownParser.maximumNesting else { return "" }
        return values.map { value in
            switch value {
            case .text(let text): return escape(text)
            case .rawHTML(let text): return "<span class=\"sw-raw-html\">" + escape(text) + "</span>"
            case .code(let text): return "<code>" + escape(text) + "</code>"
            case .emphasis(let children):
                return "<em>" + inlines(children, options: options, depth: depth + 1, context: &context) + "</em>"
            case .strikethrough(let children):
                return "<del>" + inlines(children, options: options, depth: depth + 1, context: &context) + "</del>"
            case .footnoteReference(let label):
                guard context.definitions[label] != nil else { return escape("[^\(label)]") }
                let number: Int
                if let existing = context.numbers[label] {
                    number = existing
                } else {
                    number = context.referenced.count + 1
                    context.numbers[label] = number
                    context.referenced.append(label)
                }
                let count = context.referenceCounts[label, default: 0] + 1
                context.referenceCounts[label] = count
                let suffix = count == 1 ? "" : "-\(count)"
                return
                    "<sup class=\"sw-fn-ref\"><a href=\"#fn-\(number)\" id=\"fnref-\(number)\(suffix)\">\(number)</a></sup>"
            case .strong(let children):
                return "<strong>" + inlines(children, options: options, depth: depth + 1, context: &context)
                    + "</strong>"
            case .softBreak: return options.lineBreaks == .preserve ? "<br>\n" : "\n"
            case .hardBreak: return "<br>\n"
            case .link(let label, let destination, let title):
                let content = inlines(label, options: options, depth: depth + 1, context: &context)
                guard allowed(destination, image: false, options: options) else {
                    let interaction = options.offlinePreview ? " role=\"link\" tabindex=\"0\"" : ""
                    return "<span class=\"sw-blocked-link\"" + interaction
                        + " title=\"Link not opened: this kind of link isn’t allowed.\">" + content + "</span>"
                }
                let local = localDestination(destination, options: options)
                // The preview's attachment menu copies the destination as written (#109).
                let source = local == destination ? "" : " data-sw-destination=\"" + escape(destination) + "\""
                return "<a href=\"" + escape(local) + "\"" + source + titleAttribute(title) + ">" + content + "</a>"
            case .image(let alt, let destination, let title):
                if let images = options.exportImages {
                    if let source = images[destination] {
                        return "<img src=\"" + escape(source) + "\" alt=\"" + escape(alt) + "\"" + titleAttribute(title)
                            + ">"
                    }
                    let description = "Image not included: " + escape(alt)
                    let scheme = URLComponents(string: destination)?.scheme?.lowercased()
                    if scheme == "http" || scheme == "https", allowed(destination, image: true, options: options) {
                        return "<span class=\"sw-remote-image\"><a href=\"" + escape(destination) + "\">" + description
                            + "</a></span>"
                    }
                    return "<span class=\"sw-missing-image\">" + description + "</span>"
                }
                guard allowed(destination, image: true, options: options) else {
                    if options.offlinePreview {
                        return "<span class=\"sw-missing-image\">Image outside library: " + escape(alt) + "</span>"
                    }
                    return
                        "<span class=\"sw-blocked-link\" title=\"Link not opened: this kind of link isn’t allowed.\">"
                        + escape(alt) + "</span>"
                }
                let scheme = URLComponents(string: destination)?.scheme?.lowercased()
                if options.offlinePreview, scheme == "http" || scheme == "https" || scheme == "data" {
                    return "<span class=\"sw-remote-image\">Remote image not loaded: " + escape(alt) + "</span>"
                }
                var source = localDestination(destination, options: options)
                if options.offlinePreview, let root = options.libraryRoot,
                    let url = URL(string: source), url.isFileURL
                {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        return "<span class=\"sw-missing-image\">" + escape(ImagePlaceholder.missing(destination))
                            + "</span>"
                    }
                    guard let asset = PreviewResource.assetURL(for: url, root: root) else {
                        return "<span class=\"sw-missing-image\">Image outside library: " + escape(alt) + "</span>"
                    }
                    source = asset.absoluteString
                }
                let image =
                    "<img src=\"" + escape(source) + "\" alt=\"" + escape(alt) + "\"" + titleAttribute(title) + ">"
                return scheme == "http" || scheme == "https"
                    ? "<span class=\"sw-remote-image\">" + image + "</span>" : image
            }
        }.joined()
    }

    private static func tableOfContents(_ headings: [MarkdownHeading]) -> String {
        guard !headings.isEmpty else { return "" }
        var index = 0
        func list(parentLevel: Int) -> String {
            var html = "<ul>"
            while index < headings.count, headings[index].level > parentLevel {
                let heading = headings[index]
                index += 1
                html += "<li><a href=\"#\(escape(heading.id))\">\(escape(heading.text))</a>"
                if index < headings.count, headings[index].level > heading.level {
                    html += list(parentLevel: heading.level)
                }
                html += "</li>"
            }
            return html + "</ul>"
        }
        let content = list(parentLevel: 0)
        return "<nav class=\"sw-toc\" aria-label=\"Table of contents\">" + content + "</nav>\n"
    }

    private static func footnotes(options: Options, context: inout Context) -> String {
        guard !context.referenced.isEmpty else { return "" }
        var rendered: [(label: String, number: Int, body: String)] = []
        var index = 0
        // A definition may reference another definition. Each label is rendered once,
        // so cycles terminate and the work stays bounded by the definition count.
        while index < context.referenced.count {
            let label = context.referenced[index]
            let body = inlines(context.definitions[label] ?? [], options: options, depth: 0, context: &context)
            rendered.append((label, index + 1, body))
            index += 1
        }
        let items = rendered.map { item in
            let links = (1...context.referenceCounts[item.label, default: 1]).map { count in
                let suffix = count == 1 ? "" : "-\(count)"
                return
                    "<a href=\"#fnref-\(item.number)\(suffix)\" class=\"sw-fn-back\" aria-label=\"Back to reference \(item.number)\">↩</a>"
            }.joined(separator: " ")
            return "<li id=\"fn-\(item.number)\"><p>" + item.body + " " + links + "</p></li>\n"
        }.joined()
        return "<section class=\"sw-footnotes\"><hr><ol>\n" + items + "</ol></section>\n"
    }

    private static func localDestination(_ destination: String, options: Options) -> String {
        guard options.offlinePreview, !destination.hasPrefix("#"),
            URLComponents(string: destination)?.scheme == nil,
            let document = options.documentURL
        else { return destination }
        return PreviewResource.resolve(destination, relativeTo: document)?.absoluteString ?? destination
    }

    private static func titleAttribute(_ title: String?) -> String {
        title.map { " title=\"" + escape($0) + "\"" } ?? ""
    }

    /// What a destination is before any library check. `nil` is blocked everywhere. Shared with link
    /// resolution (#176) so the preview, the index and the rename rewrite read destinations alike.
    enum Destination: Equatable {
        /// `http(s)` with a host, `mailto:` (links) or an allowed `data:` image.
        case external
        /// A `file:` URL; allowed only inside `Options.libraryRoot`.
        case file(URL)
        /// A relative reference, possibly fragment-only; containment depends on the document.
        case relative(URLComponents)
    }

    static func destination(_ destination: String, image: Bool) -> Destination? {
        // Reject controls, backslashes and malformed encodings before URL interpretation.
        guard !destination.contains("\\"),
            !destination.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            let decoded = destination.removingPercentEncoding,
            !decoded.contains("\\"),
            !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            let components = URLComponents(string: destination)
        else { return nil }
        if let scheme = components.scheme?.lowercased() {
            switch scheme {
            case "https", "http": return components.host?.isEmpty == false ? .external : nil
            case "mailto": return !image && !components.path.isEmpty ? .external : nil
            case "data":
                guard image, let comma = destination.firstIndex(of: ",") else { return nil }
                let header = destination[..<comma].lowercased()
                guard
                    [
                        "data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64",
                        "data:image/webp;base64",
                    ].contains(header)
                else { return nil }
                let payload = destination[destination.index(after: comma)...]
                // Bound embedded images and require valid base64; SVG and arbitrary data stay blocked.
                guard !payload.isEmpty, payload.utf8.count <= 4 * 1024 * 1024 else { return nil }
                return Data(base64Encoded: String(payload)) != nil ? .external : nil
            case "file":
                guard let url = components.url, url.isFileURL,
                    components.host == nil || components.host == "" || components.host == "localhost"
                else { return nil }
                return .file(url)
            default: return nil
            }
        }
        // Network-path references and encoded scheme/absolute-path lookalikes are not local assets.
        guard components.host == nil, !decoded.hasPrefix("/"),
            !decoded.hasPrefix("//"), !decoded.contains(":"),
            !(components.percentEncodedPath.removingPercentEncoding ?? "").contains("&")
        else { return nil }
        return .relative(components)
    }

    static func allowed(_ destination: String, image: Bool, options: Options) -> Bool {
        switch Self.destination(destination, image: image) {
        case nil: return false
        case .external: return true
        case .file(let url):
            guard let root = options.libraryRoot, root.isFileURL else { return false }
            return contained(url, root: root)
        case .relative(let components):
            if let root = options.libraryRoot, let document = options.documentURL {
                guard root.isFileURL, document.isFileURL, contained(document, root: root),
                    let resolved = PreviewResource.resolve(destination, relativeTo: document)
                else { return false }
                return contained(resolved, root: root)
            }
            return !(components.percentEncodedPath.removingPercentEncoding ?? "").split(separator: "/").contains("..")
        }
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

    static func contained(_ url: URL, root: URL) -> Bool {
        guard let base = resolvedPath(root), let path = resolvedPath(url) else { return false }
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }
}

import Foundation

/// Source-only image detection. The ordinary parser excludes code and escaped markers.
public enum InlineImages {
    public struct Reference: Equatable, Sendable {
        public let alt: String
        public let destination: String
    }
    public enum Resource: Equatable, Sendable {
        case local(URL), remote, outsideLibrary, unreadable
    }

    public static func paragraph(_ text: String) -> [Reference] {
        func inlines(_ values: [MarkdownInline]) -> [Reference] {
            values.flatMap { value -> [Reference] in
                switch value {
                case .image(let alt, let destination, _): return [Reference(alt: alt, destination: destination)]
                case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(let children, _, _): return inlines(children)
                default: return []
                }
            }
        }
        func blocks(_ values: [MarkdownBlock]) -> [Reference] {
            values.flatMap { value -> [Reference] in
                switch value {
                case .paragraph(let content), .heading(_, let content): return inlines(content)
                case .quote(let children), .taskItem(_, let children): return blocks(children)
                case .list(_, let items): return items.flatMap(blocks)
                case .table(let header, _, let rows): return (header + rows.flatMap { $0 }).flatMap(inlines)
                default: return []
                }
            }
        }
        return blocks(MarkdownParser.parse(text).blocks)
    }

    public static func resource(_ reference: Reference, document: URL, root: URL) -> Resource {
        let destination = reference.destination
        guard let decoded = destination.removingPercentEncoding,
              !decoded.contains("\\"), !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let url = PreviewResource.resolve(destination, relativeTo: document) else { return .unreadable }
        if ["http", "https"].contains(url.scheme?.lowercased() ?? "") { return .remote }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              HTMLRenderer.contained(document, root: root), HTMLRenderer.contained(url, root: root) else { return .outsideLibrary }
        return .local(url)
    }

    public static func fittedSize(width: Double, height: Double, column: Double, viewport: Double) -> (width: Double, height: Double) {
        guard width > 0, height > 0 else { return (0, 0) }
        let scale = max(0, min(1, column / width, viewport * 0.7 / height))
        return (width * scale, height * scale)
    }
}

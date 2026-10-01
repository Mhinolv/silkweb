import Foundation

/// The supported Markdown subset. Values contain source text, never trusted HTML.
public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlock]
    public init(blocks: [MarkdownBlock]) { self.blocks = blocks }
}

public indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, content: [MarkdownInline])
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case list(start: Int?, items: [[MarkdownBlock]])
    case thematicBreak
}

public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case code(String)
    case link(label: [MarkdownInline], destination: String, title: String?)
    case image(alt: String, destination: String, title: String?)
    case rawHTML(String)
    case softBreak
    case hardBreak

    public var plainText: String {
        switch self {
        case .text(let text), .code(let text), .rawHTML(let text): return text
        case .emphasis(let children), .strong(let children), .link(let children, _, _):
            return children.map(\.plainText).joined()
        case .image(let alt, _, _): return alt
        case .softBreak, .hardBreak: return "\n"
        }
    }
}

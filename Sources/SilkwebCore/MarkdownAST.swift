import Foundation

/// The supported Markdown subset. Values contain source text, never trusted HTML.
public struct MarkdownDocument: Equatable, Sendable {
    public var blocks: [MarkdownBlock]
    /// UTF-16 ranges into the original source, suitable for NSTextView selection.
    public var headingSourceRanges: [NSRange]
    public var footnotes: [String: [MarkdownInline]]
    public var headings: [MarkdownHeading] {
        MarkdownExtensions.headings(in: blocks, sourceRanges: headingSourceRanges)
    }
    public init(blocks: [MarkdownBlock], headingSourceRanges: [NSRange] = [],
                footnotes: [String: [MarkdownInline]] = [:]) {
        self.blocks = blocks
        self.headingSourceRanges = headingSourceRanges
        self.footnotes = footnotes
    }
}

public indirect enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownInline])
    case heading(level: Int, content: [MarkdownInline])
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case list(start: Int?, items: [[MarkdownBlock]])
    case thematicBreak
    case table(header: [[MarkdownInline]], alignments: [MarkdownTableAlignment?], rows: [[[MarkdownInline]]])
    case taskItem(checked: Bool, content: [MarkdownBlock])
    case tableOfContents
}

public indirect enum MarkdownInline: Equatable, Sendable {
    case text(String)
    case emphasis([MarkdownInline])
    case strong([MarkdownInline])
    case code(String)
    case strikethrough([MarkdownInline])
    case footnoteReference(String)
    case link(label: [MarkdownInline], destination: String, title: String?)
    case image(alt: String, destination: String, title: String?)
    case rawHTML(String)
    case softBreak
    case hardBreak

    public var plainText: String {
        switch self {
        case .text(let text), .code(let text), .rawHTML(let text): return text
        case .emphasis(let children), .strong(let children), .strikethrough(let children), .link(let children, _, _):
            return children.map(\.plainText).joined()
        case .image(let alt, _, _): return alt
        case .footnoteReference(let label): return "[^\(label)]"
        case .softBreak, .hardBreak: return "\n"
        }
    }
}

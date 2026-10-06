import Foundation

public struct MarkdownToken {
    public enum Kind: Equatable { case marker, heading(Int), bold, italic, strike, code, link, quote }
    public let range: NSRange
    public let kind: Kind
}

public enum MarkdownTokens {
    private static let definitions: [(String, MarkdownToken.Kind)] = [
        ("(\\*\\*|__)(.+?)\\1", .bold), ("(?<![*_])(\\*|_)([^*_\\n]+)\\1(?![*_])", .italic),
        ("(~~)(.+?)\\1", .strike), ("(`+)(.+?)\\1", .code),
        ("(\\[)([^\\]\\n]*)(\\]\\([^\\n)]*\\))", .link),
    ]
    private static let patterns = definitions.map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    private static let heading = try! NSRegularExpression(pattern: "^[ \\t]{0,3}(#{1,6})[ \\t]+")
    private static let quote = try! NSRegularExpression(pattern: "^[ \\t]*> ?")

    /// Parse one paragraph. Fence state is carried by the incremental app adapter.
    public static func paragraph(_ text: String, fenced: Bool) -> (tokens: [MarkdownToken], fenced: Bool) {
        let source = text as NSString
        let full = NSRange(location: 0, length: source.length)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            return ([MarkdownToken(range: full, kind: .marker)], !fenced)
        }
        if fenced { return ([MarkdownToken(range: full, kind: .code)], true) }
        var tokens: [MarkdownToken] = []
        if let match = heading.firstMatch(in: text, range: full) {
            tokens.append(MarkdownToken(range: full, kind: .heading(match.range(at: 1).length)))
            tokens.append(MarkdownToken(range: match.range, kind: .marker))
        }
        if let match = quote.firstMatch(in: text, range: full) {
            tokens.append(MarkdownToken(range: full, kind: .quote))
            tokens.append(MarkdownToken(range: match.range, kind: .marker))
        }
        if let prefix = MarkdownEditing.listPrefix(text) {
            tokens.append(MarkdownToken(range: prefix.range, kind: .marker))
        }
        var codeRanges: [NSRange] = []
        // Code runs take precedence over emphasis inside them.
        let ordered = patterns.sorted { $0.1 == .code && $1.1 != .code }
        for (regex, kind) in ordered {
            for match in regex.matches(in: text, range: full) {
                if kind != .code, codeRanges.contains(where: { NSIntersectionRange($0, match.range).length > 0 }) {
                    continue
                }
                if kind == .code { codeRanges.append(match.range) }
                tokens.append(MarkdownToken(range: match.range(at: 2), kind: kind))
                tokens.append(MarkdownToken(range: match.range(at: 1), kind: .marker))
                let tail = NSRange(
                    location: NSMaxRange(match.range(at: 2)),
                    length: NSMaxRange(match.range) - NSMaxRange(match.range(at: 2)))
                tokens.append(MarkdownToken(range: tail, kind: .marker))
            }
        }
        return (tokens, false)
    }
}

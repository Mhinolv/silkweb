import Foundation

/// Bounded grammar: single-line inline links/images, optional quoted titles,
/// angle-delimited paths, and reference definitions. Nested/escaped destinations,
/// HTML and multiline syntax are preserved and reported. Code is never rewritten.
public enum MarkdownDestinations {
    public struct Result: Sendable {
        public let text: String
        public let unsupported: [String]
    }

    private static let pattern = #"!?\[[^\]\n]*\]\((<[^>\n]*>|[^\s()]+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\)|^ {0,3}\[(?!\^)[^\]\n]+\]:\s*(<[^>\n]*>|[^\s()]+)(?:\s+(?:"[^"\n]*"|'[^'\n]*'))?\s*$"#
    private static let regex = try! NSRegularExpression(pattern: pattern)
    private static let candidates = try! NSRegularExpression(pattern: #"!?\[[^\]\n]*\]\([^\n]*?(?:\)|$)|^ {0,3}\[(?!\^)[^\]\n]+\]:[^\n]*|!?\[\[[^\]\n]+\]\]|<[^>\n]+(?:href|src)\s*=[^>\n]*>"#, options: .caseInsensitive)
    private static let delimiters = try! NSRegularExpression(pattern: #"\]\("#)
    private static let code = try! NSRegularExpression(pattern: #"(`+).*?\1"#)

    public static func rewrite(_ text: String, source: String, changes: LibraryChangeSet, canonicalPaths: [String: String] = [:]) -> Result {
        let newSource = changes.remapping(source)
        var output = ""
        var unsupported: [String] = []
        var fence: String?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = fence {
                if trimmed.hasPrefix(marker), trimmed.drop(while: { $0 == marker.first! }).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                output += line + "\n"
                continue
            }
            if line.hasPrefix("    ") || line.hasPrefix("\t") { output += line + "\n"; continue }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(while: { $0 == trimmed.first! })); output += line + "\n"; continue
            }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)
            // Mask inline code, including variable-length backtick delimiters.
            let codeRanges = code.matches(in: line, range: full).map(\.range)
            func inCode(_ range: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, range).length > 0 } }
            func escaped(_ range: NSRange) -> Bool {
                var offset = range.location
                var count = 0
                while offset > 0, ns.character(at: offset - 1) == 92 { count += 1; offset -= 1 }
                return count % 2 == 1
            }
            let matches = regex.matches(in: line, range: full).filter { !inCode($0.range) && !escaped($0.range) }
            let mutable = NSMutableString(string: line)
            for match in matches.reversed() {
                let range = match.range(at: match.range(at: 1).location == NSNotFound ? 2 : 1)
                let original = ns.substring(with: range)
                let angled = original.hasPrefix("<") && original.hasSuffix(">")
                let destination = angled ? String(original.dropFirst().dropLast()) : original
                guard !destination.hasPrefix("#"), !destination.hasPrefix("/"),
                      !destination.contains(":") else { continue }
                guard !destination.contains("\\"), !destination.contains("("), !destination.contains(")"),
                      destination.removingPercentEncoding != nil else {
                    unsupported.append(ns.substring(with: match.range)); continue
                }
                let suffixStart = destination.firstIndex(where: { $0 == "#" || $0 == "?" }) ?? destination.endIndex
                let suffix = String(destination[suffixStart...])
                let encodedPath = String(destination[..<suffixStart])
                guard let path = encodedPath.removingPercentEncoding, !path.isEmpty else { continue }
                let base = URL(fileURLWithPath: "/silkweb-root/" + source).deletingLastPathComponent()
                let target = base.appendingPathComponent(path).standardizedFileURL.path
                guard target == "/silkweb-root" || target.hasPrefix("/silkweb-root/") else {
                    unsupported.append(ns.substring(with: match.range)); continue
                }
                let relativeTarget = String(target.dropFirst("/silkweb-root/".count))
                let actualTarget = canonicalPaths[relativeTarget.precomposedStringWithCanonicalMapping.lowercased()] ?? relativeTarget
                let mappedTarget = changes.remapping(actualTarget)
                let newTarget = mappedTarget == actualTarget ? relativeTarget : mappedTarget
                guard newSource != source || newTarget != relativeTarget else { continue }
                let parent = (newSource as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
                let components = newTarget.split(separator: "/").map(String.init)
                var common = 0
                while common < min(parent.count, components.count), parent[common] == components[common] { common += 1 }
                let relative = (Array(repeating: "..", count: parent.count - common) + components.dropFirst(common)).joined(separator: "/")
                var allowed = CharacterSet.urlPathAllowed
                allowed.remove(charactersIn: "?#%()<>\\")
                let normalized = relative.isEmpty ? "." : relative
                let replacement = (normalized.addingPercentEncoding(withAllowedCharacters: allowed) ?? normalized) + suffix
                mutable.replaceCharacters(in: range, with: angled ? "<" + replacement + ">" : replacement)
            }
            let candidateMatches = candidates.matches(in: line, range: full)
            for candidate in candidateMatches where !inCode(candidate.range) && !escaped(candidate.range) {
                if !matches.contains(where: { $0.range.location == candidate.range.location }) {
                    unsupported.append(ns.substring(with: candidate.range))
                }
            }
            for delimiter in delimiters.matches(in: line, range: full) where !inCode(delimiter.range) {
                if !matches.contains(where: { NSLocationInRange(delimiter.range.location, $0.range) })
                    && !candidateMatches.contains(where: { NSLocationInRange(delimiter.range.location, $0.range) }) {
                    unsupported.append(line)
                }
            }
            output += (mutable as String) + "\n"
        }
        if !output.isEmpty { output.removeLast() } // split always returns at least one line, including empty input.
        return Result(text: output, unsupported: unsupported)
    }
}

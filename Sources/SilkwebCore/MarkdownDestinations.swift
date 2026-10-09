import Foundation

/// Rewrites relative destinations for moved items, reading links exactly as the renderer does (`MarkdownLinks`,
/// #176): inline links and images, angle-delimited paths and reference definitions. Code and escaped syntax are
/// never rewritten or reported. Destinations Silkweb can't rewrite are preserved and reported.
public enum MarkdownDestinations {
    public struct Result: Sendable {
        public let text: String
        public let unsupported: [String]
    }

    /// `resolver` picks the on-disk spelling of a target (case aliases, ambiguity); without one,
    /// `canonicalPaths` maps folded paths to spellings.
    public static func rewrite(
        _ text: String, source: String, changes: LibraryChangeSet, canonicalPaths: [String: String] = [:],
        resolver: MarkdownLinkResolver? = nil, visit: ((String) -> Void)? = nil
    ) -> Result {
        let scan = MarkdownLinks.scan(text)
        let body = text as NSString
        let output = NSMutableString(string: text)
        var unsupported: [(Int, String)] = scan.unsupported.map { ($0.range.location, $0.syntax) }
        let newSource = changes.remapping(source)
        for link in scan.links.reversed() {
            let destination = link.destination
            visit?(destination)
            func report() { unsupported.append((link.range.location, body.substring(with: link.range))) }
            guard !destination.hasPrefix("#"), !destination.hasPrefix("/"), !destination.contains(":") else {
                continue
            }
            // Backslash escapes and malformed encoding can't be rewritten in the author's form.
            guard !link.written.contains("\\"), destination.removingPercentEncoding != nil else { report(); continue }
            let suffixStart = destination.firstIndex(where: { $0 == "#" || $0 == "?" }) ?? destination.endIndex
            let suffix = String(destination[suffixStart...])
            let encodedPath = String(destination[..<suffixStart])
            guard let path = encodedPath.removingPercentEncoding, !path.isEmpty else { continue }
            guard let relativeTarget = MarkdownLinkResolver.join(source, path) else { report(); continue }
            let actualTarget: String
            if let resolver {
                switch resolver.match(relativeTarget) {
                case .item(let spelling): actualTarget = spelling
                case .none: actualTarget = relativeTarget
                case .ambiguous(let candidates):
                    // Never guess which of several spellings moved.
                    if newSource != source || candidates.contains(where: { changes.remapping($0) != $0 }) { report() }
                    continue
                }
            } else {
                actualTarget =
                    canonicalPaths[relativeTarget] ?? canonicalPaths[MarkdownLinkResolver.fold(relativeTarget)]
                    ?? relativeTarget
            }
            let mappedTarget = changes.remapping(actualTarget)
            let newTarget =
                mappedTarget == actualTarget
                ? relativeTarget : authorSpelling(mappedTarget, actual: actualTarget, written: relativeTarget)
            guard newSource != source || newTarget != relativeTarget else { continue }
            let parent = (newSource as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
            let components = newTarget.split(separator: "/").map(String.init)
            var common = 0
            while common < min(parent.count, components.count), parent[common] == components[common] { common += 1 }
            let relative = (Array(repeating: "..", count: parent.count - common) + components.dropFirst(common))
                .joined(separator: "/")
            let normalized = relative.isEmpty ? "." : relative
            let trailingSlash = path.hasSuffix("/") ? "/" : ""
            // Keep the author's form: a path written readably stays readable; anything else is encoded.
            let encoded =
                readable(path, angled: link.isAngleBracketed) == encodedPath
                ? readable(normalized, angled: link.isAngleBracketed)
                : normalized.addingPercentEncoding(withAllowedCharacters: encodedPathAllowed) ?? normalized
            output.replaceCharacters(in: link.destinationRange, with: encoded + trailingSlash + suffix)
        }
        return Result(
            text: output as String, unsupported: unsupported.sorted { $0.0 < $1.0 }.map(\.1))
    }

    /// `mapped` with the trailing components it shares with `actual` (the on-disk spelling) written as the
    /// author wrote them when they differ only in Unicode normalisation. Case aliases still take the on-disk
    /// spelling (#151); moved names come from the change.
    static func authorSpelling(_ mapped: String, actual: String, written: String) -> String {
        let mapped = mapped.split(separator: "/", omittingEmptySubsequences: false)
        let actual = actual.split(separator: "/", omittingEmptySubsequences: false)
        let written = written.split(separator: "/", omittingEmptySubsequences: false)
        guard actual.count == written.count else { return mapped.joined(separator: "/") }
        var result = mapped
        var offset = 1
        while offset <= min(mapped.count, actual.count),
            mapped[mapped.count - offset].utf8.elementsEqual(actual[actual.count - offset].utf8)
        {
            // Swift compares strings by canonical equivalence: equal means only normalisation differs.
            if written[written.count - offset] == actual[actual.count - offset] {
                result[mapped.count - offset] = written[written.count - offset]
            }
            offset += 1
        }
        return result.joined(separator: "/")
    }

    private static let encodedPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%()<>\\")
        return allowed
    }()

    private static let readableASCII: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%<>\\()")
        return allowed
    }()

    /// Percent-encodes only what the destination syntax needs: spaces and unbalanced parentheses outside
    /// angle brackets, and `%`, `#`, `?`, `<`, `>`, `\` and controls anywhere. Other Unicode stays as is.
    static func readable(_ path: String, angled: Bool) -> String {
        var depth = 0
        var balanced = true
        for character in path {
            if character == "(" { depth += 1; if depth > MarkdownParser.maximumNesting { balanced = false } }
            if character == ")" { depth -= 1; if depth < 0 { balanced = false } }
        }
        balanced = balanced && depth == 0
        var result = ""
        for scalar in path.unicodeScalars {
            let keep: Bool
            if scalar == " " {
                keep = angled
            } else if scalar == "(" || scalar == ")" {
                keep = angled || balanced
            } else if scalar.isASCII {
                keep = readableASCII.contains(scalar)
            } else {
                keep = !CharacterSet.controlCharacters.contains(scalar) && !CharacterSet.newlines.contains(scalar)
            }
            if keep {
                result.unicodeScalars.append(scalar)
            } else {
                result += String(scalar).addingPercentEncoding(withAllowedCharacters: CharacterSet()) ?? ""
            }
        }
        return result
    }
}

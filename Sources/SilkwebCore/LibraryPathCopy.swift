import Foundation

/// #227: the text Copy Path and Copy Relative Path put on the pasteboard, one path per line.
/// Paths are Library-relative (`Folder/Note.md`); the empty path is the Library root.
public enum LibraryPathCopy {
    /// The absolute POSIX path of `path` inside the Library at `root`, never with a trailing slash.
    public static func absolute(root: URL, path: String) -> String {
        let base = root.standardizedFileURL.path
        return path.isEmpty ? base : (base as NSString).appendingPathComponent(path)
    }

    /// The Library root has no relative path, so Copy Relative Path isn't offered for it.
    public static func canCopyRelative(_ paths: [String]) -> Bool {
        !paths.isEmpty && !paths.contains("")
    }

    /// One path per line in the given order, duplicates dropped; no trailing newline.
    public static func string(root: URL, paths: [String], relative: Bool) -> String {
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
            .map { relative ? $0 : absolute(root: root, path: $0) }
            .joined(separator: "\n")
    }

    /// A selection in the order the list shows it; selected paths the list doesn't show follow, sorted.
    public static func ordered(_ selection: Set<String>, in list: [String]) -> [String] {
        let shown = list.filter { selection.contains($0) }
        let rest = selection.subtracting(shown).sorted()
        return shown + rest
    }
}

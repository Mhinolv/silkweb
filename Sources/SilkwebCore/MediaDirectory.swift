import Foundation

/// The marker, rather than the directory name, distinguishes assets from notes.
public enum MediaDirectory {
    public static let marker = ".silkweb-media"

    public static func isMarked(_ directory: URL) -> Bool {
        let file = directory.appendingPathComponent(marker)
        guard (try? LibraryMetadataStore.rejectLink(file)) != nil else { return false }
        return (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    static func prepare(root: URL) throws -> URL {
        try LibraryMetadataStore.rejectLink(root)
        let fm = FileManager.default
        for name in ["media", "Media Assets"] {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try LibraryMetadataStore.rejectLink(directory)
            if isMarked(directory) { return directory }
        }
        // An unreadable tree cannot be proven free of notes; do not adopt it.
        func containsNotes(_ directory: URL) throws -> Bool {
            for url in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if ["md", "markdown"].contains(url.pathExtension.lowercased()) { return true }
                if values.isSymbolicLink != true, values.isDirectory == true, try containsNotes(url) { return true }
            }
            return false
        }
        var name = "media"
        var number = 2
        while true {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try LibraryMetadataStore.rejectLink(directory)
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            } else if (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
                        || (try? containsNotes(directory)) != false {
                name = number == 2 ? "Media Assets" : "Media Assets \(number - 1)"
                number += 1
                continue
            }
            let markerURL = directory.appendingPathComponent(marker)
            try LibraryMetadataStore.rejectLink(markerURL)
            try Data("Silkweb media store\n".utf8).write(to: markerURL, options: .atomic)
            return directory
        }
    }
}

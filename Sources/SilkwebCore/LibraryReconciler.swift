import Foundation

public enum LibraryReconciler {
    /// Remap exact identities rather than applying a parent move twice to descendants.
    public static func session(_ session: LibrarySession, from old: LibrarySnapshot, to new: LibrarySnapshot)
        -> LibrarySession
    {
        let oldIDs = old.metadata.IDsByPath
        let newPaths = Dictionary(uniqueKeysWithValues: new.metadata.IDsByPath.map { ($0.value, $0.key) })
        func remap(_ path: String) -> String? { oldIDs[path].flatMap { newPaths[$0] } }
        var result = session
        if var path = session.selectedFolder {
            while remap(path) == nil && !path.isEmpty { path = (path as NSString).deletingLastPathComponent }
            result.selectedFolder = remap(path) ?? ""
        }
        result.selectedDocuments = Set(session.selectedDocuments.compactMap(remap))
        result.expandedFolders = Set(session.expandedFolders.compactMap(remap))
        return result
    }
}

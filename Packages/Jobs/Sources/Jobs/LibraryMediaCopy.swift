import AppCore
import Foundation

/// Copies a source file into the library so the asset no longer depends on the original (FILE-AC-16).
enum LibraryMediaCopy {
    /// Copies `source` to `<libraryRoot>/Media/<assetID>/<file name>` and returns the path relative to `libraryRoot`.
    ///
    /// Re-running for the same asset replaces the earlier copy, so a retried job never leaves duplicates. On APFS the copy is
    /// a clone, so it is instant and costs no extra space until either file changes.
    static func copy(_ source: URL, assetID: MediaAssetID, libraryRoot: URL) throws -> String {
        let fm = FileManager.default
        let relativeFolder = "Media/\(assetID.rawValue.uuidString)"
        let folder = libraryRoot.appending(path: relativeFolder, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = source.lastPathComponent
        let destination = folder.appending(path: name, directoryHint: .notDirectory)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
        return "\(relativeFolder)/\(name)"
    }
}

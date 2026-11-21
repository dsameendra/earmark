import Foundation
import UniformTypeIdentifiers

/// Expands dropped files and folders into the media files to enqueue (FILE-AC-02).
public enum MediaFileScanner {
    /// Extensions treated as media even when the system has no type registered for them.
    public static let knownExtensions: Set<String> = [
        "mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "flac", "caf", "mp4", "mov", "m4v", "3gp", "amr", "opus",
    ]

    /// `true` when `url`'s extension is a known audio or video type.
    public static func isSupportedMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return false }
        if knownExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    /// Files named explicitly are kept as they are (an undecodable one fails its own job, FILE-AC-03). Folders contribute only
    /// supported media files, recursively when `recursive` is set; hidden files and package contents are skipped. Each
    /// folder's files are sorted by name so batches enqueue in a predictable order.
    public static func expand(_ urls: [URL], recursive: Bool) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        func add(_ url: URL) {
            if seen.insert(url.standardizedFileURL.path).inserted { result.append(url) }
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                for file in mediaFiles(in: url, recursive: recursive) { add(file) }
            } else {
                add(url)
            }
        }
        return result
    }

    private static func mediaFiles(in folder: URL, recursive: Bool) -> [URL] {
        var options: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]
        if !recursive { options.insert(.skipsSubdirectoryDescendants) }
        guard
            let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: options)
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            if isSupportedMedia(url) { files.append(url) }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}

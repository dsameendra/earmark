import Foundation

/// Resolves and creates security-scoped bookmarks for referenced media (FILE-AC-16, LIB-AC-10). Abstracted so tests never touch
/// the filesystem.
public protocol MediaAccessing: Sendable {
    /// The file URL for `bookmark`, or `nil` when the bookmark cannot be resolved or the file no longer exists.
    func resolve(bookmark: Data) -> URL?
    /// A new security-scoped bookmark for a user-chosen file, or `nil` on failure.
    func makeBookmark(for url: URL) -> Data?
}

/// Real implementation using `URL` security-scoped bookmarks.
public struct SecurityScopedMediaAccess: MediaAccessing {
    public init() {}

    public func resolve(bookmark: Data) -> URL? {
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        else { return nil }
        return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    public func makeBookmark(for url: URL) -> Data? {
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

/// Whether a transcript's referenced media can be found.
public enum MediaState: Sendable, Equatable {
    case available
    case missing
}

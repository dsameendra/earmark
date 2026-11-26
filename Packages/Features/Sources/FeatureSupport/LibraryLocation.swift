import Foundation
import os

/// Where the library keeps its files (LIB-AC-13).
///
/// The *base* folder is the `storage.libraryLocation` setting, or `Application Support/Earmark` when that is empty. It holds
/// `Library/` (media copied in with "Copy into library") and `Meetings/` (recordings). The transcript database is always
/// `Application Support/Earmark/earmark.sqlite`: SQLite stays open for the whole session, so it is not moved.
public enum LibraryLocation {
    public static let libraryFolderName = "Library"
    public static let meetingsFolderName = "Meetings"
    public static let attachmentsFolderName = "Attachments"
    public static let databaseFileName = "earmark.sqlite"

    /// `Application Support/Earmark`, the base used when the user has not chosen a location.
    public static var defaultBase: URL {
        URL.applicationSupportDirectory.appending(path: "Earmark", directoryHint: .isDirectory)
    }

    /// The base folder for a stored setting value (empty or nil means the default).
    public static func base(custom: String?) -> URL {
        guard let custom, !custom.isEmpty else { return defaultBase }
        return URL(fileURLWithPath: custom, isDirectory: true)
    }

    public static func libraryRoot(base: URL) -> URL { base.appending(path: libraryFolderName, directoryHint: .isDirectory) }

    /// Slides and files attached to transcripts (SCR-020).
    public static func attachmentsRoot(base: URL) -> URL { base.appending(path: attachmentsFolderName, directoryHint: .isDirectory) }

    public static func meetingsRoot(base: URL) -> URL { base.appending(path: meetingsFolderName, directoryHint: .isDirectory) }

    /// The database file and its SQLite sidecars, which stay in `defaultBase`.
    public static var databaseFiles: [URL] {
        ["", "-wal", "-shm"].map { defaultBase.appending(path: databaseFileName + $0, directoryHint: .notDirectory) }
    }

    private static let current = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// The library folder media is resolved against right now. The composition root calls ``use(base:)`` at launch and Settings
    /// calls it after a move, so playback follows the setting without reading the store on every lookup.
    public static var currentLibraryRoot: URL { current.withLock { $0 } ?? libraryRoot(base: defaultBase) }

    /// Makes `base` the active library location.
    public static func use(base: URL) { current.withLock { $0 = libraryRoot(base: base) } }
}

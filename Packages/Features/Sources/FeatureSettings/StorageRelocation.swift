import FeatureSupport
import Foundation

/// Sizes of what Earmark keeps on disk (LIB-AC-13).
public struct StorageBreakdown: Equatable, Sendable {
    /// Copied media plus the transcript database.
    public var library: Int64
    public var models: Int64
    public var recordings: Int64
    public var caches: Int64
    public var total: Int64 { library + models + recordings + caches }

    public init(library: Int64, models: Int64, recordings: Int64, caches: Int64) {
        self.library = library
        self.models = models
        self.recordings = recordings
        self.caches = caches
    }
}

/// Recursive on-disk size of files and folders.
public enum DiskMeasure {
    /// Allocated bytes under `url` (a file, a folder, or nothing). Blocking; call off the main actor.
    public static func bytes(of url: URL) -> Int64 {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        var total: Int64 = 0
        if let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? 0)
        }
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true })
        else { return 0 }
        for case let item as URL in walker {
            guard let values = try? item.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// The summed size of several roots.
    public static func bytes(of urls: [URL]) -> Int64 { urls.reduce(0) { $0 + bytes(of: $1) } }
}

/// Moving the library's files to a new base folder (LIB-AC-13 "move/confirm").
///
/// `Library/` (media copied in) and `Meetings/` (recordings) move together so relative media paths keep resolving. The
/// transcript database is not moved. ``plan(from:to:movesMeetings:)`` validates and measures without touching anything, so the
/// UI can ask for confirmation; ``move(_:)`` then performs it and undoes a partial move if anything fails.
public enum StorageRelocation {
    public enum Failure: Error, Equatable, LocalizedError {
        case sameFolder
        case notAFolder
        case insideCurrent
        case notWritable
        case conflict(String)

        public var errorDescription: String? {
            switch self {
            case .sameFolder: "That is already the library location."
            case .notAFolder: "Choose an existing folder."
            case .insideCurrent: "Choose a folder outside the current library location."
            case .notWritable: "Earmark cannot write to that folder."
            case .conflict(let name): "The folder already contains a non-empty \"\(name)\" folder. Choose an empty folder."
            }
        }
    }

    /// What a move would do.
    public struct Plan: Equatable, Sendable {
        public var source: URL
        public var destination: URL
        /// Folder names that exist under `source` and will be moved.
        public var folders: [String]
        public var bytes: Int64
    }

    private static func folderNames(movesMeetings: Bool) -> [String] {
        movesMeetings
            ? [LibraryLocation.libraryFolderName, LibraryLocation.meetingsFolderName] : [LibraryLocation.libraryFolderName]
    }

    private static func isNonEmptyFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        if !isDirectory.boolValue { return true }
        return !((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).isEmpty
    }

    /// Validates a move from `source` to `destination`; throws a ``Failure`` the UI can show.
    public static func plan(from source: URL, to destination: URL, movesMeetings: Bool = true) throws -> Plan {
        let fm = FileManager.default
        let from = source.standardizedFileURL.resolvingSymlinksInPath()
        let to = destination.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: to.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw Failure.notAFolder }
        if from.path == to.path { throw Failure.sameFolder }
        if to.path.hasPrefix(from.path + "/") { throw Failure.insideCurrent }
        guard fm.isWritableFile(atPath: to.path) else { throw Failure.notWritable }
        var existing: [String] = []
        for name in folderNames(movesMeetings: movesMeetings) {
            let old = from.appending(path: name, directoryHint: .isDirectory)
            guard fm.fileExists(atPath: old.path) else { continue }
            if isNonEmptyFolder(to.appending(path: name, directoryHint: .isDirectory)) { throw Failure.conflict(name) }
            existing.append(name)
        }
        let bytes = DiskMeasure.bytes(of: existing.map { from.appending(path: $0, directoryHint: .isDirectory) })
        return Plan(source: from, destination: to, folders: existing, bytes: bytes)
    }

    /// Performs `plan`. On failure, folders already moved are moved back before the error is rethrown.
    public static func move(_ plan: Plan) throws {
        let fm = FileManager.default
        var moved: [String] = []
        do {
            for name in plan.folders {
                let old = plan.source.appending(path: name, directoryHint: .isDirectory)
                let new = plan.destination.appending(path: name, directoryHint: .isDirectory)
                if fm.fileExists(atPath: new.path) { try fm.removeItem(at: new) }  // validated as empty by `plan`
                try fm.moveItem(at: old, to: new)
                moved.append(name)
            }
        } catch {
            for name in moved.reversed() {
                try? fm.moveItem(
                    at: plan.destination.appending(path: name, directoryHint: .isDirectory),
                    to: plan.source.appending(path: name, directoryHint: .isDirectory))
            }
            throw error
        }
    }
}

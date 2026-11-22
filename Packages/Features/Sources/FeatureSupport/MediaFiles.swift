import AppCore
import Foundation

/// Where library-owned media lives on disk.
///
/// Convention (single, documented): `MediaAsset.libraryRelativePath` and `RecordingTrack.relativePath` of a meeting are
/// relative to the meetings recordings root (`<library location or Application Support/Earmark>/Meetings`, or the custom
/// `meetings.storageLocation`), so a meeting's mix is `<folder>/mix.m4a`. Older or custom locations are covered by trying
/// several roots in order.
public enum MediaFiles {
    /// Default roots when the composition root supplies none: the meetings folder, then the legacy library folder.
    public static var defaultRoots: [URL] {
        let base = URL.applicationSupportDirectory.appending(path: "Earmark", directoryHint: .isDirectory)
        let library = LibraryLocation.currentLibraryRoot
        var roots = [
            library.deletingLastPathComponent().appending(path: "Meetings", directoryHint: .isDirectory),
            library,
            base.appending(path: "Meetings", directoryHint: .isDirectory),
            base.appending(path: "Library", directoryHint: .isDirectory),
        ]
        var seen = Set<String>()
        roots.removeAll { !seen.insert($0.standardizedFileURL.path).inserted }
        return roots
    }

    /// `relative` is a plain relative path: not empty, not absolute and without `..` components.
    static func isSafe(_ relative: String) -> Bool {
        guard !relative.isEmpty, !relative.hasPrefix("/") else { return false }
        return !relative.split(separator: "/").contains("..")
    }

    /// The first existing file for `relative` under `roots`; nil when none exists or the path is unsafe.
    public static func resolve(_ relative: String, roots: [URL]) -> URL? {
        guard isSafe(relative) else { return nil }
        for root in roots {
            let url = root.appending(path: relative)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        return nil
    }
}

/// Permanently removes transcripts together with the media files the library owns (LIB-AC-08, LIB-AC-09).
///
/// Files are removed first, then the rows, so a failure leaves a retryable transcript rather than orphaned files. Only
/// `isOwnedByLibrary` assets and meeting recording tracks are touched, never referenced user originals (LIB-AC-12), and
/// nothing is removed while another remaining transcript (for example a duplicate) still points at it.
public struct MediaPurger: Sendable {
    private let transcripts: any TranscriptRepository
    private let media: (any MediaRepository)?
    private let meetings: (any MeetingRepository)?
    private let roots: @Sendable () async -> [URL]

    public init(
        transcripts: any TranscriptRepository, media: (any MediaRepository)?, meetings: (any MeetingRepository)?,
        roots: @escaping @Sendable () async -> [URL] = { MediaFiles.defaultRoots }
    ) {
        self.transcripts = transcripts
        self.media = media
        self.meetings = meetings
        self.roots = roots
    }

    /// Removes `ids` and their owned media.
    public func purge(_ ids: [TranscriptID]) async throws {
        let plan = await makePlan(for: ids)
        await removeFiles(plan)
        try await transcripts.purge(ids)
        for id in plan.assets { try? await media?.softDelete(id) }
        for id in plan.meetings { try? await meetings?.softDelete(id) }
    }

    /// Removes items soft-deleted before `date` with their owned media; returns how many transcripts were removed.
    @discardableResult
    public func purgeDeleted(before date: Date) async throws -> Int {
        let expired = try await transcripts.list(LibraryQuery(deletedOnly: true)).filter { ($0.deletedAt ?? .distantFuture) < date }
        let plan = await makePlan(for: expired.map(\.id))
        await removeFiles(plan)
        let removed = try await transcripts.purgeDeleted(before: date)
        for id in plan.assets { try? await media?.softDelete(id) }
        for id in plan.meetings { try? await meetings?.softDelete(id) }
        return removed
    }

    // MARK: Planning

    private struct Plan {
        var assets: [MediaAssetID] = []
        var relativePaths: [String] = []
        var meetings: [MeetingID] = []
    }

    private func makePlan(for ids: [TranscriptID]) async -> Plan {
        var plan = Plan()
        let purging = Set(ids)
        let live = (try? await transcripts.list(LibraryQuery())) ?? []
        let deleted = (try? await transcripts.list(LibraryQuery(deletedOnly: true))) ?? []
        let remaining = (live + deleted).filter { !purging.contains($0.id) }
        let keptAssets = Set(remaining.compactMap(\.mediaAssetID))
        let keptMeetings = Set(remaining.compactMap(\.meetingID))
        let allMeetings = (try? await meetings?.meetings()) ?? []
        var seenPaths = Set<String>()
        func add(_ path: String?) {
            if let path, seenPaths.insert(path).inserted { plan.relativePaths.append(path) }
        }
        for id in ids {
            guard let transcript = try? await transcripts.transcript(id) else { continue }
            if let assetID = transcript.mediaAssetID, !keptAssets.contains(assetID),
                let asset = try? await media?.asset(assetID), asset.isOwnedByLibrary
            {
                plan.assets.append(assetID)
                add(asset.libraryRelativePath)
            }
            for meeting in allMeetings
            where (meeting.id == transcript.meetingID || meeting.transcriptID == id) && !keptMeetings.contains(meeting.id) {
                plan.meetings.append(meeting.id)
                for track in meeting.recording?.tracks ?? [] { add(track.relativePath) }
            }
        }
        return plan
    }

    // MARK: Removal

    private func removeFiles(_ plan: Plan) async {
        let roots = await roots()
        let fm = FileManager.default
        for relative in plan.relativePaths {
            guard let url = MediaFiles.resolve(relative, roots: roots) else { continue }
            try? fm.removeItem(at: url)
            // A meeting recording folder: also drop its manifest, then the folder once nothing else is left in it.
            let parent = url.deletingLastPathComponent()
            guard relative.contains("/"), !roots.contains(where: { $0.standardizedFileURL == parent.standardizedFileURL }) else { continue }
            let manifest = parent.appending(path: "meeting.json")
            let others = ((try? fm.contentsOfDirectory(atPath: parent.path)) ?? []).filter { $0 != "meeting.json" && $0 != ".DS_Store" }
            if others.isEmpty {
                try? fm.removeItem(at: manifest)
                try? fm.removeItem(at: parent)
            }
        }
    }
}

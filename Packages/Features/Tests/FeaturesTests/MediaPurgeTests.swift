import AppCore
import FeatureEditor
import FeatureSupport
import Foundation
import Testing

private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "earmark-purge-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ root: URL, _ relative: String) throws {
    let url = root.appending(path: relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url)
}

private func exists(_ root: URL, _ relative: String) -> Bool { FileManager.default.fileExists(atPath: root.appending(path: relative).path) }

@Suite struct MediaPurgeTests {
    private static let deletedAt = Date(timeIntervalSince1970: 1_000)

    @Test func locatorResolvesMeetingRecordingsAgainstMeetingsRoot() throws {  // B1
        let meetings = try tempRoot().appending(path: "Meetings", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: meetings.deletingLastPathComponent()) }
        let folder = "2026-11-22 10.00.00 Zoom ABCD1234"
        try write(meetings, "\(folder)/mix.m4a")
        let asset = MediaAsset(kind: .audio, libraryRelativePath: "\(folder)/mix.m4a", isOwnedByLibrary: true)
        #expect(MediaLocator.url(for: asset, roots: [meetings])?.lastPathComponent == "mix.m4a")
        #expect(MediaLocator.url(for: asset, roots: [meetings.deletingLastPathComponent()]) == nil)
        let escaping = MediaAsset(kind: .audio, libraryRelativePath: "../escape.m4a", isOwnedByLibrary: true)
        #expect(MediaLocator.url(for: escaping, roots: [meetings]) == nil)
    }

    @Test func purgeRemovesOwnedMeetingRecordingFilesAndFolder() async throws {  // B2
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = "Zoom A"
        for name in ["mix.m4a", "mic.caf", "remote.caf", "meeting.json"] { try write(root, "\(folder)/\(name)") }
        let assetID = MediaAssetID()
        let media = InMemoryMedia(items: [MediaAsset(id: assetID, kind: .audio, libraryRelativePath: "\(folder)/mix.m4a", isOwnedByLibrary: true)])
        let meeting = Meeting(
            app: .zoom, startedAt: Self.deletedAt,
            recording: Recording(
                tracks: [
                    RecordingTrack(role: .mix, relativePath: "\(folder)/mix.m4a"), RecordingTrack(role: .mic, relativePath: "\(folder)/mic.caf"),
                    RecordingTrack(role: .remote, relativePath: "\(folder)/remote.caf"),
                ], duration: 1))
        let meetings = InMemoryMeetings(items: [meeting])
        let transcript = Transcript(title: "M", source: .meeting, mediaAssetID: assetID, meetingID: meeting.id, deletedAt: Self.deletedAt)
        let repo = InMemoryTranscripts(items: [transcript])
        let purger = MediaPurger(transcripts: repo, media: media, meetings: meetings, roots: { [root] })
        try await purger.purge([transcript.id])
        #expect(!exists(root, folder))
        #expect(try await repo.transcript(transcript.id) == nil)
        #expect(try await media.asset(assetID)?.deletedAt != nil)
        #expect(try await meetings.meetings().isEmpty)
    }

    @Test func purgeNeverTouchesReferencedOriginalsOrUnsafePaths() async throws {  // B2, LIB-AC-12
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "Meetings/orig.m4a")
        try write(root, "outside.txt")
        let referenced = MediaAsset(kind: .audio, libraryRelativePath: "orig.m4a", isOwnedByLibrary: false)
        let traversal = MediaAsset(kind: .audio, libraryRelativePath: "../outside.txt", isOwnedByLibrary: true)
        let media = InMemoryMedia(items: [referenced, traversal])
        let a = Transcript(title: "a", source: .file, mediaAssetID: referenced.id, deletedAt: Self.deletedAt)
        let b = Transcript(title: "b", source: .file, mediaAssetID: traversal.id, deletedAt: Self.deletedAt)
        let repo = InMemoryTranscripts(items: [a, b])
        let meetingsRoot = root.appending(path: "Meetings", directoryHint: .isDirectory)
        let purger = MediaPurger(transcripts: repo, media: media, meetings: nil, roots: { [meetingsRoot] })
        try await purger.purge([a.id, b.id])
        #expect(exists(root, "Meetings/orig.m4a"))
        #expect(exists(root, "outside.txt"))
    }

    @Test func sharedAssetSurvivesWhileADuplicateRemains() async throws {  // B2
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "F/mix.m4a")
        let asset = MediaAsset(kind: .audio, libraryRelativePath: "F/mix.m4a", isOwnedByLibrary: true)
        let original = Transcript(title: "o", source: .meeting, mediaAssetID: asset.id, deletedAt: Self.deletedAt)
        let copy = Transcript(title: "c", source: .meeting, mediaAssetID: asset.id)
        let repo = InMemoryTranscripts(items: [original, copy])
        let purger = MediaPurger(transcripts: repo, media: InMemoryMedia(items: [asset]), meetings: nil, roots: { [root] })
        try await purger.purge([original.id])
        #expect(exists(root, "F/mix.m4a"))
        try await repo.softDelete([copy.id], at: Self.deletedAt)
        try await purger.purge([copy.id])
        #expect(!exists(root, "F/mix.m4a"))
    }

    @Test func autoPurgeRemovesExpiredFilesOnly() async throws {  // B2, LIB-AC-08
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root, "Old/mix.m4a")
        try write(root, "New/mix.m4a")
        let old = MediaAsset(kind: .audio, libraryRelativePath: "Old/mix.m4a", isOwnedByLibrary: true)
        let new = MediaAsset(kind: .audio, libraryRelativePath: "New/mix.m4a", isOwnedByLibrary: true)
        let t1 = Transcript(title: "old", source: .meeting, mediaAssetID: old.id, deletedAt: Date(timeIntervalSince1970: 100))
        let t2 = Transcript(title: "new", source: .meeting, mediaAssetID: new.id, deletedAt: Date(timeIntervalSince1970: 900))
        let purger = MediaPurger(
            transcripts: InMemoryTranscripts(items: [t1, t2]), media: InMemoryMedia(items: [old, new]), meetings: nil, roots: { [root] })
        let removed = try await purger.purgeDeleted(before: Date(timeIntervalSince1970: 500))
        #expect(removed == 1)
        #expect(!exists(root, "Old/mix.m4a"))
        #expect(exists(root, "New/mix.m4a"))
    }
}

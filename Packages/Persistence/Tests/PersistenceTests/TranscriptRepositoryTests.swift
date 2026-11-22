import AppCore
import Foundation
import Testing

@testable import Persistence

@Suite("TranscriptRepository")
struct TranscriptRepositoryTests {
    @Test func saveAndFetchRoundTrips() async throws {
        let repo = try makeDB().transcripts
        let speaker = Speaker(name: "Ann", colorHex: "#FF0000")
        var t = makeTranscript("Weekly sync", source: .meeting, languages: ["en", "si"], tags: ["work", "weekly"])
        t.speakers = [speaker]
        t.revisionOf = TranscriptID()
        t.meetingID = MeetingID()
        t.mediaAssetID = MediaAssetID()
        try await repo.save(t)
        #expect(try await repo.transcript(t.id) == t)
        t.title = "Renamed"
        try await repo.save(t)
        #expect(try await repo.transcript(t.id)?.title == "Renamed")
        #expect(try await repo.list(LibraryQuery()).count == 1)
        #expect(try await repo.transcript(TranscriptID()) == nil)
    }

    @Test func listFiltersAndSorts() async throws {
        let repo = try makeDB().transcripts
        let folder = FolderID()
        let base = Date(timeIntervalSince1970: 1_000_000)
        let a = makeTranscript("alpha", source: .file, duration: 10, languages: ["en"], tags: ["x"], folder: folder, created: base)
        let b = makeTranscript("Bravo", source: .meeting, duration: 300, languages: ["si"], tags: ["x", "y"], created: base + 100)
        let c = makeTranscript("charlie", source: .dictation, duration: 100, languages: ["en", "si"], created: base + 200)
        for t in [a, b, c] { try await repo.save(t) }

        func ids(_ q: LibraryQuery) async throws -> [String] { try await repo.list(q).map(\.title) }
        #expect(try await ids(LibraryQuery(sort: .createdDesc)) == ["charlie", "Bravo", "alpha"])
        #expect(try await ids(LibraryQuery(sort: .createdAsc)) == ["alpha", "Bravo", "charlie"])
        #expect(try await ids(LibraryQuery(sort: .titleAsc)) == ["alpha", "Bravo", "charlie"])
        #expect(try await ids(LibraryQuery(sort: .durationDesc)) == ["Bravo", "charlie", "alpha"])
        #expect(try await ids(LibraryQuery(sources: [.meeting, .dictation], sort: .createdAsc)) == ["Bravo", "charlie"])
        #expect(try await ids(LibraryQuery(languages: ["si"], sort: .createdAsc)) == ["Bravo", "charlie"])
        #expect(try await ids(LibraryQuery(folderID: folder)) == ["alpha"])
        #expect(try await ids(LibraryQuery(tags: ["x"], sort: .createdAsc)) == ["alpha", "Bravo"])
        #expect(try await ids(LibraryQuery(tags: ["x", "y"])) == ["Bravo"])
        #expect(try await ids(LibraryQuery(dateRange: (base + 50)...(base + 150))) == ["Bravo"])
        #expect(try await ids(LibraryQuery(durationRange: 50...150)) == ["charlie"])
        #expect(try await ids(LibraryQuery(text: "ravo")) == ["Bravo"])
        #expect(try await ids(LibraryQuery(limit: 2)).count == 2)
        #expect(try await ids(LibraryQuery(text: "100%")).isEmpty)
    }

    @Test func listFiltersBySpeakerNamesAnyOf() async throws {  // SCR-001
        let repo = try makeDB().transcripts
        var a = makeTranscript("with-ann")
        a.speakers = [Speaker(name: "Ann", colorHex: "#111111")]
        var b = makeTranscript("with-ann-bob")
        b.speakers = [Speaker(name: "Ann", colorHex: "#111111"), Speaker(name: "Bob", colorHex: "#222222")]
        var c = makeTranscript("with-cy")
        c.speakers = [Speaker(name: "Cy", colorHex: "#333333")]
        for t in [a, b, c, makeTranscript("nobody")] { try await repo.save(t) }
        func titles(_ names: Set<String>) async throws -> Set<String> {
            Set(try await repo.list(LibraryQuery(speakerNames: names)).map(\.title))
        }
        #expect(try await titles(["Ann"]) == ["with-ann", "with-ann-bob"])
        #expect(try await titles(["Bob", "Cy"]) == ["with-ann-bob", "with-cy"])  // any-of
        #expect(try await titles(["Zed"]).isEmpty)
        #expect(try await titles([]).count == 4)
    }

    @Test func listTextMatchesSegmentContent() async throws {
        let repo = try makeDB().transcripts
        let t = makeTranscript("Untitled")
        try await repo.save(t)
        try await repo.save(makeTranscript("Other"))
        try await repo.upsertSegments([makeSegment("budget review for the quarter")], for: t.id)
        #expect(try await repo.list(LibraryQuery(text: "budget")).map(\.id) == [t.id])
        #expect(try await repo.list(LibraryQuery(text: "budget quarter")).map(\.id) == [t.id])
        #expect(try await repo.list(LibraryQuery(text: "nonsense")).isEmpty)
    }

    @Test func segmentsRoundTripWithWordsAndTranslations() async throws {
        let repo = try makeDB().transcripts
        let t = makeTranscript()
        try await repo.save(t)
        let words = [
            Word(text: "Hello", start: 0.1, end: 0.5, confidence: 0.9), Word(text: "ලෝකය", start: 0.5, end: 1.1),
        ]
        var s = Segment(
            start: 0, end: 2, text: "Hello ලෝකය", speakerID: SpeakerID(), languageCode: "en", languageConfidence: 0.8,
            confidence: 0.7, noSpeechProbability: 0.01, isIgnored: true, ignoreFlagIsManual: true, words: words,
            translations: [SegmentTranslation(language: "si", text: "ආයුබෝවන්", engine: "apple.translate")])
        s.speakerID = SpeakerID()
        try await repo.upsertSegments([s], for: t.id)
        #expect(try await repo.segments(for: t.id) == [s])
    }

    @Test func upsertIsIncrementalAndOrdered() async throws {
        let repo = try makeDB().transcripts
        let t = makeTranscript()
        try await repo.save(t)
        var first = makeSegment("one", start: 0)
        let second = makeSegment("two", start: 2)
        try await repo.upsertSegments([second], for: t.id)
        try await repo.upsertSegments([first], for: t.id)
        #expect(try await repo.segments(for: t.id).map(\.text) == ["one", "two"])
        first.text = "one edited"
        try await repo.upsertSegments([first, makeSegment("three", start: 4)], for: t.id)
        let all = try await repo.segments(for: t.id)
        #expect(all.map(\.text) == ["one edited", "two", "three"])
        try await repo.upsertSegments([], for: t.id)
        #expect(all.count == 3)
    }

    @Test func replaceSegmentsSwapsEverything() async throws {
        let repo = try makeDB().transcripts
        let t = makeTranscript()
        try await repo.save(t)
        try await repo.upsertSegments([makeSegment("old a"), makeSegment("old b", start: 2)], for: t.id)
        try await repo.replaceSegments([makeSegment("new")], for: t.id)
        #expect(try await repo.segments(for: t.id).map(\.text) == ["new"])
        #expect(try await repo.search("old", limit: 10).isEmpty)
        #expect(try await repo.search("new", limit: 10).count == 1)
    }

    @Test func upsertForMissingTranscriptFails() async throws {
        let repo = try makeDB().transcripts
        await #expect(throws: AppError.self) { try await repo.upsertSegments([makeSegment("x")], for: TranscriptID()) }
    }

    @Test func softDeleteRestorePurgeLifecycle() async throws {
        let repo = try makeDB().transcripts
        let keep = makeTranscript("keep")
        let gone = makeTranscript("gone")
        for t in [keep, gone] {
            try await repo.save(t)
            try await repo.upsertSegments([makeSegment("searchable \(t.title)")], for: t.id)
        }
        let when = Date(timeIntervalSince1970: 2_000_000)
        try await repo.softDelete([gone.id], at: when)
        #expect(try await repo.list(LibraryQuery()).map(\.id) == [keep.id])
        let deleted = try await repo.list(LibraryQuery(deletedOnly: true))
        #expect(deleted.map(\.id) == [gone.id])
        #expect(deleted.first?.deletedAt == when)
        #expect(try await repo.transcript(gone.id)?.deletedAt == when)
        // Deleted transcripts are hidden from search but keep their segments.
        #expect(try await repo.search("gone", limit: 10).isEmpty)
        #expect(try await repo.segments(for: gone.id).count == 1)
        // Re-deleting does not move the timestamp.
        try await repo.softDelete([gone.id], at: when + 1000)
        #expect(try await repo.transcript(gone.id)?.deletedAt == when)

        try await repo.restore([gone.id])
        #expect(try await repo.list(LibraryQuery()).count == 2)
        #expect(try await repo.transcript(gone.id)?.deletedAt == nil)
        #expect(try await repo.search("gone", limit: 10).count == 1)

        try await repo.softDelete([gone.id], at: when)
        try await repo.purge([gone.id])
        #expect(try await repo.transcript(gone.id) == nil)
        #expect(try await repo.segments(for: gone.id).isEmpty)
        #expect(try await repo.list(LibraryQuery(deletedOnly: true)).isEmpty)
    }

    @Test func purgeDeletedBeforeHonoursRetention() async throws {
        let repo = try makeDB().transcripts
        let old = makeTranscript("old")
        let recent = makeTranscript("recent")
        let live = makeTranscript("live")
        for t in [old, recent, live] { try await repo.save(t) }
        try await repo.upsertSegments([makeSegment("seg")], for: old.id)
        let now = Date(timeIntervalSince1970: 10_000_000)
        try await repo.softDelete([old.id], at: now - 40 * 86400)
        try await repo.softDelete([recent.id], at: now - 5 * 86400)
        let removed = try await repo.purgeDeleted(before: now - 30 * 86400)
        #expect(removed == 1)
        #expect(try await repo.transcript(old.id) == nil)
        #expect(try await repo.segments(for: old.id).isEmpty)
        #expect(try await repo.transcript(recent.id) != nil)
        #expect(try await repo.transcript(live.id) != nil)
    }

    @Test func bookmarksCRUDAndCascade() async throws {
        let repo = try makeDB().transcripts
        let t = makeTranscript()
        try await repo.save(t)
        var b2 = TranscriptBookmark(transcriptID: t.id, time: 20, note: "later")
        let b1 = TranscriptBookmark(transcriptID: t.id, time: 5, note: "early")
        try await repo.save(b2)
        try await repo.save(b1)
        #expect(try await repo.bookmarks(for: t.id).map(\.note) == ["early", "later"])
        b2.deletedAt = Date()
        try await repo.save(b2)
        #expect(try await repo.bookmarks(for: t.id).map(\.note) == ["early"])
        try await repo.purge([t.id])
        #expect(try await repo.bookmarks(for: t.id).isEmpty)
    }
}

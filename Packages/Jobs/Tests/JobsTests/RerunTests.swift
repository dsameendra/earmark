import AppCore
import AppCoreTesting
import AudioCapture
import Foundation
import Testing

@testable import Jobs

struct FailingDiarizer: Diarizer {
    let id: EngineID = "fake.failing"
    func diarize(file: URL, options: DiarizationOptions) async throws -> [SpeakerTurn] { throw AppError.engineFailure("fake", reason: "boom") }
    func diarize(audio: AsyncThrowingStream<AudioChunk, any Error>, options: DiarizationOptions) async throws -> [SpeakerTurn] { [] }
}

/// SCR-013: non-destructive re-runs and DIA-AC-16.
@Suite("Re-run merge and diarization failure")
struct RerunTests {
    /// Transcribes a file (4 segments, 2 speakers), then applies the user's edits: segment 1 edited, segment 2 ignored by hand,
    /// speaker 1 renamed.
    private func prepared(_ h: Harness) async throws -> (job: Job, url: URL, transcript: Transcript, edited: Segment, ignored: Segment) {
        let url = try h.makeFile()
        let settings = JobSettings(diarize: true)
        let id = try await h.queue.enqueue(Job(kind: .transcribeFile, input: url, settings: settings))
        #expect(await h.waitFor(id, .completed))
        let job = try #require(await h.job(id))
        var transcript = try await h.transcript(of: job)
        var segments = try await h.segments(of: job)
        transcript.speakers[0].name = "Alice"
        try await h.database.transcripts.save(transcript)
        segments[1].text = "Hand edited"
        segments[1].isUserEdited = true
        segments[2].isIgnored = true
        segments[2].ignoreFlagIsManual = true
        try await h.database.transcripts.replaceSegments(segments, for: transcript.id)
        return (job, url, transcript, segments[1], segments[2])
    }

    @Test("a merge re-run keeps edits, manual ignore flags, speaker names and ids")
    func mergeKeepsUserData() async throws {
        let h = try Harness(diarizer: FakeDiarizer())
        let base = try await prepared(h)
        let rerun = try await h.queue.enqueue(
            Job(
                kind: .transcribeFile, input: base.url, transcriptID: base.transcript.id,
                settings: JobSettings(rerun: RerunOptions())))
        #expect(await h.waitFor(rerun, .completed))
        let after = try await h.database.transcripts.segments(for: base.transcript.id)
        let header = try #require(try await h.database.transcripts.transcript(base.transcript.id))
        #expect(after.count == 4)
        #expect(after.first { $0.id == base.edited.id }?.text == "Hand edited")
        #expect(after.first { $0.id == base.ignored.id }?.isIgnored == true)
        #expect(after.first { $0.id == base.ignored.id }?.ignoreFlagIsManual == true)
        #expect(header.speakers.first?.name == "Alice")
        // The other two were redone and inherited their speaker by time overlap.
        let redone = after.filter { $0.id != base.edited.id && $0.id != base.ignored.id }
        #expect(redone.count == 2 && redone.allSatisfy { $0.speakerID != nil })
        #expect(after.first?.speakerID == header.speakers.first?.id)
    }

    @Test("a scoped merge re-run only redoes the selected range")
    func scopedRange() async throws {
        let h = try Harness(diarizer: FakeDiarizer())
        let base = try await prepared(h)
        let before = try await h.database.transcripts.segments(for: base.transcript.id)
        var marked = before
        marked[0].text = "marker zero"
        marked[3].text = "marker three"
        try await h.database.transcripts.replaceSegments(marked, for: base.transcript.id)
        let rerun = try await h.queue.enqueue(
            Job(
                kind: .transcribeFile, input: base.url, transcriptID: base.transcript.id,
                settings: JobSettings(rerun: RerunOptions(ranges: [TimeRange(start: 0, end: 10)]))))
        #expect(await h.waitFor(rerun, .completed))
        let after = try await h.database.transcripts.segments(for: base.transcript.id)
        #expect(after.map(\.text) == ["seg 0", "Hand edited", "seg 20", "marker three"])
    }

    @Test("Replace everything wipes edits and names (the old behaviour)")
    func replaceEverything() async throws {
        let h = try Harness(diarizer: FakeDiarizer())
        let base = try await prepared(h)
        let rerun = try await h.queue.enqueue(
            Job(
                kind: .transcribeFile, input: base.url, transcriptID: base.transcript.id,
                settings: JobSettings(rerun: RerunOptions(replaceEverything: true))))
        #expect(await h.waitFor(rerun, .completed))
        let after = try await h.database.transcripts.segments(for: base.transcript.id)
        #expect(after.map(\.text) == ["seg 0", "seg 10", "seg 20", "seg 30"])
        #expect(after.allSatisfy { !$0.isUserEdited && !$0.isIgnored })
        let header = try #require(try await h.database.transcripts.transcript(base.transcript.id))
        #expect(!header.speakers.contains { $0.name == "Alice" })
    }

    @Test("identify speakers again keeps speaker names and does not run recognition")
    func speakersOnlyKeepsNames() async throws {
        let h = try Harness(diarizer: FakeDiarizer())
        let base = try await prepared(h)
        let startsBefore = h.engine.chunkStarts.count
        let rerun = try await h.queue.enqueue(
            Job(
                kind: .transcribeFile, input: base.url, transcriptID: base.transcript.id,
                settings: JobSettings(diarize: true, diarization: ["exact": 2], rerun: RerunOptions(speakersOnly: true))))
        #expect(await h.waitFor(rerun, .completed))
        #expect(h.engine.chunkStarts.count == startsBefore)  // no ASR ran
        let after = try await h.database.transcripts.segments(for: base.transcript.id)
        let header = try #require(try await h.database.transcripts.transcript(base.transcript.id))
        #expect(header.speakers.contains { $0.name == "Alice" })
        #expect(header.speakers.count == 2)
        #expect(after.first { $0.id == base.edited.id }?.text == "Hand edited")
        #expect(after.first?.speakerID == header.speakers.first { $0.name == "Alice" }?.id)
    }

    @Test("DIA-AC-16: a failed diarization step completes the job with a warning and no speakers")
    func diarizerFailureDoesNotFailJob() async throws {
        let h = try Harness(diarizer: FailingDiarizer())
        let id = try await h.queue.enqueue(
            Job(kind: .transcribeFile, input: try h.makeFile(), settings: JobSettings(diarize: true)))
        #expect(await h.waitFor(id, .completed))
        let job = try #require(await h.job(id))
        #expect(job.warning?.contains("could not be identified") == true)
        let transcript = try await h.transcript(of: job)
        #expect(transcript.speakers.isEmpty)
        let segments = try await h.segments(of: job)
        #expect(segments.count == 4 && segments.allSatisfy { $0.speakerID == nil })
    }

    @Test("merge rules: locked segments survive and new text inherits the speaker")
    func mergeRules() {
        let speaker = SpeakerID()
        let old = [
            Segment(start: 0, end: 5, text: "a", speakerID: speaker),
            Segment(start: 5, end: 10, text: "edited", speakerID: speaker, isUserEdited: true),
        ]
        let fresh = [Segment(start: 0, end: 5, text: "A"), Segment(start: 5, end: 10, text: "should be dropped")]
        let merged = RerunMerge.merge(existing: old, fresh: fresh, ranges: [])
        #expect(merged.map(\.text) == ["A", "edited"])
        #expect(merged[0].speakerID == speaker)
    }

    @Test("rerun options and job warning decode from older journals")
    func decodesOldData() throws {
        let settings = try JSONDecoder().decode(JobSettings.self, from: try JSONEncoder().encode(JobSettings()))
        #expect(settings.rerun == nil)
        let job = Job(kind: .transcribeFile, warning: "w")
        let decoded = try JSONDecoder().decode(Job.self, from: try JSONEncoder().encode(job))
        #expect(decoded.warning == "w")
        var object = try #require(
            try JSONSerialization.jsonObject(with: try JSONEncoder().encode(Segment(start: 0, end: 1, text: "x", isUserEdited: true)))
                as? [String: Any])
        object["isUserEdited"] = nil
        let legacy = try JSONDecoder().decode(Segment.self, from: try JSONSerialization.data(withJSONObject: object))
        #expect(!legacy.isUserEdited)
    }
}

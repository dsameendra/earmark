import AppCore
import AppCoreTesting
import Foundation
import Testing

@testable import Meetings

private struct Rig {
    var dir: URL
    var meeting: Meeting
    var recording: Recording
    var transcripts = InMemoryTranscripts()
    var meetings = InMemoryMeetings()
    var media = InMemoryMedia()
    var log = CallLog()

    init(tracks: [RecordingTrack.Role] = [.mic, .remote, .mix]) {
        dir = tempDirectory("final")
        let names: [RecordingTrack.Role: String] = [.mic: "mic.caf", .remote: "remote.caf", .mix: "mix.m4a"]
        var list: [RecordingTrack] = []
        for role in tracks {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(names[role]!).path, contents: Data([0]))
            list.append(RecordingTrack(role: role, relativePath: "Meetings/x/\(names[role]!)"))
        }
        recording = Recording(tracks: list, duration: 10)
        meeting = Meeting(app: .zoom, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    func finalizer(
        engine: ScriptedEngine? = nil, diarizer: FakeDiarizer? = nil, embeddings: FakeEmbeddings? = nil, profiles: [VoiceProfile] = [],
        models: (any ModelManaging)? = nil, config: FinalizationConfig = FinalizationConfig()
    ) -> MeetingFinalizer {
        let eng =
            engine
            ?? ScriptedEngine(log: log) { name in
                .success(name == "mic.caf" ? [segment(0, 2, "my own words")] : [segment(3, 5, "their words")])
            }
        return MeetingFinalizer(
            dependencies: FinalizerDependencies(
                engine: eng, diarizer: diarizer, embeddings: embeddings, transcripts: transcripts, meetings: meetings, media: media,
                voiceProfiles: InMemoryProfiles(profiles), models: models),
            config: config)
    }

    var input: FinalizationInput { FinalizationInput(meeting: meeting, recordingDirectory: dir, recording: recording) }
}

private let twoTurns = [
    SpeakerTurn(range: TimeRange(start: 0, end: 4), slot: 3), SpeakerTurn(range: TimeRange(start: 4, end: 10), slot: 5),
]

@Suite("Meeting finalization", .timeLimit(.minutes(1)))
struct FinalizerTests {
    // MTG-AC-15
    @Test("runs re-transcription, then diarization, then saves under Meetings with labelled speakers")
    func orderingAndResult() async throws {
        let rig = Rig()
        let diarizer = FakeDiarizer(log: rig.log, result: .success(twoTurns))
        let finalizer = rig.finalizer(diarizer: diarizer, config: FinalizationConfig(modelID: "big"))
        let result = try await finalizer.finalize(rig.input)

        #expect(
            await rig.log.entries == [
                "prepare:big", "transcribe:mic.caf:model=big", "transcribe:remote.caf:model=big", "diarize:remote.caf",
            ])
        let segments = try await rig.transcripts.segments(for: result.transcriptID)
        #expect(segments.map(\.text) == ["my own words", "their words"])
        let header = try #require(await rig.transcripts.transcript(result.transcriptID))
        #expect(header.source == .meeting)
        #expect(header.meetingID == rig.meeting.id)
        #expect(header.duration == 10)
        let you = try #require(header.speakers.first { $0.name == "You" })
        #expect(segments[0].speakerID == you.id)
        // Remote segment at 3...5 overlaps slot 3 (3...4, 1 s) and slot 5 (4...5, 1 s): tie goes to the lower slot.
        let remoteSpeaker = try #require(header.speakers.first { $0.id == segments[1].speakerID })
        #expect(remoteSpeaker.name == "Speaker 1")  // first to appear
        #expect(header.speakers.count == 2)

        let assets = await rig.media.assets
        #expect(assets.count == 1)
        #expect(assets.first?.libraryRelativePath == "Meetings/x/mix.m4a")
        #expect(header.mediaAssetID == assets.first?.id)

        let saved = try #require(await rig.meetings.saved.first)
        #expect(saved.transcriptID == result.transcriptID)
        #expect(saved.recording == rig.recording)
        #expect(saved.endedAt == rig.meeting.startedAt.addingTimeInterval(10))
        #expect(result.warnings.isEmpty)
    }

    @Test("the recording is persisted on the meeting before any slow step")
    func meetingSavedFirst() async throws {
        let rig = Rig()
        let engine = ScriptedEngine(log: rig.log) { _ in .failure(.engineFailure("scripted", reason: "boom")) }
        let finalizer = rig.finalizer(engine: engine)
        await #expect(throws: FinalizationError.self) { try await finalizer.finalize(rig.input) }
        let saved = try #require(await rig.meetings.saved.first)
        #expect(saved.recording == rig.recording)
        #expect(saved.transcriptID == nil)
        #expect(await rig.transcripts.headers.isEmpty)
    }

    @Test("progress is reported as monotonic JobQueue events ending completed")
    func jobEvents() async throws {
        let rig = Rig()
        let finalizer = rig.finalizer(diarizer: FakeDiarizer(log: rig.log, result: .success(twoTurns)))
        let events = Collector(finalizer.jobEvents())
        let jobID = JobID()
        _ = try await finalizer.finalize(rig.input, jobID: jobID)
        let jobs: [Job] = await events.settled().compactMap { if case .updated(let j) = $0 { j } else { nil } }
        #expect(jobs.allSatisfy { $0.id == jobID && $0.kind == .finalizeMeeting })
        #expect(jobs.first?.state == .running)
        #expect(jobs.last?.state == .completed)
        #expect(jobs.last?.progress == 1)
        let progress = jobs.map(\.progress)
        #expect(progress == progress.sorted())
        #expect(jobs.last?.transcriptID != nil)
    }

    // MTG-AC-19
    @Test("echo of the remote voices in the mic track is dropped")
    func echoDropped() async throws {
        let rig = Rig()
        let engine = ScriptedEngine(log: rig.log) { name in
            name == "mic.caf"
                ? .success([segment(3, 5, "so the quarterly numbers look strong"), segment(6, 7, "thanks I agree")])
                : .success([segment(3.2, 5.1, "So the quarterly numbers look strong.")])
        }
        let result = try await rig.finalizer(engine: engine, diarizer: FakeDiarizer(log: rig.log, result: .success(twoTurns))).finalize(
            rig.input)
        #expect(result.droppedEchoSegments == 1)
        let texts = try await rig.transcripts.segments(for: result.transcriptID).map(\.text)
        #expect(texts == ["So the quarterly numbers look strong.", "thanks I agree"])
    }

    @Test("echo removal can be turned off")
    func echoOff() async throws {
        let rig = Rig()
        let engine = ScriptedEngine(log: rig.log) { _ in .success([segment(1, 3, "same words here")]) }
        let result = try await rig.finalizer(engine: engine, config: FinalizationConfig(dedupeEcho: false)).finalize(rig.input)
        #expect(result.droppedEchoSegments == 0)
        #expect(try await rig.transcripts.segments(for: result.transcriptID).count == 2)
    }

    // MARK: Error paths

    @Test("a failing diarizer degrades: transcript is saved with one remote speaker and a warning")
    func diarizerFails() async throws {
        let rig = Rig()
        let diarizer = FakeDiarizer(log: rig.log, result: .failure(.engineFailure("fake.diarizer", reason: "no model")))
        let result = try await rig.finalizer(diarizer: diarizer).finalize(rig.input)
        #expect(result.warnings.contains { if case .diarizationFailed = $0 { true } else { false } })
        let header = try #require(await rig.transcripts.transcript(result.transcriptID))
        #expect(header.speakers.map(\.name).sorted() == ["Speaker 1", "You"])
    }

    @Test("one failing track still produces a transcript from the other")
    func oneTrackFails() async throws {
        let rig = Rig()
        let engine = ScriptedEngine(log: rig.log) { name in
            name == "mic.caf" ? .failure(.engineFailure("scripted", reason: "mic broke")) : .success([segment(3, 5, "their words")])
        }
        let result = try await rig.finalizer(engine: engine).finalize(rig.input)
        #expect(result.warnings.contains { if case .retranscriptionFailed(.mic, _) = $0 { true } else { false } })
        #expect(try await rig.transcripts.segments(for: result.transcriptID).map(\.text) == ["their words"])
    }

    @Test("when every offline transcription fails the live transcript is kept")
    func fallsBackToLive() async throws {
        let rig = Rig()
        let liveID = TranscriptID()
        await rig.transcripts.seed(liveID, segments: [segment(0, 2, "live words")])
        let engine = ScriptedEngine(log: rig.log) { _ in .failure(.engineFailure("scripted", reason: "boom")) }
        var input = rig.input
        input.live = LiveContext(transcriptID: liveID)
        let result = try await rig.finalizer(engine: engine).finalize(input)
        #expect(result.warnings.contains(.usedLiveTranscript))
        #expect(try await rig.transcripts.segments(for: result.transcriptID).map(\.text) == ["live words"])
        #expect(try await rig.transcripts.transcript(result.transcriptID)?.revisionOf == liveID)
    }

    @Test("with no live transcript, total transcription failure fails the job with a reason")
    func totalFailure() async throws {
        let rig = Rig()
        let engine = ScriptedEngine(log: rig.log) { _ in .failure(.engineFailure("scripted", reason: "boom")) }
        let finalizer = rig.finalizer(engine: engine)
        let events = Collector(finalizer.jobEvents())
        await #expect(throws: FinalizationError.self) { try await finalizer.finalize(rig.input) }
        let last = await events.settled().last
        guard case .updated(let job)? = last else {
            Issue.record("no job event")
            return
        }
        #expect(job.state == .failed)
        #expect(job.failureReason?.contains("transcriptionFailed") == true)
    }

    @Test("a recording with no audio files fails with noAudio")
    func noAudio() async throws {
        let rig = Rig(tracks: [])
        await #expect(throws: FinalizationError.noAudio) { try await rig.finalizer().finalize(rig.input) }
    }

    @Test("a failing transcript save fails the job but keeps the meeting recording")
    func persistenceFails() async throws {
        let rig = Rig()
        await rig.transcripts.setFailSave(true)
        await #expect(throws: AppError.persistence(reason: "disk full")) { try await rig.finalizer().finalize(rig.input) }
        #expect(await rig.meetings.saved.first?.recording == rig.recording)
        #expect(await rig.meetings.saved.first?.transcriptID == nil)
    }

    @Test("cancelling the task cancels the job")
    func cancellation() async throws {
        let rig = Rig()
        let engine = ScriptedEngine(log: rig.log, neverFinishes: true) { _ in .success([]) }
        let finalizer = rig.finalizer(engine: engine)
        let events = Collector(finalizer.jobEvents())
        let task = Task { try await finalizer.finalize(rig.input) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: AppError.cancelled) { try await task.value }
        let last = await events.settled().last
        guard case .updated(let job)? = last else {
            Issue.record("no job event")
            return
        }
        #expect(job.state == .cancelled)
    }

    @Test("an unavailable best model falls back to automatic selection with a warning")
    func modelFallback() async throws {
        struct FailingModels: ModelManaging {
            func catalog() async -> [ModelDescriptor] { [] }
            func state(of model: ModelID) async -> ModelState { .notInstalled }
            func stateChanges() -> AsyncStream<(ModelID, ModelState)> { AsyncStream { $0.finish() } }
            func installedModels() async -> Set<ModelID> { [] }
            func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
                AsyncThrowingStream { $0.finish(throwing: AppError.modelDownloadFailed(model, reason: "offline")) }
            }
            func pauseDownload(_ model: ModelID) async {}
            func resumeDownload(_ model: ModelID) async {}
            func cancelDownload(_ model: ModelID) async {}
            func delete(_ model: ModelID) async throws {}
            func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) async throws -> ModelDescriptor {
                throw AppError.other("n/a")
            }
            func diskUsage() async -> DiskUsage { DiskUsage(totalBytes: 0, perModel: [:]) }
            func location(of model: ModelID) async throws -> URL { throw AppError.modelNotInstalled(model) }
        }
        let rig = Rig()
        let result = try await rig.finalizer(models: FailingModels(), config: FinalizationConfig(modelID: "big")).finalize(rig.input)
        #expect(result.warnings.contains { if case .modelUnavailable = $0 { true } else { false } })
        #expect(await rig.log.entries.contains("transcribe:mic.caf:model=auto"))
    }

    // MARK: Speakers

    @Test("user-named live speakers keep their identity on the reconciled offline slot")
    func liveReconciliation() async throws {
        let rig = Rig()
        let alice = Speaker(name: "Alice", colorHex: "#111111")
        let provisional = Speaker(name: "Speaker 2", colorHex: "#222222")
        let live = LiveContext(
            transcriptID: nil,
            liveTurns: [
                SpeakerTurn(range: TimeRange(start: 0, end: 4), slot: 0), SpeakerTurn(range: TimeRange(start: 4, end: 10), slot: 1),
            ],
            liveSpeakers: [0: alice, 1: provisional])
        var input = rig.input
        input.live = live
        let engine = ScriptedEngine(log: rig.log) { name in
            name == "mic.caf" ? .success([]) : .success([segment(0.5, 3, "first voice"), segment(5, 8, "second voice")])
        }
        let result = try await rig.finalizer(engine: engine, diarizer: FakeDiarizer(log: rig.log, result: .success(twoTurns))).finalize(
            input)
        let header = try #require(await rig.transcripts.transcript(result.transcriptID))
        let segments = try await rig.transcripts.segments(for: result.transcriptID)
        #expect(segments[0].speakerID == alice.id)  // offline slot 3 <- live slot 0 (Alice)
        #expect(header.speakers.first { $0.id == alice.id }?.name == "Alice")
        #expect(header.speakers.contains { $0.name == "Speaker 2" && $0.id != provisional.id })  // provisional label is not carried
        #expect(header.speakers.count == 2)
    }

    @Test("voice profiles name matching speakers automatically and suggest near matches")
    func voiceProfiles() async throws {
        let rig = Rig()
        let carol = VoiceProfile(name: "Carol", embedding: SpeakerEmbedding(vector: [1, 0, 0]))
        let dave = VoiceProfile(name: "Dave", embedding: SpeakerEmbedding(vector: [0, 0, 1]))
        // Slot 3's longest turn starts at 0, slot 5's at 4.
        let embeddings = FakeEmbeddings(log: rig.log, vectors: [0: [1, 0.05, 0], 4: [0.5, 0, 0.5].map { $0 * 1 }])
        let engine = ScriptedEngine(log: rig.log) { name in
            name == "mic.caf" ? .success([]) : .success([segment(0.5, 3, "one"), segment(5, 8, "two")])
        }
        let result = try await rig.finalizer(
            engine: engine, diarizer: FakeDiarizer(log: rig.log, result: .success(twoTurns)), embeddings: embeddings,
            profiles: [carol, dave]
        ).finalize(rig.input)
        let header = try #require(await rig.transcripts.transcript(result.transcriptID))
        let named = try #require(header.speakers.first { $0.name == "Carol" })
        #expect(named.voiceProfileID == carol.id)
        // Slot 5 sits between Carol and Dave: ambiguous, so only a suggestion and the default name stays.
        #expect(header.speakers.contains { $0.name == "Speaker 2" })
        #expect(result.voiceSuggestions.count == 1)
        #expect(await rig.log.entries.filter { $0.hasPrefix("embed") }.count == 2)
    }

    @Test("a throwing embedding provider only adds a warning")
    func embeddingFails() async throws {
        struct Boom: SpeakerEmbeddingProvider {
            func embedding(file: URL, range: TimeRange) async throws -> SpeakerEmbedding { throw AppError.other("no model") }
        }
        let rig = Rig()
        let deps = FinalizerDependencies(
            engine: ScriptedEngine(log: rig.log) { _ in .success([segment(0, 1, "x")]) },
            diarizer: FakeDiarizer(log: rig.log, result: .success(twoTurns)), embeddings: Boom(), transcripts: rig.transcripts,
            meetings: rig.meetings, media: rig.media,
            voiceProfiles: InMemoryProfiles([VoiceProfile(name: "A", embedding: SpeakerEmbedding(vector: [1, 0]))]))
        let result = try await MeetingFinalizer(dependencies: deps).finalize(rig.input)
        #expect(result.warnings.contains { if case .voiceMatchingFailed = $0 { true } else { false } })
    }

    // MARK: Job runner, retry, bookmarks

    @Test("a queued job rebuilds its input from the recording folder manifest")
    func runJob() async throws {
        let rig = Rig()
        let manifest = RecordingManifest(
            version: 1, meetingID: rig.meeting.id, app: .zoom, startedAt: rig.meeting.startedAt, state: .finalized,
            tracks: rig.recording.tracks,
            includesVideo: false, wantsMix: true, keepSeparateTracks: true, duration: 10,
            bookmarks: [RecordingManifest.Bookmark(time: 4, note: "decision")], haltedReason: nil, relativeDirectory: "Meetings/x")
        try manifest.write(to: rig.dir)
        try await rig.meetings.save(Meeting(id: rig.meeting.id, app: .zoom, startedAt: rig.meeting.startedAt, recording: rig.recording))
        let job = MeetingFinalizer.makeJob(directory: rig.dir, liveTranscriptID: nil)
        #expect(job.kind == .finalizeMeeting)
        let result = try await rig.finalizer(diarizer: FakeDiarizer(log: rig.log, result: .success(twoTurns))).run(job: job)
        #expect(await rig.transcripts.bookmarkStore.map(\.note) == ["decision"])
        #expect(await rig.transcripts.bookmarkStore.first?.transcriptID == result.transcriptID)
        #expect(await rig.meetings.saved.count == 1)
    }

    @Test("a job without an input folder is rejected")
    func jobWithoutInput() async throws {
        let rig = Rig()
        await #expect(throws: FinalizationError.missingRecordingDirectory) {
            try await rig.finalizer().run(job: Job(kind: .finalizeMeeting))
        }
    }

    @Test("a retry replaces the previously linked transcript instead of adding another")
    func retryReusesTranscript() async throws {
        let rig = Rig()
        let finalizer = rig.finalizer()
        let first = try await finalizer.finalize(rig.input)
        var again = rig.input
        again.meeting = first.meeting
        let second = try await finalizer.finalize(again)
        #expect(second.transcriptID == first.transcriptID)
        #expect(await rig.transcripts.headers.count == 1)
    }
}

@Suite("Finalization helpers")
struct FinalizationHelperTests {
    @Test("echo needs both time overlap and similar words")
    func echoRules() {
        let remote = [segment(10, 14, "we should ship on friday")]
        let overlapping = segment(10.5, 13.5, "ship on friday")
        let sameWordsLater = segment(30, 33, "we should ship on friday")
        let overlapDifferentWords = segment(11, 13, "completely different sentence")
        let result = EchoDeduper.dedupe(mic: [overlapping, sameWordsLater, overlapDifferentWords], remote: remote)
        #expect(result.dropped == [overlapping])
        #expect(result.kept == [sameWordsLater, overlapDifferentWords])
        #expect(EchoDeduper.dedupe(mic: [], remote: remote).kept.isEmpty)
        #expect(EchoDeduper.dedupe(mic: [overlapping], remote: []).kept.count == 1)
    }

    @Test("speaker assignment prefers overlap, falls back to the nearest turn")
    func assignment() {
        let turns = [SpeakerTurn(range: TimeRange(start: 0, end: 5), slot: 1), SpeakerTurn(range: TimeRange(start: 8, end: 12), slot: 2)]
        #expect(SpeakerAssigner.slot(for: TimeRange(start: 1, end: 3), turns: turns) == 1)
        #expect(SpeakerAssigner.slot(for: TimeRange(start: 4, end: 10), turns: turns) == 2)  // 1 s vs 2 s
        #expect(SpeakerAssigner.slot(for: TimeRange(start: 5.5, end: 6), turns: turns) == 1)  // gap: nearest turn (0.5 s vs 2 s)
        #expect(SpeakerAssigner.slot(for: TimeRange(start: 0, end: 1), turns: []) == nil)
    }

    @Test("default voice matcher applies the calibrated thresholds")
    func matcherThresholds() {
        let profile = VoiceProfile(name: "Eve", embedding: SpeakerEmbedding(vector: [1, 0, 0]))
        let matcher = DistanceVoiceProfileMatcher()
        func match(_ v: [Float], seconds: Double = 10) -> VoiceProfileMatch? {
            matcher.match(
                [SpeakerSlotEvidence(slot: 0, embedding: SpeakerEmbedding(vector: v), speechSeconds: seconds)], profiles: [profile]
            ).first
        }
        #expect(match([1, 0.1, 0])?.isAuto == true)
        #expect(match([1, 1, 0])?.isAuto == false)  // distance 0.29: suggestion
        #expect(match([0, 1, 0]) == nil)
        #expect(match([1, 0, 0], seconds: 1) == nil)  // too little speech
        var deleted = profile
        deleted.deletedAt = Date()
        #expect(matcher.match([SpeakerSlotEvidence(slot: 0, embedding: profile.embedding, speechSeconds: 10)], profiles: [deleted]).isEmpty)
    }
}

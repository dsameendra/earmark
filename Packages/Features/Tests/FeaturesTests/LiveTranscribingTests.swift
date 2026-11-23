import AppCore
import AppCoreTesting
import FeatureLibrary
import FeatureQueue
import FeatureSupport
import Foundation
import Testing

@testable import FeatureEditor

/// SCR-015: the editor's transcribing mode follows the job that is still writing the transcript.
@Suite("Editor transcribing mode") @MainActor
struct LiveTranscribingTests {
    private let header = Transcript(title: "Live", source: .file, duration: 60, speakers: [Fixtures.alice, Fixtures.bob])

    private func job(
        _ state: JobState, transcriptID: TranscriptID, chunk: Int? = nil, rerun: RerunOptions? = nil, failure: String? = nil
    ) -> Job {
        var settings = JobSettings()
        settings.rerun = rerun
        return Job(
            kind: .transcribeFile, state: state, input: URL(fileURLWithPath: "/tmp/live.m4a"), transcriptID: transcriptID,
            settings: settings, progress: chunk.map { Double($0 + 1) / 4 } ?? 0,
            checkpoint: chunk.map { JobCheckpoint(lastCompletedChunk: $0, mediaTime: Double($0 + 1) * 10) }, failureReason: failure)
    }

    private func open(
        segments: [Segment] = [], jobs: [Job]
    ) async -> (TranscriptEditorModel, FakeTranscriptRepository, PlaceholderJobQueue) {
        let repo = FakeTranscriptRepository(transcript: header, segments: segments)
        let queue = PlaceholderJobQueue(seed: jobs)
        let model = TranscriptEditorModel(
            transcriptID: header.id, repository: repo, settings: InMemorySettingsStore(), persistDelay: .milliseconds(5),
            engineFactory: { _ in nil })
        model.jobQueue = queue
        await model.load()
        return (model, repo, queue)
    }

    @Test func aRunningJobPutsTheEditorInTranscribingMode() async {
        let running = job(.running, transcriptID: header.id, chunk: 0)
        let (model, _, _) = await open(segments: [Fixtures.segment("first chunk text", start: 0)], jobs: [running])
        #expect(model.isTranscribing && model.isReadOnly && model.isLockedByJob)
        #expect(model.lockedHelp == "Available when transcription finishes")
        #expect(model.segments.count == 1, "segments saved so far are shown at once")
        #expect(!model.canRerun && !model.canTranslate && !model.canRetranscribe)
    }

    @Test func aFinishedTranscriptIsNotLocked() async {
        let done = job(.completed, transcriptID: header.id, chunk: 3)
        let (model, _, _) = await open(segments: Fixtures.segments(), jobs: [done])
        #expect(!model.isLockedByJob && !model.isReadOnly && model.lockedHelp == nil)
    }

    @Test func segmentsArriveAsChunksComplete() async throws {
        let running = job(.running, transcriptID: header.id, chunk: 0)
        let (model, repo, queue) = await open(segments: [Fixtures.segment("one", start: 0)], jobs: [running])
        let token = model.liveTailToken
        try await repo.upsertSegments([Fixtures.segment("two", start: 10)], for: header.id)
        var next = running
        next.checkpoint = JobCheckpoint(lastCompletedChunk: 1, mediaTime: 20)
        next.progress = 0.5
        _ = try await queue.enqueue(next)
        #expect(await eventually { model.segments.map(\.text) == ["one", "two"] })
        #expect(model.liveTailToken > token, "the list is told a new last segment arrived")
        #expect(model.transcriptionProgress == 0.5)
        #expect(model.isReadOnly)
    }

    @Test func progressOnlyUpdatesDoNotReloadSegments() async throws {
        let running = job(.running, transcriptID: header.id, chunk: 0)
        let (model, _, queue) = await open(segments: [Fixtures.segment("one", start: 0)], jobs: [running])
        var tick = running
        tick.progress = 0.3
        tick.etaSeconds = 90
        _ = try await queue.enqueue(tick)
        #expect(await eventually { model.transcriptionJob?.progress == 0.3 })
        #expect(model.transcriptionETAText == "about 2 min left")
        #expect(model.revision == 0)
    }

    @Test func userScrollingUpStopsFollowingUntilFollowLatest() async {
        let (model, _, _) = await open(jobs: [job(.running, transcriptID: header.id)])
        #expect(model.followsLatest)
        model.userScrolledAwayFromLatest()
        #expect(!model.followsLatest)
        let token = model.liveTailToken
        model.followLatest()
        #expect(model.followsLatest && model.liveTailToken > token)
    }

    @Test func completionSwitchesToNormalModeInPlaceWithTheFinalSegments() async throws {
        let running = job(.running, transcriptID: header.id, chunk: 0)
        let raw = Fixtures.segment("raw text", start: 0)
        let (model, repo, queue) = await open(segments: [raw], jobs: [running])
        var final = raw
        final.text = "Final text."  // post-processing rewrote the raw segment
        try await repo.replaceSegments([final, Fixtures.segment("tail", start: 10)], for: header.id)
        var done = running
        done.state = .completed
        done.progress = 1
        _ = try await queue.enqueue(done)
        #expect(await eventually { !model.isLockedByJob })
        #expect(model.loadState == .loaded, "no reload state in between")
        #expect(model.segments.map(\.text) == ["Final text.", "tail"])
        #expect(!model.isReadOnly)
        #expect(model.lockedHelp == nil)
    }

    @Test func conflictingActionsAreRefusedWhileTranscribing() async throws {
        let (model, repo, _) = await open(segments: Fixtures.segments(), jobs: [job(.running, transcriptID: header.id, chunk: 0)])
        let original = model.segments
        let first = original[0]
        model.beginEditing(first.id)
        #expect(model.editingSegmentID == nil)
        model.editText(first.id, to: "changed")
        model.setIgnored(true, for: [first.id])
        model.renameSpeaker(Fixtures.alice.id, to: "Zed")
        _ = model.merge(first.id, withNext: true)
        await model.flush()
        #expect(model.segments == original)
        #expect(model.segments[0].text == first.text && !model.segments[0].isIgnored)
        #expect(model.speakers.first?.name == "Alice")
        #expect(await repo.upsertCalls == 0)
        #expect(await repo.replaceCalls == 0)
        // Read-only use stays available: selection and playback.
        model.selection = [first.id]
        #expect(model.selection == [first.id])
    }

    @Test func aFailedJobKeepsPartialSegmentsReadOnlyAndOffersRetryAndRemove() async throws {
        let failed = job(.failed, transcriptID: header.id, chunk: 1, failure: "Model failed to load")
        let (model, _, queue) = await open(segments: [Fixtures.segment("partial", start: 0)], jobs: [failed])
        #expect(model.transcriptionInterrupted && model.isReadOnly && !model.isTranscribing)
        #expect(model.segments.count == 1)
        #expect(model.lockedHelp?.hasPrefix("Available when transcription finishes") == true)

        await model.removeTranscriptionJob()
        #expect(!model.isLockedByJob && !model.isReadOnly, "removing the job keeps the partial transcript and makes it editable")
        #expect(await queue.jobs().isEmpty)
    }

    @Test func retryingAFailedJobReturnsToTranscribingMode() async throws {
        let failed = job(.failed, transcriptID: header.id, chunk: 0, failure: "boom")
        let (model, _, _) = await open(segments: [Fixtures.segment("partial", start: 0)], jobs: [failed])
        await model.retryTranscription()
        #expect(await eventually { model.isTranscribing })
    }

    @Test func aCancelledJobIsAnInterruptedTranscript() async throws {
        let running = job(.running, transcriptID: header.id, chunk: 0)
        let (model, _, queue) = await open(segments: [Fixtures.segment("partial", start: 0)], jobs: [running])
        await model.cancelTranscription()
        #expect(await eventually { model.transcriptionInterrupted })
        #expect(model.isReadOnly)
        _ = queue
    }

    @Test func pauseAndResumeFollowTheJob() async throws {
        let (model, _, _) = await open(jobs: [job(.running, transcriptID: header.id)])
        await model.pauseTranscription()
        #expect(await eventually { model.transcriptionJob?.state == .paused })
        #expect(model.isTranscribing, "a paused job is still unfinished")
        await model.resumeTranscription()
        #expect(await eventually { model.transcriptionJob?.state == .pending })
    }

    @Test func aFailedMergeRerunLeavesAFinishedTranscriptEditable() async {
        let rerun = RerunOptions(ranges: [], replaceEverything: false, speakersOnly: false)
        let failed = job(.failed, transcriptID: header.id, rerun: rerun, failure: "boom")
        let (model, _, _) = await open(segments: Fixtures.segments(), jobs: [failed])
        #expect(!model.isLockedByJob && !model.isReadOnly)
    }

    @Test func removingTheQueueEntryUnlocksTheEditor() async throws {
        let running = job(.running, transcriptID: header.id, chunk: 0)
        let (model, _, queue) = await open(segments: [Fixtures.segment("one", start: 0)], jobs: [running])
        try await queue.remove(running.id)
        #expect(await eventually { !model.isLockedByJob })
    }

    @Test func libraryTracksTranscriptsStillInProgress() async throws {
        let running = job(.running, transcriptID: header.id, chunk: 0)
        var services = AppServices.preview()
        let queue = PlaceholderJobQueue(seed: [running])
        services.jobQueue = queue
        let library = LibraryModel(services: services, mode: .library)
        let watching = Task { await library.watchJobCompletions() }
        defer { watching.cancel() }
        #expect(await eventually { library.inProgressIDs == [header.id] })
        var done = running
        done.state = .completed
        _ = try await queue.enqueue(done)
        #expect(await eventually { library.inProgressIDs.isEmpty })
    }
}

/// SCR-015: queue rows open the transcript for finished and ongoing jobs.
@Suite("Queue row activation") @MainActor
struct QueueRowActivationTests {
    private func row(_ state: JobState, transcriptID: TranscriptID? = TranscriptID()) -> Job {
        Job(kind: .transcribeFile, state: state, input: URL(fileURLWithPath: "/tmp/a.m4a"), transcriptID: transcriptID)
    }

    @Test func everyJobWithATranscriptOpensIt() {
        for state in [JobState.completed, .running, .paused, .pending, .failed, .cancelled] {
            let job = row(state)
            #expect(QueueFormatting.transcriptToOpen(for: job) == job.transcriptID)
            #expect(QueueFormatting.openHint(for: job) != nil)
        }
    }

    @Test func aJobThatHasNotStartedHasNothingToOpenYet() {
        let job = row(.pending, transcriptID: nil)
        #expect(QueueFormatting.transcriptToOpen(for: job) == nil)
        #expect(QueueFormatting.openHint(for: job) == nil)
    }

    @Test func hintsExplainWhatOpeningDoes() {
        #expect(QueueFormatting.openHint(for: row(.completed)) == "Open transcript")
        #expect(QueueFormatting.openHint(for: row(.running))?.contains("read-only") == true)
        #expect(QueueFormatting.openHint(for: row(.failed))?.contains("partial") == true)
    }

    @Test func removeIsExplainedAsUnavailableWhileRunning() {
        #expect(QueueFormatting.removeHelp(for: .running).contains("Cancel this job first"))
        #expect(QueueFormatting.removeHelp(for: .pending).contains("Cancel this job first"))
        #expect(QueueFormatting.removeHelp(for: .failed) == "Remove from queue")
        #expect(QueueFormatting.isOngoing(.paused) && !QueueFormatting.isOngoing(.completed))
    }
}

import AppCore
import Foundation

// MARK: - Transcribing mode (SCR-015)
//
// While the queue is still transcribing the file, the transcript row and its segments already exist: the pipeline creates the
// row when the job starts and persists each finalized chunk (with the job's checkpoint) as it completes. The editor follows the
// job: it shows the segments as they arrive, locks every action that would conflict with the queue's later writes, and
// switches to normal editing in place when the job completes.

extension TranscriptEditorModel {
    /// The job is queued, running or paused: segments may still arrive.
    public var isTranscribing: Bool {
        guard let state = transcriptionJob?.state else { return false }
        return state == .pending || state == .running || state == .paused
    }

    /// The job failed or was cancelled: the segments that were saved stay visible, read-only.
    public var transcriptionInterrupted: Bool {
        guard let state = transcriptionJob?.state else { return false }
        return state == .failed || state == .cancelled
    }

    /// Any job state that keeps the editor read-only.
    public var isLockedByJob: Bool { transcriptionJob != nil }

    /// The explanation shown as a tooltip on every disabled action; `nil` when nothing is locked.
    public var lockedHelp: String? {
        if isTranscribing { return "Available when transcription finishes" }
        if transcriptionInterrupted { return "Available when transcription finishes. Retry the job, or remove it to edit what was saved." }
        return nil
    }

    /// 0...1 progress of the running job.
    public var transcriptionProgress: Double {
        guard let value = transcriptionJob?.progress, value.isFinite else { return 0 }
        return min(1, max(0, value))
    }

    /// "about 3 min left", "about 40 s left"; `nil` without an estimate or while not running.
    public var transcriptionETAText: String? {
        guard transcriptionJob?.state == .running, let seconds = transcriptionJob?.etaSeconds, seconds.isFinite, seconds >= 0 else {
            return nil
        }
        if seconds < 60 { return "about \(max(1, Int(seconds.rounded()))) s left" }
        return "about \(Int((seconds / 60).rounded(.up))) min left"
    }

    /// Short status for the banner.
    public var transcriptionStatusText: String {
        guard let job = transcriptionJob else { return "" }
        let merge = Self.isMergeRerun(job)
        switch job.state {
        case .pending: return merge ? "Waiting to re-transcribe" : "Waiting to transcribe"
        case .running: return merge ? "Re-transcribing" : "Transcribing"
        case .paused: return "Transcription paused"
        case .failed: return "Transcription failed"
        case .cancelled: return "Transcription cancelled"
        case .completed: return ""
        }
    }

    // MARK: Following the job

    /// The job that decides the mode: one still working on this transcript, or a first-run job that stopped half-way.
    /// A merge re-run that failed or was cancelled leaves a complete transcript, so it does not lock anything.
    func lockingJob(in jobs: [Job]) -> Job? {
        let mine = jobs.filter { $0.kind == .transcribeFile && $0.transcriptID == transcriptID && $0.id != rerunJob?.id }
        if let ongoing = mine.first(where: { Self.isOngoing($0.state) }) { return ongoing }
        return mine.last { ($0.state == .failed || $0.state == .cancelled) && !Self.isMergeRerun($0) }
    }

    private static func isOngoing(_ state: JobState) -> Bool { state == .pending || state == .running || state == .paused }
    private static func isMergeRerun(_ job: Job) -> Bool { job.settings.rerun.map { !$0.replaceEverything } ?? false }

    func adoptInitialTranscriptionJob() async {
        guard let jobQueue else { return }
        transcriptionJob = lockingJob(in: await jobQueue.jobs())
    }

    func watchTranscriptionJob(_ events: AsyncStream<JobEvent>) {
        transcriptionWatcher?.cancel()
        transcriptionWatcher = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                await self.transcriptionEvent(event)
            }
        }
    }

    /// Applies one queue event. Events are handled one at a time, in order.
    func transcriptionEvent(_ event: JobEvent) async {
        switch event {
        case .removed(let id):
            if transcriptionJob?.id == id {
                transcriptionJob = nil  // the queue entry is gone; the saved segments are now an ordinary transcript
            }
        case .updated(let job):
            guard job.kind == .transcribeFile, job.transcriptID == transcriptID, job.id != rerunJob?.id else { return }
            await transcriptionJobUpdated(job)
        }
    }

    func transcriptionJobUpdated(_ job: Job) async {
        let previous = transcriptionJob
        if job.state == .completed {
            guard previous?.id == job.id else { return }
            // Swap segments and header in place: same list, same scroll position, no reload state in between.
            await reloadSegmentsFromRepository()
            if let header = try? await repository.transcript(transcriptID) { adoptHeader(header) }
            transcriptionJob = nil
            return
        }
        if (job.state == .failed || job.state == .cancelled) && Self.isMergeRerun(job) {
            if previous?.id == job.id { transcriptionJob = nil }
            return
        }
        transcriptionJob = job
        let moved = previous?.id != job.id || previous?.checkpoint != job.checkpoint || previous?.state != job.state
        if moved { await reloadLiveSegments() }
    }

    /// Re-reads what the queue has saved so far. A no-op when nothing changed.
    func reloadLiveSegments() async {
        guard let loaded = try? await repository.segments(for: transcriptID) else { return }
        let sorted = loaded.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }.map(\.element)
        guard sorted != segments else { return }
        let lastBefore = segments.last?.id
        replaceSegmentsFromQueue(sorted)
        if sorted.last?.id != lastBefore { liveTailToken += 1 }
    }

    // MARK: Job controls

    public func pauseTranscription() async {
        guard let job = transcriptionJob else { return }
        await jobQueue?.pause(job.id)
    }

    public func resumeTranscription() async {
        guard let job = transcriptionJob else { return }
        await jobQueue?.resume(job.id)
    }

    public func cancelTranscription() async {
        guard let job = transcriptionJob else { return }
        await jobQueue?.cancel(job.id)
    }

    public func retryTranscription() async {
        guard let job = transcriptionJob else { return }
        transcriptionError = nil
        await jobQueue?.retry(job.id)
    }

    /// Removes the stopped job from the queue; the partial transcript stays and becomes editable.
    public func removeTranscriptionJob() async {
        guard let job = transcriptionJob, let jobQueue, transcriptionInterrupted else { return }
        do {
            try await jobQueue.remove(job.id)
            transcriptionJob = nil
            transcriptionError = nil
        } catch {
            transcriptionError = "Could not remove the job: \(error.localizedDescription)"
        }
    }

    /// Return to the newest segment and resume following.
    public func followLatest() {
        followsLatest = true
        liveTailToken += 1
    }

    public func userScrolledAwayFromLatest() {
        guard isTranscribing, followsLatest else { return }
        followsLatest = false
    }
}


extension TranscriptEditorModel {
    /// A running meeting or live session keeps saving segments to this transcript: pull what it has saved so far into the list.
    public func refreshSegmentsFromStore() async { await reloadLiveSegments() }
}

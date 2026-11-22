import AppCore
import FeatureSupport
import Foundation

// MARK: - Re-transcribe and identify speakers again (SCR-013)

/// What the editor's Re-transcribe popover asks for.
public struct RerunRequest: Sendable, Equatable {
    public enum Scope: Sendable, Equatable { case wholeTranscript, selection }
    public var scope: Scope
    public var languageMode: LanguageMode
    /// `nil` is Automatic.
    public var modelID: ModelID?
    /// Re-run speech recognition. `false` with ``identifySpeakers`` only relabels speakers.
    public var transcribe: Bool
    public var identifySpeakers: Bool
    public var speakerCount: SpeakerCount
    /// Wipe and rebuild everything instead of merging. The UI asks for confirmation first.
    public var replaceEverything: Bool

    public init(
        scope: Scope = .wholeTranscript, languageMode: LanguageMode = .autoDetect, modelID: ModelID? = nil, transcribe: Bool = true,
        identifySpeakers: Bool = false, speakerCount: SpeakerCount = .auto, replaceEverything: Bool = false
    ) {
        self.scope = scope
        self.languageMode = languageMode
        self.modelID = modelID
        self.transcribe = transcribe
        self.identifySpeakers = identifySpeakers
        self.speakerCount = speakerCount
        self.replaceEverything = replaceEverything
    }
}

extension TranscriptEditorModel {
    /// A re-run needs the queue and the media, and not another run in progress.
    public var canRerun: Bool { jobQueue != nil && mediaURL != nil && !isRerunning && !isReadOnly }

    public var isRerunning: Bool {
        guard let state = rerunJob?.state else { return false }
        return state == .pending || state == .running
    }

    /// Time ranges of the selected segments, with touching ranges merged.
    public func selectedRanges() -> [TimeRange] {
        let chosen = segments.filter { selection.contains($0.id) }.sorted { $0.start < $1.start }
        var ranges: [TimeRange] = []
        for segment in chosen {
            if var last = ranges.last, segment.start <= last.end + 0.05 {
                last.end = max(last.end, segment.end)
                ranges[ranges.count - 1] = last
            } else {
                ranges.append(TimeRange(start: segment.start, end: segment.end))
            }
        }
        return ranges
    }

    /// The job a request turns into, or `nil` when it cannot run (no media, empty selection).
    public func rerunJob(for request: RerunRequest) -> Job? {
        guard let mediaURL else { return nil }
        let ranges = request.scope == .selection ? selectedRanges() : []
        if request.scope == .selection && ranges.isEmpty { return nil }
        guard request.transcribe || request.identifySpeakers else { return nil }
        let rerun = RerunOptions(
            ranges: ranges, replaceEverything: request.replaceEverything && request.transcribe,
            speakersOnly: !request.transcribe)
        let settings = JobSettings(
            languageMode: request.languageMode, modelID: request.modelID, diarize: request.identifySpeakers,
            diarization: request.identifySpeakers ? request.speakerCount.diarization : [:], rerun: rerun)
        return Job(kind: .transcribeFile, input: mediaURL, transcriptID: transcriptID, settings: settings)
    }

    /// Queues the re-run and follows it. Edits are saved first and the editor is read-only until the job ends, so a stale
    /// editor can never overwrite the merged result.
    public func rerun(_ request: RerunRequest) async {
        // A second Start while one is running or starting would capture the locked state as the one to restore.
        guard !isRerunning, !rerunStarting else { return }
        rerunStatus = nil
        guard let jobQueue, let job = rerunJob(for: request) else {
            rerunStatus = request.scope == .selection && selectedRanges().isEmpty ? "Select some segments first." : nil
            return
        }
        rerunStarting = true
        defer { rerunStarting = false }
        rerunRestoreReadOnly = isReadOnly
        setReadOnly(true)  // before the flush suspends: nothing can slip in between
        await flush()
        rerunJob = job
        // Subscribe before enqueueing: a quick job can finish before a later subscription exists.
        watchRerunJob(job.id)
        do {
            _ = try await jobQueue.enqueue(job)
            if let latest = await jobQueue.jobs().first(where: { $0.id == job.id }), rerunJob?.state != latest.state {
                await rerunJobUpdated(latest)
            }
        } catch {
            rerunWatcher?.cancel()
            rerunJob = nil
            setReadOnly(rerunRestoreReadOnly)
            rerunStatus = "Could not start the re-run: \(error.localizedDescription)"
        }
    }

    public func cancelRerun() async {
        guard let job = rerunJob else { return }
        await jobQueue?.cancel(job.id)
    }

    func watchRerunJob(_ id: JobID) {
        rerunWatcher?.cancel()
        guard let jobQueue else { return }
        let events = jobQueue.events()
        rerunWatcher = Task { [weak self] in
            for await event in events {
                guard let self, !Task.isCancelled else { return }
                guard case .updated(let job) = event, job.id == id else { continue }
                await self.rerunJobUpdated(job)
                if [.completed, .failed, .cancelled].contains(job.state) { return }
            }
        }
    }

    func rerunJobUpdated(_ job: Job) async {
        rerunJob = job
        switch job.state {
        case .completed:
            await finishRerun()
            rerunStatus = job.warning
        case .failed:
            await finishRerun()
            rerunStatus = job.failureReason ?? "The re-run failed."
        case .cancelled:
            await finishRerun()
            rerunStatus = "Re-run cancelled. Your transcript is unchanged."
        default: break
        }
    }

    /// Reloads what the job changed and hands the editor back to the user.
    private func finishRerun() async {
        await reloadSegmentsFromRepository()
        if let header = try? await repository.transcript(transcriptID) { adoptHeader(header) }
        undoManager.removeAllActions()  // earlier undo steps describe segments the job has replaced
        refreshUndoState()
        setReadOnly(rerunRestoreReadOnly)
    }

    // MARK: Transcript language

    /// "Set transcript language": states which language(s) the transcript is in, and relabels the segments when it is a single
    /// language. No recognition runs.
    public func setTranscriptLanguages(_ languages: Set<LanguageCode>) {
        guard !languages.isEmpty, !isReadOnly else { return }
        languagesPinned = true
        if languages.count == 1, let only = languages.first {
            let changes = segments.filter { $0.languageCode?.primary != only.primary }.map { old -> EditDelta.Replacement in
                var new = old
                new.languageCode = only
                new.languageConfidence = 1
                return .init(before: old, after: new)
            }
            if !changes.isEmpty { perform(EditDelta(name: "Set Transcript Language", replaced: changes)) }
        }
        updateHeader { $0.languages = languages }
    }
}

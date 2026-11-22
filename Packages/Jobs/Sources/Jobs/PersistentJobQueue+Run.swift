import AppCore
import AudioCapture
import Diarization
import Export
import Foundation
import Processing
import Transcription

// The per-job pipeline: prepare -> models -> transcribe (checkpointed) -> diarize -> post-process -> save -> export -> notify.

extension PersistentJobQueue {
    /// Runs one job to a final state. Never throws; every error ends in `finish(_:error:)`.
    func execute(_ id: JobID) async {
        do {
            try await run(id)
        } catch {
            await finish(id, error: error)
        }
        running[id] = nil
        await unloadEnginesIfIdle()
        await schedule()
    }

    // MARK: - Pipeline

    private func run(_ id: JobID) async throws {
        guard let queued = store[id],
            await apply(
                id, .start,
                {
                    $0.failureReason = nil
                    $0.etaSeconds = nil
                })
        else { return }
        setNote(id, nil)
        failures[id] = nil
        guard queued.kind == .transcribeFile else {
            try await runHandled(id, queued)
            return
        }
        guard let declaredInput = queued.input else { throw AppError.other("The job has no input file.") }

        var transcript = try await existingTranscript(for: queued)
        let input = await resolvedInput(declaredInput, transcript: transcript)
        let scoped = input.startAccessingSecurityScopedResource()
        defer { if scoped { input.stopAccessingSecurityScopedResource() } }
        let assetID = transcript?.mediaAssetID ?? Self.mediaAssetID(for: queued)
        guard FileManager.default.fileExists(atPath: input.path) else { throw AppError.mediaMissing(assetID) }

        let total = (try? await services.decoder.duration(of: input)) ?? 0
        if transcript == nil {
            transcript = try await createTranscript(for: queued, input: input, assetID: assetID, duration: total)
        }
        guard var header = transcript else { return }
        let settings = queued.settings
        // SCR-013: a re-run of an existing transcript merges by time range instead of wiping it, unless asked to replace everything.
        let rerun = (queued.transcriptID != nil && !(settings.rerun?.replaceEverything ?? false)) ? settings.rerun : nil
        var warning: String?
        var segments: [Segment]

        if let rerun {
            let existing = try await services.transcripts.segments(for: header.id)
            let existingSpeakers = header.speakers
            if rerun.speakersOnly {
                segments = existing
            } else {
                let plan = try await planEngines(for: settings)
                await mutate(id) { $0.engine = plan.assignments.first?.engine }
                try await ensureModels(of: plan, for: id)
                var fresh: [Segment] = []
                try await transcribe(
                    id, input: input, transcriptID: header.id, plan: plan, checkpoint: nil, total: total, collect: { fresh += $0 })
                fresh = try await postProcess(fresh, settings: settings)
                segments = RerunMerge.merge(existing: existing, fresh: fresh, ranges: rerun.ranges)
            }
            if settings.diarize {
                let before = segments
                let result = await diarizeSafely(id, input: input, settings: settings, segments: &segments)
                warning = result.warning
                if let speakers = result.speakers {
                    let mapped = RerunMerge.remapSpeakers(
                        before: before, after: segments, newSpeakers: speakers, existingSpeakers: existingSpeakers)
                    segments = mapped.segments
                    header.speakers = mapped.speakers
                } else {
                    segments = before
                    header.speakers = existingSpeakers
                }
            }
        } else {
            let checkpoint = try await trimToCheckpoint(header.id, checkpoint: store[id]?.checkpoint)
            let plan = try await planEngines(for: settings)
            await mutate(id) { $0.engine = plan.assignments.first?.engine }
            try await ensureModels(of: plan, for: id)

            try await transcribe(id, input: input, transcriptID: header.id, plan: plan, checkpoint: checkpoint, total: total)

            segments = try await services.transcripts.segments(for: header.id)
            if settings.diarize {
                // DIA-AC-16: a failed speaker step never fails the job; it completes without speaker labels and a warning.
                let result = await diarizeSafely(id, input: input, settings: settings, segments: &segments)
                header.speakers = result.speakers ?? []
                warning = result.warning
            }
            segments = try await postProcess(segments, settings: settings)
            if settings.rerun?.replaceEverything == true && !settings.diarize { header.speakers = [] }
        }

        header.duration = max(total, segments.map(\.end).max() ?? 0)
        header.languages = languages(of: segments, settings: settings, detected: detected[id] ?? [])
        header.modifiedAt = configuration.now()
        // Last cancellation point. Replacement rules are not idempotent, so once the processed segments are written the
        // job must complete; until then the raw segments plus the checkpoint make a retry safe.
        try Task.checkCancellation()
        try await services.transcripts.save(header)
        try await services.transcripts.replaceSegments(segments, for: header.id)

        if let target = settings.translateTo { await translateAfterTranscription(id, transcriptID: header.id, target: target) }
        await mutate(id) {
            $0.state = .completed
            $0.progress = 1
            $0.etaSeconds = nil
            $0.warning = warning
        }
        detected[id] = nil
        let exported = await autoExport(id, document: TranscriptDocument(transcript: header, segments: segments))
        await jobReachedFinalState(id, title: header.title, exportedTo: exported)
    }

    /// Runs the injected handler of a non-file job (meeting finalization, translation) to a final state.
    private func runHandled(_ id: JobID, _ queued: Job) async throws {
        guard let handler = services.handlers[queued.kind] else {
            throw AppError.unsupportedFormat("The queue cannot run \(queued.kind.rawValue) jobs in this build.")
        }
        await mutate(id, persist: false) { $0.progress = 0 }
        let context = JobHandlerContext(
            job: queued,
            progress: { [weak self] fraction in
                await self?.mutate(id, persist: false) { $0.progress = max($0.progress, min(1, max(0, fraction))) }
            },
            note: { [weak self] text in await self?.setNote(id, text) })
        let result = try await handler(context)
        try Task.checkCancellation()
        await mutate(id) {
            if let transcriptID = result.transcriptID { $0.transcriptID = transcriptID }
            $0.state = .completed
            $0.progress = 1
            $0.etaSeconds = nil
        }
        setNote(id, nil)
        await jobReachedFinalState(id, title: result.title)
    }

    /// `JobSettings.translateTo`: after a transcription job saved its segments, runs the `.translate` handler on them.
    /// A failure never fails the transcription (the transcript is complete); it is reported as a note instead.
    private func translateAfterTranscription(_ id: JobID, transcriptID: TranscriptID, target: LanguageCode) async {
        guard let handler = services.handlers[.translate], let queued = store[id] else {
            setNote(id, "Translation was skipped: it is not available in this build.")
            return
        }
        var translate = Job(kind: .translate, transcriptID: transcriptID, settings: queued.settings)
        translate.settings.translateTo = target
        setNote(id, "Translating")
        let context = JobHandlerContext(job: translate, progress: { _ in }, note: { _ in })
        do {
            _ = try await handler(context)
            setNote(id, nil)
        } catch {
            setNote(id, "Translation failed: \(String(describing: error))")
        }
    }

    private func existingTranscript(for job: Job) async throws -> Transcript? {
        guard let id = job.transcriptID else { return nil }
        return try await services.transcripts.transcript(id)
    }

    /// The referenced file, or the one the stored security-scoped bookmark resolves to when it moved.
    private func resolvedInput(_ declared: URL, transcript: Transcript?) async -> URL {
        if FileManager.default.fileExists(atPath: declared.path) { return declared }
        guard let assetID = transcript?.mediaAssetID, let asset = try? await services.media.asset(assetID), let bookmark = asset.bookmark
        else { return declared }
        var stale = false
        let resolved = try? URL(
            resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        return resolved ?? declared
    }

    private func createTranscript(for job: Job, input: URL, assetID: MediaAssetID, duration: TimeInterval) async throws -> Transcript {
        let video = ["mp4", "mov", "m4v"].contains(input.pathExtension.lowercased())
        var asset = MediaAsset(
            id: assetID, kind: video ? .video : .audio, bookmark: try? input.bookmarkData(options: [.withSecurityScope]),
            duration: duration)
        if job.settings.copyIntoLibrary {
            // FILE-AC-16: an owned copy replaces the bookmark. A failed copy falls back to referencing the original.
            do {
                guard let root = await services.libraryRoot?() else { throw AppError.other("No library folder is configured.") }
                asset.libraryRelativePath = try LibraryMediaCopy.copy(input, assetID: assetID, libraryRoot: root)
                asset.isOwnedByLibrary = true
                asset.bookmark = nil
            } catch {
                log.error("Copy into library failed: \(String(describing: error), privacy: .public)")
                setNote(job.id, "Could not copy into the library; the original file is referenced instead.")
            }
        }
        try await services.media.save(asset)
        let transcript = Transcript(
            title: input.deletingPathExtension().lastPathComponent, source: .file, duration: duration, mediaAssetID: assetID,
            createdAt: configuration.now(), modifiedAt: configuration.now())
        try await services.transcripts.save(transcript)
        await mutate(job.id) { $0.transcriptID = transcript.id }
        return transcript
    }

    /// Drops segments at or after the checkpoint so a chunk caught between "segments saved" and "checkpoint saved" by a crash
    /// is not duplicated when it is transcribed again (FILE-AC-08). Without a checkpoint the run starts from scratch.
    private func trimToCheckpoint(_ id: TranscriptID, checkpoint: JobCheckpoint?) async throws -> JobCheckpoint? {
        let existing = try await services.transcripts.segments(for: id)
        let kept = checkpoint.map { cp in existing.filter { $0.start < cp.mediaTime } } ?? []
        if kept.count != existing.count { try await services.transcripts.replaceSegments(kept, for: id) }
        return checkpoint
    }

    // MARK: - Engines and models

    private func planEngines(for settings: JobSettings) async throws -> EnginePlan {
        let catalog = await services.models.catalog()
        let installed = await services.models.installedModels()
        let request = RoutingRequest(
            languageMode: settings.languageMode, useCase: .file, tier: services.hardware.profile.tier, installedModels: installed,
            explicitModel: settings.modelID)
        return try DefaultEngineRouter(catalog: catalog).plan(for: request)
    }

    /// Makes every model of the plan available (system-managed Apple assets excluded). Installed models finish at once, but
    /// still go through `ensureAvailable` so the model manager can complete missing pieces such as the Whisper tokenizer
    /// (ENG-AC-14).
    private func ensureModels(of plan: EnginePlan, for id: JobID) async throws {
        let catalog = await services.models.catalog()
        var seen = Set<ModelID>()
        for model in plan.assignments.compactMap(\.model) where seen.insert(model).inserted {
            if catalog.first(where: { $0.id == model })?.runtime == .appleAsset { continue }
            try await ensureModel(model, for: id)
        }
    }

    /// Downloads `model` if needed. The job stays `.running` and reports the download as progress plus a status note.
    func ensureModel(_ model: ModelID, for id: JobID) async throws {
        let name = await services.models.catalog().first { $0.id == model }?.displayName ?? model.rawValue
        for try await event in services.models.ensureAvailable(model) {
            try Task.checkCancellation()
            switch event {
            case .progress(let fraction, _, _):
                setNote(id, "Downloading \(name) (\(Int((fraction * 100).rounded()))%)")
                await mutate(id, persist: false) { $0.progress = min(1, max(0, fraction)) }
            case .verifying: setNote(id, "Verifying \(name)")
            case .completed: break
            }
        }
        try Task.checkCancellation()
        setNote(id, nil)
    }

    // MARK: - Transcription

    private func transcribe(
        _ id: JobID, input: URL, transcriptID: TranscriptID, plan: EnginePlan, checkpoint: JobCheckpoint?, total: TimeInterval,
        collect: (([Segment]) -> Void)? = nil
    ) async throws {
        guard let job = store[id] else { return }
        let options = TranscriptionOptions(languageMode: job.settings.languageMode, useCase: .file, modelID: job.settings.modelID)
        let startFraction = total > 0 ? min(1, (checkpoint?.mediaTime ?? 0) / total) : 0
        await mutate(id, persist: false) { $0.progress = startFraction }
        let estimator = ETAEstimator(startedAt: configuration.now(), startFraction: startFraction)
        var lastBroadcast = Date.distantPast
        let resolver = services.engineResolver?(plan, job.settings) ?? EngineBinding.resolver(plan: plan, engines: services.engines)

        do {
            for try await event in services.pipeline(plan).run(file: input, options: options, resumeFrom: checkpoint, engines: resolver) {
                try Task.checkCancellation()
                switch event {
                case .languageDetected(let scores):
                    if let top = scores.max(by: { $0.probability < $1.probability }) { detected[id, default: []].insert(top.language) }
                case .chunkCompleted(let segments, let marker):
                    // Segments first, then the checkpoint: a crash in between re-transcribes the chunk, and the
                    // trim in `trimToCheckpoint` removes its orphaned segments.
                    // SCR-013: a merge re-run collects in memory and never checkpoints (an interrupt restarts it from scratch).
                    if let collect {
                        collect(segments)
                    } else if !segments.isEmpty {
                        try await services.transcripts.upsertSegments(segments, for: transcriptID)
                    }
                    let fraction = total > 0 ? min(1, marker.mediaTime / total) : 0
                    let eta = estimator.eta(fraction: fraction, now: configuration.now())
                    let storesCheckpoint = collect == nil
                    await mutate(id) {
                        if storesCheckpoint { $0.checkpoint = marker }
                        $0.progress = fraction
                        $0.etaSeconds = eta
                    }
                    lastBroadcast = configuration.now()
                case .progress(let fraction, _):
                    let now = configuration.now()
                    guard now.timeIntervalSince(lastBroadcast) >= configuration.progressInterval else { continue }
                    lastBroadcast = now
                    let eta = estimator.eta(fraction: fraction, now: now)
                    await mutate(id, persist: false) {
                        $0.progress = max($0.progress, fraction)
                        $0.etaSeconds = eta
                    }
                }
            }
        } catch AppError.mediaMissing {
            // The decoder only knows the file, not the asset; attribute the error to this job's asset.
            throw AppError.mediaMissing(Self.mediaAssetID(for: job))
        }
        try Task.checkCancellation()  // a cancelled consumer ends the stream quietly instead of throwing
    }

    // MARK: - Diarization and post-processing

    /// DIA-AC-16: runs the speaker step; a failure (model download, diarizer) yields `nil` speakers and a warning instead of
    /// failing the job. Cancellation (pause/cancel) is never swallowed: the caller's next checkpoint rethrows it.
    private func diarizeSafely(
        _ id: JobID, input: URL, settings: JobSettings, segments: inout [Segment]
    ) async -> (speakers: [Speaker]?, warning: String?) {
        var working = segments
        do {
            let speakers = try await diarize(id, input: input, settings: settings, segments: &working)
            segments = working
            return (speakers, services.diarizer == nil ? "Speaker identification is unavailable in this build." : nil)
        } catch {
            if error is CancellationError || (error as? AppError) == .cancelled || Task.isCancelled { return (nil, nil) }
            log.error("Diarization failed: \(String(describing: error), privacy: .public)")
            setNote(id, nil)
            return (nil, "Speakers could not be identified (\(String(describing: error))). The transcript has no speaker labels.")
        }
    }

    private func diarize(_ id: JobID, input: URL, settings: JobSettings, segments: inout [Segment]) async throws -> [Speaker] {
        guard let diarizer = services.diarizer else {
            setNote(id, "Speaker identification is unavailable in this build.")
            return []
        }
        try await ensureModel(DiarizationModelID.community1, for: id)
        setNote(id, "Identifying speakers")
        await mutate(id, persist: false) { $0.etaSeconds = nil }
        let turns = try await diarizer.diarize(file: input, options: Self.diarizationOptions(settings.diarization))
        try Task.checkCancellation()
        setNote(id, nil)
        return Self.assignSpeakers(turns: turns, to: &segments)
    }

    /// `["exact": n]` or `["min": a, "max": b]`; anything else (or empty) is automatic.
    static func diarizationOptions(_ raw: [String: Int]) -> DiarizationOptions {
        if let exact = raw["exact"], exact > 0 { return DiarizationOptions(speakerCount: .exact(exact)) }
        if let lower = raw["min"], let upper = raw["max"], lower > 0, upper >= lower {
            return DiarizationOptions(speakerCount: .range(min: lower, max: upper))
        }
        return DiarizationOptions()
    }

    private static let speakerColors = ["#4F8EF7", "#F5A623", "#7ED321", "#BD10E0", "#50E3C2", "#D0021B", "#8B572A", "#9B9B9B"]

    /// Labels each segment with the speaker whose turns overlap it most; speakers are numbered by slot.
    static func assignSpeakers(turns: [SpeakerTurn], to segments: inout [Segment]) -> [Speaker] {
        var bySlot: [Int: Speaker] = [:]
        for slot in Set(turns.map(\.slot)).sorted() {
            let number = bySlot.count + 1
            bySlot[slot] = Speaker(name: "Speaker \(number)", colorHex: speakerColors[(number - 1) % speakerColors.count])
        }
        for index in segments.indices {
            if let slot = TurnAssigner.slot(for: segments[index].range, in: turns) { segments[index].speakerID = bySlot[slot]?.id }
        }
        let used = Set(segments.compactMap(\.speakerID))
        return bySlot.keys.sorted().compactMap { bySlot[$0] }.filter { used.contains($0.id) }
    }

    private func postProcess(_ segments: [Segment], settings: JobSettings) async throws -> [Segment] {
        // The hallucination filter follows the Settings toggle (off by default, IGN) so re-deriving flags later agrees with it.
        let hallucination = await services.settings.value(for: "ignore.hallucinationFilter", as: Bool.self) ?? false
        let lowConfidence = await services.settings.value(for: "ignore.lowConfidenceThreshold", as: Double.self) ?? 0.5
        let noSpeech = await services.settings.value(for: "ignore.noSpeechThreshold", as: Double.self) ?? 0.6
        let context = PostProcessingContext(
            ignoreRules: try await services.rules.ignoreRules(), replacementRules: try await services.rules.replacementRules(),
            applyReplacements: settings.applyReplacements, enableHallucinationFilter: hallucination,
            lowConfidenceThreshold: lowConfidence, noSpeechThreshold: noSpeech)
        return await services.postProcessor.process(segments, context: context)
    }

    private func languages(of segments: [Segment], settings: JobSettings, detected: Set<LanguageCode>) -> Set<LanguageCode> {
        var result = detected
        for segment in segments { if let code = segment.languageCode { result.insert(code.primary) } }
        if result.isEmpty {
            switch settings.languageMode {
            case .single(let code): result = [code]
            case .multilingual(let set): result = set
            case .autoDetect: break
            }
        }
        return result
    }

    // MARK: - Completion

    private func autoExport(_ id: JobID, document: TranscriptDocument) async -> URL? {
        guard let presetID = store[id]?.settings.autoExportPresetID, let provider = services.autoExport,
            let writer = await provider()
        else { return nil }
        switch await writer.exportCompleted(document, presetID: presetID) {
        case .written(let url): return url
        case .skipped: return nil
        case .failed(let reason):
            setNote(id, "Auto-export failed: \(reason)")
            return nil
        }
    }

    /// Records how a run that threw ended: pause or cancel as requested, otherwise a retryable failure.
    private func finish(_ id: JobID, error: any Error) async {
        let intent = running[id]?.intent
        let isCancellation = error is CancellationError || (error as? AppError) == .cancelled || Task.isCancelled
        if isCancellation, intent != nil || Task.isCancelled {
            setNote(id, nil)
            switch intent {
            case .pause: await apply(id, .pause) { $0.etaSeconds = nil }
            case .cancel:
                await apply(id, .cancel) { $0.etaSeconds = nil }
                await jobReachedFinalState(id)
            case nil: await apply(id, .interrupt) { $0.etaSeconds = nil }  // shut down mid-run; resumes from the checkpoint
            }
            return
        }
        guard let job = store[id] else { return }
        var appError = AppError.mapping(error, engine: "jobs")
        if case .mediaMissing = appError { appError = .mediaMissing(await mediaAssetID(of: job)) }
        failures[id] = appError
        log.error("Job \(id.description, privacy: .public) failed: \(String(describing: appError), privacy: .public)")
        setNote(id, nil)
        await apply(id, .fail) {
            $0.failureReason = Self.describe(appError, input: job.input)
            $0.etaSeconds = nil
        }
        await jobReachedFinalState(id)
    }

    private func mediaAssetID(of job: Job) async -> MediaAssetID {
        guard let tid = job.transcriptID, let transcript = try? await services.transcripts.transcript(tid) else {
            return Self.mediaAssetID(for: job)
        }
        return transcript.mediaAssetID ?? Self.mediaAssetID(for: job)
    }

    /// Notifies the app once a job (or, for multi-file batches, the whole batch) is done.
    func jobReachedFinalState(_ id: JobID, title: String? = nil, exportedTo: URL? = nil) async {
        guard let job = store[id], JobStateMachine.isTerminal(job.state) else { return }
        if let batchID = batchOf[id], var batch = batches[batchID] {
            switch job.state {
            case .completed: batch.completed += 1
            case .failed: batch.failed += 1
            default: batch.cancelled += 1
            }
            batch.remaining.remove(id)
            if batch.remaining.isEmpty {
                batches[batchID] = nil
                for member in batch.jobIDs { batchOf[member] = nil }
                await services.notifier?.batchFinished(
                    JobBatchSummary(jobIDs: batch.jobIDs, completed: batch.completed, failed: batch.failed, cancelled: batch.cancelled))
            } else {
                batches[batchID] = batch
            }
            return
        }
        switch job.state {
        case .completed: await services.notifier?.jobCompleted(JobCompletionInfo(job: job, transcriptTitle: title, exportedTo: exportedTo))
        case .failed: await services.notifier?.jobFailed(job)
        default: break
        }
    }

    /// User-facing text for a failure (shown with the Retry action).
    static func describe(_ error: AppError, input: URL?) -> String {
        let name = input?.lastPathComponent ?? "the file"
        switch error {
        case .cancelled: return "Cancelled."
        case .modelNotInstalled(let model): return "The model \(model) is not installed."
        case .modelDownloadFailed(let model, let reason): return "Downloading \(model) failed: \(reason)"
        case .checksumMismatch(let model): return "The downloaded \(model) files were corrupt. Retry to download them again."
        case .unsupportedLanguage(let language): return "No available model supports the language \(language)."
        case .unsupportedFormat(let message): return "\(name) cannot be transcribed: \(message)"
        case .engineFailure(let engine, let reason): return "The \(engine) engine failed: \(reason)"
        case .permissionDenied(let kind): return "Permission denied (\(kind))."
        case .captureSilent(let reason): return reason
        case .deviceUnavailable: return "The audio device is unavailable."
        case .mediaMissing: return "The media file \(name) is missing. Move it back or add it again, then retry."
        case .persistence(let reason): return "Could not save the transcript: \(reason)"
        case .exportFailed(let reason): return "Export failed: \(reason)"
        case .outOfMemory: return "Ran out of memory. Close other apps or pick a smaller model, then retry."
        case .other(let message): return message
        }
    }
}

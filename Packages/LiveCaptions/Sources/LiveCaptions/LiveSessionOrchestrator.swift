import AppCore
import Foundation

/// Live-session orchestrator: capture, ASR engine, optional streaming diarization, the post-processing chain,
/// caption lines, optional translation and crash-safe incremental persistence.
///
/// One session at a time. Volatile text is shown as a distinct line that finalizes in place; finals go through the
/// `TranscriptPostProcessor` (ignored lines are hidden but still persisted, flagged). When "Save as transcript" is on,
/// the transcript header is created at start and finalized segments are flushed every `checkpointInterval`.
public actor LiveSessionOrchestrator: LiveSessionControlling {
    private let audio: any LiveAudioProviding
    private let engines: any LiveEngineProviding
    private let transcripts: any TranscriptRepository
    private let postProcessor: any TranscriptPostProcessor
    private let postContext: @Sendable () async -> PostProcessingContext
    private let diarizer: (any StreamingDiarizer)?
    private let translation: (any TranslationRouter)?
    private let options: LiveSessionOptions
    private let log = AppLog.logger("liveSession")

    private let stateBus = Broadcaster<LiveSessionState>(initial: .idle, buffering: 16)
    private let linesBus = Broadcaster<[CaptionLine]>(initial: [], buffering: 1)
    private let eventBus = Broadcaster<LiveSessionEvent>(buffering: 32, replayLatest: false)
    private let pauseGate = PauseGate()

    private var currentState: LiveSessionState = .idle
    private var session: SessionContext?
    private var completedTranscriptID: TranscriptID?
    private var lastTurns: [SpeakerTurn] = []

    public init(
        audio: any LiveAudioProviding, engines: any LiveEngineProviding, transcripts: any TranscriptRepository,
        postProcessor: any TranscriptPostProcessor,
        postProcessingContext: @escaping @Sendable () async -> PostProcessingContext = { PostProcessingContext() },
        diarizer: (any StreamingDiarizer)? = nil, translation: (any TranslationRouter)? = nil,
        options: LiveSessionOptions = LiveSessionOptions()
    ) {
        self.audio = audio
        self.engines = engines
        self.transcripts = transcripts
        self.postProcessor = postProcessor
        self.postContext = postProcessingContext
        self.diarizer = diarizer
        self.translation = translation
        self.options = options
    }

    // MARK: Observation

    public nonisolated func state() -> AsyncStream<LiveSessionState> { stateBus.subscribe() }
    public nonisolated func lines() -> AsyncStream<[CaptionLine]> { linesBus.subscribe() }
    /// Notices such as device fallback, silent capture, speaker limit and pause/resume.
    public nonisolated func events() -> AsyncStream<LiveSessionEvent> { eventBus.subscribe() }
    /// `true` while capture is paused (audio is discarded, not transcribed).
    public nonisolated var isPaused: Bool { pauseGate.isPaused }

    /// Provisional speaker turns of the most recent session, for `SpeakerReconciler` once the offline pass exists.
    public func liveSpeakerTurns() -> [SpeakerTurn] { session?.timeline.turns ?? lastTurns }

    // MARK: Control

    public func start(_ config: LiveSessionConfig) async throws {
        switch currentState {
        case .starting, .running, .stopping: throw AppError.other("A live session is already active")
        case .idle, .failed: break
        }
        completedTranscriptID = nil
        lastTurns = []
        pauseGate.set(false)
        let ctx = SessionContext(config: config, maxRetainedLines: options.maxRetainedLines)
        session = ctx
        setState(.starting)
        linesBus.send([])
        do {
            let selection = try await engines.resolve(languageMode: config.languageMode)
            try checkStartNotCancelled(ctx)
            ctx.lanes = try await audio.lanes(for: config.source)
            guard !ctx.lanes.isEmpty else { throw AppError.deviceUnavailable }
            try checkStartNotCancelled(ctx)
            ctx.postContext = await postContext()
            try checkStartNotCancelled(ctx)

            if config.saveAsTranscript {
                ctx.createdAt = options.now()
                ctx.transcriptTitle = "Live captions \(ctx.createdAt.formatted(date: .abbreviated, time: .shortened))"
                let header = Transcript(
                    title: ctx.transcriptTitle, source: .liveCaptions, languages: ctx.fixedLanguage.map { [$0] } ?? [],
                    createdAt: ctx.createdAt, modifiedAt: ctx.createdAt)
                ctx.transcriptID = header.id
                do { try await transcripts.save(header) } catch { throw AppError.persistence(reason: String(describing: error)) }
                try checkStartNotCancelled(ctx)
            }

            var streams: [AsyncStream<AudioChunk>] = []
            for lane in ctx.lanes {
                streams.append(try await lane.source.start())
                try checkStartNotCancelled(ctx)
            }

            // No suspension points from here: tasks cannot observe a half-started session.
            ctx.phase = .running
            let transcriptionOptions = TranscriptionOptions(
                languageMode: config.languageMode, useCase: .live, modelID: selection.model,
                vocabulary: options.vocabulary, wordTimestamps: false)
            for (index, lane) in ctx.lanes.enumerated() {
                launch(lane: index, lane, chunks: streams[index], engine: selection.engine, options: transcriptionOptions, ctx: ctx)
            }
            if ctx.transcriptID != nil { launchCheckpointing(ctx) }
            if config.translateTo != nil, translation != nil { launchTranslation(ctx) }
            setState(.running)
        } catch {
            let wasCancelled = ctx.cancelRequested
            await abortStart(ctx)
            if wasCancelled {
                setState(.idle)
                throw AppError.cancelled
            }
            let appError = (error as? AppError) ?? .other(String(describing: error))
            setState(.failed(Self.describe(appError)))
            throw appError
        }
    }

    public func stop() async -> TranscriptID? {
        guard let ctx = session else {
            defer { completedTranscriptID = nil }
            return completedTranscriptID
        }
        switch ctx.phase {
        case .starting:
            ctx.cancelRequested = true
            return nil
        case .stopping, .finished:
            return nil
        case .running:
            break
        }
        ctx.phase = .stopping
        setState(.stopping)
        await stopSources(ctx)
        await drain(ctx)
        let id = await finish(ctx, graceful: true)
        setState(.idle)
        return id
    }

    /// Pauses transcription: audio keeps flowing from the source but is discarded until `resume()`.
    public func pause() {
        guard currentState == .running, !pauseGate.isPaused else { return }
        pauseGate.set(true)
        eventBus.send(.paused)
    }

    public func resume() {
        guard currentState == .running, pauseGate.isPaused else { return }
        pauseGate.set(false)
        eventBus.send(.resumed)
    }

    // MARK: Start helpers

    private func checkStartNotCancelled(_ ctx: SessionContext) throws {
        if ctx.cancelRequested || Task.isCancelled { ctx.cancelRequested = true; throw AppError.cancelled }
    }

    private func abortStart(_ ctx: SessionContext) async {
        ctx.phase = .stopping
        for lane in ctx.lanes { await lane.source.stop() }
        ctx.sourcesStopped = true
        cancelAll(ctx)
        ctx.phase = .finished
        if session === ctx { session = nil }
    }

    // MARK: Pipeline

    private func launch(
        lane index: Int, _ lane: LiveAudioLane, chunks: AsyncStream<AudioChunk>, engine: any TranscriptionEngine,
        options transcriptionOptions: TranscriptionOptions, ctx: SessionContext
    ) {
        let (engineIn, engineOut) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(64))
        var diarIn: AsyncStream<AudioChunk>?
        var diarOut: AsyncStream<AudioChunk>.Continuation?
        if ctx.config.diarize, lane.diarize, diarizer != nil {
            let (s, c) = AsyncStream.makeStream(of: AudioChunk.self, bufferingPolicy: .bufferingNewest(64))
            diarIn = s
            diarOut = c
            ctx.diarizedLanes.insert(index)
        }
        let gate = pauseGate
        let clock = ctx.clock
        let diarContinuation = diarOut
        ctx.pumpTasks.append(
            Task.detached {
                for await chunk in chunks {
                    clock.advance(to: chunk.startSeconds + chunk.duration)
                    if gate.isPaused { continue }
                    engineOut.yield(chunk)
                    diarContinuation?.yield(chunk)
                }
                engineOut.finish()
                diarContinuation?.finish()
            })

        ctx.activeEngineLanes += 1
        let engineID = engine.id
        ctx.engineTasks.append(
            Task {
                do {
                    for try await event in engine.stream(audio: engineIn, options: transcriptionOptions) {
                        await self.handle(event, lane: index, ctx: ctx)
                    }
                } catch is CancellationError {
                } catch {
                    await self.fail(Self.mapEngineError(error, engine: engineID), ctx: ctx)
                }
                await self.laneFinished(ctx)
            })

        if let diarizer, let diarIn {
            ctx.auxTasks.append(
                Task {
                    do {
                        for try await event in diarizer.stream(audio: diarIn, options: DiarizationOptions()) {
                            self.handleDiarization(event, ctx: ctx)
                        }
                    } catch is CancellationError {
                    } catch {
                        // Diarization is best effort: captions continue without speaker labels.
                        self.log.error("diarization stopped: \(String(describing: error), privacy: .public)")
                    }
                })
        }

        let source = lane.source
        ctx.auxTasks.append(
            Task {
                for await health in source.health {
                    switch health {
                    case .silent:
                        self.eventBus.send(.captureProblem(.captureSilent(reason: "No audio is arriving from the selected source")))
                    case .deviceChanged(let to):
                        self.eventBus.send(.deviceFallback(to: to))
                    case .running, .stopped:
                        break
                    }
                }
            })
    }

    private func laneFinished(_ ctx: SessionContext) async {
        ctx.activeEngineLanes -= 1
        guard ctx.activeEngineLanes == 0, ctx.phase == .running else { return }
        // Every engine stream ended on its own (source ended): complete the session as if stopped.
        ctx.phase = .stopping
        setState(.stopping)
        await stopSources(ctx)
        let id = await finish(ctx, graceful: true)
        completedTranscriptID = id
        setState(.idle)
    }

    private func fail(_ error: AppError, ctx: SessionContext) async {
        guard ctx.phase == .running else {
            log.error("engine error while stopping: \(String(describing: error), privacy: .public)")
            return
        }
        ctx.phase = .stopping
        setState(.stopping)
        await stopSources(ctx)
        // Flush first: this runs inside an engine task, which must not be cancelled before the final checkpoint.
        let id = await finish(ctx, graceful: true)
        for t in ctx.engineTasks { t.cancel() }
        completedTranscriptID = id
        setState(.failed(Self.describe(error)))
    }

    private func stopSources(_ ctx: SessionContext) async {
        guard !ctx.sourcesStopped else { return }
        ctx.sourcesStopped = true
        for lane in ctx.lanes { await lane.source.stop() }
    }

    /// Waits for capture pumps and engines to flush remaining finals, cancelling them after `drainTimeout`.
    private func drain(_ ctx: SessionContext) async {
        let timeout = options.drainTimeout
        let all = ctx.pumpTasks + ctx.engineTasks
        let watchdog = Task {
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { for t in all { t.cancel() } }
        }
        for t in ctx.pumpTasks { await t.value }
        for t in ctx.engineTasks { await t.value }
        watchdog.cancel()
    }

    private func cancelAll(_ ctx: SessionContext) {
        for t in ctx.pumpTasks + ctx.engineTasks + ctx.auxTasks { t.cancel() }
        ctx.checkpointTask?.cancel()
        ctx.translationWake?.finish()
    }

    /// Final promotion and flush shared by stop, natural completion and failure. Returns the saved transcript id.
    private func finish(_ ctx: SessionContext, graceful: Bool) async -> TranscriptID? {
        for t in ctx.auxTasks { t.cancel() }
        ctx.translationWake?.finish()
        ctx.checkpointTask?.cancel()
        await ctx.checkpointTask?.value
        if graceful { await promoteVolatile(ctx) }
        linesBus.send(ctx.store.lines)
        // Unstructured on purpose: a cancelled caller (view teardown, app quit) must not drop the last flush.
        _ = await Task { await self.checkpoint(ctx) }.value
        lastTurns = ctx.timeline.turns
        ctx.phase = .finished
        if session === ctx { session = nil }
        pauseGate.set(false)
        return ctx.transcriptID
    }

    /// Volatile text still on screen at stop becomes a final segment so the last words are never lost.
    private func promoteVolatile(_ ctx: SessionContext) async {
        for lane in ctx.lanes.indices {
            guard let v = ctx.store.volatileEntry(lane: lane) else { continue }
            let text = v.line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                ctx.store.removeVolatile(lane: lane)
                continue
            }
            let segment = Segment(
                start: v.start, end: max(v.start, ctx.clock.now), text: text, languageCode: v.line.language)
            await commitFinal(segment, lane: lane, ctx: ctx)
        }
    }

    // MARK: Events

    private func handle(_ event: TranscriptionEvent, lane: Int, ctx: SessionContext) async {
        guard ctx.phase != .finished else { return }
        switch event {
        case .partial(let p):
            let text = p.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let id = ctx.store.setVolatile(
                lane: lane, text: text, start: p.start, language: p.languageCode ?? ctx.detectedLanguage ?? ctx.fixedLanguage,
                laneLabel: ctx.laneLabel(lane))
            if ctx.diarizedLanes.contains(lane) {
                relabel(ctx, lane: lane, touching: TimeRange(start: p.start, end: max(p.start, ctx.clock.now)))
            }
            queueTranslation(ctx, lineID: id, segmentID: nil, text: text, language: p.languageCode, volatile: true)
            linesBus.send(ctx.store.lines)
        case .final(let segment):
            await commitFinal(segment, lane: lane, ctx: ctx)
        case .progress:
            break
        case .languageDetected(let scores):
            if let best = scores.max(by: { $0.probability < $1.probability }) { ctx.detectedLanguage = best.language }
        }
    }

    private func commitFinal(_ segment: Segment, lane: Int, ctx: SessionContext) async {
        let processed = await postProcessor.process([segment], context: ctx.postContext)
        guard ctx.phase != .finished else { return }
        if processed.isEmpty { ctx.store.removeVolatile(lane: lane) }
        for var p in processed {
            p.languageCode = p.languageCode ?? ctx.detectedLanguage ?? ctx.fixedLanguage
            let label = ctx.diarizedLanes.contains(lane) ? ctx.timeline.label(for: p.range) : nil
            if let index = label?.index { p.speakerID = ctx.speaker(forIndex: index).id }
            ctx.record(p)
            let hidden = p.isIgnored || p.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hidden {
                ctx.store.removeVolatile(lane: lane)
                continue
            }
            let id = ctx.store.finalize(
                lane: lane, text: p.text, start: p.start, end: p.end, language: p.languageCode, segmentID: p.id,
                laneLabel: ctx.laneLabel(lane))
            if let label {
                ctx.store.updateEntries { e in
                    if e.line.id == id {
                        e.line.speakerLabel = label.name
                        e.line.speakerSlot = label.index
                    }
                }
            }
            queueTranslation(ctx, lineID: id, segmentID: p.id, text: p.text, language: p.languageCode, volatile: false)
        }
        linesBus.send(ctx.store.lines)
    }

    private func handleDiarization(_ event: LiveDiarizationEvent, ctx: SessionContext) {
        guard ctx.phase != .finished else { return }
        switch event {
        case .turn(let turn):
            ctx.timeline.apply(turn)
            if ctx.timeline.limitReached { notifyLimitOnce(ctx) }
            for lane in ctx.diarizedLanes { relabel(ctx, lane: lane, touching: turn.range) }
            linesBus.send(ctx.store.lines)
        case .finalized:
            break
        case .speakerLimitReached:
            ctx.timeline.noteLimitReached()
            notifyLimitOnce(ctx)
        }
    }

    private func notifyLimitOnce(_ ctx: SessionContext) {
        guard !ctx.limitNotified else { return }
        ctx.limitNotified = true
        eventBus.send(.speakerLimitReached)
    }

    /// Re-labels lines (and persisted segments) of a diarized lane that overlap `range` (or all when nil).
    private func relabel(_ ctx: SessionContext, lane: Int, touching range: TimeRange? = nil) {
        var segmentChanges: [(SegmentID, SpeakerID?)] = []
        ctx.store.updateEntries { e in
            guard e.lane == lane else { return }
            let entryRange = TimeRange(start: e.start, end: max(e.end, e.start + 0.5))
            if let range, entryRange.overlap(with: range) <= 0, e.line.speakerLabel != nil { return }
            guard let label = ctx.timeline.label(for: TimeRange(start: e.start, end: e.end)) else { return }
            e.line.speakerLabel = label.name
            e.line.speakerSlot = label.index
            if let segmentID = e.segmentID {
                segmentChanges.append((segmentID, label.index.map { ctx.speaker(forIndex: $0).id }))
            }
        }
        for (id, speaker) in segmentChanges {
            if let i = ctx.finalIndex[id], ctx.finals[i].speakerID != speaker {
                ctx.mutateFinal(id) { $0.speakerID = speaker }
            }
        }
    }

    // MARK: Translation (best effort, at most one update per `translationMinInterval`)

    private func queueTranslation(
        _ ctx: SessionContext, lineID: UUID, segmentID: SegmentID?, text: String, language: LanguageCode?, volatile: Bool
    ) {
        guard ctx.config.translateTo != nil, translation != nil else { return }
        let job = SessionContext.TranslationJob(lineID: lineID, segmentID: segmentID, text: text, language: language)
        if volatile {
            ctx.volatileTranslation = job
        } else {
            ctx.pendingFinalTranslations.append(job)
            if ctx.volatileTranslation?.lineID == lineID { ctx.volatileTranslation = nil }
        }
        ctx.translationWake?.yield()
    }

    private func nextTranslationJob(_ ctx: SessionContext) -> SessionContext.TranslationJob? {
        if !ctx.pendingFinalTranslations.isEmpty { return ctx.pendingFinalTranslations.removeFirst() }
        defer { ctx.volatileTranslation = nil }
        return ctx.volatileTranslation
    }

    private func launchTranslation(_ ctx: SessionContext) {
        guard let target = ctx.config.translateTo, let router = translation else { return }
        let (wake, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        ctx.translationWake = continuation
        let minInterval = options.translationMinInterval
        ctx.auxTasks.append(
            Task {
                let clock = ContinuousClock()
                for await _ in wake {
                    while !Task.isCancelled {
                        if let last = ctx.lastTranslationAt {
                            let wait = minInterval - last.duration(to: clock.now)
                            if wait > .zero { try? await Task.sleep(for: wait) }
                        }
                        guard !Task.isCancelled, let job = self.nextTranslationJob(ctx) else { break }
                        ctx.lastTranslationAt = clock.now
                        await self.translate(job, to: target, router: router, ctx: ctx)
                    }
                }
            })
    }

    private func translate(
        _ job: SessionContext.TranslationJob, to target: LanguageCode, router: any TranslationRouter, ctx: SessionContext
    ) async {
        let source = job.language ?? ctx.detectedLanguage ?? ctx.fixedLanguage ?? .english
        guard source.primary != target.primary else { return }
        do {
            let engine = try await router.engine(for: LanguagePair(source: source, target: target))
            let item = TranslationItem(segmentID: job.segmentID ?? SegmentID(), text: job.text)
            var result: TranslatedSegment?
            for try await t in engine.translate(items: [item], from: source, to: target) {
                result = t
                break
            }
            guard let result, ctx.phase != .finished else { return }
            // English to Sinhala is always flagged low-confidence, whatever the engine reports.
            let low = result.isLowConfidence || (source.primary == .english && target.primary == .sinhala)
            let shown = (low ? LiveCaptionMarkers.lowConfidenceTranslationPrefix : "") + result.text
            ctx.store.setTranslation(shown, forLine: job.lineID)
            if let segmentID = job.segmentID {
                ctx.mutateFinal(segmentID) {
                    $0.translations.removeAll { $0.language == target }
                    $0.translations.append(SegmentTranslation(language: target, text: result.text, engine: result.engine))
                }
            }
            linesBus.send(ctx.store.lines)
        } catch {
            log.error("translation skipped: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: Persistence (crash-safe checkpoints)

    private func launchCheckpointing(_ ctx: SessionContext) {
        let interval = options.checkpointInterval
        ctx.checkpointTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { break }
                _ = await self.checkpoint(ctx)
            }
        }
    }

    /// Flushes dirty segments and refreshes the transcript header. Failures never end the session.
    @discardableResult
    private func checkpoint(_ ctx: SessionContext) async -> Bool {
        guard let id = ctx.transcriptID else { return true }
        let batch = ctx.dirty.compactMap { sid in ctx.finalIndex[sid].map { ctx.finals[$0] } }.sorted { $0.start < $1.start }
        var languages = Set(ctx.finals.compactMap(\.languageCode))
        if let fixed = ctx.fixedLanguage { languages.insert(fixed) }
        let usedSpeakers = ctx.speakers.keys.sorted().compactMap { ctx.speakers[$0] }
        let header = Transcript(
            id: id, title: ctx.transcriptTitle, source: .liveCaptions, duration: ctx.clock.now, languages: languages,
            speakers: usedSpeakers, createdAt: ctx.createdAt, modifiedAt: options.now())
        do {
            if !batch.isEmpty { try await transcripts.upsertSegments(batch, for: id) }
            try await transcripts.save(header)
            for s in batch where ctx.finalIndex[s.id].map({ ctx.finals[$0] }) == s { ctx.dirty.remove(s.id) }
            return true
        } catch {
            let reason = String(describing: error)
            log.error("checkpoint failed: \(reason, privacy: .public)")
            eventBus.send(.checkpointFailed(reason))
            return false
        }
    }

    // MARK: Helpers

    private func setState(_ new: LiveSessionState) {
        currentState = new
        stateBus.send(new)
    }

    static func mapEngineError(_ error: any Error, engine: EngineID) -> AppError {
        if let app = error as? AppError { return app }
        return .engineFailure(engine, reason: String(describing: error))
    }

    static func describe(_ error: AppError) -> String {
        switch error {
        case .permissionDenied(let kind): "Permission denied: \(kind.rawValue)"
        case .engineFailure(let id, let reason): "\(id.rawValue): \(reason)"
        case .deviceUnavailable: "Audio device unavailable"
        case .captureSilent(let reason): reason
        case .modelNotInstalled(let model): "Model not installed: \(model.rawValue)"
        case .other(let message): message
        default: String(describing: error)
        }
    }
}

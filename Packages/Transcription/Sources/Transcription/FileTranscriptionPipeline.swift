import AppCore
import AudioCapture
import Foundation

/// An engine together with the model it should use, as resolved for one language.
public struct EngineBinding: Sendable {
    public var engine: any TranscriptionEngine
    /// Model to pass in `TranscriptionOptions.modelID`; `nil` keeps whatever the options already carry.
    public var model: ModelID?
    public init(engine: any TranscriptionEngine, model: ModelID? = nil) {
        self.engine = engine
        self.model = model
    }
}

/// Resolves the engine for a language (`nil` = language not yet known / applies to everything).
public typealias EngineResolver = @Sendable (LanguageCode?) async throws -> EngineBinding

extension EngineBinding {
    /// Builds a resolver from an ``EnginePlan`` and the available engine instances.
    ///
    /// A language-specific assignment wins, then the plan's language-agnostic assignment, then the first assignment.
    /// - Throws (from the resolver): ``AppError/engineFailure(_:reason:)`` when the plan names an engine that is not provided.
    public static func resolver(plan: EnginePlan, engines: [EngineID: any TranscriptionEngine]) -> EngineResolver {
        { language in
            let match =
                plan.assignments.first { assignment in
                    guard let language, let target = assignment.language else { return false }
                    return target == language || target.primary == language.primary
                } ?? plan.assignments.first { $0.language == nil } ?? plan.assignments.first
            guard let match else { throw AppError.other("The engine plan has no assignments.") }
            guard let engine = engines[match.engine] else {
                throw AppError.engineFailure(match.engine, reason: "Engine is not available in this build.")
            }
            return EngineBinding(engine: engine, model: match.model)
        }
    }
}

/// Progress emitted by ``FileTranscriptionPipeline``.
public enum FileTranscriptionEvent: Sendable {
    /// Language identification result (auto-detect once per file).
    case languageDetected([LanguageScore])
    /// One chunk is fully transcribed. Persist `segments` and `checkpoint` in one transaction; resuming from
    /// `checkpoint` never re-emits these segments.
    case chunkCompleted(segments: [Segment], checkpoint: JobCheckpoint)
    /// Fraction of the file covered (0...1; 0 when the duration is unknown) and the media time reached.
    case progress(fraction: Double, mediaTime: TimeInterval)
}

/// Streams a media file through an engine in bounded-memory, VAD-aligned chunks and journals a ``JobCheckpoint`` after
/// each one (FILE-AC-08, FILE-AC-09).
///
/// ### Chunking
/// The decoder yields blocks of `chunkSeconds`. Each block is appended to a carry buffer; when the next block exists, the
/// buffer is cut at the quietest gap found in its second half (so words are not split), the head is transcribed, and the
/// tail stays in the buffer. The last buffer is transcribed whole. Memory is therefore bounded by roughly
/// `1.5 x chunkSeconds` of audio regardless of file length.
///
/// ### Resume
/// Pass the last persisted checkpoint as `resumeFrom`: decoding restarts at `checkpoint.mediaTime` and chunk numbering
/// continues after `checkpoint.lastCompletedChunk`.
///
/// ### Languages
/// - `.single`: the language is passed straight to the engine.
/// - `.autoDetect`: with a ``LanguageIdentifier`` the language is identified once from the first ~30 s and then fixed;
///   without one the engine detects on its own.
/// - `.multilingual`: each VAD speech range is identified (restricted to the chosen set), then transcribed with the engine
///   assigned to that language. Ranges shorter than ``Configuration/minLanguageIDSeconds`` or identified below
///   ``Configuration/languageConfidenceThreshold`` inherit the previous range's language (LANG-AC-06); their segments keep the
///   low confidence in `languageConfidence`.
///
/// Errors are mapped to ``AppError``; cancelling the consumer stops decoding and engine calls promptly.
public struct FileTranscriptionPipeline: Sendable {
    /// Tunables.
    public struct Configuration: Sendable, Equatable {
        /// Decoder block length in seconds.
        public var chunkSeconds: TimeInterval = 30
        /// Skip engine calls for chunks without speech according to the VAD (also avoids Whisper hallucinations).
        public var skipSilentChunks = true
        /// Ranges shorter than this are not language-identified (LID is unreliable below ~1 s).
        public var minLanguageIDSeconds: TimeInterval = 1.0
        /// Identifications below this probability fall back to the previous range's language.
        public var languageConfidenceThreshold: Double = 0.5
        /// Speech ranges closer than this are merged before multilingual splitting.
        public var mergeGapSeconds: TimeInterval = 0.6
        /// Silence padding added around each multilingual range.
        public var rangePaddingSeconds: TimeInterval = 0.15
        public init() {}
    }

    private let decoder: any AudioFileDecoder
    private let vad: (any VoiceActivityDetector)?
    private let identifier: (any LanguageIdentifier)?
    private let configuration: Configuration

    /// Creates a pipeline.
    /// - Parameters:
    ///   - decoder: File decoder (defaults to ``AVFileDecoder``).
    ///   - vad: Voice-activity detector used to choose cut points and skip silence; `nil` cuts at block boundaries.
    ///   - identifier: Language identifier for auto-detect and multilingual modes.
    ///   - configuration: Chunking tunables.
    public init(
        decoder: any AudioFileDecoder = AVFileDecoder(), vad: (any VoiceActivityDetector)? = EnergyVoiceActivityDetector(),
        identifier: (any LanguageIdentifier)? = nil, configuration: Configuration = Configuration()
    ) {
        self.decoder = decoder
        self.vad = vad
        self.identifier = identifier
        self.configuration = configuration
    }

    /// Runs the pipeline with a single engine for every language.
    public func run(
        file: URL, options: TranscriptionOptions, engine: any TranscriptionEngine, resumeFrom checkpoint: JobCheckpoint? = nil
    ) -> AsyncThrowingStream<FileTranscriptionEvent, any Error> {
        run(file: file, options: options, resumeFrom: checkpoint, engines: { _ in EngineBinding(engine: engine) })
    }

    /// Runs the pipeline, asking `engines` for the engine/model of each language (see ``EngineBinding/resolver(plan:engines:)``).
    public func run(
        file: URL, options: TranscriptionOptions, resumeFrom checkpoint: JobCheckpoint? = nil, engines: @escaping EngineResolver
    ) -> AsyncThrowingStream<FileTranscriptionEvent, any Error> {
        let worker = Worker(decoder: decoder, vad: vad, identifier: identifier, configuration: configuration, engines: engines)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await worker.run(file: file, options: options, resumeFrom: checkpoint, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppError.mapping(error, engine: "pipeline"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Adapter used by engines to implement `TranscriptionEngine.transcribe(file:options:)` on top of the pipeline.
    func transcriptionEvents(
        file: URL, options: TranscriptionOptions, engine: any TranscriptionEngine
    ) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let source = run(file: file, options: options, engine: engine)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in source {
                        switch event {
                        case .languageDetected(let scores): continuation.yield(.languageDetected(scores))
                        case .chunkCompleted(let segments, _): for segment in segments { continuation.yield(.final(segment)) }
                        case .progress(let fraction, let mediaTime): continuation.yield(.progress(fraction: fraction, mediaTime: mediaTime))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Worker

    private struct Worker: Sendable {
        let decoder: any AudioFileDecoder
        let vad: (any VoiceActivityDetector)?
        let identifier: (any LanguageIdentifier)?
        let configuration: Configuration
        let engines: EngineResolver

        private static let rate = AudioChunk.sampleRate

        func run(
            file: URL, options: TranscriptionOptions, resumeFrom checkpoint: JobCheckpoint?,
            continuation: AsyncThrowingStream<FileTranscriptionEvent, any Error>.Continuation
        ) async throws {
            let total = try? await decoder.duration(of: file)
            let startAt = max(0, checkpoint?.mediaTime ?? 0)
            var chunkIndex = (checkpoint?.lastCompletedChunk ?? -1) + 1
            var mode = options.languageMode
            var pending: [Float] = []
            var pendingStart = startAt
            var blockQueue: [AudioChunk] = []

            func emitProgress(_ mediaTime: TimeInterval) {
                let fraction = (total ?? 0) > 0 ? min(1, max(0, mediaTime / (total ?? 1))) : 0
                continuation.yield(.progress(fraction: fraction, mediaTime: mediaTime))
            }

            func process(final isFinal: Bool) async throws {
                let pendingSeconds = Double(pending.count) / Self.rate
                guard pendingSeconds > 0 else { return }
                let cut = isFinal ? pending.count : await cutIndex(in: pending, start: pendingStart)
                let unit = Array(pending.prefix(cut))
                let unitChunk = AudioChunk(samples: unit, startSeconds: pendingStart, source: .file)
                var segments: [Segment] = []
                if try await hasSpeech(unitChunk) {
                    var local = options
                    local.languageMode = mode
                    let result = try await transcribe(unitChunk, options: local, continuation: continuation)
                    segments = result.segments
                    if let resolved = result.resolvedMode { mode = resolved }
                }
                try Task.checkCancellation()
                let end = pendingStart + Double(cut) / Self.rate
                pending.removeFirst(cut)
                pendingStart = end
                let marker = JobCheckpoint(lastCompletedChunk: chunkIndex, mediaTime: end)
                chunkIndex += 1
                continuation.yield(.chunkCompleted(segments: segments, checkpoint: marker))
                emitProgress(end)
            }

            for try await block in decoder.decode(file: file, chunkSeconds: configuration.chunkSeconds, startingAt: startAt) {
                try Task.checkCancellation()
                blockQueue.append(block)
                // Hold one block back so we know whether the buffer is the last one.
                while blockQueue.count > 1 {
                    let next = blockQueue.removeFirst()
                    if pending.isEmpty { pendingStart = next.startSeconds }
                    pending.append(contentsOf: next.samples)
                    try await process(final: false)
                }
            }
            for block in blockQueue {
                if pending.isEmpty { pendingStart = block.startSeconds }
                pending.append(contentsOf: block.samples)
            }
            try Task.checkCancellation()
            while !pending.isEmpty { try await process(final: true) }
        }

        /// Chooses where to cut the carry buffer: the middle of the last silent gap in its second half, else the end.
        private func cutIndex(in pending: [Float], start: TimeInterval) async -> Int {
            guard let vad else { return pending.count }
            let chunk = AudioChunk(samples: pending, startSeconds: start, source: .file)
            guard let ranges = try? await vad.speechRanges(in: chunk), !ranges.isEmpty else { return pending.count }
            let duration = Double(pending.count) / Self.rate
            var best: TimeInterval?
            for (current, next) in zip(ranges, ranges.dropFirst()) {
                let midpoint = (current.end + next.start) / 2
                if midpoint >= duration / 2, next.start - current.end >= 0.2 { best = midpoint }
            }
            if best == nil, let last = ranges.last, last.end < duration - 0.3, last.end >= duration / 2 {
                best = (last.end + duration) / 2  // trailing silence
            }
            guard let best else { return pending.count }
            return min(pending.count, max(1, Int(best * Self.rate)))
        }

        private func hasSpeech(_ chunk: AudioChunk) async throws -> Bool {
            guard configuration.skipSilentChunks, let vad else { return true }
            do { return !(try await vad.speechRanges(in: chunk)).isEmpty } catch { return true }
        }

        // MARK: Per-chunk transcription

        struct UnitResult {
            var segments: [Segment]
            var resolvedMode: LanguageMode?
        }

        private func transcribe(
            _ chunk: AudioChunk, options: TranscriptionOptions,
            continuation: AsyncThrowingStream<FileTranscriptionEvent, any Error>.Continuation
        ) async throws -> UnitResult {
            switch options.languageMode {
            case .single(let language):
                let segments = try await run(chunk, options: options, language: language, continuation: continuation).segments
                return UnitResult(segments: segments, resolvedMode: nil)
            case .autoDetect:
                return try await autoDetect(chunk, options: options, continuation: continuation)
            case .multilingual(let set):
                if set.count == 1, let only = set.first {
                    var local = options
                    local.languageMode = .single(only)
                    let segments = try await run(chunk, options: local, language: only, continuation: continuation).segments
                    return UnitResult(segments: segments, resolvedMode: nil)
                }
                return UnitResult(
                    segments: try await multilingual(chunk, options: options, set: set, continuation: continuation), resolvedMode: nil)
            }
        }

        private func autoDetect(
            _ chunk: AudioChunk, options: TranscriptionOptions,
            continuation: AsyncThrowingStream<FileTranscriptionEvent, any Error>.Continuation
        ) async throws -> UnitResult {
            var local = options
            var resolved: LanguageMode?
            var resolvedLanguage: LanguageCode?
            if let identifier {
                let binding = try await engines(nil)
                let candidates = await binding.engine.supportedLanguages(model: binding.model ?? options.modelID)
                let head = AudioChunk(
                    samples: Array(chunk.samples.prefix(Int(30 * Self.rate))), startSeconds: chunk.startSeconds, source: .file)
                let scores = try await identifier.identify(chunk: head, candidates: candidates)
                if let top = scores.max(by: { $0.probability < $1.probability }) {
                    continuation.yield(.languageDetected(scores))
                    local.languageMode = .single(top.language)
                    resolved = .single(top.language)
                    resolvedLanguage = top.language
                }
            }
            let result = try await run(chunk, options: local, language: resolvedLanguage, continuation: continuation)
            if resolved == nil, let detected = result.detected?.max(by: { $0.probability < $1.probability }) {
                resolved = .single(detected.language)
            }
            return UnitResult(segments: result.segments, resolvedMode: resolved)
        }

        private func multilingual(
            _ chunk: AudioChunk, options: TranscriptionOptions, set: Set<LanguageCode>,
            continuation: AsyncThrowingStream<FileTranscriptionEvent, any Error>.Continuation
        ) async throws -> [Segment] {
            let ranges = await speechRanges(of: chunk)
            var previous: LanguageCode?
            var segments: [Segment] = []
            for range in ranges {
                try Task.checkCancellation()
                let sub = slice(chunk, range: range)
                var language = previous
                var confidence: Double?
                if let identifier, range.duration >= configuration.minLanguageIDSeconds {
                    let scores = try await identifier.identify(chunk: sub, candidates: set)
                    if let top = scores.max(by: { $0.probability < $1.probability }) {
                        confidence = top.probability
                        if top.probability >= configuration.languageConfidenceThreshold || previous == nil { language = top.language }
                    }
                }
                let chosen = language ?? set.sorted().first
                guard let chosen else { continue }
                previous = chosen
                var local = options
                local.languageMode = .single(chosen)
                let produced = try await run(sub, options: local, language: chosen, continuation: continuation).segments
                for var segment in produced {
                    segment.languageCode = chosen
                    segment.languageConfidence = confidence
                    segments.append(segment)
                }
            }
            return segments
        }

        private func speechRanges(of chunk: AudioChunk) async -> [TimeRange] {
            let duration = chunk.duration
            let whole = [TimeRange(start: 0, end: duration)]
            guard let vad, let raw = try? await vad.speechRanges(in: chunk), !raw.isEmpty else { return whole }
            var merged: [TimeRange] = []
            for range in raw.sorted(by: { $0.start < $1.start }) {
                if var last = merged.last, range.start - last.end <= configuration.mergeGapSeconds {
                    last.end = max(last.end, range.end)
                    merged[merged.count - 1] = last
                } else {
                    merged.append(range)
                }
            }
            let pad = configuration.rangePaddingSeconds
            return merged.map { TimeRange(start: max(0, $0.start - pad), end: min(duration, $0.end + pad)) }
        }

        private func slice(_ chunk: AudioChunk, range: TimeRange) -> AudioChunk {
            let lower = min(chunk.samples.count, max(0, Int(range.start * Self.rate)))
            let upper = min(chunk.samples.count, max(lower, Int(range.end * Self.rate)))
            return AudioChunk(
                samples: Array(chunk.samples[lower..<upper]), startSeconds: chunk.startSeconds + Double(lower) / Self.rate,
                source: chunk.source)
        }

        struct EngineRun {
            var segments: [Segment]
            var detected: [LanguageScore]?
        }

        /// Sends one chunk to the engine for `language` and gathers its final segments.
        private func run(
            _ chunk: AudioChunk, options: TranscriptionOptions, language: LanguageCode?,
            continuation: AsyncThrowingStream<FileTranscriptionEvent, any Error>.Continuation
        ) async throws -> EngineRun {
            let binding = try await engines(language)
            var local = options
            if let model = binding.model { local.modelID = model }
            let engineID = binding.engine.id
            let input = AsyncStream<AudioChunk> { stream in
                stream.yield(chunk)
                stream.finish()
            }
            var segments: [Segment] = []
            var detected: [LanguageScore]?
            do {
                for try await event in binding.engine.stream(audio: input, options: local) {
                    try Task.checkCancellation()
                    switch event {
                    case .final(let segment): segments.append(segment)
                    case .languageDetected(let scores):
                        detected = scores
                        if language == nil { continuation.yield(.languageDetected(scores)) }
                    case .partial, .progress: break
                    }
                }
            } catch {
                throw AppError.mapping(error, engine: engineID)
            }
            return EngineRun(segments: segments, detected: detected)
        }
    }
}

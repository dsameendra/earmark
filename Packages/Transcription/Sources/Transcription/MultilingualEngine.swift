import AppCore
import AudioCapture
import Foundation

/// The per-utterance language decision shared by live multilingual routing (LANG-AC-05, LANG-AC-06).
public enum LanguageDecision {
    /// Outcome of one decision.
    public struct Outcome: Sendable, Equatable {
        public var language: LanguageCode
        /// Identification probability (restricted to the candidate set); `nil` when no identification ran.
        public var confidence: Double?
        /// `true` when the identification was missing or below the threshold and the previous language was reused.
        public var isUncertain: Bool
    }

    /// Picks the language of one speech range.
    ///
    /// - A one-language set needs no identification.
    /// - Otherwise the best-scoring candidate wins when its probability is at least `threshold` (or there is no previous
    ///   language yet); below it the previous language is kept and the result is flagged uncertain (LANG-AC-06).
    /// - Ranges shorter than `minimumSeconds` skip identification (LID is unreliable below ~1 s) and inherit the previous
    ///   language, also flagged uncertain.
    public static func choose(
        scores: [LanguageScore]?, duration: TimeInterval, set: Set<LanguageCode>, previous: LanguageCode?,
        threshold: Double = 0.5, minimumSeconds: TimeInterval = 1
    ) -> Outcome? {
        if set.count == 1, let only = set.first { return Outcome(language: only, confidence: 1, isUncertain: false) }
        let previous = previous.flatMap { set.contains($0) ? $0 : nil }
        guard duration >= minimumSeconds, let top = scores?.max(by: { $0.probability < $1.probability }), set.contains(top.language)
        else {
            guard let fallback = previous ?? set.sorted().first else { return nil }
            return Outcome(language: fallback, confidence: nil, isUncertain: true)
        }
        if top.probability >= threshold || previous == nil {
            return Outcome(language: top.language, confidence: top.probability, isUncertain: top.probability < threshold)
        }
        return Outcome(language: previous ?? top.language, confidence: top.probability, isUncertain: true)
    }
}

/// Code-switching engine: segments audio by voice activity, identifies the language of every speech range within the user's
/// candidate set, routes each range to the engine assigned to that language, and merges the results in time order with
/// language tags (LANG-AC-05).
///
/// - Files go through ``FileTranscriptionPipeline`` (bounded memory, checkpoints). Live audio is cut into utterances with
///   the energy segmenter used by the Whisper stream; each utterance is identified and decoded as a unit, so live output is
///   `.final` per utterance (no partials) with a latency of the utterance length plus decode time.
/// - The candidate set can change while a session runs (``setLanguages(_:)``, LANG-AC-15): the new set applies to the
///   next utterance without restarting capture.
/// - Engines are resolved per language through the ``EngineResolver`` (typically ``EngineBinding/resolver(plan:engines:)``
///   from ``DefaultEngineRouter``), so Sinhala goes to the Qwen3-ASR engine and never to Apple/stock Whisper.
/// - Segments carry `languageCode` and `languageConfidence`; ranges that fell back to the previous language have a nil or
///   low confidence (the editor shows them as uncertain; there is no dedicated flag in `Segment`, see the T25 report).
public actor MultilingualEngine: TranscriptionEngine {
    public nonisolated let id: EngineID = "multilingual"

    private let resolver: EngineResolver
    private let identifier: (any LanguageIdentifier)?
    private let configuration: FileTranscriptionPipeline.Configuration
    private var languages: Set<LanguageCode>

    /// Creates the engine.
    /// - Parameters:
    ///   - languages: Initial candidate set.
    ///   - resolver: Engine/model per language.
    ///   - identifier: Language identifier (typically ``WhisperLanguageIdentifier``); without one, ranges fall back to the
    ///     first language of the set.
    ///   - configuration: Thresholds shared with the file pipeline.
    public init(
        languages: Set<LanguageCode>, resolver: @escaping EngineResolver, identifier: (any LanguageIdentifier)?,
        configuration: FileTranscriptionPipeline.Configuration = .init()
    ) {
        self.languages = languages
        self.resolver = resolver
        self.identifier = identifier
        self.configuration = configuration
    }

    /// Replaces the candidate set; applies to the next utterance (LANG-AC-15).
    public func setLanguages(_ set: Set<LanguageCode>) { languages = set }

    /// The current candidate set.
    public func currentLanguages() -> Set<LanguageCode> { languages }

    // MARK: - TranscriptionEngine

    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { languages }

    public func prepare(model: ModelID) async throws {}

    public func unload() async {}

    public nonisolated func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        let resolver = resolver
        let pipeline = FileTranscriptionPipeline(identifier: identifier, configuration: configuration)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var local = options
                    local.languageMode = await self.effectiveMode(options.languageMode)
                    for try await event in pipeline.run(file: file, options: local, engines: resolver) {
                        switch event {
                        case .languageDetected(let scores): continuation.yield(.languageDetected(scores))
                        case .chunkCompleted(let segments, _): for segment in segments { continuation.yield(.final(segment)) }
                        case .progress(let fraction, let mediaTime): continuation.yield(.progress(fraction: fraction, mediaTime: mediaTime))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AppError.mapping(error, engine: "multilingual"))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public nonisolated func stream(
        audio: AsyncStream<AudioChunk>, options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        .engineTask(engine: id) { continuation in
            try await self.runStream(audio: audio, options: options, continuation: continuation)
        }
    }

    /// `.multilingual` sets win over the stored set; `.single` is honoured as-is; `.autoDetect` uses the stored set.
    private func effectiveMode(_ requested: LanguageMode) -> LanguageMode {
        switch requested {
        case .single: return requested
        case .multilingual(let set) where !set.isEmpty:
            languages = set
            return requested
        default: return .multilingual(languages)
        }
    }

    // MARK: - Live

    private func runStream(
        audio: AsyncStream<AudioChunk>, options: TranscriptionOptions,
        continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        if case .multilingual(let set) = options.languageMode, !set.isEmpty { languages = set }
        if case .single(let only) = options.languageMode { languages = [only] }
        var config = StreamSegmenter.Config()
        config.maxUtterance = 12
        var state = LiveState(segmenter: StreamSegmenter(config: config))
        for await chunk in audio {
            try Task.checkCancellation()
            state.segmenter.append(chunk)
            while let end = state.segmenter.finalizationPoint() {
                try await finalize(through: end, state: &state, options: options, continuation: continuation)
            }
        }
        // Flush the last open utterance.
        if state.segmenter.hasSpeech {
            try await finalize(through: state.segmenter.buffer.count, state: &state, options: options, continuation: continuation)
        }
    }

    private struct LiveState {
        var segmenter: StreamSegmenter
        var previous: LanguageCode?
    }

    private func finalize(
        through end: Int, state: inout LiveState, options: TranscriptionOptions,
        continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        if state.segmenter.hasSpeech, state.segmenter.speechSeconds >= state.segmenter.config.minSpeech {
            let samples = Array(state.segmenter.samples(upTo: end))
            let start = state.segmenter.time(at: state.segmenter.utteranceStart)
            let chunk = AudioChunk(samples: samples, startSeconds: start, source: .mixed)
            for segment in try await decode(chunk, options: options, previous: &state.previous) { continuation.yield(.final(segment)) }
        }
        state.segmenter.consume(upTo: end)
    }

    /// Identifies and decodes one utterance with the engine of the chosen language.
    func decode(_ chunk: AudioChunk, options: TranscriptionOptions, previous: inout LanguageCode?) async throws -> [Segment] {
        let set = languages
        var scores: [LanguageScore]?
        if set.count > 1, let identifier, chunk.duration >= configuration.minLanguageIDSeconds {
            scores = try await identifier.identify(chunk: chunk, candidates: set)
        }
        guard
            let outcome = LanguageDecision.choose(
                scores: scores, duration: chunk.duration, set: set, previous: previous,
                threshold: configuration.languageConfidenceThreshold, minimumSeconds: configuration.minLanguageIDSeconds)
        else { return [] }
        previous = outcome.language
        let binding = try await resolver(outcome.language)
        var local = options
        local.languageMode = .single(outcome.language)
        if let model = binding.model { local.modelID = model }
        let input = AsyncStream<AudioChunk> { stream in
            stream.yield(chunk)
            stream.finish()
        }
        var segments: [Segment] = []
        for try await event in binding.engine.stream(audio: input, options: local) {
            try Task.checkCancellation()
            if case .final(var segment) = event {
                segment.languageCode = outcome.language
                segment.languageConfidence = outcome.confidence
                segments.append(segment)
            }
        }
        return segments
    }
}

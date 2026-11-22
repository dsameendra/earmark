import AppCore
import AudioCapture
import Foundation

/// Well-known identifiers; they match `RoutingTargets` in the Transcription package and `BuiltInCatalog` in Models (kept as
/// literals because this package must not depend on either, see `Package.swift`).
public enum QwenSinhalaTargets {
    public static let engine: EngineID = "qwen3-asr"
    public static let model: ModelID = "mlx/qwen3-asr-0.6b-sinhala-8bit"
}

/// Sinhala ASR engine: Qwen3-ASR-0.6B Sinhala (8-bit) on MLX via mlx-audio-swift (experimental, CC BY-SA 4.0 weights).
///
/// - Models are loaded from the folder `ModelManaging.location(of:)` reports; the engine never downloads (the user starts the
///   download in Settings, LANG-AC-10).
/// - Input is cut into utterances with a VAD; each utterance is one bounded model call (token cap `64 + 30 s`, repetition-loop
///   guard, wrong-script rejection), emitted as a `.final` ``Segment`` tagged `si`. The model returns no word timings, so
///   `Segment.words` is empty.
/// - `transcribe(file:)` streams the file in bounded memory; `stream(audio:)` emits `.final` per finished utterance and
///   throttled `.partial`s of the open one while decoding keeps up with real time.
/// - Only Sinhala is accepted: `.single(other)` throws ``AppError/unsupportedLanguage(_:)`` (route other languages to
///   WhisperKit/Apple through `EngineRouter`); `.autoDetect` and `.multilingual` are treated as Sinhala because the
///   multilingual pipeline already restricts each call to one language.
/// - Cancelling the consumer stops generation at the next token. Failures are mapped to ``AppError``.
public actor QwenSinhalaEngine: TranscriptionEngine {
    public typealias ModelLocator = @Sendable (ModelID) async throws -> URL

    public nonisolated let id: EngineID = QwenSinhalaTargets.engine

    private let locate: ModelLocator
    private let defaultModel: ModelID
    private let vad: any VoiceActivityDetector
    private let loader: @Sendable (URL) async throws -> any SinhalaRecognizing
    private var loaded: (model: ModelID, recognizer: any SinhalaRecognizing)?
    private var loading: (model: ModelID, task: Task<any SinhalaRecognizing, any Error>)?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Seconds of new audio between partial decodes while streaming.
    static let partialStepSeconds: TimeInterval = 2.0
    /// Partials are skipped while decoding lags the audio by more than this.
    static let maxPartialLagSeconds: TimeInterval = 1.5

    /// Creates an engine that locates the model through a closure.
    public init(
        locate: @escaping ModelLocator, defaultModel: ModelID = QwenSinhalaTargets.model,
        vad: any VoiceActivityDetector = EnergyVoiceActivityDetector()
    ) {
        self.init(locate: locate, defaultModel: defaultModel, vad: vad, loader: { try await MLXQwenRecognizer.load(folder: $0) })
    }

    /// Creates an engine that loads models installed by `models`.
    public init(models: any ModelManaging, vad: any VoiceActivityDetector = EnergyVoiceActivityDetector()) {
        self.init(locate: { try await models.location(of: $0) }, vad: vad)
    }

    init(
        locate: @escaping ModelLocator, defaultModel: ModelID = QwenSinhalaTargets.model,
        vad: any VoiceActivityDetector, loader: @escaping @Sendable (URL) async throws -> any SinhalaRecognizing
    ) {
        self.locate = locate
        self.defaultModel = defaultModel
        self.vad = vad
        self.loader = loader
    }

    // MARK: - TranscriptionEngine

    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { [.sinhala] }

    public func prepare(model: ModelID) async throws { _ = try await recognizer(for: model) }

    public func unload() async {
        loading?.task.cancel()
        loading = nil
        loaded = nil
    }

    public nonisolated func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        stream(engine: id) { continuation in try await self.runFile(file, options: options, continuation: continuation) }
    }

    public nonisolated func stream(
        audio: AsyncStream<AudioChunk>, options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        stream(engine: id) { continuation in try await self.runStream(audio, options: options, continuation: continuation) }
    }

    private nonisolated func stream(
        engine: EngineID, _ body: @escaping @Sendable (AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation) async throws -> Void
    ) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await body(continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: QwenSinhalaEngine.map(error, engine: engine))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Loading

    private func recognizer(for model: ModelID) async throws -> any SinhalaRecognizing {
        if let loaded, loaded.model == model { return loaded.recognizer }
        if let loading, loading.model == model { return try await loading.task.value }
        loading?.task.cancel()
        loaded = nil
        let locate = locate
        let loader = loader
        let task = Task<any SinhalaRecognizing, any Error> {
            let folder = try await locate(model)
            guard FileManager.default.fileExists(atPath: folder.path) else { throw AppError.modelNotInstalled(model) }
            return try await loader(folder)
        }
        loading = (model, task)
        do {
            let recognizer = try await task.value
            if loading?.model == model { loading = nil }
            loaded = (model, recognizer)
            return recognizer
        } catch {
            if loading?.model == model { loading = nil }
            throw error
        }
    }

    // MARK: - Serialisation (one model call at a time)

    private func acquire() async {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    // MARK: - Recognition

    /// Recognises one utterance. Returns `nil` text for empty/rejected output.
    private func recognize(_ utterance: Utterance, model: ModelID) async throws -> RecognizedText? {
        let recognizer = try await recognizer(for: model)
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await Self.collect(recognizer.recognize(
            samples: utterance.samples, maxTokens: SinhalaOutputGuard.maxTokens(forSeconds: utterance.duration)))
    }

    /// Consumes a recognizer stream, stopping early when the text degenerates into a repetition loop.
    static func collect(_ pieces: AsyncThrowingStream<RecognitionPiece, any Error>) async throws -> RecognizedText? {
        var streamed = ""
        var final: String?
        var tokenCount = 0
        loop: for try await piece in pieces {
            try Task.checkCancellation()
            switch piece {
            case .text(let text):
                streamed += text
                tokenCount += 1
                if tokenCount % 16 == 0, SinhalaOutputGuard.truncateRepetition(streamed).truncated { break loop }
            case .final(let text):
                final = text
            }
        }
        let raw = SinhalaOutputGuard.normalise(final ?? streamed)
        let cleaned = SinhalaOutputGuard.truncateRepetition(raw)
        let text = SinhalaOutputGuard.normalise(cleaned.text)
        guard !text.isEmpty, !SinhalaOutputGuard.isWrongScript(text) else { return nil }
        return RecognizedText(text: text, hitLoopGuard: cleaned.truncated || final == nil)
    }

    struct RecognizedText: Sendable, Equatable {
        var text: String
        /// The output was cut by the repetition guard (or generation was stopped early): lower trust.
        var hitLoopGuard: Bool
    }

    private func segment(for utterance: Utterance, text: RecognizedText) -> Segment {
        Segment(
            start: utterance.start, end: utterance.end, text: text.text, languageCode: .sinhala,
            languageConfidence: 1, confidence: text.hitLoopGuard ? 0.3 : nil, words: [])
    }

    private func checkLanguage(_ options: TranscriptionOptions) throws {
        if case .single(let language) = options.languageMode, language.primary != .sinhala {
            throw AppError.unsupportedLanguage(language)
        }
    }

    // MARK: - File

    private func runFile(
        _ file: URL, options: TranscriptionOptions, continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        try checkLanguage(options)
        let model = options.modelID ?? defaultModel
        _ = try await recognizer(for: model)
        let decoder = AVFileDecoder()
        let total = try? await decoder.duration(of: file)
        var segmenter = UtteranceSegmenter(vad: vad)
        func progress(_ time: TimeInterval) {
            let fraction = (total ?? 0) > 0 ? min(1, max(0, time / (total ?? 1))) : 0
            continuation.yield(.progress(fraction: fraction, mediaTime: time))
        }
        func emit(_ utterances: [Utterance]) async throws {
            for utterance in utterances {
                try Task.checkCancellation()
                if let text = try await recognize(utterance, model: model) {
                    continuation.yield(.final(segment(for: utterance, text: text)))
                }
            }
        }
        for try await block in decoder.decode(file: file, chunkSeconds: 30, startingAt: 0) {
            try Task.checkCancellation()
            segmenter.append(block)
            try await emit(await segmenter.drain(final: false))
            progress(segmenter.bufferEnd)
        }
        try await emit(await segmenter.drain(final: true))
        progress(total ?? segmenter.bufferEnd)
    }

    // MARK: - Live

    private func runStream(
        _ audio: AsyncStream<AudioChunk>, options: TranscriptionOptions,
        continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        try checkLanguage(options)
        let model = options.modelID ?? defaultModel
        _ = try await recognizer(for: model)
        var segmenter = UtteranceSegmenter(vad: vad)
        let clock = ContinuousClock()
        let origin = clock.now
        var firstMedia: TimeInterval?
        var lastDrain = 0.0
        var lastPartialAt = 0.0
        var lastPartialCost = 0.0
        for await chunk in audio {
            try Task.checkCancellation()
            if firstMedia == nil { firstMedia = chunk.startSeconds }
            segmenter.append(chunk)
            let mediaElapsed = segmenter.bufferEnd - (firstMedia ?? 0)
            // Run the VAD at most every 0.25 s of audio.
            guard mediaElapsed - lastDrain >= 0.25 else { continue }
            lastDrain = mediaElapsed
            for utterance in await segmenter.drain(final: false) {
                if let text = try await recognize(utterance, model: model) {
                    continuation.yield(.final(segment(for: utterance, text: text)))
                }
            }
            let lag = (clock.now - origin).secondsValue - mediaElapsed
            let step = max(Self.partialStepSeconds, 1.5 * lastPartialCost)
            guard lag < Self.maxPartialLagSeconds, mediaElapsed - lastPartialAt >= step,
                let open = await segmenter.openUtterance(), open.duration >= 1
            else { continue }
            lastPartialAt = mediaElapsed
            let began = clock.now
            if let text = try await recognize(open, model: model), !text.hitLoopGuard {
                continuation.yield(.partial(PartialSegment(text: text.text, start: open.start, languageCode: .sinhala)))
            }
            lastPartialCost = (clock.now - began).secondsValue
        }
        for utterance in await segmenter.drain(final: true) {
            if let text = try await recognize(utterance, model: model) {
                continuation.yield(.final(segment(for: utterance, text: text)))
            }
        }
    }

    // MARK: - Errors

    static func map(_ error: any Error, engine: EngineID) -> AppError {
        if let app = error as? AppError { return app }
        if error is CancellationError { return .cancelled }
        let description = (error as? any LocalizedError)?.errorDescription ?? String(describing: error)
        let lowered = description.lowercased()
        if lowered.contains("out of memory") || lowered.contains("insufficient memory") { return .outOfMemory }
        return .engineFailure(engine, reason: description)
    }
}

extension Duration {
    fileprivate var secondsValue: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

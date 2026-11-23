import AppCore
import AudioCapture
import Foundation

/// Well-known identifiers; they match `RoutingTargets` in the Transcription package and `BuiltInCatalog` in Models (kept as
/// literals because this package must not depend on either, see `Package.swift`).
public enum QwenSinhalaTargets {
    public static let engine: EngineID = "qwen3-asr"
    public static let model: ModelID = "mlx/qwen3-asr-0.6b-sinhala-8bit"
}

/// Native Qwen3-ASR engine with explicit checkpoint profiles. The existing public type name is retained for compatibility.
/// The Sinhala specialist keeps its measured unforced-language prompt and script guard. General checkpoints accept their
/// own language set and preserve detected language headers without applying Sinhala-only filtering. Models load only from
/// installed folders. File and buffered Live recognition share bounded VAD utterances and serial native generation; no word
/// timestamps are invented. Cancellation takes effect between bounded model calls.
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

    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> { QwenModelProfile.profile(for: model ?? defaultModel)?.languages ?? [] }

    public func prepare(model: ModelID) async throws {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        _ = try await recognizer(for: model)
    }

    public func unload() async {
        await acquire()
        defer { release() }
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
        guard QwenModelProfile.profile(for: model) != nil else { throw AppError.modelNotInstalled(model) }
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
    ///
    /// The gate is held until the recognizer has completely finished (it only returns once the model is idle), so a cancelled
    /// or looping utterance can never overlap the next one on the shared model.
    private func recognize(_ utterance: Utterance, model: ModelID, requestedLanguage: LanguageCode?) async throws -> RecognizedText? {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        let recognizer = try await recognizer(for: model)
        let profile = QwenModelProfile.profile(for: model)!
        let forced = profile.isSinhala ? nil : requestedLanguage.flatMap { QwenModelProfile.languageNames[$0.primary] }
        let output = try await recognizer.recognize(
            samples: utterance.samples, maxTokens: SinhalaOutputGuard.maxTokens(forSeconds: utterance.duration), language: forced)
        try Task.checkCancellation()
        if profile.isSinhala { return Self.clean(output.text) }
        let cleaned = SinhalaOutputGuard.truncateRepetition(SinhalaOutputGuard.normalise(output.text))
        guard !cleaned.text.isEmpty else { return nil }
        let detected = output.language.flatMap { name in
            QwenModelProfile.languageNames.first { $0.value.caseInsensitiveCompare(name) == .orderedSame }?.key
        }
        return RecognizedText(text: cleaned.text, hitLoopGuard: cleaned.truncated, language: detected ?? requestedLanguage)
    }

    /// Normalises a raw transcript, cuts repetition loops and rejects empty or wrong-script output.
    static func clean(_ rawText: String) -> RecognizedText? {
        let raw = SinhalaOutputGuard.normalise(rawText)
        let cleaned = SinhalaOutputGuard.truncateRepetition(raw)
        let text = SinhalaOutputGuard.normalise(cleaned.text)
        guard !text.isEmpty, !SinhalaOutputGuard.isWrongScript(text) else { return nil }
        return RecognizedText(text: text, hitLoopGuard: cleaned.truncated, language: .sinhala)
    }

    struct RecognizedText: Sendable, Equatable {
        var text: String
        /// The output was cut by the repetition guard (or generation was stopped early): lower trust.
        var hitLoopGuard: Bool
        var language: LanguageCode? = nil
    }

    private func segment(for utterance: Utterance, text: RecognizedText) -> Segment {
        Segment(
            start: utterance.start, end: utterance.end, text: text.text, languageCode: text.language ?? "und",
            languageConfidence: text.language == .sinhala ? 1 : nil, confidence: text.hitLoopGuard ? 0.3 : nil, words: [])
    }

    private func requestedLanguage(_ options: TranscriptionOptions) throws -> LanguageCode? {
        let model = options.modelID ?? defaultModel
        guard let profile = QwenModelProfile.profile(for: model) else { throw AppError.modelNotInstalled(model) }
        switch options.languageMode {
        case .single(let language):
            guard profile.languages.contains(language.primary) else { throw AppError.unsupportedLanguage(language) }
            return profile.isSinhala ? .sinhala : language.primary
        case .autoDetect, .multilingual:
            return profile.isSinhala ? .sinhala : nil
        }
    }

    // MARK: - File

    private func runFile(
        _ file: URL, options: TranscriptionOptions, continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        let language = try requestedLanguage(options)
        let model = options.modelID ?? defaultModel
        try await prepare(model: model)
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
                if let text = try await recognize(utterance, model: model, requestedLanguage: language) {
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
        let language = try requestedLanguage(options)
        let model = options.modelID ?? defaultModel
        try await prepare(model: model)
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
                if let text = try await recognize(utterance, model: model, requestedLanguage: language) {
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
            if let text = try await recognize(open, model: model, requestedLanguage: language), !text.hitLoopGuard {
                continuation.yield(.partial(PartialSegment(text: text.text, start: open.start, languageCode: text.language ?? language ?? "und")))
            }
            lastPartialCost = (clock.now - began).secondsValue
        }
        for utterance in await segmenter.drain(final: true) {
            if let text = try await recognize(utterance, model: model, requestedLanguage: language) {
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

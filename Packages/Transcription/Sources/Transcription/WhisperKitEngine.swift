import AppCore
import Foundation
import Models
import WhisperKit

/// Owns the non-`Sendable` WhisperKit pipeline. All access is serialised by ``WhisperKitEngine``'s gate.
final class WhisperHandle: @unchecked Sendable {
    let kit: WhisperKit
    let model: ModelID
    init(kit: WhisperKit, model: ModelID) {
        self.kit = kit
        self.model = model
    }
}

/// One decoded window of audio, with times already shifted to the media timeline.
struct DecodedWindow: Sendable {
    var segments: [Segment]
    var language: String?
}

/// ASR engine backed by WhisperKit (CoreML Whisper).
///
/// - Models are loaded from the folder the ``ModelManaging`` actor reports (`location(of:)`); the engine never downloads.
///   Custom imported WhisperKit folders therefore work like built-in ones.
/// - File transcription runs through ``FileTranscriptionPipeline`` (bounded memory, VAD-aligned chunks). Streaming
///   re-decodes the unconfirmed tail of the buffer about once per second of new audio, emitting `.partial` for the tail
///   and `.final` for segments that have settled.
/// - Word timestamps, `skipSpecialTokens`, single/auto-detect/multilingual language handling and a vocabulary prompt
///   (`TranscriptionOptions.vocabulary`, encoded to Whisper prompt tokens) are supported.
/// - Cancelling the consuming task stops decoding at the next Core ML prediction.
/// - Every failure is mapped to ``AppError``; nothing in here traps.
///
/// WhisperKit resolves the Whisper tokenizer from `tokenizerFolder` (or downloads it from the Hugging Face hub when that is
/// `nil`), so production callers should supply a folder the Models package provisioned.
public actor WhisperKitEngine: TranscriptionEngine {
    /// Resolves a model id to its on-disk CoreML folder.
    public typealias ModelLocator = @Sendable (ModelID) async throws -> URL

    public nonisolated let id: EngineID = RoutingTargets.whisperKitEngine

    private let locate: ModelLocator
    private let tokenizerFolder: URL?
    private let catalog: [ModelDescriptor]
    private let defaultModel: ModelID
    private let gate = AsyncGate()
    private var handle: WhisperHandle?
    private var loading: (model: ModelID, task: Task<WhisperHandle, any Error>)?

    /// Seconds of new audio that trigger a re-decode while streaming.
    static let streamStepSeconds: TimeInterval = 1.0
    /// Buffered audio beyond which settled segments are confirmed and trimmed.
    static let streamMaxBufferSeconds: TimeInterval = 24.0

    /// Creates an engine that locates models through a closure (handy for tests and previews).
    public init(
        locate: @escaping ModelLocator, tokenizerFolder: URL? = nil, catalog: [ModelDescriptor] = BuiltInCatalog.models,
        defaultModel: ModelID = RoutingTargets.whisperLarge
    ) {
        self.locate = locate
        self.tokenizerFolder = tokenizerFolder
        self.catalog = catalog
        self.defaultModel = defaultModel
    }

    /// Creates an engine that loads models installed by `models`.
    public init(models: any ModelManaging, tokenizerFolder: URL? = nil, catalog: [ModelDescriptor] = BuiltInCatalog.models) {
        self.init(locate: { try await models.location(of: $0) }, tokenizerFolder: tokenizerFolder, catalog: catalog)
    }

    // MARK: - TranscriptionEngine

    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> {
        let id = model ?? handle?.model ?? defaultModel
        if let descriptor = catalog.first(where: { $0.id == id }) { return descriptor.languages }
        return catalog.first(where: { $0.id == defaultModel })?.languages ?? []
    }

    /// Loads the model into memory (idempotent). Switching models unloads the previous one first so only one stays resident.
    /// - Throws: ``AppError/modelNotInstalled(_:)`` when the model has no local folder, ``AppError/engineFailure(_:reason:)``
    ///   when Core ML fails to load it.
    public func prepare(model: ModelID) async throws {
        _ = try await loadedHandle(for: model)
    }

    public func unload() async {
        loading?.task.cancel()
        loading = nil
        guard let current = handle else { return }
        handle = nil
        _ = try? await gate.run { await current.kit.unloadModels() }
    }

    public nonisolated func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        FileTranscriptionPipeline().transcriptionEvents(file: file, options: options, engine: self)
    }

    public nonisolated func stream(
        audio: AsyncStream<AppCore.AudioChunk>, options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        .engineTask(engine: id) { continuation in
            try await self.runStream(audio: audio, options: options, continuation: continuation)
        }
    }

    // MARK: - Loading

    private func loadedHandle(for model: ModelID) async throws -> WhisperHandle {
        if let handle, handle.model == model { return handle }
        if let loading, loading.model == model { return try await loading.task.value }
        loading?.task.cancel()
        if let old = handle {
            handle = nil
            _ = try? await gate.run { await old.kit.unloadModels() }
        }
        let locate = locate
        let tokenizerFolder = tokenizerFolder
        let engineID = id
        let task = Task<WhisperHandle, any Error> {
            do {
                let folder = try await locate(model)
                guard FileManager.default.fileExists(atPath: folder.path) else { throw AppError.modelNotInstalled(model) }
                let config = WhisperKitConfig(
                    modelFolder: folder.path, tokenizerFolder: tokenizerFolder, verbose: false, logLevel: .none, prewarm: false,
                    load: true, download: false)
                let kit = try await WhisperKit(config)
                return WhisperHandle(kit: kit, model: model)
            } catch {
                throw AppError.mapping(error, engine: engineID)
            }
        }
        loading = (model, task)
        do {
            let loaded = try await task.value
            if loading?.model == model { loading = nil }
            handle = loaded
            return loaded
        } catch {
            if loading?.model == model { loading = nil }
            throw AppError.mapping(error, engine: id)
        }
    }

    // MARK: - Language detection

    /// Detects the language of `samples` (first ~30 s), restricted to `candidates` when non-empty.
    ///
    /// WhisperKit reports only the winning language token's probability, and its language filter cannot be narrowed from
    /// outside the module. When the winner lies outside `candidates` the result is empty so callers can fall back to the
    /// previous language instead of mislabelling the segment.
    func detectLanguage(samples: [Float], candidates: Set<LanguageCode>, model: ModelID) async throws -> [LanguageScore] {
        let handle = try await loadedHandle(for: model)
        do {
            let detected = try await gate.run { () -> (String, [String: Float]) in
                let result = try await handle.kit.detectLangauge(audioArray: samples)
                return (result.language, result.langProbs)
            }
            let language = LanguageCode(detected.0)
            guard candidates.isEmpty || candidates.contains(language) || candidates.contains(language.primary) else { return [] }
            let raw = detected.1[detected.0] ?? 0
            // WhisperKit reports a log-probability (<= 0); tolerate an already-linear value.
            let probability = raw <= 0 ? Double(exp(raw)) : Double(raw)
            return [LanguageScore(language: language, probability: min(1, max(0, probability)))]
        } catch {
            throw AppError.mapping(error, engine: id)
        }
    }

    // MARK: - Decoding

    private func decodingOptions(_ options: TranscriptionOptions, language: LanguageCode?, handle: WhisperHandle) -> DecodingOptions {
        var decoding = DecodingOptions(
            task: .transcribe, language: language?.primary.rawValue, usePrefillPrompt: true, detectLanguage: language == nil,
            skipSpecialTokens: true, wordTimestamps: options.wordTimestamps)
        let vocabulary = options.vocabulary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !vocabulary.isEmpty, let tokenizer = handle.kit.tokenizer {
            // Whisper prompts condition the decoder on preceding text; a comma list biases spelling of names and acronyms.
            let tokens = tokenizer.encode(text: " " + vocabulary.joined(separator: ", "))
            decoding.promptTokens = Array(tokens.prefix(200))
        }
        return decoding
    }

    private func decodeWindow(
        _ samples: [Float], offset: TimeInterval, decoding: DecodingOptions, handle: WhisperHandle
    ) async throws -> DecodedWindow {
        try await gate.run {
            try Task.checkCancellation()
            let results = try await handle.kit.transcribe(audioArray: samples, decodeOptions: decoding)
            try Task.checkCancellation()
            var segments: [Segment] = []
            var language: String?
            for result in results {
                language = language ?? result.language
                for source in result.segments {
                    if let segment = Self.map(source, language: result.language, offset: offset) { segments.append(segment) }
                }
            }
            return DecodedWindow(segments: segments, language: language)
        }
    }

    /// Converts a WhisperKit segment to the shared domain type, shifting times by `offset`. Empty text yields `nil`.
    static func map(_ source: TranscriptionSegment, language: String, offset: TimeInterval) -> Segment? {
        let text = TranscriptText.clean(source.text)
        guard !text.isEmpty else { return nil }
        let words: [Word] = (source.words ?? []).compactMap { timing in
            let word = TranscriptText.clean(timing.word)
            guard !word.isEmpty else { return nil }
            return Word(
                text: word, start: offset + Double(timing.start), end: offset + Double(timing.end),
                confidence: Double(timing.probability))
        }
        let confidence = exp(Double(source.avgLogprob))
        return Segment(
            start: offset + Double(source.start), end: offset + Double(source.end), text: text,
            languageCode: LanguageCode(language), confidence: confidence.isFinite ? min(1, max(0, confidence)) : nil,
            noSpeechProbability: Double(source.noSpeechProb), words: words)
    }

    // MARK: - Streaming

    private struct StreamLanguage {
        var fixed: LanguageCode?
        var candidates: Set<LanguageCode>
        var needsDetection: Bool
        init(mode: LanguageMode) {
            switch mode {
            case .single(let language):
                fixed = language
                candidates = [language]
                needsDetection = false
            case .autoDetect:
                fixed = nil
                candidates = []
                needsDetection = true
            case .multilingual(let set):
                fixed = set.count == 1 ? set.first : nil
                candidates = set
                needsDetection = set.count > 1
            }
        }
    }

    private struct StreamState {
        var language: StreamLanguage
        var buffer: [Float] = []
        var bufferStart: TimeInterval?
        var decodedCount = 0
        var lastWindow: [Segment] = []

        var bufferSeconds: TimeInterval { Double(buffer.count) / AppCore.AudioChunk.sampleRate }
        var endTime: TimeInterval { (bufferStart ?? 0) + bufferSeconds }
    }

    private func decode(
        _ state: inout StreamState, options: TranscriptionOptions, model: ModelID, handle: WhisperHandle,
        continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        if state.language.needsDetection {
            state.language.needsDetection = false
            let scores = try? await detectLanguage(samples: state.buffer, candidates: state.language.candidates, model: model)
            if let scores, let top = scores.first {
                state.language.fixed = top.language
                continuation.yield(.languageDetected(scores))
            }
        }
        let decoding = decodingOptions(options, language: state.language.fixed, handle: handle)
        let window = try await decodeWindow(state.buffer, offset: state.bufferStart ?? 0, decoding: decoding, handle: handle)
        state.decodedCount = state.buffer.count
        state.lastWindow = window.segments
        if state.language.fixed == nil, let detected = window.language {
            state.language.fixed = LanguageCode(detected)
            continuation.yield(.languageDetected([LanguageScore(language: LanguageCode(detected), probability: 1)]))
        }
    }

    /// Emits `.final` for the first `count` segments of the last window and trims the buffer to the end of the last one.
    private func confirm(
        _ count: Int, state: inout StreamState, continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) {
        guard count > 0 else { return }
        let confirmed = Array(state.lastWindow.prefix(count))
        for segment in confirmed { continuation.yield(.final(segment)) }
        state.lastWindow.removeFirst(min(count, state.lastWindow.count))
        if let end = confirmed.last?.end, let start = state.bufferStart {
            let drop = min(state.buffer.count, max(0, Int((end - start) * AppCore.AudioChunk.sampleRate)))
            state.buffer.removeFirst(drop)
            state.bufferStart = start + Double(drop) / AppCore.AudioChunk.sampleRate
            state.decodedCount = max(0, state.decodedCount - drop)
        }
    }

    private func runStream(
        audio: AsyncStream<AppCore.AudioChunk>, options: TranscriptionOptions,
        continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        let model = options.modelID ?? handle?.model ?? defaultModel
        let handle = try await loadedHandle(for: model)
        var state = StreamState(language: StreamLanguage(mode: options.languageMode))
        let step = Int(Self.streamStepSeconds * AppCore.AudioChunk.sampleRate)

        for await chunk in audio {
            try Task.checkCancellation()
            if state.bufferStart == nil { state.bufferStart = chunk.startSeconds }
            state.buffer.append(contentsOf: chunk.samples)
            guard state.buffer.count - state.decodedCount >= step else { continue }
            try await decode(&state, options: options, model: model, handle: handle, continuation: continuation)
            if state.bufferSeconds >= Self.streamMaxBufferSeconds + 4 {
                confirm(state.lastWindow.count, state: &state, continuation: continuation)
            } else if state.bufferSeconds >= Self.streamMaxBufferSeconds, state.lastWindow.count > 1 {
                confirm(state.lastWindow.count - 1, state: &state, continuation: continuation)
            }
            if let tail = state.lastWindow.last {
                continuation.yield(.partial(PartialSegment(text: tail.text, start: tail.start, languageCode: state.language.fixed)))
            }
        }
        try Task.checkCancellation()
        let endTime = state.endTime
        if state.buffer.count - state.decodedCount >= step / 5 {
            try await decode(&state, options: options, model: model, handle: handle, continuation: continuation)
        }
        confirm(state.lastWindow.count, state: &state, continuation: continuation)
        continuation.yield(.progress(fraction: 1, mediaTime: endTime))
    }
}

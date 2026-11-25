import AppCore
import FluidAudio
import Foundation

/// File-only Cohere Transcribe adapter. The native decoder receives explicit language prompts and real bounded audio.
/// No synthetic word times or speaker attribution are reported.
public actor CohereEngine: TranscriptionEngine {
    public nonisolated let id: EngineID = "fluidaudio.cohere"
    public static let modelID: ModelID = "fluidaudio/cohere-transcribe-2b"
    public static let languages = Set(CohereAsrConfig.Language.allCases.map { LanguageCode($0.rawValue) })
    private let locate: @Sendable (ModelID) async throws -> URL
    private let gate = AsyncGate()
    private let pipeline = CoherePipeline()
    private var loaded: CoherePipeline.LoadedModels?

    public init(models: any ModelManaging) { locate = { try await models.location(of: $0) } }
    public init(locate: @escaping @Sendable (ModelID) async throws -> URL) { self.locate = locate }
    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> {
        (model == nil || model == Self.modelID) ? Self.languages : []
    }

    private func models() async throws -> CoherePipeline.LoadedModels {
        if let loaded { return loaded }
        let folder = try await locate(Self.modelID)
        // The catalog installs the int8 build under `q8/`; a flat folder of compiled models is also accepted.
        let q8 = folder.appendingPathComponent("q8")
        let compiled = FileManager.default.fileExists(atPath: q8.appendingPathComponent("cohere_encoder.mlmodelc").path) ? q8 : folder
        let models = try await CoherePipeline.loadModels(encoderDir: compiled, decoderDir: compiled, vocabDir: folder)
        loaded = models
        return models
    }

    public func prepare(model: ModelID) async throws {
        guard model == Self.modelID else { throw AppError.modelNotInstalled(model) }
        await gate.acquire()
        do { try Task.checkCancellation(); _ = try await models(); await gate.release() }
        catch { await gate.release(); throw AppError.mapping(error, engine: id) }
    }

    public func unload() async {
        await gate.acquire()
        loaded = nil
        await gate.release()
    }

    public nonisolated func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        FileTranscriptionPipeline().transcriptionEvents(file: file, options: options, engine: self)
    }

    public nonisolated func stream(
        audio: AsyncStream<AppCore.AudioChunk>, options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        .engineTask(engine: id) { continuation in try await self.run(audio: audio, options: options, output: continuation) }
    }

    private func decode(samples: [Float], start: Double, language: CohereAsrConfig.Language) async throws -> Segment? {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let models = try await models()
            let result = try await pipeline.transcribeLong(audio: samples, models: models, language: language)
            try Task.checkCancellation()
            // A capped window lost output. Surface it as an error instead of silently publishing an incomplete transcript.
            guard result.cappedWindows == 0 else { throw AppError.engineFailure(id, reason: "Cohere reached its decoding limit. Retry with shorter audio windows.") }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let segment = text.isEmpty ? nil : Segment(
                start: start, end: start + Double(samples.count) / AppCore.AudioChunk.sampleRate,
                text: text, languageCode: LanguageCode(language.rawValue), words: [])
            await gate.release()
            return segment
        } catch { await gate.release(); throw error }
    }

    private func run(
        audio: AsyncStream<AppCore.AudioChunk>, options: TranscriptionOptions,
        output: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        guard options.useCase == .file else { throw AppError.other("Cohere Transcribe is available for file transcription only.") }
        if let model = options.modelID, model != Self.modelID { throw AppError.modelNotInstalled(model) }
        guard case .single(let source) = options.languageMode, let language = CohereAsrConfig.Language(rawValue: source.primary.rawValue) else {
            throw AppError.other("Choose one of Cohere's supported languages before transcribing.")
        }
        var configuration = StreamSegmenter.Config()
        configuration.maxUtterance = 30
        configuration.softMinUtterance = 12
        var segmenter = StreamSegmenter(config: configuration)
        for await chunk in audio {
            try Task.checkCancellation()
            segmenter.append(chunk)
            while let end = segmenter.finalizationPoint() {
                if let segment = try await decode(
                    samples: Array(segmenter.samples(upTo: end)), start: segmenter.time(at: segmenter.utteranceStart), language: language
                ) { output.yield(.final(segment)) }
                segmenter.consume(upTo: end)
            }
        }
        if segmenter.hasSpeech, let segment = try await decode(
            samples: Array(segmenter.samples(upTo: segmenter.buffer.count)), start: segmenter.time(at: segmenter.utteranceStart), language: language
        ) { output.yield(.final(segment)) }
    }
}

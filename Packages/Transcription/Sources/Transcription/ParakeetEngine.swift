import AppCore
import FluidAudio
import Foundation

/// FluidAudio's offline TDT decoder, used with bounded utterances for buffered Live captions.
/// It loads installed Core ML artifacts only; native streaming is a separate engine integration.
public actor ParakeetEngine: TranscriptionEngine {
    public nonisolated let id: EngineID = "fluidaudio.parakeet"
    public static let modelV3: ModelID = "fluidaudio/parakeet-tdt-v3"
    public static let modelUltra: ModelID = "fluidaudio/parakeet-ultra"
    public static let modelRedux: ModelID = "fluidaudio/parakeet-redux"
    public static let languages: Set<LanguageCode> = [
        "en", "de", "fr", "es", "it", "pt", "nl", "pl", "ru", "uk", "cs", "sk", "sl", "hr", "bg", "ro", "hu", "el", "sv", "da", "fi",
        "et", "lv", "lt", "mt"
    ]
    private let locate: @Sendable (ModelID) async throws -> URL
    private let gate = AsyncGate()
    private var loaded: (id: ModelID, manager: AsrManager)?

    public init(models: any ModelManaging) { locate = { try await models.location(of: $0) } }
    public init(locate: @escaping @Sendable (ModelID) async throws -> URL) { self.locate = locate }

    private static func version(_ id: ModelID) throws -> AsrModelVersion {
        switch id {
        case modelV3: .v3
        case modelUltra: .ultra
        case modelRedux: .redux
        default: throw AppError.modelNotInstalled(id)
        }
    }

    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> {
        guard (try? Self.version(model ?? Self.modelV3)) != nil else { return [] }
        return Self.languages
    }

    /// Caller holds the gate across loading and every native prediction, including unload/switch.
    private func manager(for model: ModelID) async throws -> AsrManager {
        if let loaded, loaded.id == model { return loaded.manager }
        loaded = nil
        let version = try Self.version(model)
        let folder = try await locate(model)
        let models = try AsrModels.loadLocal(from: folder, version: version, encoderPrecision: .int8)
        let manager = AsrManager(models: models)
        loaded = (model, manager)
        return manager
    }

    public func prepare(model: ModelID) async throws {
        await gate.acquire()
        do { try Task.checkCancellation(); _ = try await manager(for: model); await gate.release() }
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

    private func decode(samples: [Float], start: Double, language: LanguageCode?, model: ModelID) async throws -> Segment? {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let manager = try await manager(for: model)
            var state = try TdtDecoderState()
            let result = try await manager.transcribe(samples, decoderState: &state, language: language.flatMap { Language(rawValue: $0.primary.rawValue) })
            try Task.checkCancellation()
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let duration = Double(samples.count) / AppCore.AudioChunk.sampleRate
            let words = buildWordTimings(from: result.tokenTimings ?? []).map { timing in
                Word(text: timing.word, start: start + max(0, min(duration, timing.startTime)), end: start + max(0, min(duration, timing.endTime)))
            }
            let segment = text.isEmpty ? nil : Segment(
                start: start, end: start + duration, text: text, languageCode: language ?? "und",
                confidence: Double(result.confidence), words: words)
            await gate.release()
            return segment
        } catch { await gate.release(); throw error }
    }

    private func run(
        audio: AsyncStream<AppCore.AudioChunk>, options: TranscriptionOptions,
        output: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        let language: LanguageCode?
        switch options.languageMode {
        case .single(let value):
            guard Self.languages.contains(value.primary) else { throw AppError.unsupportedLanguage(value) }
            language = value.primary
        case .autoDetect: language = nil
        case .multilingual:
            throw AppError.other("Choose one language per Parakeet recognition stream; multilingual routing resolves separate streams.")
        }
        let model = options.modelID ?? Self.modelV3
        _ = try Self.version(model)
        var segmenter = StreamSegmenter()
        for await chunk in audio {
            try Task.checkCancellation()
            segmenter.append(chunk)
            while let end = segmenter.finalizationPoint() {
                let start = segmenter.time(at: segmenter.utteranceStart)
                let samples = Array(segmenter.samples(upTo: end))
                if let segment = try await decode(samples: samples, start: start, language: language, model: model) { output.yield(.final(segment)) }
                segmenter.consume(upTo: end)
            }
        }
        if segmenter.hasSpeech {
            let start = segmenter.time(at: segmenter.utteranceStart)
            if let segment = try await decode(samples: Array(segmenter.samples(upTo: segmenter.buffer.count)), start: start, language: language, model: model) {
                output.yield(.final(segment))
            }
        }
    }
}

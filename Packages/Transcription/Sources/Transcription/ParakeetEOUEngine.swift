@preconcurrency import AVFoundation
import AppCore
import FluidAudio
import Foundation
import Synchronization

/// Parakeet realtime EOU 120M: genuinely streaming English recognition that finalizes an utterance when the model's
/// end-of-utterance head fires after sustained silence. English only; no word alignment is reported.
public actor ParakeetEOUEngine: TranscriptionEngine {
    public nonisolated let id: EngineID = "fluidaudio.parakeet-eou"
    public static let modelID: ModelID = "fluidaudio/parakeet-eou-120m"
    public static let languages: Set<LanguageCode> = ["en"]
    /// The 160 ms chunk build is the lowest-latency variant the catalog installs.
    static let variantFolder = "160ms"
    static let debounceSeconds = 1.28

    /// Notes written by manager callbacks while a chunk is processed, read by the session after that call returns.
    private final class Notes: Sendable {
        enum Note: Sendable { case partial(String), utterance(String) }
        private let items = Mutex<[Note]>([])
        func add(_ note: Note) { items.withLock { $0.append(note) } }
        func take() -> [Note] { items.withLock { let taken = $0; $0 = []; return taken } }
    }

    private let locate: @Sendable (ModelID) async throws -> URL
    private let gate = AsyncGate()
    private var manager: StreamingEouAsrManager?

    public init(models: any ModelManaging) { locate = { try await models.location(of: $0) } }
    public init(locate: @escaping @Sendable (ModelID) async throws -> URL) { self.locate = locate }

    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> {
        (model == nil || model == Self.modelID) ? Self.languages : []
    }

    private func loadedManager() async throws -> StreamingEouAsrManager {
        if let manager { return manager }
        let folder = try await locate(Self.modelID).appendingPathComponent(Self.variantFolder)
        let created = StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: Int(Self.debounceSeconds * 1000))
        try await created.loadModels(from: folder)
        manager = created
        return created
    }

    public func prepare(model: ModelID) async throws {
        guard model == Self.modelID else { throw AppError.modelNotInstalled(model) }
        await gate.acquire()
        do { try Task.checkCancellation(); _ = try await loadedManager(); await gate.release() }
        catch { await gate.release(); throw AppError.mapping(error, engine: id) }
    }

    public func unload() async {
        await gate.acquire()
        if let manager { await manager.cleanup() }
        manager = nil
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

    private static func buffer(_ samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        return buffer
    }

    /// Words of the cumulative transcript that have not been finalized yet.
    static func pending(_ full: String, consumedWords: Int) -> (text: String, wordCount: Int) {
        let words = full.split(whereSeparator: \.isWhitespace)
        return (words.dropFirst(consumedWords).joined(separator: " "), words.count)
    }

    private func run(
        audio: AsyncStream<AppCore.AudioChunk>, options: TranscriptionOptions,
        output: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        if let model = options.modelID, model != Self.modelID { throw AppError.modelNotInstalled(model) }
        switch options.languageMode {
        case .single(let language) where language.primary == "en": break
        case .single(let language): throw AppError.unsupportedLanguage(language)
        default: throw AppError.other("Parakeet EOU recognizes English only. Choose English.")
        }
        await gate.acquire()
        var manager: StreamingEouAsrManager?
        do {
            try Task.checkCancellation()
            let active = try await loadedManager()
            manager = active
            await active.reset()
            let notes = Notes()
            await active.setPartialCallback { notes.add(.partial($0)) }
            await active.setEouCallback { notes.add(.utterance($0)) }
            var consumedWords = 0
            var lastEnd = 0.0
            var fed = 0.0
            let language: LanguageCode = "en"

            func finalize(_ full: String, end: Double) -> Segment? {
                let result = Self.pending(full, consumedWords: consumedWords)
                consumedWords = result.wordCount
                guard !result.text.isEmpty else { return nil }
                let segment = Segment(start: lastEnd, end: max(lastEnd, end), text: result.text, languageCode: language, words: [])
                lastEnd = segment.end
                return segment
            }

            for await chunk in audio {
                try Task.checkCancellation()
                guard let buffer = Self.buffer(chunk.samples) else { continue }
                fed += Double(chunk.samples.count) / AppCore.AudioChunk.sampleRate
                _ = try await active.process(audioBuffer: buffer)
                var rearm = false
                for note in notes.take() {
                    switch note {
                    case .partial(let full):
                        let result = Self.pending(full, consumedWords: consumedWords)
                        if !result.text.isEmpty { output.yield(.partial(PartialSegment(text: result.text, start: lastEnd, languageCode: language))) }
                    case .utterance(let full):
                        if let segment = finalize(full, end: max(lastEnd, fed - Self.debounceSeconds)) { output.yield(.final(segment)) }
                        rearm = true
                    }
                }
                if rearm { try await active.rearm(keepTranscript: true) }
            }
            let full = try await active.finish()
            if let segment = finalize(full, end: fed) { output.yield(.final(segment)) }
            await active.reset()
            await gate.release()
        } catch {
            if let manager { await manager.reset() }
            await gate.release()
            throw error
        }
    }
}

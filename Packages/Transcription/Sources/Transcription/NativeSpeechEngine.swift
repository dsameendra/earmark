import AppCore
import Foundation
import SpeechNative

/// Recognition through the isolated native speech worker (Nemotron 3.5 streaming and Canary v2).
///
/// Files and utterances run as bounded `run` requests. Nemotron live capture uses the worker's cache-aware stream:
/// its tentative text becomes partials and its committed segments become finals. Recognition never translates.
public actor NativeSpeechEngine: TranscriptionEngine {
    public nonisolated let id: EngineID = "native.speech"
    public static let nemotronModel: ModelID = "native/nemotron-3.5-asr-q4"
    public static let canaryModel: ModelID = "native/canary-1b-v2-q4"

    struct Binding: Sendable {
        let profile: NativeSpeechProfile
        let file: String
    }

    static let bindings: [ModelID: Binding] = [
        nemotronModel: Binding(profile: .nemotron35, file: "nemotron-3.5-asr-streaming-0.6b-Q4_K_M.gguf"),
        canaryModel: Binding(profile: .canaryV2, file: "canary-1b-v2-Q4_K_M.gguf"),
    ]

    /// Base language codes each model accepts.
    public static func languages(for model: ModelID) -> Set<LanguageCode> {
        guard let profile = bindings[model]?.profile else { return [] }
        return Set(profile.languages.map { LanguageCode(String($0.split(separator: "-").first ?? "")) })
    }

    private let locate: @Sendable (ModelID) async throws -> URL
    private let helper: @Sendable () -> URL?
    private let gate = AsyncGate()
    private var client: SpeechWorkerClient?
    private var loaded: ModelID?

    public init(models: any ModelManaging, helper: @escaping @Sendable () -> URL?) {
        locate = { try await models.location(of: $0) }
        self.helper = helper
    }

    public init(locate: @escaping @Sendable (ModelID) async throws -> URL, helper: @escaping @Sendable () -> URL?) {
        self.locate = locate
        self.helper = helper
    }

    /// The signed helper inside the app bundle, if present.
    public static func bundledHelper(in bundle: Bundle = .main) -> URL? {
        let candidate = bundle.bundleURL.appendingPathComponent("Contents/Helpers/EarmarkSpeechWorker")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> {
        guard let model else { return Self.languages(for: Self.nemotronModel) }
        return Self.languages(for: model)
    }

    private func worker(for model: ModelID) async throws -> SpeechWorkerClient {
        guard let binding = Self.bindings[model] else { throw AppError.modelNotInstalled(model) }
        if let client, loaded == model { return client }
        if let client { _ = await client.stop() }
        client = nil; loaded = nil
        guard let executable = helper() else { throw AppError.engineFailure(id, reason: "The native speech helper is missing from this build.") }
        let file = try await locate(model).appendingPathComponent(binding.file)
        guard FileManager.default.isReadableFile(atPath: file.path) else { throw AppError.modelNotInstalled(model) }
        let created = SpeechWorkerClient(executable: executable)
        do { _ = try await created.start(modelFile: file, profile: binding.profile.rawValue) }
        catch { _ = await created.stop(); throw AppError.mapping(error, engine: id) }
        client = created; loaded = model
        return created
    }

    public func prepare(model: ModelID) async throws {
        await gate.acquire()
        do { try Task.checkCancellation(); _ = try await worker(for: model); await gate.release() }
        catch { await gate.release(); throw error }
    }

    public func unload() async {
        await gate.acquire()
        if let client { _ = await client.stop() }
        client = nil; loaded = nil
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

    // MARK: - Request helpers

    private static func pcm(_ samples: ArraySlice<Float>) -> Data {
        var data = Data(capacity: samples.count * 4)
        for sample in samples {
            var bits = sample.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func clamp(_ samples: [Float]) -> [Float] { samples.map { $0.isFinite ? max(-1, min(1, $0)) : 0 } }

    /// The worker language tag for a requested language, or an error that names the real constraint.
    private static func sourceLanguage(_ options: TranscriptionOptions, binding: Binding) throws -> String {
        switch options.languageMode {
        case .single(let value):
            do { return try binding.profile.resolveLanguage(value.primary.rawValue) }
            catch { throw AppError.unsupportedLanguage(value) }
        case .autoDetect:
            throw AppError.other("Choose the spoken language explicitly for this model.")
        case .multilingual:
            throw AppError.other("Choose one language per recognition stream; multilingual routing resolves separate streams.")
        }
    }

    private func decode(samples: [Float], start: Double, language: String, model: ModelID) async throws -> Segment? {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let client = try await worker(for: model)
            var request = SpeechWorkerRequest(id: 0, operation: .run, pcm: Self.pcm(Self.clamp(samples)[...]))
            request.language = language
            let reply: SpeechWorkerReply
            do { reply = try await client.send(request) } catch { throw error is CancellationError ? error : AppError.mapping(error, engine: id) }
            try Task.checkCancellation()
            let text = (reply.snapshot?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            await gate.release()
            guard !text.isEmpty else { return nil }
            let duration = Double(samples.count) / AppCore.AudioChunk.sampleRate
            let code = LanguageCode(String(language.split(separator: "-").first ?? ""))
            return Segment(start: start, end: start + duration, text: text, languageCode: code, words: [])
        } catch { await gate.release(); throw error }
    }

    private func run(
        audio: AsyncStream<AppCore.AudioChunk>, options: TranscriptionOptions,
        output: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        let model = options.modelID ?? Self.nemotronModel
        guard let binding = Self.bindings[model] else { throw AppError.modelNotInstalled(model) }
        if options.useCase != .file, !binding.profile.canStream {
            throw AppError.other("This model transcribes files only; it cannot caption live audio.")
        }
        let language = try Self.sourceLanguage(options, binding: binding)
        if options.useCase == .file || !binding.profile.canStream {
            try await runBuffered(audio: audio, language: language, model: model, output: output)
        } else {
            try await runStreaming(audio: audio, language: language, model: model, output: output)
        }
    }

    private func runBuffered(
        audio: AsyncStream<AppCore.AudioChunk>, language: String, model: ModelID,
        output: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        var configuration = StreamSegmenter.Config()
        configuration.maxUtterance = 28
        configuration.softMinUtterance = 12
        var segmenter = StreamSegmenter(config: configuration)
        for await chunk in audio {
            try Task.checkCancellation()
            segmenter.append(chunk)
            while let end = segmenter.finalizationPoint() {
                if let segment = try await decode(
                    samples: Array(segmenter.samples(upTo: end)), start: segmenter.time(at: segmenter.utteranceStart),
                    language: language, model: model) { output.yield(.final(segment)) }
                segmenter.consume(upTo: end)
            }
        }
        if segmenter.hasSpeech, let segment = try await decode(
            samples: Array(segmenter.samples(upTo: segmenter.buffer.count)), start: segmenter.time(at: segmenter.utteranceStart),
            language: language, model: model) { output.yield(.final(segment)) }
    }

    /// Cache-aware native streaming. The gate is held for the whole session, so no other request can interleave.
    private func runStreaming(
        audio: AsyncStream<AppCore.AudioChunk>, language: String, model: ModelID,
        output: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        await gate.acquire()
        var began = false
        var client: SpeechWorkerClient?
        do {
            try Task.checkCancellation()
            let active = try await worker(for: model)
            client = active
            var begin = SpeechWorkerRequest(id: 0, operation: .begin)
            begin.language = language
            do { _ = try await active.send(begin) } catch { throw error is CancellationError ? error : AppError.mapping(error, engine: id) }
            began = true
            var emitter = StreamEmitter(language: LanguageCode(String(language.split(separator: "-").first ?? "")))
            var pending: [Float] = []

            for await chunk in audio {
                try Task.checkCancellation()
                pending.append(contentsOf: Self.clamp(chunk.samples))
                while pending.count >= SpeechWire.maximumFrameSamples {
                    let frame = Array(pending.prefix(SpeechWire.maximumFrameSamples))
                    pending.removeFirst(SpeechWire.maximumFrameSamples)
                    try await feed(frame, client: active, emitter: &emitter, output: output)
                }
            }
            if !pending.isEmpty { try await feed(pending, client: active, emitter: &emitter, output: output); pending.removeAll() }
            let finished: SpeechWorkerReply
            do { finished = try await active.send(SpeechWorkerRequest(id: 0, operation: .finish)) }
            catch { throw error is CancellationError ? error : AppError.mapping(error, engine: id) }
            began = false
            if let snapshot = finished.snapshot { emitter.events(snapshot, final: true).forEach { output.yield($0) } }
            await gate.release()
        } catch {
            if began, let client { _ = try? await client.send(SpeechWorkerRequest(id: 0, operation: .reset)) }
            await gate.release()
            throw error
        }
    }

    private func feed(
        _ frame: [Float], client: SpeechWorkerClient, emitter: inout StreamEmitter,
        output: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        let request = SpeechWorkerRequest(id: 0, operation: .feed, pcm: Self.pcm(frame[...]))
        let reply: SpeechWorkerReply
        do { reply = try await client.send(request) } catch { throw error is CancellationError ? error : AppError.mapping(error, engine: id) }
        if let snapshot = reply.snapshot { emitter.events(snapshot, final: false).forEach { output.yield($0) } }
    }

    /// Turns cumulative, text-only native stream snapshots into finals and one current partial.
    ///
    /// The native stream reports an append-only committed transcript with no segment rows or word times, so the engine
    /// cuts finals at sentence-ending punctuation or after about ten seconds, and never invents word alignment.
    struct StreamEmitter {
        static let maximumPendingSeconds = 10.0
        let language: LanguageCode
        private var consumed = 0
        private var lastEnd = 0.0

        init(language: LanguageCode) { self.language = language }

        private static func endsSentence(_ text: String) -> Bool {
            guard let last = text.last else { return false }
            return ".?!。？！".contains(last)
        }

        mutating func events(_ snapshot: SpeechNativeSnapshot, final: Bool) -> [TranscriptionEvent] {
            var events: [TranscriptionEvent] = []
            let committed = snapshot.committedText
            if committed.count < consumed { consumed = 0 }
            let now = max(lastEnd, Double(max(snapshot.audioCommittedMS, 0)) / 1000)
            let pending = String(committed.dropFirst(consumed)).trimmingCharacters(in: .whitespacesAndNewlines)
            let words = pending.split(whereSeparator: \.isWhitespace).count
            let isFinal = final || (!pending.isEmpty && (Self.endsSentence(pending) || (now - lastEnd >= Self.maximumPendingSeconds && words >= 8)))
            if isFinal {
                let tail = final ? snapshot.tentativeText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
                let text = [pending, tail].filter { !$0.isEmpty }.joined(separator: " ")
                consumed = committed.count
                if !text.isEmpty {
                    let end = final ? max(now, Double(snapshot.inputReceivedMS) / 1000) : now
                    events.append(.final(Segment(start: lastEnd, end: max(lastEnd, end), text: text, languageCode: language, words: [])))
                    lastEnd = max(lastEnd, end)
                }
                return events
            }
            let shown = [pending, snapshot.tentativeText.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty }.joined(separator: " ")
            if !shown.isEmpty { events.append(.partial(PartialSegment(text: shown, start: lastEnd, languageCode: language))) }
            return events
        }
    }
}

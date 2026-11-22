@preconcurrency import AVFoundation
import AppCore
import Foundation
import Speech

/// Install state of the on-device speech assets for one language.
public enum AppleSpeechAssetStatus: Sendable, Equatable {
    /// Apple Speech does not support this language on this machine.
    case unsupported
    /// Supported, but the locale assets are not installed yet.
    case notInstalled
    /// The assets are being downloaded by the system.
    case downloading
    case installed
    /// `SpeechTranscriber.isAvailable` is false (unsupported hardware, region or OS configuration).
    case unavailable
}

/// ASR engine backed by Apple's `SpeechAnalyzer` / `SpeechTranscriber` (macOS 26+).
///
/// - Live use: `stream(audio:options:)` converts 16 kHz mono chunks to the analyzer's preferred format, emits volatile
///   results as `.partial` and finalized results as `.final` with per-word timings (`audioTimeRange`).
/// - File use: `transcribe(file:options:)` runs ``FileTranscriptionPipeline`` over this engine.
/// - `TranscriptionOptions.vocabulary` is passed as `AnalysisContext.contextualStrings[.general]`.
/// - Locale assets are system-managed. The engine never downloads: when assets are missing it throws
///   ``AppError/modelNotInstalled(_:)`` (model `apple/speech-analyzer`) and callers can use ``assetStatus(for:)`` and
///   ``installAssets(for:progress:)`` to offer the install (LANG-AC-13). Routing falls back to WhisperKit on that error.
/// - Symbols that exist only on macOS 27 (`SpeechAnalyzer.Options.ignoresResourceLimits`) are behind `#available`.
public actor AppleSpeechEngine: TranscriptionEngine {
    public nonisolated let id: EngineID = RoutingTargets.appleEngine

    private let backend: any AppleSpeechAssetBackend

    /// Creates the engine.
    /// - Parameter backend: Seam over the system assets; tests inject a fake.
    public init(backend: any AppleSpeechAssetBackend = SystemAppleSpeechBackend()) { self.backend = backend }

    // MARK: - Capability

    public func supportedLanguages(model: ModelID?) async -> Set<LanguageCode> {
        let locales = await backend.supportedLocales()
        return Set(locales.compactMap { locale in locale.language.languageCode.map { LanguageCode($0.identifier) } })
    }

    /// Whether the system speech assets for `language` are installed.
    public func assetStatus(for language: LanguageCode) async -> AppleSpeechAssetStatus {
        guard backend.isAvailable else { return .unavailable }
        guard let locale = await resolveLocale(language) else { return .unsupported }
        switch await backend.status(for: locale) {
        case .unsupported: return .unsupported
        case .downloading: return .downloading
        case .installed: return .installed
        case .supported:
            // `AssetInventory` reports `.supported` for assets that are on disk but not yet reserved by this app.
            let installed = await backend.installedLocales()
            let key = AppleSpeechLocaleResolver.key(locale)
            return installed.contains { AppleSpeechLocaleResolver.key($0) == key } ? .installed : .notInstalled
        }
    }

    /// Downloads and installs the locale assets (user-initiated; shows `progress` as 0...1).
    /// - Throws: ``AppError/unsupportedLanguage(_:)`` or ``AppError/modelDownloadFailed(_:reason:)`` whose reason explains
    ///   the cause and where to look in System Settings.
    public func installAssets(for language: LanguageCode, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        guard backend.isAvailable else {
            throw AppError.modelDownloadFailed(RoutingTargets.appleSpeech, reason: AppleSpeechMessages.unavailable(language: nil))
        }
        guard let locale = await resolveLocale(language) else {
            throw AppError.modelDownloadFailed(
                RoutingTargets.appleSpeech, reason: AppleSpeechMessages.unavailable(language: language))
        }
        do {
            try await backend.install(locale, progress: progress)
            if await assetStatus(for: language) == .notInstalled { try await backend.reserve(locale) }
        } catch {
            if error is CancellationError { throw error }
            throw AppError.modelDownloadFailed(RoutingTargets.appleSpeech, reason: AppleSpeechMessages.installFailure(error))
        }
    }

    /// Nothing to load: assets are managed per locale by the system. Verifies the framework is usable.
    public func prepare(model: ModelID) async throws {
        guard backend.isAvailable else {
            throw AppError.engineFailure(id, reason: "Speech transcription is not available on this device.")
        }
    }

    public func unload() async {}

    // MARK: - Transcription

    public nonisolated func transcribe(file: URL, options: TranscriptionOptions) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        FileTranscriptionPipeline().transcriptionEvents(file: file, options: options, engine: self)
    }

    public nonisolated func stream(
        audio: AsyncStream<AppCore.AudioChunk>, options: TranscriptionOptions
    ) -> AsyncThrowingStream<TranscriptionEvent, any Error> {
        .engineTask(engine: id) { continuation in
            try await self.runSession(audio: audio, options: options, continuation: continuation)
        }
    }

    // MARK: - Session

    func resolveLocale(_ language: LanguageCode) async -> Locale? {
        AppleSpeechLocaleResolver.resolve(
            language: language, supported: await backend.supportedLocales(), installed: await backend.installedLocales(),
            preferred: Locale.current)
    }

    private static func language(of options: TranscriptionOptions) throws -> LanguageCode {
        switch options.languageMode {
        case .single(let language): return language
        case .multilingual(let set) where set.count == 1: return set.first ?? .english
        case .autoDetect, .multilingual:
            // SpeechAnalyzer binds one locale per transcriber and cannot identify languages.
            throw AppError.unsupportedLanguage(.init("auto"))
        }
    }

    private func runSession(
        audio: AsyncStream<AppCore.AudioChunk>, options: TranscriptionOptions,
        continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) async throws {
        let engineID = RoutingTargets.appleEngine
        guard backend.isAvailable else {
            throw AppError.engineFailure(engineID, reason: "Speech transcription is not available on this device.")
        }
        let language = try Self.language(of: options)
        guard let locale = await resolveLocale(language) else { throw AppError.unsupportedLanguage(language) }
        guard await assetStatus(for: language) == .installed else { throw AppError.modelNotInstalled(RoutingTargets.appleSpeech) }
        // Installed assets must also be reserved for this app before a transcriber can use them.
        if await backend.status(for: locale) != .installed { try await backend.reserve(locale) }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedProgressiveTranscription)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw AppError.engineFailure(engineID, reason: "No compatible audio format for \(locale.identifier).")
        }
        let converter = try ChunkConverter(target: format)

        let analyzer = SpeechAnalyzer(modules: [transcriber], options: Self.analyzerOptions(for: options.useCase))
        if let context = Self.contextualContext(options.vocabulary) { try await analyzer.setContext(context) }
        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let wantWords = options.wordTimestamps
        let baseBox = BaseTime()
        let results = Task {
            // Result times are relative to the first sample fed; the first chunk's start shifts them onto the media timeline.
            for try await result in transcriber.results {
                Self.emit(
                    result, offset: baseBox.current ?? 0, language: language, words: wantWords, continuation: continuation)
            }
        }

        do {
            try await withTaskCancellationHandler {
                try await analyzer.start(inputSequence: inputs)
                var fed = false
                for await chunk in audio {
                    try Task.checkCancellation()
                    baseBox.setIfNeeded(chunk.startSeconds)
                    if let buffer = try converter.convert(chunk.samples) {
                        fed = true
                        inputContinuation.yield(AnalyzerInput(buffer: buffer))
                    }
                }
                inputContinuation.finish()
                // SpeechAnalyzer never finalizes when it received no audio; end cleanly instead of waiting forever.
                guard fed else {
                    results.cancel()
                    await analyzer.cancelAndFinishNow()
                    return
                }
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                try await results.value
            } onCancel: {
                inputContinuation.finish()
                results.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            inputContinuation.finish()
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }

    /// Contextual strings bias recognition toward custom vocabulary; `nil` when there is none.
    private static func contextualContext(_ vocabulary: [String]) -> AnalysisContext? {
        let strings = vocabulary.filter { !$0.isEmpty }
        guard !strings.isEmpty else { return nil }
        let context = AnalysisContext()
        context.contextualStrings[.general] = strings
        return context
    }

    private static func emit(
        _ result: SpeechTranscriber.Result, offset: TimeInterval, language: LanguageCode, words: Bool,
        continuation: AsyncThrowingStream<TranscriptionEvent, any Error>.Continuation
    ) {
        if result.isFinal {
            if let segment = segment(from: result, offset: offset, language: language, words: words) {
                continuation.yield(.final(segment))
            }
            return
        }
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            continuation.yield(.partial(PartialSegment(text: text, start: offset + result.range.start.seconds, languageCode: language)))
        }
    }

    private static func analyzerOptions(for useCase: UseCase) -> SpeechAnalyzer.Options? {
        if #available(macOS 27, *), useCase == .file {
            // Offline batch work may use as many resources as the system allows (macOS 27+ only).
            return SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse, ignoresResourceLimits: true)
        }
        return nil
    }

    /// Builds a final `Segment` with per-word timings from an attributed transcriber result.
    private static func segment(
        from result: SpeechTranscriber.Result, offset: TimeInterval, language: LanguageCode, words includeWords: Bool
    ) -> Segment? {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var words: [Word] = []
        if includeWords {
            for run in result.text.runs {
                guard let range = run.audioTimeRange else { continue }
                let word = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !word.isEmpty else { continue }
                words.append(Word(text: word, start: offset + range.start.seconds, end: offset + range.end.seconds))
            }
        }
        return Segment(
            start: offset + result.range.start.seconds, end: offset + result.range.end.seconds, text: text, languageCode: language,
            words: words)
    }
}

/// Converts 16 kHz mono Float32 samples to the analyzer's preferred `AVAudioFormat`.
private final class ChunkConverter {
    private let source: AVAudioFormat
    private let target: AVAudioFormat
    private let converter: AVAudioConverter?

    init(target: AVAudioFormat) throws {
        guard
            let source = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: AppCore.AudioChunk.sampleRate, channels: 1, interleaved: false)
        else { throw AppError.engineFailure(RoutingTargets.appleEngine, reason: "Cannot create the source audio format.") }
        self.source = source
        self.target = target
        if source == target {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: source, to: target) else {
                throw AppError.engineFailure(RoutingTargets.appleEngine, reason: "Cannot convert audio to \(target).")
            }
            self.converter = converter
        }
    }

    func convert(_ samples: [Float]) throws -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = input.floatChannelData?[0]
        else { return nil }
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
        input.frameLength = AVAudioFrameCount(samples.count)
        guard let converter else { return input }

        let ratio = target.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        if status == .error || error != nil {
            throw AppError.engineFailure(RoutingTargets.appleEngine, reason: error?.localizedDescription ?? "Audio conversion failed.")
        }
        return output
    }
}

/// Records the media time of the first chunk so result times can be shifted onto the media timeline.
private final class BaseTime: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval?
    func setIfNeeded(_ time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        if value == nil { value = time }
    }
    var current: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

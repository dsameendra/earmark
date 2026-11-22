import AppCore
import AudioCapture
import Foundation

/// Re-runs ASR for one time range of a media file with a user-chosen language (LANG-AC-08, EDIT-AC-09).
///
/// The editor calls this after the user corrects a segment's language. Only the segment's time range is decoded and
/// transcribed; the engine is chosen for the *new* language (``EngineResolver``/router, so Sinhala goes to the Qwen3-ASR
/// engine and never to stock Whisper). Persisting the replacement and keeping the previous text as a revision is the
/// editor/Persistence side: this API only produces the new content.
public protocol SegmentRetranscribing: Sendable {
    /// Transcribes `range` of `file` as `language`.
    ///
    /// - Returns: Segments on the **media timeline** (times are absolute and clamped to `range`), tagged with `language`
    ///   and `languageConfidence == 1` (the user chose it). Empty when the range holds no speech.
    /// - Throws: ``AppError`` (for example ``AppError/unsupportedLanguage(_:)``, ``AppError/modelNotInstalled(_:)``,
    ///   ``AppError/cancelled``).
    func retranscribe(file: URL, range: TimeRange, language: LanguageCode, options: TranscriptionOptions) async throws -> [Segment]
}

extension SegmentRetranscribing {
    /// Convenience for the editor: re-transcribes `segment` and returns it with its new text, words, language and
    /// confidence, keeping its identity (`id`, `speakerID`), its time range and its flags. Translations are cleared because
    /// they no longer match the text.
    ///
    /// - Returns: the updated segment; text is empty if no speech was found (the editor decides what to do then).
    public func retranscribe(
        segment: Segment, file: URL, language: LanguageCode, options: TranscriptionOptions = TranscriptionOptions(useCase: .file)
    ) async throws -> Segment {
        let produced = try await retranscribe(file: file, range: segment.range, language: language, options: options)
        var updated = segment
        updated.text = produced.map(\.text).joined(separator: " ")
        updated.words = produced.flatMap(\.words)
        updated.languageCode = language
        updated.languageConfidence = 1
        let confidences = produced.compactMap(\.confidence)
        updated.confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        updated.noSpeechProbability = produced.compactMap(\.noSpeechProbability).max()
        updated.translations = []
        return updated
    }
}

/// ``SegmentRetranscribing`` on top of ``FileTranscriptionPipeline``: decodes only `range`, then runs the normal bounded,
/// VAD-aligned pipeline with a fixed language.
public struct SegmentRetranscriber: SegmentRetranscribing {
    private let decoder: any AudioFileDecoder
    private let engines: EngineResolver
    private let vad: (any VoiceActivityDetector)?

    /// - Parameters:
    ///   - decoder: File decoder (defaults to ``AVFileDecoder``).
    ///   - engines: Engine/model per language (see ``EngineBinding/resolver(plan:engines:)``).
    ///   - vad: VAD used by the pipeline to skip silence (defaults to the energy detector).
    public init(
        decoder: any AudioFileDecoder = AVFileDecoder(), engines: @escaping EngineResolver,
        vad: (any VoiceActivityDetector)? = EnergyVoiceActivityDetector()
    ) {
        self.decoder = decoder
        self.engines = engines
        self.vad = vad
    }

    public func retranscribe(file: URL, range: TimeRange, language: LanguageCode, options: TranscriptionOptions) async throws -> [Segment] {
        guard range.duration > 0 else { return [] }
        var local = options
        local.languageMode = .single(language)
        let pipeline = FileTranscriptionPipeline(decoder: RangeDecoder(base: decoder, range: range), vad: vad, identifier: nil)
        var out: [Segment] = []
        do {
            for try await event in pipeline.run(
                file: file, options: local, resumeFrom: JobCheckpoint(lastCompletedChunk: -1, mediaTime: range.start), engines: engines)
            {
                if case .chunkCompleted(let segments, _) = event { out.append(contentsOf: segments) }
            }
        } catch {
            throw AppError.mapping(error, engine: "retranscribe")
        }
        return out.compactMap { clamp($0, to: range, language: language) }.sorted { $0.start < $1.start }
    }

    private func clamp(_ segment: Segment, to range: TimeRange, language: LanguageCode) -> Segment? {
        var result = segment
        result.start = max(range.start, segment.start)
        result.end = min(range.end, max(result.start, segment.end))
        result.words = segment.words.filter { $0.end > range.start && $0.start < range.end }
        result.languageCode = language
        result.languageConfidence = 1
        return result.end > result.start || !result.text.isEmpty ? result : nil
    }
}

/// Decoder wrapper that stops at the end of a time range.
struct RangeDecoder: AudioFileDecoder {
    let base: any AudioFileDecoder
    let range: TimeRange

    func decode(file: URL, chunkSeconds: TimeInterval, startingAt: TimeInterval) -> AsyncThrowingStream<AudioChunk, any Error> {
        let base = base
        let end = range.end
        let start = max(startingAt, range.start)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in base.decode(file: file, chunkSeconds: chunkSeconds, startingAt: start) {
                        try Task.checkCancellation()
                        if chunk.startSeconds >= end { break }
                        let keep = Int(((end - chunk.startSeconds) * AudioChunk.sampleRate).rounded(.up))
                        if keep < chunk.samples.count {
                            var trimmed = chunk
                            trimmed.samples = Array(chunk.samples.prefix(max(0, keep)))
                            continuation.yield(trimmed)
                            break
                        }
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func duration(of file: URL) async throws -> TimeInterval { range.end }
}

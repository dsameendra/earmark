import AppCore
import Foundation

/// ``LanguageIdentifier`` backed by Whisper's language tokens, restricted to a candidate set.
///
/// Used by ``FileTranscriptionPipeline`` for auto-detect (first ~30 s) and for per-VAD-segment language ID in multilingual
/// mode (LANG-AC-04, LANG-AC-05).
///
/// It does **not** call WhisperKit's `detectLangauge` (which wedged, T25). It runs the encoder and a single decoder step and
/// reads only the candidate language logits (``WhisperKitEngine/detectLanguage(samples:candidates:model:minimumMass:timeout:)``),
/// so the result is a real distribution **over the candidates** (probabilities sum to 1), for example `{en: 0.97, si: 0.03}`.
///
/// - Returns an empty array when the candidates hold less than ``minimumMass`` of Whisper's unrestricted language
///   probability (the audio is probably in some other language) or when the Core ML call timed out (the engine then reloads
///   its model on next use). The caller keeps the previous language in both cases (LANG-AC-06).
/// - Throws ``AppError`` for engine failures and ``AppError/cancelled`` on cancellation; it never blocks longer than the
///   engine's language-ID timeout.
/// - Note: stock Whisper cannot transcribe Sinhala, but it has a Sinhala language token, so Sinhala-vs-English
///   identification works even though Sinhala ASR must go to the Qwen3-ASR engine (see `specs/research/sinhala-asr.md`).
public struct WhisperLanguageIdentifier: LanguageIdentifier {
    private let engine: WhisperKitEngine
    private let model: ModelID
    private let minimumMass: Double

    /// Creates an identifier that uses (and, if needed, loads) `model` in `engine`.
    /// - Parameter minimumMass: Minimum unrestricted probability the candidate set must hold (default 0.02).
    public init(engine: WhisperKitEngine, model: ModelID = RoutingTargets.whisperSmall, minimumMass: Double = 0.02) {
        self.engine = engine
        self.model = model
        self.minimumMass = minimumMass
    }

    public func identify(chunk: AudioChunk, candidates: Set<LanguageCode>) async throws -> [LanguageScore] {
        guard !chunk.samples.isEmpty else { return [] }
        do {
            return try await engine.detectLanguage(
                samples: chunk.samples, candidates: candidates, model: model, minimumMass: minimumMass)
        } catch LanguageIDError.timedOut {
            return []
        }
    }
}

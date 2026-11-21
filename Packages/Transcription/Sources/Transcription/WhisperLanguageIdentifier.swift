import AppCore
import Foundation

/// ``LanguageIdentifier`` backed by WhisperKit's language detection, restricted to a candidate set.
///
/// Used by ``FileTranscriptionPipeline`` for auto-detect (first ~30 s) and for per-VAD-segment language ID in multilingual
/// mode (LANG-AC-04, LANG-AC-05). It returns an empty array when the detector's winner is not one of `candidates` (the
/// caller then keeps the previous language) and throws ``AppError`` for engine failures.
///
/// - Note: WhisperKit exposes only the winning language's probability and cannot narrow its language filter, so a
///   restricted *distribution* over the candidates is not available yet; T25 may replace this with a custom logits filter.
///   Stock Whisper cannot recognise Sinhala reliably, so for sets containing Sinhala the pipeline relies on the
///   low-confidence fallback.
public struct WhisperLanguageIdentifier: LanguageIdentifier {
    private let engine: WhisperKitEngine
    private let model: ModelID

    /// Creates an identifier that uses (and, if needed, loads) `model` in `engine`.
    public init(engine: WhisperKitEngine, model: ModelID = RoutingTargets.whisperSmall) {
        self.engine = engine
        self.model = model
    }

    public func identify(chunk: AudioChunk, candidates: Set<LanguageCode>) async throws -> [LanguageScore] {
        guard !chunk.samples.isEmpty else { return [] }
        return try await engine.detectLanguage(samples: chunk.samples, candidates: candidates, model: model)
    }
}

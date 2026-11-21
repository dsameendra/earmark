import AppCore
import FluidAudio
import Foundation

/// Embeds raw 16 kHz mono samples. Lets the voice-profile and bleed logic work without a file on disk.
public protocol SpeakerSpanEmbedder: Sendable {
    func embedding(samples: [Float]) async throws -> SpeakerEmbedding
}

/// ``AppCore/SpeakerEmbeddingProvider`` backed by the Community-1 WeSpeaker embedder (256-d, raw, pre-PLDA).
///
/// Uses the same model folder as ``FluidAudioDiarizer`` and the same offline-only loader; the embedder is always
/// initialised from local files before `embedSpans` is called, so FluidAudio's own default-directory fallback in
/// `embedSpans` is never reached.
public actor FluidSpeakerEmbeddingProvider: SpeakerEmbeddingProvider, SpeakerSpanEmbedder {
    private let models: any ModelManaging
    private let modelID: ModelID
    private var manager: ManagerBox?

    /// - Parameters:
    ///   - models: The app's model manager; only `location(of:)` is used.
    ///   - modelID: Catalog id of the offline model (default ``DiarizationModelID/community1``).
    public init(models: any ModelManaging, modelID: ModelID = DiarizationModelID.community1) {
        self.models = models
        self.modelID = modelID
    }

    /// Embedding space tag to store with a ``AppCore/VoiceProfile``.
    public nonisolated var embeddingModel: String { FluidAudioDiarizer.embeddingModelName }

    public func embedding(file: URL, range: TimeRange) async throws -> SpeakerEmbedding {
        let samples = try await DiarizationAudio.samples(of: file)
        return try await embed(samples: DiarizationAudio.slice(samples, range: range))
    }

    public func embedding(samples: [Float]) async throws -> SpeakerEmbedding {
        try await embed(samples: samples)
    }

    private func embed(samples: [Float]) async throws -> SpeakerEmbedding {
        guard samples.count >= Int(AudioChunk.sampleRate / 4) else {
            throw AppError.engineFailure(FluidAudioDiarizer.engineID, reason: "Audio span too short to embed")
        }
        let manager = try await loadedManager()
        do {
            let seconds = Double(samples.count) / AudioChunk.sampleRate
            let vectors = try await manager.value.embedSpans(audioSource: ArrayAudioSampleSource(samples: samples), spans: [0..<seconds])
            guard let vector = vectors.first, !vector.isEmpty else {
                throw AppError.engineFailure(FluidAudioDiarizer.engineID, reason: "Embedder returned no vector")
            }
            return SpeakerEmbedding(vector: vector)
        } catch let error as AppError {
            throw error
        } catch {
            throw AppError.engineFailure(FluidAudioDiarizer.engineID, reason: error.localizedDescription)
        }
    }

    private func loadedManager() async throws -> ManagerBox {
        if let manager { return manager }
        let fresh = OfflineDiarizerManager()
        fresh.initialize(models: try await FluidOfflineModelLoader.load(model: modelID, using: models))
        let box = ManagerBox(fresh)
        manager = box
        return box
    }
}

/// FluidAudio's manager is a non-`Sendable` class whose model references are written once during `initialize`; after
/// that `embedSpans` only reads them, so sharing the initialised instance is safe.
final class ManagerBox: @unchecked Sendable {
    let value: OfflineDiarizerManager
    init(_ value: OfflineDiarizerManager) { self.value = value }
}

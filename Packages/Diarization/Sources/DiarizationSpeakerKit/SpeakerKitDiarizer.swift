import AppCore
import Diarization
import Foundation
import SpeakerKit

/// Swappable offline fallback backed by Argmax `SpeakerKit` (pyannote segmenter + embedder + PLDA/VBx).
///
/// Why it is a fallback: on the AMI spike it matched FluidAudio within noise (19.2 % vs 18.1 % strict DER) but
/// over-segmented two of three meetings (5 and 6 clusters for 4 speakers), it has no streaming API, and it links
/// WhisperKit. It lives in its own target so apps that do not ship it do not link SpeakerKit.
///
/// Models are loaded from `ModelManaging.location(of:)` with `download: false`; the engine never downloads. There is no
/// catalog entry for the SpeakerKit models yet (open risk), so the model id is injected.
///
/// Speaker count: ``AppCore/DiarizationOptions/Count/exact(_:)`` is passed through; min/max ranges are not supported by
/// SpeakerKit and fall back to automatic.
public actor SpeakerKitDiarizer: AppCore.Diarizer {
    /// `EngineID` of this engine.
    public static let engineID: EngineID = "speakerkit.offline"

    public nonisolated var id: EngineID { Self.engineID }
    private let models: any ModelManaging
    private let modelID: ModelID
    private var kit: SpeakerKit?

    /// - Parameters:
    ///   - models: The app's model manager; only `location(of:)` is used.
    ///   - modelID: Catalog id under which the `argmaxinc/speakerkit-coreml` folder is installed.
    public init(models: any ModelManaging, modelID: ModelID) {
        self.models = models
        self.modelID = modelID
    }

    public func diarize(file: URL, options: AppCore.DiarizationOptions) async throws -> [SpeakerTurn] {
        try await run(samples: DiarizationAudio.samples(of: file), options: options)
    }

    public func diarize(audio: AsyncThrowingStream<AudioChunk, any Error>, options: AppCore.DiarizationOptions) async throws
        -> [SpeakerTurn]
    {
        try await run(samples: DiarizationAudio.collect(audio), options: options)
    }

    private func run(samples: [Float], options: AppCore.DiarizationOptions) async throws -> [SpeakerTurn] {
        guard !samples.isEmpty else { return [] }
        let kit = try await loadKit()
        var pyannote = PyannoteDiarizationOptions(centroidSource: .finalAssignment)
        if case .exact(let count) = options.speakerCount { pyannote.numberOfSpeakers = max(1, count) }
        do {
            let result = try await kit.diarize(audioArray: samples, options: pyannote, progressCallback: nil)
            return result.segments.map {
                SpeakerTurn(range: TimeRange(start: Double($0.startTime), end: Double($0.endTime)), slot: $0.speaker.speakerId ?? 0)
            }.sorted { $0.range.start < $1.range.start }
        } catch is CancellationError {
            throw AppError.cancelled
        } catch {
            throw AppError.engineFailure(Self.engineID, reason: error.localizedDescription)
        }
    }

    private func loadKit() async throws -> SpeakerKit {
        if let kit { return kit }
        let folder: URL
        do {
            folder = try await models.location(of: modelID)
        } catch {
            throw AppError.modelNotInstalled(modelID)
        }
        let config = PyannoteConfig(modelFolder: folder.path, download: false, verbose: false)
        do {
            let loaded = try await SpeakerKit(config)
            kit = loaded
            return loaded
        } catch {
            throw AppError.engineFailure(Self.engineID, reason: error.localizedDescription)
        }
    }
}

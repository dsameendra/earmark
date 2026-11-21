import Foundation
import SpeakerKit
import DiarCore

/// SpeakerKit (argmax-oss-swift): whole-buffer pyannote pipeline. No streaming API.
public actor SpeakerKitEngine: DiarizationEngine {
    public nonisolated let name = "speakerkit-pyannote"
    private let numSpeakers: Int?
    public init(numSpeakers: Int? = nil) { self.numSpeakers = numSpeakers }

    public func diarize(samples: [Float], cacheDir: URL) async throws -> DiarOutput {
        let cfg = PyannoteConfig(downloadBase: cacheDir.appendingPathComponent("speakerkit").path,
                                 verbose: false)
        let kit = try await SpeakerKit(cfg)
        let opts = PyannoteDiarizationOptions(numberOfSpeakers: numSpeakers,
                                              centroidSource: .finalAssignment)
        let r = try await kit.diarize(audioArray: samples, options: opts, progressCallback: nil)
        let turns = r.segments.map { seg in
            Turn(speaker: "SPK\(seg.speaker.speakerId ?? -1)", start: Double(seg.startTime), end: Double(seg.endTime))
        }
        var emb: [String: [Float]] = [:]
        for (k, v) in r.speakerCentroidEmbeddings { emb["SPK\(k)"] = v }
        return DiarOutput(turns: turns, embeddings: emb, embeddingModel: "pyannote-v3 embedder via SpeakerKit 1.1.1 (raw, pre-PLDA)")
    }
}

import Foundation
import FluidAudio
import DiarCore

/// FluidAudio offline pipeline: pyannote Community-1 segmentation + WeSpeaker embedding + PLDA + VBx.
/// The manager is a non-Sendable class; it is created and used only inside this actor.
public actor FluidOfflineEngine: DiarizationEngine {
    public nonisolated let name = "fluidaudio-offline-vbx"
    private let numSpeakers: Int?
    public init(numSpeakers: Int? = nil) { self.numSpeakers = numSpeakers }

    public func diarize(samples: [Float], cacheDir: URL) async throws -> DiarOutput {
        var cfg = OfflineDiarizerConfig()
        if let n = numSpeakers { cfg.clustering.numSpeakers = n }
        let mgr = OfflineDiarizerManager(config: cfg)
        try await mgr.prepareModels(directory: cacheDir.appendingPathComponent("fluidaudio"))
        let r = try await mgr.process(audio: samples)
        let turns = r.segments.map { Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) }
        return DiarOutput(turns: turns, embeddings: r.speakerDatabase ?? [:],
                          embeddingModel: "wespeaker-community1-256d (FluidAudio 0.18.4)")
    }
}

/// Mic-track "You" detection via FluidAudio's VAD (Silero). Returns speech spans in seconds.
public enum FluidVAD {
    public static func spans(samples: [Float], cacheDir: URL) async throws -> [Turn] {
        let vad = try await VadManager(config: .default, modelDirectory: cacheDir.appendingPathComponent("fluidaudio"))
        let results = try await vad.process(samples)
        let hop = Double(VadManager.chunkSize) / Double(VadManager.sampleRate)
        var spans: [Turn] = []; var open: Double?
        for (i, r) in results.enumerated() {
            let t = Double(i) * hop
            if r.isVoiceActive { if open == nil { open = t } }
            else if let s = open { spans.append(Turn(speaker: "You", start: s, end: t)); open = nil }
        }
        if let s = open { spans.append(Turn(speaker: "You", start: s, end: Double(results.count) * hop)) }
        return spans
    }
}

import Foundation
import FluidAudio
import DiarCore

/// One streaming update, in AUDIO time (no wall clock): how much audio had been fed when it arrived.
public struct StreamUpdate: Sendable, Codable {
    public var fed: Double            // seconds of audio fed so far
    public var finalized: [Turn]      // segments finalized by this update
    public var tentative: [Turn]      // current tentative (revisable) segments
}

public struct StreamResult: Sendable, Codable {
    public var engine: String
    public var chunkSeconds: Double
    public var maxSlots: Int
    public var updates: [StreamUpdate]
    public var turns: [Turn] { updates.flatMap { $0.finalized } }
}

/// Feeds audio to a FluidAudio streaming diarizer in small chunks, as fast as possible (NO pacing, NO timing).
/// Latency is reported in audio time: (audio fed when a label appeared) - (time of speech it labels).
public actor FluidStreamEngine {
    public init() {}

    func seg(_ s: DiarizerSegment) -> Turn {
        Turn(speaker: "S\(s.speakerIndex)", start: Double(s.startTime), end: Double(s.endTime))
    }

    /// kind: lseend-ami | lseend-dihard3 | sortformer-fastV2 | sortformer-balancedV2 | sortformer-fastV2_1 | legacy
    public func run(kind: String, samples: [Float], cache: URL, chunk: Double) async throws -> StreamResult {
        let step = max(1, Int(chunk * 16000))
        var updates: [StreamUpdate] = []
        func feed(_ d: any Diarizer) throws {
            var i = 0
            while i < samples.count {
                let j = min(i + step, samples.count)
                try d.addAudio(samples[i..<j], sourceSampleRate: 16000)
                while let u = try d.process() {
                    updates.append(StreamUpdate(fed: Double(j) / 16000,
                                                finalized: u.finalizedSegments.map(seg),
                                                tentative: u.tentativeSegments.map(seg)))
                }
                i = j
            }
            if let u = try d.finalizeSession() {
                updates.append(StreamUpdate(fed: Double(samples.count) / 16000,
                                            finalized: u.finalizedSegments.map(seg),
                                            tentative: []))
            }
        }
        let dir = cache.appendingPathComponent("fluidaudio-stream")
        var slots = 0
        switch kind {
        case "lseend-ami", "lseend-dihard3":
            let d = LSEENDDiarizer()
            try await d.initialize(variant: kind == "lseend-ami" ? .ami : .dihard3, cacheDirectory: dir)
            slots = d.numSpeakers ?? 0
            try feed(d)
        case "sortformer-fastV2", "sortformer-balancedV2", "sortformer-fastV2_1":
            let cfg: SortformerConfig = kind.hasSuffix("balancedV2") ? .balancedV2 : (kind.hasSuffix("fastV2_1") ? .fastV2_1 : .fastV2)
            let d = SortformerDiarizer(config: cfg)
            let models = try await SortformerModels.loadFromHuggingFace(config: cfg, cacheDirectory: dir)
            d.initialize(models: models)
            slots = d.numSpeakers ?? 4
            try feed(d)
        case "legacy":
            // Classic pyannote-3.1-derived DiarizerManager + SpeakerManager, non-overlapping chunks.
            var cfg = DiarizerConfig()
            if let t = ProcessInfo.processInfo.environment["DIAR_LEGACY_THRESHOLD"].flatMap(Float.init) { cfg.clusteringThreshold = t }  // default 0.7
            let m = DiarizerManager(config: cfg)
            m.initialize(models: try await DiarizerModels.downloadIfNeeded(to: dir.appendingPathComponent("legacy")))
            var i = 0
            while i < samples.count {
                let j = min(i + step, samples.count)
                var piece = Array(samples[i..<j])
                if piece.count < 16000 * 5 { piece += [Float](repeating: 0, count: 16000 * 5 - piece.count) }
                let r = try m.performCompleteDiarization(piece, atTime: Double(i) / 16000)
                updates.append(StreamUpdate(fed: Double(j) / 16000,
                    finalized: r.segments.map { Turn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds)) },
                    tentative: []))
                i = j
            }
            slots = Set(updates.flatMap { $0.finalized.map(\.speaker) }).count
        default: throw NSError(domain: "FluidStream", code: 1, userInfo: [NSLocalizedDescriptionKey: "unknown kind \(kind)"])
        }
        return StreamResult(engine: kind, chunkSeconds: chunk, maxSlots: slots, updates: updates)
    }
}

/// Live mic-track VAD: feeds 4096-sample (256 ms) frames through Silero streaming state, emits "You" spans.
public actor LiveMicVAD {
    private var vad: VadManager?
    private var state: VadStreamState?
    private var open: Double?
    private var buf: [Float] = []
    private var consumed = 0
    public private(set) var spans: [Turn] = []
    public init() {}
    public func start(cache: URL) async throws {
        let v = try await VadManager(config: .default, modelDirectory: cache.appendingPathComponent("fluidaudio"))
        vad = v; state = await v.makeStreamState()
    }
    /// Feed any amount of audio; returns spans that CLOSED during this call.
    public func feed(_ x: [Float]) async throws -> [Turn] {
        guard let vad, var st = state else { return [] }
        buf += x
        var closed: [Turn] = []
        while buf.count >= VadManager.chunkSize {
            let frame = Array(buf.prefix(VadManager.chunkSize)); buf.removeFirst(VadManager.chunkSize)
            let r = try await vad.processStreamingChunk(frame, state: st, returnSeconds: true, timeResolution: 2)
            st = r.state; consumed += VadManager.chunkSize
            if let e = r.event {
                switch e.kind {
                case .speechStart: open = e.time ?? Double(e.sampleIndex) / 16000
                case .speechEnd:
                    if let s = open { let t = Turn(speaker: "You", start: s, end: e.time ?? Double(e.sampleIndex) / 16000); closed.append(t); spans.append(t); open = nil }
                }
            }
        }
        state = st
        return closed
    }
    public func finish() -> [Turn] {
        if let s = open { let t = Turn(speaker: "You", start: s, end: Double(consumed) / 16000); spans.append(t); open = nil; return [t] }
        return []
    }
    public var openSince: Double? { open }
}

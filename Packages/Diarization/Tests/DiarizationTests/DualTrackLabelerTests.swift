import AppCore
import AudioCapture
import Foundation
import Testing

@testable import Diarization

/// Deterministic embedder: the "voice" is encoded in the samples (a constant tone level picks a one-hot direction).
struct ToneEmbedder: SpeakerSpanEmbedder {
    static func vector(_ voice: Int) -> SpeakerEmbedding {
        var v = [Float](repeating: 0, count: 4)
        v[voice] = 1
        return SpeakerEmbedding(vector: v)
    }
    func embedding(samples: [Float]) async throws -> SpeakerEmbedding {
        guard let first = samples.first else { throw AppError.other("empty") }
        return Self.vector(Int((first * 10).rounded()))
    }
}

struct FixedVAD: VoiceActivityDetector {
    var ranges: [TimeRange]
    func speechRanges(in chunk: AudioChunk) async throws -> [TimeRange] { ranges }
}

@Suite("Dual-track labeling") struct DualTrackLabelerTests {
    /// 20 s of mic audio at 16 kHz where the sample value encodes which voice is speaking: 0.0 = you, 0.1 = remote voice 1.
    private func mic(voice: (Double) -> Int) -> [Float] {
        (0..<(20 * 16_000)).map { Float(voice(Double($0) / 16_000)) / 10 }
    }

    private func you(_ turns: [DualTrackTurn]) -> [TimeRange] { turns.filter { $0.speaker == .you }.map(\.range) }

    // DIA-AC-07
    @Test func micIsYouAndRemoteKeepsItsSlots() async throws {
        let labeler = DualTrackLabeler(vad: FixedVAD(ranges: [TimeRange(start: 1, end: 3)]))
        let remote = [SpeakerTurn(range: TimeRange(start: 5, end: 8), slot: 2), SpeakerTurn(range: TimeRange(start: 9, end: 10), slot: 0)]
        let chunk = AudioChunk(samples: [Float](repeating: 0, count: 16_000 * 12), startSeconds: 0, source: .mic(deviceUID: nil))
        let turns = try await labeler.label(mic: chunk, remoteTurns: remote)
        #expect(turns.map(\.speaker) == [.you, .remote(slot: 2), .remote(slot: 0)])
        #expect(you(turns) == [TimeRange(start: 1, end: 3)])
    }

    @Test func vadRangesAreShiftedToMediaTime() async throws {
        let labeler = DualTrackLabeler(vad: FixedVAD(ranges: [TimeRange(start: 1, end: 3)]))
        let chunk = AudioChunk(samples: [Float](repeating: 0, count: 16_000 * 5), startSeconds: 60, source: .mic(deviceUID: nil))
        let turns = try await labeler.label(mic: chunk, remoteTurns: [])
        #expect(you(turns) == [TimeRange(start: 61, end: 63)])
    }

    // DIA-AC-08: no naive overlap gate.
    @Test func overlapAloneNeverDeletesGenuineSimultaneousSpeech() async {
        let labeler = DualTrackLabeler(suppressor: KeepAllBleedSuppressor())
        let remote = [SpeakerTurn(range: TimeRange(start: 2, end: 8), slot: 0)]
        let turns = await labeler.label(
            micSpans: [TimeRange(start: 3, end: 6)], micSamples: mic { _ in 0 }, micStartSeconds: 0, remoteTurns: remote)
        #expect(you(turns) == [TimeRange(start: 3, end: 6)])
    }

    @Test func profileSuppressorRemovesBleedButKeepsYourInterruption() async {
        let suppressor = VoiceProfileBleedSuppressor(
            embedder: ToneEmbedder(), youProfile: ToneEmbedder.vector(0), remoteCentroids: [0: ToneEmbedder.vector(1)])
        let labeler = DualTrackLabeler(suppressor: suppressor)
        let remote = [SpeakerTurn(range: TimeRange(start: 2, end: 12), slot: 0)]
        // 3-5 s: remote voice leaking into the mic (bleed). 8-10 s: the user genuinely talks over the remote speaker.
        let audio = mic { t in (3..<5).contains(t) ? 1 : 0 }
        let turns = await labeler.label(
            micSpans: [TimeRange(start: 3, end: 5), TimeRange(start: 8, end: 10)], micSamples: audio, micStartSeconds: 0,
            remoteTurns: remote)
        #expect(you(turns) == [TimeRange(start: 8, end: 10)])
    }

    @Test func partialOverlapOnlyDropsTheContestedBleedPart() async {
        let suppressor = VoiceProfileBleedSuppressor(
            embedder: ToneEmbedder(), youProfile: ToneEmbedder.vector(0), remoteCentroids: [0: ToneEmbedder.vector(1)])
        let labeler = DualTrackLabeler(suppressor: suppressor)
        let remote = [SpeakerTurn(range: TimeRange(start: 4, end: 7), slot: 0)]
        // Mic span 2-7 s: the user speaks 2-4 s alone (kept), 4-7 s is remote bleed (dropped).
        let audio = mic { t in t >= 4 ? 1 : 0 }
        let turns = await labeler.label(micSpans: [TimeRange(start: 2, end: 7)], micSamples: audio, micStartSeconds: 0, remoteTurns: remote)
        #expect(you(turns) == [TimeRange(start: 2, end: 4)])
    }

    @Test func noProfileKeepsEverythingByDefault() async {
        let suppressor = VoiceProfileBleedSuppressor(embedder: ToneEmbedder(), youProfile: nil, remoteCentroids: [0: ToneEmbedder.vector(1)])
        let labeler = DualTrackLabeler(suppressor: suppressor)
        let remote = [SpeakerTurn(range: TimeRange(start: 2, end: 8), slot: 0)]
        let turns = await labeler.label(
            micSpans: [TimeRange(start: 3, end: 6)], micSamples: mic { _ in 1 }, micStartSeconds: 0, remoteTurns: remote)
        #expect(you(turns) == [TimeRange(start: 3, end: 6)])
    }

    @Test func remoteOnlyModeSuppressesSpansThatMatchARemoteCentroid() async {
        let configuration = VoiceProfileBleedSuppressor.Configuration(remoteOnlyThreshold: 0.25)
        let suppressor = VoiceProfileBleedSuppressor(
            embedder: ToneEmbedder(), youProfile: nil, remoteCentroids: [0: ToneEmbedder.vector(1)], configuration: configuration)
        let labeler = DualTrackLabeler(suppressor: suppressor)
        let remote = [SpeakerTurn(range: TimeRange(start: 2, end: 8), slot: 0)]
        let bleed = await labeler.label(
            micSpans: [TimeRange(start: 3, end: 6)], micSamples: mic { _ in 1 }, micStartSeconds: 0, remoteTurns: remote)
        #expect(you(bleed).isEmpty)
        let own = await labeler.label(
            micSpans: [TimeRange(start: 3, end: 6)], micSamples: mic { _ in 0 }, micStartSeconds: 0, remoteTurns: remote)
        #expect(you(own) == [TimeRange(start: 3, end: 6)])
    }

    @Test func aThirdUnknownVoiceIsKept() async {
        let suppressor = VoiceProfileBleedSuppressor(
            embedder: ToneEmbedder(), youProfile: ToneEmbedder.vector(0), remoteCentroids: [0: ToneEmbedder.vector(1)])
        let labeler = DualTrackLabeler(suppressor: suppressor)
        let remote = [SpeakerTurn(range: TimeRange(start: 2, end: 8), slot: 0)]
        // Voice 2 is far from the user and from the remote speaker (orthogonal to both): no positive evidence of bleed.
        let turns = await labeler.label(
            micSpans: [TimeRange(start: 3, end: 6)], micSamples: mic { _ in 2 }, micStartSeconds: 0, remoteTurns: remote)
        #expect(you(turns) == [TimeRange(start: 3, end: 6)])
    }

    @Test func shortContestedSpansAndEmbeddingFailuresAreKept() async {
        struct Failing: SpeakerSpanEmbedder {
            func embedding(samples: [Float]) async throws -> SpeakerEmbedding { throw AppError.other("boom") }
        }
        let suppressor = VoiceProfileBleedSuppressor(
            embedder: Failing(), youProfile: ToneEmbedder.vector(0), remoteCentroids: [0: ToneEmbedder.vector(1)])
        let labeler = DualTrackLabeler(suppressor: suppressor)
        let remote = [SpeakerTurn(range: TimeRange(start: 2, end: 8), slot: 0)]
        let turns = await labeler.label(
            micSpans: [TimeRange(start: 3, end: 6)], micSamples: mic { _ in 1 }, micStartSeconds: 0, remoteTurns: remote)
        #expect(you(turns) == [TimeRange(start: 3, end: 6)])
    }

    @Test func intervalAlgebra() {
        let merged = DualTrackLabeler.union([TimeRange(start: 5, end: 6), TimeRange(start: 1, end: 2), TimeRange(start: 1.5, end: 3)])
        #expect(merged == [TimeRange(start: 1, end: 3), TimeRange(start: 5, end: 6)])
        #expect(
            DualTrackLabeler.subtract(TimeRange(start: 0, end: 10), merged) == [
                TimeRange(start: 0, end: 1), TimeRange(start: 3, end: 5), TimeRange(start: 6, end: 10),
            ])
        #expect(DualTrackLabeler.intersect(TimeRange(start: 2, end: 5.5), merged) == [TimeRange(start: 2, end: 3), TimeRange(start: 5, end: 5.5)])
    }
}

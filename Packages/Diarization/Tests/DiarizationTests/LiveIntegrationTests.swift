import AppCore
import Foundation
import Testing

@testable import Diarization

@Suite("Live diarization (integration)", .serialized) struct LiveIntegrationTests {
    struct Collected {
        var finalTurns: [SpeakerTurn] = []
        var provisional: [SpeakerTurn] = []
        var finalizedUpTo: [TimeInterval] = []
        var limitReached = false
    }

    /// Feeds `samples` in 100 ms chunks, as fast as possible (no pacing, so no wall-clock latency is measured here; the
    /// spike measured about 1.1 s label latency for LS-EEND in audio time).
    static func run(_ diarizer: some StreamingDiarizer, samples: [Float], options: DiarizationOptions = .init()) async throws -> Collected {
        let step = 1600
        let audio = AsyncStream<AudioChunk> { continuation in
            var index = 0
            while index < samples.count {
                let end = min(index + step, samples.count)
                continuation.yield(AudioChunk(samples: Array(samples[index..<end]), startSeconds: Double(index) / 16_000, source: .file))
                index = end
            }
            continuation.finish()
        }
        var out = Collected()
        for try await event in diarizer.stream(audio: audio, options: options) {
            switch event {
            case .turn(let turn):
                if turn.isProvisional { out.provisional.append(turn) } else { out.finalTurns.append(turn) }
            case .finalized(let upTo): out.finalizedUpTo.append(upTo)
            case .speakerLimitReached: out.limitReached = true
            }
        }
        return out
    }

    /// Measured 2026-11-21 (M3 Pro, debug build) on ES2004a 180-420 s, strict protocol A, 100 ms chunks, finalized turns only:
    /// LS-EEND `.ami` 32.8 % (miss 16.0, fa 6.2, conf 10.7; 4 slots; 240 s of audio in 2.9 s wall), Sortformer v2 fast 40.0 %
    /// (miss 31.8, fa 6.4, conf 1.8). Baselines add about 3 points.
    static let lseendStrictDERBaseline = 36.0
    static let sortformerStrictDERBaseline = 43.0

    private func score(_ turns: [SpeakerTurn], uem: ClosedRange<Double>, reference: [DERScorer.Turn]) -> DERScorer.Result {
        DERScorer.score(
            reference: reference, hypothesis: OfflineIntegrationTests.toScorer(turns), uem: uem, collar: 0, skipOverlap: false)
    }

    @Test func lseendOnAMIExcerpt() async throws {
        guard let models = LocalAssets.spikeModels(), models.folders[DiarizationModelID.lseendAMI] != nil,
            let wav = LocalAssets.fixture(LocalAssets.ami240), let ref = try OfflineIntegrationTests.reference()
        else { return }
        let samples = try await DiarizationAudio.samples(of: wav)
        let started = Date()
        let result = try await Self.run(LSEENDStreamingDiarizer(models: models), samples: samples)
        let wall = Date().timeIntervalSince(started)
        let r = score(result.finalTurns, uem: ref.uem, reference: ref.turns)
        let slots = Set(result.finalTurns.map(\.slot))
        print(
            "LSEEND-DER A \(r.der * 100) (miss \(r.missRate * 100) fa \(r.falseAlarmRate * 100) conf \(r.confusionRate * 100)) slots \(slots.sorted()) "
            + "wall \(wall)s for \(Double(samples.count) / 16_000)s"
        )
        #expect(!result.finalTurns.isEmpty)
        #expect(result.finalTurns.allSatisfy { !$0.isProvisional && $0.slot < maxLiveSpeakers })
        #expect(result.finalizedUpTo == result.finalizedUpTo.sorted())
        #expect(abs((result.finalizedUpTo.last ?? 0) - 240) < 1)
        #expect(r.der * 100 < Self.lseendStrictDERBaseline)
        // Provisional labels are emitted ahead of finalization (DIA-AC-03) and are all inside the stream.
        #expect(!result.provisional.isEmpty)
        #expect(result.provisional.allSatisfy { $0.isProvisional && $0.range.end <= 241 })
    }

    @Test func sortformerV2OnAMIExcerpt() async throws {
        guard let models = LocalAssets.spikeModels(), models.folders[DiarizationModelID.sortformerV2] != nil,
            let wav = LocalAssets.fixture(LocalAssets.ami240), let ref = try OfflineIntegrationTests.reference()
        else { return }
        let samples = try await DiarizationAudio.samples(of: wav)
        let result = try await Self.run(SortformerStreamingDiarizer(models: models), samples: samples)
        let r = score(result.finalTurns, uem: ref.uem, reference: ref.turns)
        print("SORTFORMER-DER A \(r.der * 100) (miss \(r.missRate * 100) fa \(r.falseAlarmRate * 100) conf \(r.confusionRate * 100))")
        #expect(!result.finalTurns.isEmpty)
        #expect(r.der * 100 < Self.sortformerStrictDERBaseline)
    }

    @Test func missingLiveModelFailsTheStream() async throws {
        let diarizer = LSEENDStreamingDiarizer(models: FolderModelManager(folders: [:]))
        let audio = AsyncStream<AudioChunk> { c in
            c.yield(AudioChunk(samples: [Float](repeating: 0, count: 1600), startSeconds: 0, source: .file))
            c.finish()
        }
        await #expect(throws: AppError.modelNotInstalled(DiarizationModelID.lseendAMI)) {
            for try await _ in diarizer.stream(audio: audio, options: DiarizationOptions()) {}
        }
    }
}

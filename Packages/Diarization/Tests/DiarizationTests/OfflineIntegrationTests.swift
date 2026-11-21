import AppCore
import Foundation
import Testing

@testable import Diarization

/// Real-model tests. They skip (return early) when the spike's `.model-cache` or the gitignored fixture wav is absent;
/// `EARMARK_MODEL_CACHE` / `EARMARK_FIXTURES_DIR` override the upward search from this file.
@Suite("Offline diarization (integration)", .serialized) struct OfflineIntegrationTests {
    static func reference() throws -> (turns: [DERScorer.Turn], uem: ClosedRange<Double>)? {
        guard let url = LocalAssets.fixture("ami-es2004a-4spk-240s/reference.rttm") else { return nil }
        return (DERScorer.parseRTTM(try String(contentsOf: url, encoding: .utf8)), 0...240)
    }

    static func toScorer(_ turns: [SpeakerTurn]) -> [DERScorer.Turn] {
        turns.map { DERScorer.Turn(speaker: "S\($0.slot)", start: $0.range.start, end: $0.range.end) }
    }

    /// Measured 2026-11-21 (M3 Pro, debug build) on ES2004a 180-420 s, headset mix, auto speaker count:
    /// strict protocol A DER 34.3 % (miss 19.0, fa 5.5, conf 9.8), lenient protocol B 22.0 %; only 3 of the 4 speakers are
    /// found (the 4-minute window gives the quietest speaker too little speech to form a cluster). The same engine on the
    /// full meeting reproduces the spike (22.2 %, 4 speakers), see `fullMeetingMatchesSpikeBaseline`.
    /// The assertion leaves about 3 points of headroom; it guards against regressions.
    static let offlineStrictDERBaseline = 37.0

    @Test func communityOneOnAMIExcerpt() async throws {
        guard let models = LocalAssets.spikeModels(), models.folders[DiarizationModelID.community1] != nil,
            let wav = LocalAssets.fixture(LocalAssets.ami240), let ref = try Self.reference()
        else { return }
        let diarizer = FluidAudioDiarizer(models: models)
        let output = try await diarizer.diarizeDetailed(file: wav, options: DiarizationOptions())
        let a = DERScorer.score(
            reference: ref.turns, hypothesis: Self.toScorer(output.turns), uem: ref.uem, collar: 0, skipOverlap: false)
        let b = DERScorer.score(
            reference: ref.turns, hypothesis: Self.toScorer(output.turns), uem: ref.uem, collar: 0.25, skipOverlap: true)
        let speakers = Set(output.turns.map(\.slot)).count
        print(
            "OFFLINE-DER A \(a.der * 100) (miss \(a.missRate * 100) fa \(a.falseAlarmRate * 100) conf \(a.confusionRate * 100)) B \(b.der * 100) speakers \(speakers)"
        )
        #expect(speakers >= 3)
        #expect(a.der * 100 < Self.offlineStrictDERBaseline)
        #expect(output.centroids.count == speakers)
        #expect(output.centroids.values.allSatisfy { $0.vector.count == 256 })
    }

    /// Equivalence check against the spike: the full ES2004a meeting must land near the spike's recorded strict DER of 22.2 %
    /// (same models, same engine, loaded through our offline-only loader instead of `prepareModels`).
    @Test func fullMeetingMatchesSpikeBaseline() async throws {
        guard let models = LocalAssets.spikeModels(), models.folders[DiarizationModelID.community1] != nil,
            let cache = LocalAssets.modelCache
        else { return }
        let wav = cache.appendingPathComponent("datasets/ami/audio/ES2004a.Mix-Headset.wav")
        let refURL = cache.appendingPathComponent("datasets/ami/ref/ES2004a.rttm")
        guard FileManager.default.fileExists(atPath: wav.path), FileManager.default.fileExists(atPath: refURL.path) else { return }
        let ref = DERScorer.parseRTTM(try String(contentsOf: refURL, encoding: .utf8))
        let turns = try await FluidAudioDiarizer(models: models).diarize(file: wav, options: DiarizationOptions())
        let a = DERScorer.score(
            reference: ref, hypothesis: Self.toScorer(turns), uem: 0...1049.354687, collar: 0, skipOverlap: false)
        print("FULL-MEETING-DER A \(a.der * 100) speakers \(Set(turns.map(\.slot)).count)")
        #expect(abs(a.der * 100 - 22.2) < 1.0)
    }

    @Test func exactSpeakerCountIsRespected() async throws {
        guard let models = LocalAssets.spikeModels(), models.folders[DiarizationModelID.community1] != nil,
            let wav = LocalAssets.fixture(LocalAssets.ami240)
        else { return }
        let diarizer = FluidAudioDiarizer(models: models)
        let turns = try await diarizer.diarize(file: wav, options: DiarizationOptions(speakerCount: .exact(2)))
        #expect(Set(turns.map(\.slot)).count <= 2)
    }

    @Test func embeddingProviderSeparatesSpeakers() async throws {
        guard let models = LocalAssets.spikeModels(), models.folders[DiarizationModelID.community1] != nil,
            let wav = LocalAssets.fixture(LocalAssets.ami240), let ref = try Self.reference()
        else { return }
        let provider = FluidSpeakerEmbeddingProvider(models: models)
        // Longest reference turn of the two most active speakers.
        var longest: [String: DERScorer.Turn] = [:]
        for turn in ref.turns where turn.end - turn.start > (longest[turn.speaker].map { $0.end - $0.start } ?? 0) {
            longest[turn.speaker] = turn
        }
        let picked = longest.values.sorted { ($0.end - $0.start) > ($1.end - $1.start) }.prefix(2)
        #expect(picked.count == 2)
        var embeddings: [SpeakerEmbedding] = []
        for turn in picked { embeddings.append(try await provider.embedding(file: wav, range: TimeRange(start: turn.start, end: turn.end))) }
        let same = try await provider.embedding(
            file: wav, range: TimeRange(start: picked[0].start, end: picked[0].start + (picked[0].end - picked[0].start) / 2))
        print("EMBED distances: different \(embeddings[0].distance(to: embeddings[1])) same-turn-half \(embeddings[0].distance(to: same))")
        #expect(embeddings[0].distance(to: embeddings[1]) > embeddings[0].distance(to: same))
    }

    @Test func missingModelThrowsAndNeverTouchesFluidAudioCache() async throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio")
        let existedBefore = FileManager.default.fileExists(atPath: support.path)
        let models = FolderModelManager(folders: [DiarizationModelID.community1: empty])
        let diarizer = FluidAudioDiarizer(models: models)
        await #expect(throws: AppError.modelNotInstalled(DiarizationModelID.community1)) {
            _ = try await diarizer.diarize(
                audio: AsyncThrowingStream { c in
                    c.yield(AudioChunk(samples: [Float](repeating: 0.1, count: 16_000), startSeconds: 0, source: .file))
                    c.finish()
                }, options: DiarizationOptions())
        }
        let uninstalled = FluidAudioDiarizer(models: FolderModelManager(folders: [:]))
        await #expect(throws: AppError.modelNotInstalled(DiarizationModelID.community1)) {
            _ = try await uninstalled.diarizeDetailed(samples: [0.1, 0.2], options: DiarizationOptions())
        }
        #expect(FileManager.default.fileExists(atPath: support.path) == existedBefore)
    }

    @Test func speakerCountMapsToClustering() {
        #expect(FluidAudioDiarizer.config(for: DiarizationOptions()).clustering.numSpeakers == nil)
        #expect(FluidAudioDiarizer.config(for: DiarizationOptions(speakerCount: .exact(3))).clustering.numSpeakers == 3)
        let range = FluidAudioDiarizer.config(for: DiarizationOptions(speakerCount: .range(min: 2, max: 5))).clustering
        #expect(range.minSpeakers == 2 && range.maxSpeakers == 5 && range.numSpeakers == nil)
    }
}

import AppCore
import AudioCapture
import Foundation
import Testing

@testable import Transcription

/// Feeds the fixture to a live engine in real time, like a microphone would.
func realTimeAudio(file: URL, seconds: Double, chunkSeconds: Double = 0.1) async throws -> (
    stream: AsyncStream<AudioChunk>, start: ContinuousClock.Instant
) {
    var samples: [Float] = []
    for try await chunk in AVFileDecoder().decode(file: file, chunkSeconds: 5, startingAt: 0) { samples += chunk.samples }
    let total = min(samples.count, Int(seconds * 16000))
    let step = Int(chunkSeconds * 16000)
    let t0 = ContinuousClock.now
    let all = samples
    let stream = AsyncStream<AudioChunk>(bufferingPolicy: .unbounded) { continuation in
        let task = Task.detached {
            var index = 0
            while index < total, !Task.isCancelled {
                let end = min(total, index + step)
                continuation.yield(
                    AudioChunk(samples: Array(all[index..<end]), startSeconds: Double(index) / 16000, source: .mic(deviceUID: nil)))
                index = end
                try? await Task.sleep(until: t0 + .milliseconds(index / 16))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
    return (stream, t0)
}

@Suite("WhisperKit live stream (real time, needs local model + fixture)", .serialized)
struct WhisperKitLiveStreamTests {
    @Test(
        "a 30 s real-time stream confirms utterances as they settle and keeps every one", .enabled(if: LocalAssets.available),
        .timeLimit(.minutes(3)))
    func confirmsAsItGoes() async throws {
        let wav = try #require(LocalAssets.fixtureWAV)
        let folder = try #require(LocalAssets.smallModel)
        let engine = WhisperKitEngine(locate: { _ in folder }, tokenizerFolder: LocalAssets.cacheRoot, defaultModel: "whisperkit/small")
        try await engine.prepare(model: "whisperkit/small")
        let (audio, t0) = try await realTimeAudio(file: wav, seconds: 30)
        var finals: [(segment: Segment, wall: Double)] = []
        var partials = 0
        let options = TranscriptionOptions(languageMode: .single("en"), useCase: .live, modelID: "whisperkit/small")
        for try await event in engine.stream(audio: audio, options: options) {
            let wall = (ContinuousClock.now - t0).secondsValue
            switch event {
            case .final(let segment): finals.append((segment, wall))
            case .partial: partials += 1
            default: break
            }
        }
        await engine.unload()
        for item in finals {
            print(
                "INTEGRATION whisper-live final media \(String(format: "%.2f-%.2f", item.segment.start, item.segment.end)) "
                    + "emitted at \(String(format: "%.2f", item.wall))s: \(item.segment.text)")
        }
        print("INTEGRATION whisper-live partials=\(partials) finals=\(finals.count)")
        let text = finals.map(\.segment.text).joined(separator: " ")
        let reference =
            "GO DO YOU HEAR BUT IN LESS THAN FIVE MINUTES THE STAIRCASE GROANED BENEATH AN EXTRAORDINARY WEIGHT AT THIS MOMENT THE WHOLE SOUL OF THE OLD MAN SEEMED CENTRED IN HIS EYES WHICH BECAME BLOODSHOT THE VEINS OF THE THROAT SWELLED HIS CHEEKS AND TEMPLES BECAME PURPLE AS THOUGH HE WAS STRUCK WITH EPILEPSY NOTHING WAS WANTING TO COMPLETE THIS BUT THE UTTERANCE OF A CRY AND THE CRY ISSUED FROM HIS PORES IF WE MAY THUS SPEAK A CRY FRIGHTFUL IN ITS SILENCE"
        let wer = wordErrorRate(reference: reference, hypothesis: text)
        print("INTEGRATION whisper-live WER(first 27.8s)=\(String(format: "%.3f", wer))")
        let beforeEnd = finals.filter { $0.wall < 29.5 }
        #expect(beforeEnd.count >= 3, "only \(beforeEnd.count) finals before the stream ended")
        #expect(finals.count >= 4)
        // Media timeline, ordered, non-overlapping.
        #expect(zip(finals, finals.dropFirst()).allSatisfy { $0.segment.end <= $1.segment.start + 0.3 })
        #expect(finals.first.map { $0.segment.start < 1.0 } == true)
        // Earlier text is not lost.
        #expect(text.uppercased().contains("STAIRCASE"))
        #expect(text.uppercased().contains("FRIGHTFUL"))
        #expect(wer < 0.35, "WER \(wer)")
        // Bounded latency: each final appears soon after the media time it ends at.
        #expect(finals.dropLast().allSatisfy { $0.wall - $0.segment.end < 12 })
    }
}

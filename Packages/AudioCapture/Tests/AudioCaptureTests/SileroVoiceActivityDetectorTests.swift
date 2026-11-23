import AppCore
import Foundation
import Testing
@testable import AudioCapture

private let sileroModel = ProcessInfo.processInfo.environment["EARMARK_SILERO_MODEL"]
private let speechFixtures = ProcessInfo.processInfo.environment["EARMARK_VAD_FIXTURES"]

@Suite("Silero speech detection", .serialized)
struct SileroVoiceActivityDetectorTests {
    @Test func hysteresisBridgesShortPausesAndRetainsTheFinalFrame() {
        let ranges = SileroVoiceActivityDetector.ranges(probabilities: [0, 0.9, 0.8, 0.1, 0.9, 0.8], samples: 6 * 4_096)
        #expect(ranges.count == 1)
        #expect(abs((ranges.first?.start ?? -1) - 0.106) < 0.000_001)
        #expect(abs((ranges.first?.end ?? -1) - 1.536) < 0.000_001)
        #expect(SileroVoiceActivityDetector.ranges(probabilities: [0, 0, 0], samples: 12_288).isEmpty)
    }

    @Test("Real neural detector retains quiet and steady speech", .enabled(if: sileroModel != nil && speechFixtures != nil),
          arguments: ["fr", "de", "es", "ja"])
    func nativeSpeech(language: String) async throws {
        let detector = try SileroVoiceActivityDetector(modelURL: URL(fileURLWithPath: #require(sileroModel)))
        let file = URL(fileURLWithPath: try #require(speechFixtures)).appendingPathComponent(language + ".wav")
        var ranges: [TimeRange] = []
        for try await chunk in AVFileDecoder().decode(file: file, chunkSeconds: 30, startingAt: 0) {
            ranges += try await detector.speechRanges(in: chunk)
        }
        print("SILERO \(language): \(ranges)")
        #expect(!ranges.isEmpty)
        let covered = ranges.reduce(0) { $0 + $1.duration }
        #expect(covered > 3)
        let silence = AudioChunk(samples: [Float](repeating: 0, count: 16_000), startSeconds: 0, source: .file)
        #expect(try await detector.speechRanges(in: silence).isEmpty)
    }
}

import AppCore
import Foundation
import Testing

@testable import AudioCapture

@Suite struct VoiceActivityDetectorTests {
    let vad = EnergyVoiceActivityDetector()

    /// First `seconds` of a fixture as one chunk, or `nil` when the (gitignored) fixture is absent.
    private func load(_ relative: String, seconds: TimeInterval) async throws -> AudioChunk? {
        guard let url = Fixtures.url(relative) else { return nil }
        var samples: [Float] = []
        for try await chunk in AVFileDecoder().decode(file: url, chunkSeconds: seconds, startingAt: 0) {
            samples = chunk.samples
            break
        }
        return AudioChunk(samples: samples, startSeconds: 0, source: .file)
    }

    @Test func syntheticBurstsAreFoundBetweenSilence() async throws {
        var samples = [Float](repeating: 0, count: 16_000 * 6)
        for second in [1, 4] {  // two 1 s amplitude-modulated bursts
            for i in 0..<16_000 {
                let t = Double(i) / 16_000
                let envelope = 0.5 + 0.5 * sin(2 * Double.pi * 4 * t)
                samples[second * 16_000 + i] = Float(0.2 * envelope * sin(2 * Double.pi * 220 * t))
            }
        }
        for i in samples.indices { samples[i] += Float.random(in: -0.0005...0.0005) }
        let ranges = try await vad.speechRanges(in: AudioChunk(samples: samples, startSeconds: 100, source: .file))
        #expect(ranges.count == 2)
        #expect(abs((ranges.first?.start ?? 0) - 1) < 0.2)  // relative to chunk start, not 100
        #expect(abs((ranges.last?.end ?? 0) - 5) < 0.3)
    }

    @Test func digitalSilenceAndEmptyHaveNoSpeech() async throws {
        let chunk = AudioChunk(samples: [Float](repeating: 0, count: 16_000 * 5), startSeconds: 0, source: .file)
        #expect(try await vad.speechRanges(in: chunk).isEmpty)
        #expect(try await vad.speechRanges(in: AudioChunk(samples: [], startSeconds: 0, source: .file)).isEmpty)
    }

    @Test func fixtureSpeechCoversMostOfTheUtterances() async throws {
        guard let chunk = try await load("en-single-librispeech/en-single-librispeech.wav", seconds: 30) else { return }
        let ranges = try await vad.speechRanges(in: chunk)
        let speech = ranges.reduce(0) { $0 + $1.duration }
        #expect(speech > 18 && speech < 30, "speech seconds \(speech)")  // utterances with 0.4 s gaps: mostly speech
        #expect(ranges.count >= 3)
    }

    @Test func fixtureSilenceRoomToneAndSteadyNoiseHaveNoSpeech() async throws {
        let names = [
            "nonspeech-music-noise-silence/silence_digital_60s.wav",
            "nonspeech-music-noise-silence/silence_roomtone_synth_60s.wav",
            "nonspeech-music-noise-silence/noise_pink_synth_60s.wav",
        ]
        for name in names {
            guard let chunk = try await load(name, seconds: 30) else { continue }
            #expect(try await vad.speechRanges(in: chunk).isEmpty, "\(name)")
        }
    }
}

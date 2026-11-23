import AppCore
import Foundation
import Testing

@testable import AudioCapture

/// Serves a fixed sample array as blocks, honouring `startingAt` like the real decoder.
private struct ArrayDecoder: AudioFileDecoder {
    let samples: [Float]
    func decode(file: URL, chunkSeconds: TimeInterval, startingAt: TimeInterval) -> AsyncThrowingStream<AudioChunk, any Error> {
        let size = max(1, Int(chunkSeconds * AudioChunk.sampleRate))
        let first = Int(startingAt * AudioChunk.sampleRate)
        let samples = samples
        return AsyncThrowingStream { continuation in
            var index = first
            while index < samples.count {
                let end = min(samples.count, index + size)
                continuation.yield(
                    AudioChunk(samples: Array(samples[index..<end]), startSeconds: Double(index) / AudioChunk.sampleRate, source: .file))
                index = end
            }
            continuation.finish()
        }
    }
    func duration(of file: URL) async throws -> TimeInterval { Double(samples.count) / AudioChunk.sampleRate }
}

@Suite struct VoiceProcessingDecoderTests {
    let url = URL(fileURLWithPath: "/tmp/none.wav")

    private func collect(_ decoder: some AudioFileDecoder, chunk: Double = 5, from start: Double = 0) async throws -> [AudioChunk] {
        var chunks: [AudioChunk] = []
        for try await block in decoder.decode(file: url, chunkSeconds: chunk, startingAt: start) { chunks.append(block) }
        return chunks
    }

    private var noisy: [Float] { SynthVoice.mix(SynthVoice.speech(seconds: 23, rmsDB: -26), noiseDB: -32, seed: 4) }

    @Test func keepsChunkTimingAndSampleCounts() async throws {
        let input = noisy
        let inner = ArrayDecoder(samples: input)
        let plain = try await collect(inner)
        let processed = try await collect(VoiceProcessingDecoder(wrapping: inner, level: .standard))
        #expect(processed.count == plain.count)
        for (a, b) in zip(plain, processed) {
            #expect(a.samples.count == b.samples.count)
            #expect(a.startSeconds == b.startSeconds)
        }
        #expect(processed.flatMap(\.samples) != input)
        // Equal to running the enhancer over the whole stream.
        let whole = VoiceEnhancer.enhance(input, level: .standard)
        #expect(processed.flatMap(\.samples) == whole)
    }

    @Test func offReturnsTheOriginalBlocks() async throws {
        let input = noisy
        let out = try await collect(VoiceProcessingDecoder(wrapping: ArrayDecoder(samples: input), level: .off))
        #expect(out.flatMap(\.samples) == input)
    }

    @Test func resumeStartsAtTheCheckpointWithTheSameLength() async throws {
        let input = noisy
        let decoder = VoiceProcessingDecoder(wrapping: ArrayDecoder(samples: input), level: .standard)
        let resumed = try await collect(decoder, from: 10)
        #expect(abs((resumed.first?.startSeconds ?? 0) - 10) < 1e-9)
        #expect(resumed.flatMap(\.samples).count == input.count - 10 * 16_000)
        // Deterministic for the same start point.
        let again = try await collect(decoder, from: 10)
        #expect(resumed.flatMap(\.samples) == again.flatMap(\.samples))
        // Close to the uninterrupted run once the warm-up has passed (the pre-roll re-estimates the noise floor).
        let full = try await collect(decoder).flatMap(\.samples)
        let tail = Array(full[(10 * 16_000 + 16_000 * 6)...])
        let resumedTail = Array(resumed.flatMap(\.samples)[(16_000 * 6)...])
        #expect(SynthVoice.snr(resumedTail, reference: tail) > 15)
    }

    @Test func durationIsPassedThrough() async throws {
        let decoder = VoiceProcessingDecoder(wrapping: ArrayDecoder(samples: noisy), level: .light)
        #expect(try await decoder.duration(of: url) == 23)
    }

    @Test func cancellationStopsTheStream() async throws {
        let decoder = VoiceProcessingDecoder(wrapping: ArrayDecoder(samples: noisy), level: .strong)
        let task = Task { () -> Int in
            var count = 0
            for try await _ in decoder.decode(file: url, chunkSeconds: 1, startingAt: 0) {
                count += 1
                try await Task.sleep(for: .milliseconds(20))
            }
            return count
        }
        task.cancel()
        let count = (try? await task.value) ?? 0
        #expect(count < 23)
    }
}

import AppCore
import AudioCapture
import Foundation
import Testing

@testable import Transcription

/// Decoder over fixed samples (blocks of `chunkSeconds`), honouring `startingAt`.
private struct SamplesDecoder: AudioFileDecoder {
    let samples: [Float]
    func decode(file: URL, chunkSeconds: TimeInterval, startingAt: TimeInterval) -> AsyncThrowingStream<AudioChunk, any Error> {
        let size = Int(chunkSeconds * AudioChunk.sampleRate)
        let samples = samples
        return AsyncThrowingStream { continuation in
            var index = Int(startingAt * AudioChunk.sampleRate)
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

private func noise(_ count: Int, amplitude: Float) -> [Float] {
    var state: UInt64 = 0x1234_5678_9ABC_DEF1
    return (0..<count).map { _ in
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return amplitude * Float(Double(state >> 11) / Double(1 << 53) * 2 - 1)
    }
}

/// Speech-like bursts: a few harmonics gated at 3 Hz.
private func speechLike(seconds: Double) -> [Float] {
    (0..<Int(seconds * 16_000)).map { i in
        let t = Double(i) / 16_000
        let gate = max(0, sin(2 * Double.pi * 0.5 * t)) > 0.3 ? 1.0 : 0
        return Float(gate * 0.15 * (sin(2 * Double.pi * 200 * t) + 0.5 * sin(2 * Double.pi * 600 * t) + 0.3 * sin(2 * Double.pi * 1_300 * t)))
    }
}

@Suite("Voice processing in the file pipeline")
struct VoiceProcessingPipelineTests {
    private let file = URL(fileURLWithPath: "/tmp/none.wav")

    private func options(_ level: VoiceProcessingLevel) -> TranscriptionOptions {
        TranscriptionOptions(languageMode: .single("en"), useCase: .file, voiceProcessing: level)
    }

    @Test("same checkpoints, chunk times and durations as without processing")
    func timingUnchanged() async throws {
        let audio = speechLike(seconds: 70)
        let pipeline = FileTranscriptionPipeline(decoder: SamplesDecoder(samples: audio), vad: EnergyVoiceActivityDetector())
        let plainEngine = ChunkEngine()
        let plain = try await collect(pipeline.run(file: file, options: options(.off), engine: plainEngine))
        let processedEngine = ChunkEngine()
        let processed = try await collect(pipeline.run(file: file, options: options(.standard), engine: processedEngine))
        #expect(processed.checkpoints == plain.checkpoints)
        #expect(processed.progress.last == plain.progress.last)
        #expect(processedEngine.calls.map(\.duration).count == plainEngine.calls.map(\.duration).count)
        // Cut points follow the (similar) pauses; the media time covered is the same.
        let processedTotal: Double = processedEngine.calls.map(\.duration).reduce(0, +)
        let plainTotal: Double = plainEngine.calls.map(\.duration).reduce(0, +)
        #expect(abs(processedTotal - plainTotal) < 1e-6)
    }

    @Test("the engine and VAD see processed samples when enabled, originals when off")
    func engineSeesProcessedAudio() async throws {
        // A DC offset plus a tone: the high-pass removes the offset, so processed audio has a different mean.
        let audio: [Float] = (0..<(16_000 * 8)).map { (i: Int) -> Float in
            let phase: Double = 2 * Double.pi * 440 * Double(i) / 16_000
            return 0.2 + 0.1 * Float(sin(phase))
        }
        let seen = SampleLog()
        let vad = ScriptedVAD { chunk in
            seen.record(chunk.samples)
            return [TimeRange(start: 0, end: chunk.duration)]
        }
        let pipeline = FileTranscriptionPipeline(decoder: SamplesDecoder(samples: audio), vad: vad)
        _ = try await collect(pipeline.run(file: file, options: options(.off), engine: ChunkEngine()))
        let offMean = seen.meanOfLast()
        seen.reset()
        _ = try await collect(pipeline.run(file: file, options: options(.light), engine: ChunkEngine()))
        let onMean = seen.meanOfLast()
        #expect(offMean > 0.19)
        #expect(abs(onMean) < 0.05)
    }

    @Test("noise-only audio still makes no engine calls with processing on")
    func noiseOnlyStaysSilent() async throws {
        let audio = noise(16_000 * 40, amplitude: 0.05)
        let pipeline = FileTranscriptionPipeline(decoder: SamplesDecoder(samples: audio), vad: EnergyVoiceActivityDetector())
        for level in [VoiceProcessingLevel.off, .light, .standard, .strong] {
            let engine = ChunkEngine()
            _ = try await collect(pipeline.run(file: file, options: options(level), engine: engine))
            #expect(engine.calls.isEmpty, "\(level) made engine calls on noise")
        }
    }

    @Test("resume with processing continues at the checkpoint without duplicating chunks")
    func resumeWithProcessing() async throws {
        let audio = speechLike(seconds: 100)
        let pipeline = FileTranscriptionPipeline(decoder: SamplesDecoder(samples: audio), vad: nil)
        let full = try await collect(pipeline.run(file: file, options: options(.standard), engine: ChunkEngine()))
        let checkpoint = JobCheckpoint(lastCompletedChunk: 1, mediaTime: 60)
        let resumed = try await collect(
            pipeline.run(file: file, options: options(.standard), engine: ChunkEngine(), resumeFrom: checkpoint))
        #expect(resumed.checkpoints.first == JobCheckpoint(lastCompletedChunk: 2, mediaTime: 90))
        #expect(resumed.segments.map(\.start) == full.segments.map(\.start).filter { $0 >= 60 })
    }
}

private final class SampleLog: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [[Float]] = []
    func record(_ samples: [Float]) {
        lock.lock()
        chunks.append(samples)
        lock.unlock()
    }
    func reset() {
        lock.lock()
        chunks = []
        lock.unlock()
    }
    /// Mean of the second half of the last recorded chunk (past any start-up transient).
    func meanOfLast() -> Float {
        lock.lock()
        defer { lock.unlock() }
        guard let last = chunks.last else { return 0 }
        let half = last[(last.count / 2)...]
        return half.reduce(0, +) / Float(max(1, half.count))
    }
}

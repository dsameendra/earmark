import AppCore
import AudioCapture
import Foundation

/// Audio helpers shared by the offline engines.
public enum DiarizationAudio {
    /// Decodes a whole file to 16 kHz mono Float32 samples (via `AVFileDecoder`).
    public static func samples(of file: URL, decoder: any AudioFileDecoder = AVFileDecoder()) async throws -> [Float] {
        try await collect(decoder.decode(file: file, chunkSeconds: 30, startingAt: 0))
    }

    /// Concatenates a chunk stream into one sample buffer, honouring cancellation. Gaps between chunks are not padded.
    public static func collect(_ audio: AsyncThrowingStream<AudioChunk, any Error>) async throws -> [Float] {
        var out: [Float] = []
        for try await chunk in audio {
            try Task.checkCancellation()
            out.append(contentsOf: chunk.samples)
        }
        return out
    }

    /// The samples of `range` (media seconds) out of a buffer that starts at `startSeconds`, clamped to the buffer.
    public static func slice(_ samples: [Float], startSeconds: TimeInterval = 0, range: TimeRange) -> [Float] {
        let rate = AudioChunk.sampleRate
        let lower = max(0, Int(((range.start - startSeconds) * rate).rounded()))
        let upper = min(samples.count, Int(((range.end - startSeconds) * rate).rounded()))
        guard lower < upper else { return [] }
        return Array(samples[lower..<upper])
    }
}

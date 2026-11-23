import AppCore
import Foundation

/// An ``AudioFileDecoder`` that runs every decoded block through a ``VoiceEnhancer`` (SCR-014).
///
/// Blocks keep their original `startSeconds` and sample counts, so media time, word timestamps, checkpoints and chunk cuts are
/// unaffected; only the sample values change. Decoding stays pull-based and bounded: the enhancer holds about 256 samples of
/// latency, so a block is released once the next one (or the end of the stream) has been read.
///
/// ### Resume
/// When decoding starts after 0 (a checkpoint), the enhancer is warmed up on ``preRollSeconds`` of audio before that point,
/// which is discarded. The noise floor therefore does not restart cold, though the result can differ slightly from an
/// uninterrupted run (state is not journaled); it is deterministic for a given start point.
public struct VoiceProcessingDecoder: AudioFileDecoder {
    public static let preRollSeconds: TimeInterval = 1.0

    private let inner: any AudioFileDecoder
    private let level: VoiceProcessingLevel

    public init(wrapping inner: any AudioFileDecoder, level: VoiceProcessingLevel) {
        self.inner = inner
        self.level = level
    }

    public func decode(file: URL, chunkSeconds: TimeInterval, startingAt: TimeInterval) -> AsyncThrowingStream<AudioChunk, any Error> {
        guard level != .off else { return inner.decode(file: file, chunkSeconds: chunkSeconds, startingAt: startingAt) }
        let wanted = max(0, startingAt)
        let from = max(0, wanted - Self.preRollSeconds)
        let upstream = inner.decode(file: file, chunkSeconds: chunkSeconds, startingAt: from)
        let chunkSamples = Int((chunkSeconds * AudioChunk.sampleRate).rounded())
        let session = EnhanceSession(
            upstream: upstream, level: level, chunkSamples: chunkSamples, resumeAt: wanted > 0 ? wanted : nil)
        return AsyncThrowingStream(unfolding: { try await session.next() })
    }

    public func duration(of file: URL) async throws -> TimeInterval { try await inner.duration(of: file) }
}

/// Wraps the upstream iterator; only ever used by `EnhanceSession`, one call at a time.
private final class UpstreamBox: @unchecked Sendable {
    private var iterator: AsyncThrowingStream<AudioChunk, any Error>.Iterator
    init(_ stream: AsyncThrowingStream<AudioChunk, any Error>) { iterator = stream.makeAsyncIterator() }
    func next() async throws -> AudioChunk? { try await iterator.next() }
}

private actor EnhanceSession {
    private let upstream: UpstreamBox
    private let enhancer: VoiceEnhancer
    private let chunkSamples: Int
    private let resumeAt: TimeInterval?
    private var ready: [Float] = []
    private var source: AudioSourceTag = .file
    private var upstreamDone = false
    /// Pre-roll samples still to discard from the front of the output (decided when the first block arrives).
    private var dropRemaining: Int?
    /// Media time of the first emitted sample and the number of samples emitted so far.
    private var originStart: TimeInterval?
    private var emitted = 0

    init(upstream: AsyncThrowingStream<AudioChunk, any Error>, level: VoiceProcessingLevel, chunkSamples: Int, resumeAt: TimeInterval?) {
        self.upstream = UpstreamBox(upstream)
        enhancer = VoiceEnhancer(level: level)
        self.chunkSamples = max(1, chunkSamples)
        self.resumeAt = resumeAt
    }

    /// Emits blocks of `chunkSamples` (the last one shorter), re-blocked after the pre-roll is discarded so a resumed run cuts
    /// at the same grid as an uninterrupted one would from the checkpoint.
    func next() async throws -> AudioChunk? {
        while true {
            try Task.checkCancellation()
            if ready.count >= chunkSamples || (upstreamDone && !ready.isEmpty) {
                let count = min(chunkSamples, ready.count)
                let samples = Array(ready.prefix(count))
                ready.removeFirst(count)
                let start = (originStart ?? 0) + Double(emitted) / AudioChunk.sampleRate
                emitted += count
                return AudioChunk(samples: samples, startSeconds: start, source: source)
            }
            if upstreamDone { return nil }
            if let block = try await upstream.next() {
                var output = enhancer.process(block.samples)
                if dropRemaining == nil {
                    // The first block starts at or before the resume point; everything before the resume point is pre-roll.
                    source = block.source
                    let skip = resumeAt.map { max(0, Int((($0 - block.startSeconds) * AudioChunk.sampleRate).rounded())) } ?? 0
                    dropRemaining = skip
                    originStart = block.startSeconds + Double(skip) / AudioChunk.sampleRate
                }
                if let drop = dropRemaining, drop > 0 {
                    let cut = min(drop, output.count)
                    output.removeFirst(cut)
                    dropRemaining = drop - cut
                }
                ready.append(contentsOf: output)
            } else {
                upstreamDone = true
                var tail = enhancer.finish()
                if let drop = dropRemaining, drop > 0 {
                    let cut = min(drop, tail.count)
                    tail.removeFirst(cut)
                    dropRemaining = drop - cut
                }
                ready.append(contentsOf: tail)
            }
        }
    }
}

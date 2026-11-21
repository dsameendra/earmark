import AppCore
import Foundation

/// A simple, tunable energy-based ``VoiceActivityDetector``.
///
/// The chunk is split into short frames and the RMS level (dBFS) of each frame is computed. A frame is speech when it is
/// louder than both an absolute floor and an adaptive noise floor (a low percentile of the chunk's frame levels) plus a
/// margin. Chunks whose level barely varies (digital silence, room tone, steady noise) are treated as stationary and
/// contain no speech. Frame decisions are merged across short gaps, and short blips are dropped.
///
/// Limitations: it cannot tell speech from other dynamic sounds such as music; use it to find pauses for chunking and as
/// a pre-filter, not as a classifier.
public struct EnergyVoiceActivityDetector: VoiceActivityDetector {
    /// Tunable parameters. Defaults suit 16 kHz close-talk speech.
    public struct Configuration: Sendable, Equatable {
        /// Analysis frame length in seconds.
        public var frameSeconds: TimeInterval = 0.02
        /// Frames quieter than this (dBFS) are never speech.
        public var absoluteFloorDB: Float = -50
        /// A frame must exceed the adaptive noise floor by this many dB.
        public var marginDB: Float = 10
        /// Percentile (0...1) of frame levels used as the noise floor estimate.
        public var noiseFloorPercentile: Float = 0.1
        /// If the spread between the 90th percentile and the noise floor is below this, the chunk is stationary (no speech).
        public var minDynamicRangeDB: Float = 12
        /// Speech runs shorter than this are discarded.
        public var minSpeechSeconds: TimeInterval = 0.15
        /// Gaps shorter than this between speech runs are bridged.
        public var maxGapSeconds: TimeInterval = 0.3
        /// Padding added to both ends of every range (clamped to the chunk).
        public var paddingSeconds: TimeInterval = 0.05
        public init() {}
    }

    /// The active configuration.
    public var configuration: Configuration

    /// Creates a detector.
    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    public func speechRanges(in chunk: AudioChunk) async throws -> [TimeRange] {
        analyze(samples: chunk.samples, sampleRate: AudioChunk.sampleRate)
    }

    /// Synchronous core, exposed for callers that already hold raw samples. Ranges are in seconds from the first sample.
    public func analyze(samples: [Float], sampleRate: Double) -> [TimeRange] {
        let cfg = configuration
        let frameLength = max(1, Int(cfg.frameSeconds * sampleRate))
        let frameCount = samples.count / frameLength
        guard frameCount > 0 else { return [] }

        var levels = [Float](repeating: -120, count: frameCount)
        samples.withUnsafeBufferPointer { buffer in
            for frame in 0..<frameCount {
                var sum: Float = 0
                for sample in buffer[frame * frameLength..<(frame + 1) * frameLength] { sum += sample * sample }
                let rms = (sum / Float(frameLength)).squareRoot()
                levels[frame] = rms > 1e-6 ? 20 * log10(rms) : -120
            }
        }
        let sorted = levels.sorted()
        func percentile(_ fraction: Float) -> Float { sorted[min(frameCount - 1, Int(Float(frameCount - 1) * fraction))] }
        let noiseFloor = percentile(cfg.noiseFloorPercentile)
        guard percentile(0.9) - noiseFloor >= cfg.minDynamicRangeDB else { return [] }
        let threshold = max(cfg.absoluteFloorDB, noiseFloor + cfg.marginDB)

        // Runs of speech frames, bridging short gaps.
        let maxGapFrames = Int((cfg.maxGapSeconds / cfg.frameSeconds).rounded())
        var runs: [(start: Int, end: Int)] = []
        for (index, level) in levels.enumerated() where level > threshold {
            if let last = runs.last, index - last.end <= maxGapFrames + 1 {
                runs[runs.count - 1].end = index
            } else {
                runs.append((index, index))
            }
        }
        let total = Double(samples.count) / sampleRate
        return runs.compactMap { run in
            let start = Double(run.start) * cfg.frameSeconds
            let end = Double(run.end + 1) * cfg.frameSeconds
            guard end - start >= cfg.minSpeechSeconds else { return nil }
            return TimeRange(start: max(0, start - cfg.paddingSeconds), end: min(total, end + cfg.paddingSeconds))
        }
    }
}

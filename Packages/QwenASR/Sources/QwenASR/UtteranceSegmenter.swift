import AppCore
import Foundation

/// One run of speech cut out of a longer stream, with its position on the media timeline.
struct Utterance: Sendable, Equatable {
    var samples: [Float]
    var start: TimeInterval
    var duration: TimeInterval { Double(samples.count) / AudioChunk.sampleRate }
    var end: TimeInterval { start + duration }
}

/// Cuts a continuous 16 kHz stream into utterances using a ``VoiceActivityDetector``.
///
/// Used for both file and live input so memory stays bounded: audio is appended as it arrives, speech runs that are followed
/// by at least ``minSilence`` of quiet (or reach ``maxUtterance``) are released as closed utterances, and everything before
/// them is dropped. Qwen3-ASR gets one utterance per call, which also gives each segment usable start/end times (the model
/// returns no word timings).
struct UtteranceSegmenter: Sendable {
    let vad: any VoiceActivityDetector
    /// Quiet needed after speech before an utterance counts as finished.
    var minSilence: TimeInterval = 0.5
    /// Hard cap on one utterance (the model is trained on clips of up to ~30 s).
    var maxUtterance: TimeInterval = 20
    /// Shorter speech runs are dropped as clicks.
    var minSpeech: TimeInterval = 0.25
    /// Context kept before the detected speech start.
    var padding: TimeInterval = 0.15

    private(set) var buffer: [Float] = []
    private(set) var bufferStart: TimeInterval = 0
    private var started = false

    init(vad: any VoiceActivityDetector) { self.vad = vad }

    var bufferedSeconds: TimeInterval { Double(buffer.count) / AudioChunk.sampleRate }
    var bufferEnd: TimeInterval { bufferStart + bufferedSeconds }

    mutating func append(_ chunk: AudioChunk) {
        if !started {
            started = true
            bufferStart = chunk.startSeconds
        } else if buffer.isEmpty {
            bufferStart = chunk.startSeconds
        }
        buffer.append(contentsOf: chunk.samples)
    }

    /// Releases utterances that are complete (or all remaining speech when `final`).
    mutating func drain(final: Bool) async -> [Utterance] {
        guard !buffer.isEmpty else { return [] }
        let chunk = AudioChunk(samples: buffer, startSeconds: bufferStart, source: .file)
        let raw = (try? await vad.speechRanges(in: chunk)) ?? []
        let ranges = merge(raw)
        let total = bufferedSeconds
        var out: [Utterance] = []
        var consumed = 0.0
        var open: TimeRange?
        for range in ranges {
            var current = range
            // Split overlong runs at the cap.
            while current.duration > maxUtterance {
                out.append(slice(TimeRange(start: current.start, end: current.start + maxUtterance)))
                consumed = current.start + maxUtterance
                current = TimeRange(start: consumed, end: current.end)
            }
            if final || total - current.end >= minSilence {
                if current.duration >= minSpeech { out.append(slice(current)) }
                consumed = max(consumed, current.end)
            } else {
                open = current
            }
        }
        // Drop what has been released; keep the open run (with padding) or a short tail of quiet.
        let keepFrom: TimeInterval
        if let open {
            keepFrom = max(consumed, open.start - padding)
        } else if final {
            keepFrom = total
        } else {
            keepFrom = max(consumed, total - 1.0)
        }
        let drop = min(buffer.count, max(0, Int(keepFrom * AudioChunk.sampleRate)))
        if drop > 0 {
            buffer.removeFirst(drop)
            bufferStart += Double(drop) / AudioChunk.sampleRate
        }
        return out
    }

    /// The speech run still in progress (for partial results), if any.
    func openUtterance() async -> Utterance? {
        guard !buffer.isEmpty else { return nil }
        let chunk = AudioChunk(samples: buffer, startSeconds: bufferStart, source: .file)
        let ranges = merge((try? await vad.speechRanges(in: chunk)) ?? [])
        guard let last = ranges.last, bufferedSeconds - last.end < minSilence, last.duration >= minSpeech else { return nil }
        return slice(last)
    }

    private func merge(_ raw: [TimeRange]) -> [TimeRange] {
        var merged: [TimeRange] = []
        for range in raw.sorted(by: { $0.start < $1.start }) {
            if var last = merged.last, range.start - last.end < minSilence {
                last.end = max(last.end, range.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    private func slice(_ range: TimeRange) -> Utterance {
        let lower = min(buffer.count, max(0, Int((range.start - padding) * AudioChunk.sampleRate)))
        let upper = min(buffer.count, max(lower, Int((range.end + padding) * AudioChunk.sampleRate)))
        return Utterance(samples: Array(buffer[lower..<upper]), start: bufferStart + Double(lower) / AudioChunk.sampleRate)
    }
}

import AppCore
import Foundation

/// Energy-VAD segmentation of a live 16 kHz mono stream into utterances (used by ``WhisperKitEngine/stream``).
///
/// Audio is appended chunk by chunk; the segmenter classifies fixed frames as speech or silence against an adaptive noise
/// floor and reports when the buffered utterance should be finalised:
/// - after `endpointSilence` of trailing silence,
/// - after the shorter `softEndpointSilence` once the utterance is at least `softMinUtterance` long (natural sentence
///   pauses), or
/// - when the utterance reaches `maxUtterance`, in which case it is cut at the quietest frame so no word is split mid-way.
///
/// Buffered audio is therefore bounded by `maxUtterance` plus the endpoint silence, and leading silence is discarded.
struct StreamSegmenter: Sendable {
    struct Config: Sendable {
        var frameSeconds: TimeInterval = 0.05
        var endpointSilence: TimeInterval = 0.8
        var softEndpointSilence: TimeInterval = 0.3
        var softMinUtterance: TimeInterval = 3
        var maxUtterance: TimeInterval = 8
        var preroll: TimeInterval = 0.3
        var tailPad: TimeInterval = 0.2
        /// Utterances with less speech than this are treated as noise and dropped.
        var minSpeech: TimeInterval = 0.25
        var absoluteThreshold: Float = 0.006
        var floorMultiplier: Float = 3.5
    }

    let config: Config
    private let sampleRate = AppCore.AudioChunk.sampleRate
    private let frameLength: Int

    /// Buffered samples; index 0 is at media time `bufferStart`.
    private(set) var buffer: [Float] = []
    private(set) var bufferStart: TimeInterval = 0
    private var started = false
    private var rms: [Float] = []
    private var speech: [Bool] = []
    private var noiseFloor: Float = 0.003

    init(config: Config = Config()) {
        self.config = config
        frameLength = max(1, Int(config.frameSeconds * AppCore.AudioChunk.sampleRate))
    }

    var bufferSeconds: TimeInterval { Double(buffer.count) / sampleRate }
    /// Media time at the end of the buffered audio.
    var endTime: TimeInterval { bufferStart + bufferSeconds }

    // MARK: - Input

    mutating func append(_ chunk: AppCore.AudioChunk) {
        if !started {
            started = true
            bufferStart = chunk.startSeconds
        }
        buffer.append(contentsOf: chunk.samples)
        while (rms.count + 1) * frameLength <= buffer.count {
            let start = rms.count * frameLength
            var sum: Float = 0
            for index in start..<(start + frameLength) { sum += buffer[index] * buffer[index] }
            let level = (sum / Float(frameLength)).squareRoot()
            let isSpeech = level > max(config.absoluteThreshold, noiseFloor * config.floorMultiplier)
            if isSpeech {
                noiseFloor *= 1.001
            } else {
                noiseFloor = level < noiseFloor ? level : noiseFloor * 0.95 + level * 0.05
            }
            rms.append(level)
            speech.append(isSpeech)
        }
        if firstSpeechFrame == nil { discardLeadingSilence() }
    }

    // MARK: - State

    private var firstSpeechFrame: Int? { speech.firstIndex(of: true) }
    private var lastSpeechFrame: Int? { speech.lastIndex(of: true) }

    /// Whether the buffer holds a pending utterance.
    var hasSpeech: Bool { firstSpeechFrame != nil }

    /// Index (in `buffer`) where the pending utterance starts, including pre-roll.
    var utteranceStart: Int {
        guard let first = firstSpeechFrame else { return buffer.count }
        return max(0, first * frameLength - Int(config.preroll * sampleRate))
    }

    /// Seconds of speech audio (first to last speech frame) in the pending utterance.
    var speechSeconds: TimeInterval {
        guard let first = firstSpeechFrame, let last = lastSpeechFrame else { return 0 }
        return Double((last + 1 - first) * frameLength) / sampleRate
    }

    /// Samples of the pending utterance up to (excluding) `end`.
    func samples(upTo end: Int) -> ArraySlice<Float> {
        let start = min(utteranceStart, end)
        return buffer[start..<min(end, buffer.count)]
    }

    /// Media time of `index` in the buffer.
    func time(at index: Int) -> TimeInterval { bufferStart + Double(index) / sampleRate }

    // MARK: - Decisions

    /// End index to finalise through, or `nil` while the utterance is still open.
    func finalizationPoint() -> Int? {
        guard let first = firstSpeechFrame, let last = lastSpeechFrame else { return nil }
        let lastEnd = (last + 1) * frameLength
        let trailing = Double(buffer.count - lastEnd) / sampleRate
        let length = Double(lastEnd - first * frameLength) / sampleRate
        let endpoint = trailing >= config.endpointSilence || (trailing >= config.softEndpointSilence && length >= config.softMinUtterance)
        if endpoint { return min(buffer.count, lastEnd + Int(config.tailPad * sampleRate)) }
        guard Double(buffer.count - first * frameLength) / sampleRate >= config.maxUtterance else { return nil }
        // Too long without a pause: cut at the quietest frame in the later half so the next utterance starts cleanly.
        let from = first + Int(config.maxUtterance * 0.5 / config.frameSeconds)
        let to = max(from + 1, rms.count - Int(0.5 / config.frameSeconds))
        guard from < rms.count else { return buffer.count }
        let range = from..<min(to, rms.count)
        let quietest = range.min { rms[$0] < rms[$1] } ?? range.lowerBound
        return (quietest + 1) * frameLength
    }

    // MARK: - Mutation

    /// Drops everything before `index` (frame aligned) and re-evaluates the remaining frames.
    mutating func consume(upTo index: Int) {
        let drop = min(buffer.count, (index / frameLength) * frameLength)
        guard drop > 0 else { return }
        buffer.removeFirst(drop)
        let frames = min(drop / frameLength, rms.count)
        rms.removeFirst(frames)
        speech.removeFirst(frames)
        bufferStart += Double(drop) / sampleRate
        if firstSpeechFrame == nil { discardLeadingSilence() }
    }

    /// Keeps only the pre-roll while no speech has been seen, bounding memory during long silences.
    private mutating func discardLeadingSilence() {
        let keep = Int(config.preroll * sampleRate)
        guard buffer.count > keep + frameLength else { return }
        let drop = ((buffer.count - keep) / frameLength) * frameLength
        buffer.removeFirst(drop)
        let frames = min(drop / frameLength, rms.count)
        rms.removeFirst(frames)
        speech.removeFirst(frames)
        bufferStart += Double(drop) / sampleRate
    }
}

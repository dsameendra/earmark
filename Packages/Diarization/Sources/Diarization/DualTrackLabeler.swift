import AppCore
import AudioCapture
import Foundation

/// Who a dual-track turn belongs to.
public enum DualTrackSpeaker: Hashable, Sendable {
    /// The local user (mic track).
    case you
    /// A diarized remote speaker (engine slot; map through ``LiveReconciliation`` / the speaker table for display).
    case remote(slot: Int)
}

/// A labelled turn of a meeting.
public struct DualTrackTurn: Hashable, Sendable {
    public var range: TimeRange
    public var speaker: DualTrackSpeaker
    public var isProvisional: Bool
    public init(range: TimeRange, speaker: DualTrackSpeaker, isProvisional: Bool = false) {
        self.range = range
        self.speaker = speaker
        self.isProvisional = isProvisional
    }
}

// MARK: - Bleed suppression

/// Mic speech that coincides with remote speech: the only place where loudspeaker bleed can create a false "You".
public struct BleedCandidate: Sendable {
    /// The contested mic span (media seconds).
    public var range: TimeRange
    /// Mic samples of `range` (16 kHz mono; the AEC-processed mic when the capture layer provides one).
    public var samples: [Float]
    /// Remote turns that overlap `range`.
    public var remoteTurns: [SpeakerTurn]
    public init(range: TimeRange, samples: [Float], remoteTurns: [SpeakerTurn]) {
        self.range = range
        self.samples = samples
        self.remoteTurns = remoteTurns
    }
}

public enum BleedVerdict: Sendable, Hashable {
    /// Genuine local speech; stays "You".
    case keep
    /// Remote speech leaking into the mic; removed from "You".
    case suppress
}

/// Decides whether concurrent mic speech is real or echo bleed.
///
/// Time overlap alone is **never** a reason to delete mic speech (DIA-AC-08): the labeler only asks about spans that
/// overlap remote speech, and implementations should keep a span unless they have positive evidence it is bleed.
/// Echo cancellation (Voice Processing I/O) is the first line of defence and lives in the capture layer; this protocol is
/// the second line, a content check.
public protocol BleedSuppressor: Sendable {
    func verdict(for candidate: BleedCandidate) async -> BleedVerdict
}

/// Keeps every span (the default when no voice profile is available).
public struct KeepAllBleedSuppressor: BleedSuppressor {
    public init() {}
    public func verdict(for candidate: BleedCandidate) async -> BleedVerdict { .keep }
}

/// Voice-profile-distance bleed check.
///
/// For a contested span it embeds the mic audio and compares it with the user's voice profile and with the centroids of
/// the remote speakers talking at that moment:
/// - with a profile: **suppress only if** the span is farther than ``Configuration/youThreshold`` from the user's voice
///   **and** clearly nearer (by ``Configuration/margin``) to an overlapping remote speaker. A span that is far from the
///   user but also unlike every remote speaker (a third voice, a noisy mix) is kept.
/// - without a profile: keep everything, unless ``Configuration/remoteOnlyThreshold`` is set, in which case a span that is
///   within that distance of an overlapping remote centroid is suppressed.
/// - spans shorter than ``Configuration/minSpanSeconds`` and embedding failures are kept.
///
/// Distances are cosine distances of the Community-1 WeSpeaker space. Spike data (same-person max 0.076, different-person
/// min 0.678, n = 4, one meeting series) motivates the 0.45 default; it is uncalibrated on real loudspeaker bleed.
public struct VoiceProfileBleedSuppressor: BleedSuppressor {
    public struct Configuration: Sendable, Hashable {
        public var youThreshold: Double
        public var margin: Double
        public var minSpanSeconds: TimeInterval
        public var remoteOnlyThreshold: Double?
        public init(
            youThreshold: Double = 0.45, margin: Double = 0.05, minSpanSeconds: TimeInterval = 0.8, remoteOnlyThreshold: Double? = nil
        ) {
            self.youThreshold = youThreshold
            self.margin = margin
            self.minSpanSeconds = minSpanSeconds
            self.remoteOnlyThreshold = remoteOnlyThreshold
        }
    }

    private let embedder: any SpeakerSpanEmbedder
    private let youProfile: SpeakerEmbedding?
    private let remoteCentroids: [Int: SpeakerEmbedding]
    private let configuration: Configuration

    /// - Parameters:
    ///   - youProfile: The user's stored voice profile embedding, if any.
    ///   - remoteCentroids: Remote speaker centroids by slot (e.g. from ``OfflineDiarization/centroids``).
    public init(
        embedder: any SpeakerSpanEmbedder, youProfile: SpeakerEmbedding?, remoteCentroids: [Int: SpeakerEmbedding],
        configuration: Configuration = Configuration()
    ) {
        self.embedder = embedder
        self.youProfile = youProfile
        self.remoteCentroids = remoteCentroids
        self.configuration = configuration
    }

    public func verdict(for candidate: BleedCandidate) async -> BleedVerdict {
        guard candidate.range.duration >= configuration.minSpanSeconds,
            youProfile != nil || configuration.remoteOnlyThreshold != nil,
            let span = try? await embedder.embedding(samples: candidate.samples)
        else { return .keep }
        let nearestRemote = Set(candidate.remoteTurns.map(\.slot)).compactMap { remoteCentroids[$0] }
            .map { span.distance(to: $0) }.min()
        if let youProfile {
            let toYou = span.distance(to: youProfile)
            guard toYou > configuration.youThreshold, let nearestRemote, nearestRemote + configuration.margin < toYou else { return .keep }
            return .suppress
        }
        if let limit = configuration.remoteOnlyThreshold, let nearestRemote, nearestRemote <= limit { return .suppress }
        return .keep
    }
}

// MARK: - Labeler

/// Labels a meeting's tracks: the mic track is "You" (via voice activity detection), the remote track is diarized.
///
/// Only the remote track goes through a diarizer; the mic track never does (DIA-AC-07). Mic speech that overlaps remote
/// speech is passed to a ``BleedSuppressor`` in isolation; mic speech with no remote activity is always "You", and a
/// suppressed span removes only its own overlapped part, so a genuine interruption of the remote speaker survives
/// unless the suppressor positively identifies it as bleed.
public struct DualTrackLabeler: Sendable {
    private let vad: any VoiceActivityDetector
    private let suppressor: any BleedSuppressor
    private let minYouSeconds: TimeInterval
    private let mergeGapSeconds: TimeInterval

    /// - Parameters:
    ///   - vad: Mic voice activity detector. FluidAudio's Silero VAD is not used (it is not in the model catalog and would
    ///     download); the default is AudioCapture's energy VAD.
    ///   - suppressor: Bleed check for overlapped spans (default keeps all).
    public init(
        vad: any VoiceActivityDetector = EnergyVoiceActivityDetector(), suppressor: any BleedSuppressor = KeepAllBleedSuppressor(),
        minYouSeconds: TimeInterval = 0.25, mergeGapSeconds: TimeInterval = 0.2
    ) {
        self.vad = vad
        self.suppressor = suppressor
        self.minYouSeconds = minYouSeconds
        self.mergeGapSeconds = mergeGapSeconds
    }

    /// Mic speech spans in media time.
    public func micSpeech(in mic: AudioChunk) async throws -> [TimeRange] {
        try await vad.speechRanges(in: mic).map { TimeRange(start: $0.start + mic.startSeconds, end: $0.end + mic.startSeconds) }
    }

    /// Labels a mic chunk against remote turns.
    public func label(mic: AudioChunk, remoteTurns: [SpeakerTurn]) async throws -> [DualTrackTurn] {
        await label(
            micSpans: try await micSpeech(in: mic), micSamples: mic.samples, micStartSeconds: mic.startSeconds, remoteTurns: remoteTurns)
    }

    /// Labels pre-computed mic speech spans (media seconds) against remote turns.
    public func label(micSpans: [TimeRange], micSamples: [Float], micStartSeconds: TimeInterval, remoteTurns: [SpeakerTurn]) async
        -> [DualTrackTurn]
    {
        let remoteUnion = Self.union(remoteTurns.map(\.range))
        var kept: [TimeRange] = []
        for span in micSpans {
            for piece in Self.subtract(span, remoteUnion) { kept.append(piece) }
            for piece in Self.intersect(span, remoteUnion) where piece.duration > 0 {
                let candidate = BleedCandidate(
                    range: piece, samples: DiarizationAudio.slice(micSamples, startSeconds: micStartSeconds, range: piece),
                    remoteTurns: remoteTurns.filter { $0.range.overlap(with: piece) > 0 })
                if await suppressor.verdict(for: candidate) == .keep { kept.append(piece) }
            }
        }
        let you = Self.union(kept, gap: mergeGapSeconds).filter { $0.duration >= minYouSeconds }
            .map { DualTrackTurn(range: $0, speaker: .you) }
        let remote = remoteTurns.map { DualTrackTurn(range: $0.range, speaker: .remote(slot: $0.slot), isProvisional: $0.isProvisional) }
        return (you + remote).sorted { ($0.range.start, $0.range.end) < ($1.range.start, $1.range.end) }
    }

    // MARK: Interval algebra

    /// Sorted, merged union (ranges closer than `gap` are joined).
    static func union(_ ranges: [TimeRange], gap: TimeInterval = 0) -> [TimeRange] {
        var out: [TimeRange] = []
        for range in ranges.sorted(by: { $0.start < $1.start }) where range.end > range.start {
            if let last = out.last, range.start - last.end <= gap {
                out[out.count - 1].end = max(last.end, range.end)
            } else {
                out.append(range)
            }
        }
        return out
    }

    static func intersect(_ range: TimeRange, _ merged: [TimeRange]) -> [TimeRange] {
        merged.compactMap {
            let lower = max(range.start, $0.start)
            let upper = min(range.end, $0.end)
            return upper > lower ? TimeRange(start: lower, end: upper) : nil
        }
    }

    static func subtract(_ range: TimeRange, _ merged: [TimeRange]) -> [TimeRange] {
        var out: [TimeRange] = []
        var cursor = range.start
        for cut in merged where cut.end > range.start && cut.start < range.end {
            if cut.start > cursor { out.append(TimeRange(start: cursor, end: cut.start)) }
            cursor = max(cursor, cut.end)
        }
        if cursor < range.end { out.append(TimeRange(start: cursor, end: range.end)) }
        return out
    }
}

import AppCore
import Foundation

// MARK: - Echo de-duplication (MTG-AC-19)

/// Cross-track echo removal. With speakers instead of headphones the mic hears the remote voices, so the same speech is
/// transcribed twice. A mic segment is dropped when it overlaps a remote segment in time and says nearly the same words.
public enum EchoDeduper {
    public static func dedupe(
        mic: [Segment], remote: [Segment], minOverlapFraction: Double = 0.5, minSimilarity: Double = 0.6
    ) -> (kept: [Segment], dropped: [Segment]) {
        var kept: [Segment] = []
        var dropped: [Segment] = []
        for segment in mic {
            let words = tokens(segment.text)
            let isEcho = remote.contains { other in
                let overlap = segment.range.overlap(with: other.range)
                let shorter = min(segment.range.duration, other.range.duration)
                guard shorter > 0, overlap / shorter >= minOverlapFraction else { return false }
                return similarity(words, tokens(other.text)) >= minSimilarity
            }
            if isEcho { dropped.append(segment) } else { kept.append(segment) }
        }
        return (kept, dropped)
    }

    static func tokens(_ text: String) -> Set<String> {
        Set(
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty })
    }

    /// Overlap coefficient: shared words over the smaller word set (robust to the quieter echo losing words).
    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}

// MARK: - Speaker assignment

public enum SpeakerAssigner {
    /// The diarization slot of the turn overlapping `range` most; otherwise the nearest turn.
    public static func slot(for range: TimeRange, turns: [SpeakerTurn]) -> Int? {
        guard !turns.isEmpty else { return nil }
        var overlap: [Int: TimeInterval] = [:]
        for turn in turns {
            let t = range.overlap(with: turn.range)
            if t > 0 { overlap[turn.slot, default: 0] += t }
        }
        if let best = overlap.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) { return best.key }
        func gap(_ turn: SpeakerTurn) -> TimeInterval { max(0, turn.range.start - range.end, range.start - turn.range.end) }
        return turns.min { (gap($0), $0.slot) < (gap($1), $1.slot) }?.slot
    }
}

// MARK: - Voice profile matching seam

/// A diarized speaker cluster with the evidence needed to compare it with stored voice profiles.
public struct SpeakerSlotEvidence: Sendable, Hashable {
    public var slot: Int
    public var embedding: SpeakerEmbedding
    public var speechSeconds: TimeInterval
    public init(slot: Int, embedding: SpeakerEmbedding, speechSeconds: TimeInterval) {
        self.slot = slot
        self.embedding = embedding
        self.speechSeconds = speechSeconds
    }
}

public struct VoiceProfileMatch: Sendable, Hashable {
    public var slot: Int
    public var profileID: VoiceProfileID
    public var name: String
    public var distance: Double
    /// `true`: safe to apply the name automatically; `false`: suggest it for confirmation.
    public var isAuto: Bool
    public init(slot: Int, profileID: VoiceProfileID, name: String, distance: Double, isAuto: Bool) {
        self.slot = slot
        self.profileID = profileID
        self.name = name
        self.distance = distance
        self.isAuto = isAuto
    }
}

/// Matches diarized speakers to voice profiles. The `Diarization` package has a calibrated `VoiceProfileMatcher`; since
/// this package depends only on AppCore, the App adapts that matcher to this protocol. ``DistanceVoiceProfileMatcher``
/// is the AppCore-only default.
public protocol VoiceProfileMatching: Sendable {
    func match(_ evidence: [SpeakerSlotEvidence], profiles: [VoiceProfile]) -> [VoiceProfileMatch]
}

/// Same calibration as the Diarization matcher: auto at distance <= 0.25 (and unambiguous), suggestion <= 0.35.
public struct DistanceVoiceProfileMatcher: VoiceProfileMatching {
    public var autoApplyThreshold: Double
    public var suggestThreshold: Double
    public var ambiguityMargin: Double
    public var minSpeechSeconds: TimeInterval
    public init(
        autoApplyThreshold: Double = 0.25, suggestThreshold: Double = 0.35, ambiguityMargin: Double = 0.1,
        minSpeechSeconds: TimeInterval = 2
    ) {
        self.autoApplyThreshold = autoApplyThreshold
        self.suggestThreshold = suggestThreshold
        self.ambiguityMargin = ambiguityMargin
        self.minSpeechSeconds = minSpeechSeconds
    }

    public func match(_ evidence: [SpeakerSlotEvidence], profiles: [VoiceProfile]) -> [VoiceProfileMatch] {
        let usable = profiles.filter { $0.deletedAt == nil }
        var out: [VoiceProfileMatch] = []
        for item in evidence where item.speechSeconds >= minSpeechSeconds {
            let ranked = usable.map { ($0, item.embedding.distance(to: $0.embedding)) }.sorted { $0.1 < $1.1 }
            guard let best = ranked.first, best.1 <= suggestThreshold else { continue }
            let ambiguous = ranked.dropFirst().first.map { $0.1 - best.1 < ambiguityMargin } ?? false
            out.append(
                VoiceProfileMatch(
                    slot: item.slot, profileID: best.0.id, name: best.0.name, distance: best.1,
                    isAuto: best.1 <= autoApplyThreshold && !ambiguous))
        }
        return out
    }
}

import AppCore
import Foundation

/// A speaker cluster from a diarization pass, as seen by voice-profile matching.
public struct SpeakerCluster: Sendable, Hashable {
    public var slot: Int
    public var embedding: SpeakerEmbedding
    /// Total speech attributed to the cluster; tiny clusters are noise and are ignored for matching.
    public var speechSeconds: TimeInterval
    public init(slot: Int, embedding: SpeakerEmbedding, speechSeconds: TimeInterval) {
        self.slot = slot
        self.embedding = embedding
        self.speechSeconds = speechSeconds
    }

    /// Clusters from an offline result: centroid per slot plus the speech time of that slot.
    public static func clusters(from output: OfflineDiarization) -> [SpeakerCluster] {
        var seconds: [Int: TimeInterval] = [:]
        for turn in output.turns { seconds[turn.slot, default: 0] += turn.range.duration }
        return output.centroids.map { SpeakerCluster(slot: $0.key, embedding: $0.value, speechSeconds: seconds[$0.key] ?? 0) }
            .sorted { $0.slot < $1.slot }
    }
}

/// Matches diarized speakers to stored voice profiles and proposes merges of clusters that are one person.
///
/// Calibration (spike, FluidAudio Community-1 centroids, AMI ES2004a vs ES2004b, same four participants): same-person
/// distances max 0.076 (n = 4); different-person min 0.678, median 0.929 (n = 12). SpeakerKit's split clusters showed
/// same-person pairs at 0.50 to 0.89 when a cluster was impure, which is why matching is per cluster and many-to-one.
/// The defaults sit well inside that gap: **0.25** to auto-apply a name, **0.35** to suggest one (research §4 recommends
/// 0.3 to 0.4). One meeting series, one mic chain, four people: treat them as provisional and re-calibrate on real
/// recordings before trusting auto-apply; names are never applied without being visible and reversible in the UI.
public struct VoiceProfileMatcher: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Distance at or below which a name may be applied automatically.
        public var autoApplyThreshold: Double
        /// Distance at or below which a profile is offered as a suggestion.
        public var suggestThreshold: Double
        /// If the runner-up profile is within this of the best, the match is downgraded to a suggestion.
        public var ambiguityMargin: Double
        /// Two clusters closer than this are treated as one person (split cluster).
        public var mergeThreshold: Double
        /// Clusters with less speech than this are ignored (impure / noise).
        public var minClusterSpeechSeconds: TimeInterval

        public init(
            autoApplyThreshold: Double = 0.25, suggestThreshold: Double = 0.35, ambiguityMargin: Double = 0.1,
            mergeThreshold: Double = 0.3, minClusterSpeechSeconds: TimeInterval = 2
        ) {
            self.autoApplyThreshold = autoApplyThreshold
            self.suggestThreshold = suggestThreshold
            self.ambiguityMargin = ambiguityMargin
            self.mergeThreshold = mergeThreshold
            self.minClusterSpeechSeconds = minClusterSpeechSeconds
        }
    }

    public enum Confidence: Sendable, Hashable {
        /// Within ``Configuration/autoApplyThreshold`` and unambiguous.
        case auto
        /// Within ``Configuration/suggestThreshold`` (or ambiguous): show as a suggestion to confirm.
        case suggested
    }

    public struct Match: Sendable, Hashable {
        public var slot: Int
        public var profile: VoiceProfileID
        public var distance: Double
        public var confidence: Confidence
    }

    public var configuration: Configuration
    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    /// Best profile per cluster. Every cluster is compared on its own and several clusters may map to one profile, so a
    /// person split across clusters still gets the name on each part. Soft-deleted profiles and dimension mismatches
    /// (a different embedding model) never match.
    public func matches(clusters: [SpeakerCluster], profiles: [VoiceProfile]) -> [Match] {
        let usable = profiles.filter { $0.deletedAt == nil }
        var out: [Match] = []
        for cluster in clusters where cluster.speechSeconds >= configuration.minClusterSpeechSeconds {
            let ranked = usable.map { ($0, cluster.embedding.distance(to: $0.embedding)) }.sorted { $0.1 < $1.1 }
            guard let best = ranked.first, best.1 <= configuration.suggestThreshold else { continue }
            let runnerUp = ranked.dropFirst().first?.1
            let ambiguous = runnerUp.map { $0 - best.1 < configuration.ambiguityMargin } ?? false
            let confidence: Confidence = (best.1 <= configuration.autoApplyThreshold && !ambiguous) ? .auto : .suggested
            out.append(Match(slot: cluster.slot, profile: best.0.id, distance: best.1, confidence: confidence))
        }
        return out
    }

    /// Proposes which slots are one person (DIA-AC-15): clusters that match the same profile, or whose centroids are within
    /// ``Configuration/mergeThreshold`` of each other, are grouped. Returns slot to canonical slot (the slot with the most
    /// speech in the group); slots that stay alone are absent. A proposal only: apply it behind a confirmable UI.
    public func mergePlan(clusters: [SpeakerCluster], profiles: [VoiceProfile]) -> [Int: Int] {
        let eligible = clusters.filter { $0.speechSeconds >= configuration.minClusterSpeechSeconds }
        var parent = Dictionary(uniqueKeysWithValues: eligible.map { ($0.slot, $0.slot) })
        func find(_ x: Int) -> Int {
            var root = x
            while let p = parent[root], p != root { root = p }
            return root
        }
        func join(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        for (i, a) in eligible.enumerated() {
            for b in eligible[(i + 1)...] where a.embedding.distance(to: b.embedding) <= configuration.mergeThreshold {
                join(a.slot, b.slot)
            }
        }
        var byProfile: [VoiceProfileID: Int] = [:]
        for match in matches(clusters: eligible, profiles: profiles) {
            if let other = byProfile[match.profile] { join(match.slot, other) } else { byProfile[match.profile] = match.slot }
        }

        var groups: [Int: [SpeakerCluster]] = [:]
        for cluster in eligible { groups[find(cluster.slot), default: []].append(cluster) }
        var plan: [Int: Int] = [:]
        for members in groups.values where members.count > 1 {
            guard let canonical = members.max(by: { $0.speechSeconds < $1.speechSeconds })?.slot else { continue }
            for member in members where member.slot != canonical { plan[member.slot] = canonical }
        }
        return plan
    }

    /// Duration-weighted centroid of clusters that belong together (used to match the merged speaker).
    public func mergedEmbedding(of clusters: [SpeakerCluster]) -> SpeakerEmbedding? {
        guard let dimension = clusters.first?.embedding.vector.count, dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        var weight: Float = 0
        for cluster in clusters where cluster.embedding.vector.count == dimension {
            let w = Float(max(cluster.speechSeconds, 0.001))
            let norm = max(cluster.embedding.vector.reduce(0) { $0 + $1 * $1 }.squareRoot(), 1e-9)
            for i in 0..<dimension { sum[i] += w * cluster.embedding.vector[i] / norm }
            weight += w
        }
        guard weight > 0 else { return nil }
        return SpeakerEmbedding(vector: sum.map { $0 / weight })
    }

    /// Rewrites turn slots through a merge plan.
    public static func apply(_ plan: [Int: Int], to turns: [SpeakerTurn]) -> [SpeakerTurn] {
        turns.map {
            var turn = $0
            turn.slot = plan[$0.slot] ?? $0.slot
            return turn
        }
    }
}

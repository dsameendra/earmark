import AppCore
import Foundation
import Testing

@testable import Diarization

@Suite("Voice profile matcher") struct VoiceProfileMatcherTests {
    /// Unit vector at `angle` radians in a 2-D plane, so cosine distance = 1 - cos(angle difference).
    private func embedding(_ angle: Double) -> SpeakerEmbedding { SpeakerEmbedding(vector: [Float(cos(angle)), Float(sin(angle))]) }
    private func profile(_ name: String, _ angle: Double, deleted: Bool = false) -> VoiceProfile {
        VoiceProfile(name: name, embedding: embedding(angle), deletedAt: deleted ? Date() : nil)
    }
    private func cluster(_ slot: Int, _ angle: Double, seconds: Double = 30) -> SpeakerCluster {
        SpeakerCluster(slot: slot, embedding: embedding(angle), speechSeconds: seconds)
    }

    // DIA-AC-14
    @Test func closeClusterIsAutoLabelledFarOneIsNot() {
        let ana = profile("Ana", 0)
        let matcher = VoiceProfileMatcher()
        let result = matcher.matches(clusters: [cluster(0, 0.2), cluster(1, 2.0)], profiles: [ana])
        #expect(result.count == 1)
        #expect(result[0].slot == 0 && result[0].profile == ana.id && result[0].confidence == .auto)
    }

    @Test func borderlineIsOnlySuggested() {
        // 1 - cos(0.85) = 0.34: inside the suggest threshold, outside auto-apply.
        let result = VoiceProfileMatcher().matches(clusters: [cluster(0, 0.85)], profiles: [profile("Ana", 0)])
        #expect(result.first?.confidence == .suggested)
    }

    @Test func ambiguousBetweenTwoProfilesIsOnlySuggested() {
        let result = VoiceProfileMatcher().matches(clusters: [cluster(0, 0.3)], profiles: [profile("Ana", 0), profile("Bo", 0.6)])
        #expect(result.first?.confidence == .suggested)
    }

    @Test func deletedProfilesAndDimensionMismatchNeverMatch() {
        let wrongSize = VoiceProfile(name: "Old model", embedding: SpeakerEmbedding(vector: [1, 0, 0]))
        let result = VoiceProfileMatcher().matches(
            clusters: [cluster(0, 0)], profiles: [profile("Gone", 0, deleted: true), wrongSize])
        #expect(result.isEmpty)
    }

    @Test func tinyClustersAreIgnored() {
        #expect(VoiceProfileMatcher().matches(clusters: [cluster(0, 0, seconds: 0.5)], profiles: [profile("Ana", 0)]).isEmpty)
    }

    // DIA-AC-15
    @Test func splitClustersOfOnePersonBothMatchAndMerge() {
        let ana = profile("Ana", 0)
        let clusters = [cluster(0, 0.05, seconds: 40), cluster(1, -0.1, seconds: 8), cluster(2, 2.5, seconds: 30)]
        let matcher = VoiceProfileMatcher()
        let matches = matcher.matches(clusters: clusters, profiles: [ana])
        #expect(Set(matches.map(\.slot)) == [0, 1])
        #expect(matcher.mergePlan(clusters: clusters, profiles: [ana]) == [1: 0])
    }

    @Test func clustersNeverMergeJustForBeingNeighboursInTime() {
        let clusters = [cluster(0, 0), cluster(1, 1.5), cluster(2, 3.0)]
        #expect(VoiceProfileMatcher().mergePlan(clusters: clusters, profiles: []).isEmpty)
    }

    @Test func mergePlanRewritesTurnsAndWeightsTheCentroid() {
        let clusters = [cluster(0, 0, seconds: 30), cluster(1, 0.1, seconds: 10)]
        let matcher = VoiceProfileMatcher()
        let plan = matcher.mergePlan(clusters: clusters, profiles: [])
        #expect(plan == [1: 0])
        let turns = [SpeakerTurn(range: TimeRange(start: 0, end: 1), slot: 1), SpeakerTurn(range: TimeRange(start: 1, end: 2), slot: 2)]
        #expect(VoiceProfileMatcher.apply(plan, to: turns).map(\.slot) == [0, 2])
        let merged = matcher.mergedEmbedding(of: clusters)
        #expect(merged != nil)
        #expect((merged?.distance(to: embedding(0.025)) ?? 1) < 0.01)  // pulled toward the longer cluster (0 .. 0.1, 3:1)
    }

    /// The defaults must sit inside the spike's measured gap (same-person max 0.076, different-person min 0.678).
    @Test func defaultsSitInsideTheMeasuredGap() {
        let c = VoiceProfileMatcher.Configuration()
        #expect(c.autoApplyThreshold > 0.076 && c.suggestThreshold < 0.678)
        #expect(c.autoApplyThreshold <= c.suggestThreshold)
    }
}

@Suite("Reconciliation and assignment") struct ReconciliationTests {
    private func turn(_ start: Double, _ end: Double, _ slot: Int) -> SpeakerTurn {
        SpeakerTurn(range: TimeRange(start: start, end: end), slot: slot)
    }

    // DIA-AC-05
    @Test func namesCarryOverThroughTheSlotMap() {
        let live = [turn(0, 10, 0), turn(10, 20, 1)]
        let offline = [turn(0, 10, 3), turn(10, 20, 2)]
        let ana = SpeakerID()
        let result = LiveReconciliation.reconcile(live: live, offline: offline, liveSpeakers: [0: ana])
        #expect(result.slotMap == [0: 3, 1: 2])
        #expect(result.assignments == [3: ana])
        #expect(result.needsReview.isEmpty)
        #expect(result.changedFraction == 0)
    }

    // DIA-AC-06
    @Test func changedFractionIsTheShareOfRelabelledSpeech() {
        // Live slot 0 maps to offline 0 (6 of 10 s); the other 4 s are speech the offline pass gave to speaker 1.
        let live = [turn(0, 10, 0)]
        let offline = [turn(0, 6, 0), turn(6, 10, 1)]
        let result = LiveReconciliation.reconcile(live: live, offline: offline, liveSpeakers: [:])
        #expect(abs(result.changedFraction - 0.4) < 1e-9)
        #expect(result.needsReview == [0])
    }

    @Test func splitLiveSlotNamesOnlyTheDominantOfflineSpeaker() {
        let live = [turn(0, 10, 0)]
        let offline = [turn(0, 7.5, 5), turn(7.5, 10, 6)]
        let ana = SpeakerID()
        let result = LiveReconciliation.reconcile(live: live, offline: offline, liveSpeakers: [0: ana])
        #expect(result.assignments == [5: ana])
        #expect(result.needsReview.isEmpty)  // 75 % dominant share is above the 0.7 review threshold
        let strict = LiveReconciliation.reconcile(live: live, offline: offline, liveSpeakers: [0: ana], splitThreshold: 0.8)
        #expect(strict.needsReview == [0])
    }

    @Test func twoLiveSlotsOnOneOfflineSpeakerKeepTheLongerNames() {
        let live = [turn(0, 30, 0), turn(30, 35, 1)]
        let offline = [turn(0, 35, 0)]
        let long = SpeakerID()
        let short = SpeakerID()
        let result = LiveReconciliation.reconcile(live: live, offline: offline, liveSpeakers: [0: long, 1: short])
        #expect(result.assignments == [0: long])
    }

    @Test func extraOfflineSpeakerHasNoAssignment() {
        let live = [turn(0, 10, 0)]
        let offline = [turn(0, 10, 0), turn(10, 20, 4)]
        let result = LiveReconciliation.reconcile(live: live, offline: offline, liveSpeakers: [0: SpeakerID()])
        #expect(result.assignments[4] == nil)
    }

    // DIA-AC-01
    @Test func segmentsGoToTheTurnWithMostOverlap() {
        let turns = [turn(0, 4, 0), turn(4, 10, 1), turn(8, 12, 2)]
        #expect(TurnAssigner.slot(for: TimeRange(start: 3, end: 7), in: turns) == 1)
        #expect(TurnAssigner.slot(for: TimeRange(start: 11, end: 20), in: turns) == 2)
        #expect(TurnAssigner.slot(for: TimeRange(start: 30, end: 31), in: turns) == nil)
    }

    @Test func sortformerVariantsAreV2Only() {
        for variant in [SortformerStreamingDiarizer.Variant.fast, .balanced] {
            #expect(!variant.bundleFile.contains("2.1"))
            #expect(variant.bundleFile.hasSuffix("_v2.mlmodelc"))
        }
    }
}

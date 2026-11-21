import AppCore
import Foundation

/// Result of reconciling provisional live slots with the final offline pass (DIA-AC-05, DIA-AC-06).
public struct ReconciliationResult: Sendable, Equatable {
    /// Live slot to the offline slot holding most of its speech (``SpeakerReconciler/mapLiveSlots(live:offline:)``).
    public var slotMap: [Int: Int]
    /// Speaker for each offline slot, carried over from the live slot(s) mapped to it. Offline slots with no entry are new
    /// speakers (for instance a fifth speaker the 4-slot live pass could not label).
    public var assignments: [Int: SpeakerID]
    /// Live slots whose speech split across several offline speakers (dominant share below `splitThreshold`): the name
    /// stays on the dominant part and the user should review the rest.
    public var needsReview: Set<Int>
    /// Share of live speech whose speaker changes at reconciliation (about 0.17 to 0.29 for LS-EEND on AMI). Drives
    /// the one-time "refining speakers" relabel flag.
    public var changedFraction: Double
}

/// Maps live labels onto the offline pass while preserving user renames.
///
/// Built on AppCore's ``SpeakerReconciler``: each live slot goes to the offline slot it overlaps most. Offline wins on
/// conflicts. When two live slots map to one offline slot (the live pass split a person) the slot with more speech keeps
/// its name. Run once; the result is final, so labels do not flip again afterwards.
public enum LiveReconciliation {
    public static func reconcile(
        live: [SpeakerTurn], offline: [SpeakerTurn], liveSpeakers: [Int: SpeakerID], splitThreshold: Double = 0.7
    ) -> ReconciliationResult {
        let slotMap = SpeakerReconciler.mapLiveSlots(live: live, offline: offline)

        // Per live slot: total overlapped speech and the part inside the mapped offline slot.
        var total: [Int: TimeInterval] = [:]
        var inside: [Int: TimeInterval] = [:]
        for l in live {
            for o in offline {
                let t = l.range.overlap(with: o.range)
                guard t > 0 else { continue }
                total[l.slot, default: 0] += t
                if slotMap[l.slot] == o.slot { inside[l.slot, default: 0] += t }
            }
        }
        var needsReview: Set<Int> = []
        for (slot, t) in total where t > 0 && (inside[slot] ?? 0) / t < splitThreshold { needsReview.insert(slot) }

        var assignments: [Int: SpeakerID] = [:]
        var claimed: [Int: TimeInterval] = [:]  // offline slot -> speech of the live slot that named it
        for (liveSlot, offlineSlot) in slotMap {
            guard let speaker = liveSpeakers[liveSlot] else { continue }
            let weight = inside[liveSlot] ?? 0
            if weight > (claimed[offlineSlot] ?? -1) {
                claimed[offlineSlot] = weight
                assignments[offlineSlot] = speaker
            }
        }

        let all = total.values.reduce(0, +)
        let kept = inside.values.reduce(0, +)
        return ReconciliationResult(
            slotMap: slotMap, assignments: assignments, needsReview: needsReview, changedFraction: all > 0 ? 1 - kept / all : 0)
    }
}

/// Assigns transcript segments to speakers by maximum overlap with turns (DIA-AC-01).
public enum TurnAssigner {
    /// The slot whose turns overlap `range` the most, or `nil` when no turn overlaps. Ties go to the lower slot.
    public static func slot(for range: TimeRange, in turns: [SpeakerTurn]) -> Int? {
        var overlap: [Int: TimeInterval] = [:]
        for turn in turns {
            let t = range.overlap(with: turn.range)
            if t > 0 { overlap[turn.slot, default: 0] += t }
        }
        return overlap.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key
    }
}

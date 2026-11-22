import AppCore
import Foundation

/// SCR-013: pure merge rules for a non-destructive re-run of an existing transcript.
///
/// A segment is *locked* when the user touched it (`isUserEdited`) or set its ignore flag by hand (`ignoreFlagIsManual`). Locked
/// segments, and everything outside the re-run ranges, survive exactly as they are.
enum RerunMerge {
    static func isLocked(_ segment: Segment) -> Bool { segment.isUserEdited || segment.ignoreFlagIsManual }

    /// `true` when the midpoint of `segment` falls inside one of `ranges`, or `ranges` is empty (whole transcript). Old and
    /// new segments are partitioned by the same midpoint rule, so a long old segment that merely grazes a range is kept (its
    /// replacement would be dropped) instead of being deleted and leaving a hole.
    static func inScope(_ segment: Segment, ranges: [TimeRange]) -> Bool {
        guard !ranges.isEmpty else { return true }
        let midpoint = (segment.start + segment.end) / 2
        return ranges.contains { $0.start <= midpoint && midpoint < $0.end }
    }

    /// Replaces the unlocked, in-scope part of `existing` with `fresh`. New segments inherit the speaker of the old segment
    /// they overlap most and are dropped when they mostly cover a locked segment or fall outside the scope.
    static func merge(existing: [Segment], fresh: [Segment], ranges: [TimeRange]) -> [Segment] {
        let kept = existing.filter { isLocked($0) || !inScope($0, ranges: ranges) }
        let replaced = existing.filter { !(isLocked($0) || !inScope($0, ranges: ranges)) }
        var result = kept
        for var candidate in fresh {
            guard inScope(candidate, ranges: ranges) else { continue }
            let covered = kept.filter { isLocked($0) }.reduce(0.0) { $0 + $1.range.overlap(with: candidate.range) }
            if candidate.range.duration > 0, covered / candidate.range.duration > 0.5 { continue }
            if candidate.speakerID == nil {
                candidate.speakerID = dominantSpeaker(of: candidate.range, in: replaced + existing)
            }
            // Identical text keeps its translations (they are still correct) instead of silently losing them.
            if candidate.translations.isEmpty,
                let twin = replaced.first(where: {
                    !$0.translations.isEmpty && $0.text == candidate.text && $0.range.overlap(with: candidate.range) > 0
                })
            {
                candidate.translations = twin.translations
            }
            result.append(candidate)
        }
        return result.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The speaker with the greatest overlap with `range`, or `nil`.
    static func dominantSpeaker(of range: TimeRange, in segments: [Segment]) -> SpeakerID? {
        var totals: [SpeakerID: TimeInterval] = [:]
        for segment in segments { if let speaker = segment.speakerID { totals[speaker, default: 0] += segment.range.overlap(with: range) } }
        return totals.filter { $0.value > 0 }.max { $0.value < $1.value }?.key
    }

    /// Maps a fresh diarization onto the speakers the transcript already had, so names and colours survive. `before` and `after`
    /// hold the same segments (same ids) before and after the diarizer labelled them. Locked segments keep their old speaker; a
    /// new speaker takes over the existing speaker it overlaps most (each existing speaker at most once); the rest become
    /// "Speaker N" with N continuing after the existing names.
    static func remapSpeakers(
        before: [Segment], after: [Segment], newSpeakers: [Speaker], existingSpeakers: [Speaker]
    ) -> (segments: [Segment], speakers: [Speaker]) {
        let oldByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        var overlap: [SpeakerID: [SpeakerID: TimeInterval]] = [:]
        for segment in after {
            guard let new = segment.speakerID, let old = oldByID[segment.id]?.speakerID, !isLocked(segment) else { continue }
            overlap[new, default: [:]][old, default: 0] += segment.range.duration
        }
        let pairs = overlap.flatMap { new, olds in olds.map { (new: new, old: $0.key, weight: $0.value) } }
            .sorted { $0.weight != $1.weight ? $0.weight > $1.weight : $0.new.description < $1.new.description }
        var mapping: [SpeakerID: SpeakerID] = [:]
        var claimed = Set<SpeakerID>()
        for pair in pairs where mapping[pair.new] == nil && !claimed.contains(pair.old) && pair.weight > 0 {
            guard existingSpeakers.contains(where: { $0.id == pair.old }) else { continue }
            mapping[pair.new] = pair.old
            claimed.insert(pair.old)
        }
        var speakers = existingSpeakers
        var nextNumber = 1
        func freeName() -> String {
            while speakers.contains(where: { $0.name == "Speaker \(nextNumber)" }) { nextNumber += 1 }
            defer { nextNumber += 1 }
            return "Speaker \(nextNumber)"
        }
        for speaker in newSpeakers where mapping[speaker.id] == nil {
            var renamed = speaker
            renamed.name = freeName()
            speakers.append(renamed)
        }
        let segments = after.map { segment -> Segment in
            var copy = segment
            if isLocked(segment), let previous = oldByID[segment.id] {
                copy.speakerID = previous.speakerID
            } else if let new = segment.speakerID, let old = mapping[new] {
                copy.speakerID = old
            }
            return copy
        }
        let used = Set(segments.compactMap(\.speakerID))
        return (segments, speakers.filter { used.contains($0.id) })
    }
}

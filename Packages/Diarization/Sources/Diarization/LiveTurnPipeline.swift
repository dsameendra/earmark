import AppCore
import Foundation

/// An engine-neutral segment from a streaming diarizer (times in seconds from the start of the stream).
public struct RawLiveSegment: Sendable, Hashable {
    public var slot: Int
    public var start: TimeInterval
    public var end: TimeInterval
    public init(slot: Int, start: TimeInterval, end: TimeInterval) {
        self.slot = slot
        self.start = start
        self.end = end
    }
}

/// Reduces slot flips in provisional live labels.
///
/// Streaming diarizers revise tentative output every step, which shows up as short-lived label flips. Three conservative
/// rules are applied to **tentative** turns only (finalized output is never altered):
/// 1. *Island removal*: turns shorter than ``Configuration/minTurnSeconds`` are dropped until they grow.
/// 2. *Flip hysteresis*: a turn shorter than ``Configuration/flipHoldSeconds`` that mostly overlaps a turn already shown
///    with another slot keeps the slot it was shown with.
/// 3. *Gap bridging*: same-slot turns closer than ``Configuration/mergeGapSeconds`` are merged.
///
/// None of the rules delays the first label of a new speaker beyond ``Configuration/minTurnSeconds`` of speech, which
/// keeps the ~1.5 s label budget (DIA-AC-03).
public struct LabelStabilizer: Sendable {
    public struct Configuration: Sendable, Hashable {
        public var minTurnSeconds: TimeInterval
        public var flipHoldSeconds: TimeInterval
        public var mergeGapSeconds: TimeInterval
        public init(minTurnSeconds: TimeInterval = 0.2, flipHoldSeconds: TimeInterval = 0.5, mergeGapSeconds: TimeInterval = 0.3) {
            self.minTurnSeconds = minTurnSeconds
            self.flipHoldSeconds = flipHoldSeconds
            self.mergeGapSeconds = mergeGapSeconds
        }
    }

    public var configuration: Configuration
    private var shown: [SpeakerTurn] = []

    public init(configuration: Configuration = Configuration()) { self.configuration = configuration }

    /// Stabilizes the current tentative set and remembers it as what the user now sees.
    public mutating func stabilize(_ tentative: [SpeakerTurn]) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        for var turn in tentative.sorted(by: { $0.range.start < $1.range.start }) {
            let duration = turn.range.duration
            guard duration >= configuration.minTurnSeconds else { continue }
            if duration < configuration.flipHoldSeconds,
                let anchor = shown.filter({ $0.slot != turn.slot && $0.range.overlap(with: turn.range) >= 0.5 * duration })
                    .max(by: { $0.range.overlap(with: turn.range) < $1.range.overlap(with: turn.range) })
            {
                turn.slot = anchor.slot
            }
            if let last = turns.last, last.slot == turn.slot, turn.range.start - last.range.end <= configuration.mergeGapSeconds {
                turns[turns.count - 1].range.end = max(last.range.end, turn.range.end)
            } else {
                turns.append(turn)
            }
        }
        shown = turns
        return turns
    }

    /// Forgets shown turns that ended before `time` (they are final now).
    public mutating func discard(before time: TimeInterval) { shown.removeAll { $0.range.end <= time } }
}

/// Pure translation of a streaming diarizer's per-step output into ``LiveDiarizationEvent``s.
///
/// Event semantics (the contract for consumers):
/// - A `.turn` with `isProvisional == true` is a tentative label. It supersedes any earlier provisional turn it overlaps.
///   Provisional turns that are not re-sent simply stay as last reported until a `.finalized` event passes them.
/// - A `.turn` with `isProvisional == false` is final for this live pass.
/// - `.finalized(upTo:)` is monotonic: every provisional turn ending before it must be discarded.
/// - `.speakerLimitReached` is sent at most once, when more than ``maxLiveSpeakers`` speakers are active; the extra
///   speakers are not labelled (the UI shows "More speakers" until the offline pass).
///
/// To limit chatter an unchanged provisional turn is re-sent only when its end moved by at least
/// ``Configuration/endDelta`` seconds.
public struct LiveTurnPipeline: Sendable {
    public struct Configuration: Sendable, Hashable {
        /// Hard engine limit; slots at or above it are dropped and trigger `.speakerLimitReached`.
        public var hardSlotLimit: Int
        /// Slots at or above this are dropped silently (a user-chosen maximum speaker count, at most `hardSlotLimit`).
        public var visibleSlots: Int
        /// Dropped speech (seconds) above the hard limit needed before `.speakerLimitReached` is sent.
        public var limitMinSeconds: TimeInterval
        public var endDelta: TimeInterval
        public var stabilizer: LabelStabilizer.Configuration
        public init(
            hardSlotLimit: Int = maxLiveSpeakers, visibleSlots: Int = maxLiveSpeakers, limitMinSeconds: TimeInterval = 0.5,
            endDelta: TimeInterval = 0.25, stabilizer: LabelStabilizer.Configuration = .init()
        ) {
            self.hardSlotLimit = hardSlotLimit
            self.visibleSlots = min(visibleSlots, hardSlotLimit)
            self.limitMinSeconds = limitMinSeconds
            self.endDelta = endDelta
            self.stabilizer = stabilizer
        }

        /// Derives the visible slot count from the user's speaker-count option.
        public init(options: DiarizationOptions) {
            var visible = maxLiveSpeakers
            switch options.speakerCount {
            case .auto: break
            case .exact(let count): visible = max(1, count)
            case .range(_, let upper): visible = max(1, upper)
            }
            self.init(visibleSlots: min(visible, maxLiveSpeakers))
        }
    }

    private let configuration: Configuration
    private let timeOffset: TimeInterval
    private var stabilizer: LabelStabilizer
    private var emitted: [SpeakerTurn] = []
    private var finalizedUpTo: TimeInterval = 0
    private var limitSignalled = false
    private var droppedSeconds: TimeInterval = 0

    /// - Parameter timeOffset: Added to every engine time (the first chunk's `startSeconds`).
    public init(configuration: Configuration = Configuration(), timeOffset: TimeInterval = 0) {
        self.configuration = configuration
        self.timeOffset = timeOffset
        self.stabilizer = LabelStabilizer(configuration: configuration.stabilizer)
    }

    /// Feeds one engine step: `finalized` segments that became final, and the current full `tentative` set.
    public mutating func ingest(tentative: [RawLiveSegment], finalized: [RawLiveSegment]) -> [LiveDiarizationEvent] {
        var events: [LiveDiarizationEvent] = []
        let finals = admitted(finalized, countsTowardLimit: true)
        let tentatives = admitted(tentative, countsTowardLimit: false)
        if !limitSignalled, droppedSeconds >= configuration.limitMinSeconds {
            limitSignalled = true
            events.append(.speakerLimitReached)
        }

        var horizon = finalizedUpTo
        for segment in finals {
            events.append(.turn(SpeakerTurn(range: TimeRange(start: segment.start, end: segment.end), slot: segment.slot)))
            horizon = max(horizon, segment.end)
        }

        let live = tentatives.filter { $0.end > horizon }
        let stable = stabilizer.stabilize(
            live.map { SpeakerTurn(range: TimeRange(start: max($0.start, horizon), end: $0.end), slot: $0.slot, isProvisional: true) })
        var nowShown: [SpeakerTurn] = []
        for turn in stable {
            if let previous = emitted.first(where: {
                $0.slot == turn.slot && abs($0.range.start - turn.range.start) <= 0.1
                    && abs($0.range.end - turn.range.end) < configuration.endDelta
            }) {
                nowShown.append(previous)
            } else {
                events.append(.turn(turn))
                nowShown.append(turn)
            }
        }
        emitted = nowShown

        if horizon > finalizedUpTo {
            finalizedUpTo = horizon
            stabilizer.discard(before: horizon)
            emitted.removeAll { $0.range.end <= horizon }
            events.append(.finalized(upTo: horizon))
        }
        return events
    }

    /// Ends the stream: everything up to `totalDuration` (media time) is final.
    public mutating func finish(totalDuration: TimeInterval) -> [LiveDiarizationEvent] {
        guard totalDuration > finalizedUpTo else { return [] }
        finalizedUpTo = totalDuration
        emitted = []
        return [.finalized(upTo: totalDuration)]
    }

    private mutating func admitted(_ segments: [RawLiveSegment], countsTowardLimit: Bool) -> [RawLiveSegment] {
        var out: [RawLiveSegment] = []
        for segment in segments where segment.end > segment.start {
            let shifted = RawLiveSegment(slot: segment.slot, start: segment.start + timeOffset, end: segment.end + timeOffset)
            if segment.slot >= configuration.hardSlotLimit {
                if countsTowardLimit {
                    droppedSeconds += shifted.end - shifted.start
                } else {
                    droppedSeconds = max(droppedSeconds, shifted.end - shifted.start)
                }
            } else if segment.slot < configuration.visibleSlots {
                out.append(shifted)
            }
        }
        return out
    }
}

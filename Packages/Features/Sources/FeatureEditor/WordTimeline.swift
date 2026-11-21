import AppCore
import Foundation

/// A position in the transcript: a segment and optionally a word within it.
public struct WordRef: Hashable, Sendable {
    public var segmentID: SegmentID
    public var wordIndex: Int?
    public init(segmentID: SegmentID, wordIndex: Int?) {
        self.segmentID = segmentID
        self.wordIndex = wordIndex
    }
}

/// Time-to-word index over a transcript, used for click-to-seek, karaoke highlighting and auto-scroll (EDIT-AC-02, 04).
///
/// Segments are indexed by start time (binary search); words inside a segment are binary searched too, so a lookup is
/// O(log n) even for 10 000 segments. Overlapping segments (dual-track) are handled by walking back a bounded distance.
public struct WordTimeline: Sendable {
    private struct Entry: Sendable {
        var end: TimeInterval
        var id: SegmentID
        var wordStarts: [TimeInterval]
        var wordEnds: [TimeInterval]
    }

    private let entries: [Entry]
    private let starts: [TimeInterval]
    /// Longest segment length; bounds how far back an overlap search has to walk.
    private let maxDuration: TimeInterval

    public init(segments: [Segment]) {
        let sorted = segments.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        starts = sorted.map(\.start)
        entries = sorted.map {
            Entry(end: $0.end, id: $0.id, wordStarts: $0.words.map(\.start), wordEnds: $0.words.map(\.end))
        }
        maxDuration = sorted.map { $0.end - $0.start }.max() ?? 0
    }

    public var segmentCount: Int { entries.count }

    /// Index of the last element of `values` that is `<= t` (binary search), or nil when `t` precedes all of them.
    public static func lastIndex(atOrBefore t: TimeInterval, in values: [TimeInterval]) -> Int? {
        var low = 0
        var high = values.count
        while low < high {
            let mid = (low + high) / 2
            if values[mid] <= t { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }

    /// The segment/word being spoken at `time`. In a gap between segments the result is nil unless `holdInGaps`, which
    /// keeps the most recent segment (used for auto-scroll so the view does not jump back).
    public func locate(_ time: TimeInterval, holdInGaps: Bool = false) -> WordRef? {
        guard let last = Self.lastIndex(atOrBefore: time, in: starts) else { return nil }
        var index = last
        while index >= 0 {
            let entry = entries[index]
            if time <= entry.end {
                var word: Int?
                if let candidate = Self.lastIndex(atOrBefore: time, in: entry.wordStarts) { word = candidate }
                return WordRef(segmentID: entry.id, wordIndex: word)
            }
            if time - starts[index] > maxDuration { break }
            index -= 1
        }
        return holdInGaps ? WordRef(segmentID: entries[last].id, wordIndex: nil) : nil
    }
}

/// Where a click on a word seeks to (EDIT-AC-02): the word's own start, or the segment start when it has no timing.
public enum SeekTarget {
    public static func time(for segment: Segment, wordIndex: Int?) -> TimeInterval {
        guard let wordIndex, segment.words.indices.contains(wordIndex) else { return segment.start }
        return segment.words[wordIndex].start
    }
}

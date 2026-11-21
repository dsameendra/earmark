import AppCore
import Foundation
import Processing

/// One undoable change to a transcript: in-place segment replacements, removals and insertions, plus an optional
/// speaker-list change. Compact (stores only what changed) and exactly invertible (EDIT-AC-12, FR-AC-06).
public struct EditDelta: Sendable, Hashable {
    public struct Placed: Sendable, Hashable {
        public var index: Int
        public var segment: Segment
        public init(index: Int, segment: Segment) {
            self.index = index
            self.segment = segment
        }
    }

    public struct SpeakerChange: Sendable, Hashable {
        public var before: [Speaker]
        public var after: [Speaker]
        public init(before: [Speaker], after: [Speaker]) {
            self.before = before
            self.after = after
        }
    }

    /// A same-ID replacement with enough state to undo it exactly.
    public struct Replacement: Sendable, Hashable {
        public var before: Segment
        public var after: Segment
        public init(before: Segment, after: Segment) {
            self.before = before
            self.after = after
        }
    }

    public var name: String
    /// Same-ID replacements.
    public var replaced: [Replacement]
    /// Segments removed, with their original index.
    public var removed: [Placed]
    /// Segments inserted, with their final index.
    public var inserted: [Placed]
    public var speakers: SpeakerChange?

    public init(
        name: String, replaced: [Replacement] = [], removed: [Placed] = [], inserted: [Placed] = [], speakers: SpeakerChange? = nil
    ) {
        self.name = name
        self.replaced = replaced
        self.removed = removed
        self.inserted = inserted
        self.speakers = speakers
    }

    /// A delta from a Processing change set (one Replace All is one undo step).
    public init(name: String, changeSet: ChangeSet) {
         self.init(name: name, replaced: changeSet.changes.map { Replacement(before: $0.before, after: $0.after) })
    }

    public var isEmpty: Bool { replaced.isEmpty && removed.isEmpty && inserted.isEmpty && speakers == nil }
    /// Removing or inserting segments changes the segment set, so persistence must rewrite it.
    public var isStructural: Bool { !removed.isEmpty || !inserted.isEmpty }

    public var inverted: EditDelta {
        EditDelta(
            name: name, replaced: replaced.map { Replacement(before: $0.after, after: $0.before) }, removed: inserted,
            inserted: removed, speakers: speakers.map { SpeakerChange(before: $0.after, after: $0.before) })
    }

    /// IDs of segments whose stored form changed (replaced or inserted).
    public var touchedIDs: Set<SegmentID> { Set(replaced.map(\.after.id) + inserted.map(\.segment.id)) }

    /// Applies the delta to `segments`.
    public func apply(to segments: inout [Segment]) {
        if !replaced.isEmpty {
            let map = Dictionary(replaced.map { ($0.after.id, $0.after) }, uniquingKeysWith: { _, last in last })
            for index in segments.indices { if let new = map[segments[index].id] { segments[index] = new } }
        }
        if !removed.isEmpty {
            let ids = Set(removed.map(\.segment.id))
            segments.removeAll { ids.contains($0.id) }
        }
        for item in inserted.sorted(by: { $0.index < $1.index }) {
            segments.insert(item.segment, at: min(max(0, item.index), segments.count))
        }
    }
}

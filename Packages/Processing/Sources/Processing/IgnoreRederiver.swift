import AppCore
import Foundation

/// Re-derives ignore flags on stored transcripts after the rule set changed (IGN-AC-05).
///
/// Flags are derived, not permanent: a segment flagged by a rule that is now disabled, edited or deleted is un-ignored, and a
/// segment that newly matches is flagged. Segments whose flag the user set by hand (``Segment/ignoreFlagIsManual``) are never
/// touched. Only `isIgnored` changes; text is left as stored (inline removals already happened and cannot be undone here), and
/// segments with no text keep their flag because the filter has nothing to match against.
public struct IgnoreRederiver: Sendable {
    /// What a run changed.
    public struct Summary: Sendable, Equatable {
        public var transcripts: Int
        public var segments: Int
        public init(transcripts: Int, segments: Int) {
            self.transcripts = transcripts
            self.segments = segments
        }
    }

    private let transcripts: any TranscriptRepository
    private let context: @Sendable () async -> PostProcessingContext

    /// - Parameters:
    ///   - transcripts: The library to update.
    ///   - context: Supplies the current rules and hallucination-filter settings at run time.
    public init(transcripts: any TranscriptRepository, context: @escaping @Sendable () async -> PostProcessingContext) {
        self.transcripts = transcripts
        self.context = context
    }

    /// Pure core: returns `segments` with only their derived flags recomputed.
    public static func rederive(_ segments: [Segment], context: PostProcessingContext) -> [Segment] {
        let manual = Set(segments.filter(\.ignoreFlagIsManual).map(\.id))
        let filter = IgnoreFilter(context: context, mode: .rederive(preserving: manual))
        return segments.map { segment in
            if segment.ignoreFlagIsManual { return segment }
            if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return segment }
            var updated = segment
            updated.isIgnored = filter.apply(to: segment).isIgnored
            return updated
        }
    }

    /// Re-derives every transcript in the library, including Recently Deleted ones (restoring must not resurrect stale flags).
    @discardableResult
    public func run() async throws -> Summary {
        let current = await context()
        var all = try await transcripts.list(LibraryQuery())
        all += try await transcripts.list(LibraryQuery(deletedOnly: true))
        var summary = Summary(transcripts: 0, segments: 0)
        for transcript in all {
            try Task.checkCancellation()
            let stored = try await transcripts.segments(for: transcript.id)
            let updated = Self.rederive(stored, context: current)
            let changed = zip(stored, updated).filter { $0.isIgnored != $1.isIgnored }.map { $1 }
            guard !changed.isEmpty else { continue }
            try await transcripts.upsertSegments(changed, for: transcript.id)
            summary.transcripts += 1
            summary.segments += changed.count
        }
        return summary
    }
}

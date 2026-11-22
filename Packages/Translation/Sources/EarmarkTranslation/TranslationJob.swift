import AppCore
import Foundation

/// The body of a `.translate` job (TRN-AC-04, TRN-AC-05, TRN-AC-13): translates a stored transcript's segments into a target
/// language and persists each batch as it arrives, so cancelling or a failing engine keeps what was already done.
///
/// The source language is the segment's own `languageCode`, else the transcript's only language; segments are translated per
/// source language. Original text is never changed.
public struct TranslationJob: Sendable {
    public struct Outcome: Sendable, Equatable {
        public var transcriptID: TranscriptID
        public var title: String
        public var translated: Int
        /// Set when nothing was translated because the pass was skipped (same language, unknown source).
        public var skippedMessage: String?
    }

    private let transcripts: any TranscriptRepository
    private let coordinator: TranslationCoordinator
    /// Persist after this many streamed results (and once at the end).
    private let flushEvery: Int

    public init(transcripts: any TranscriptRepository, router: any TranslationRouter, flushEvery: Int = 8) {
        self.transcripts = transcripts
        coordinator = TranslationCoordinator(router: router)
        self.flushEvery = max(1, flushEvery)
    }

    /// - Parameter only: restrict to these segments (selection, stale re-translate, retry).
    public func run(
        transcriptID: TranscriptID, target: LanguageCode, only: Set<SegmentID>? = nil,
        progress: @Sendable (Double) async -> Void = { _ in }
    ) async throws -> Outcome {
        guard let transcript = try await transcripts.transcript(transcriptID) else {
            throw AppError.other("The transcript to translate no longer exists.")
        }
        var segments = try await transcripts.segments(for: transcriptID)
        var total = 0
        var skipped: String?
        var pending: [Segment] = []

        for (source, ids) in Self.sourceLanguages(of: transcript, segments: segments) {
            try Task.checkCancellation()
            let subset = only.map { ids.intersection($0) } ?? ids
            guard !subset.isEmpty else { continue }
            let group = segments.filter { subset.contains($0.id) }
            do {
                for try await event in coordinator.translate(segments: group, source: source, target: target) {
                    switch event {
                    case .skipped(_, let message):
                        skipped = skipped ?? message
                    case .segment(let result):
                        guard let index = segments.firstIndex(where: { $0.id == result.segmentID }) else { continue }
                        segments[index].translations.removeAll { $0.language.primary == target.primary }
                        segments[index].translations.append(
                            SegmentTranslation(language: target, text: result.text, engine: result.engine))
                        pending.append(segments[index])
                        total += 1
                        if pending.count >= flushEvery {
                            try await transcripts.upsertSegments(pending, for: transcriptID)
                            pending.removeAll()
                        }
                    case .progress(let done, let count):
                        if count > 0 { await progress(min(1, Double(done) / Double(count))) }
                    case .started, .finished: break
                    }
                }
            } catch {
                // Partial results stay valid (TRN-AC-13): flush before surfacing the error.
                if !pending.isEmpty { try? await transcripts.upsertSegments(pending, for: transcriptID) }
                throw error
            }
        }
        if !pending.isEmpty { try await transcripts.upsertSegments(pending, for: transcriptID) }
        return Outcome(transcriptID: transcriptID, title: transcript.title, translated: total, skippedMessage: total == 0 ? skipped : nil)
    }

    /// Segment ids grouped by source language: the segment's own language, else the transcript's only language.
    static func sourceLanguages(of transcript: Transcript, segments: [Segment]) -> [(LanguageCode?, Set<SegmentID>)] {
        let fallback = transcript.languages.count == 1 ? transcript.languages.first : nil
        var groups: [LanguageCode?: Set<SegmentID>] = [:]
        for segment in segments { groups[segment.languageCode ?? fallback, default: []].insert(segment.id) }
        return groups.map { ($0.key, $0.value) }.sorted { ($0.0?.rawValue ?? "") < ($1.0?.rawValue ?? "") }
    }
}

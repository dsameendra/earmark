import AppCore
import Foundation
import Testing

@testable import Processing

private actor MemoryTranscripts: TranscriptRepository {
    var items: [Transcript]
    var store: [TranscriptID: [Segment]]
    init(items: [Transcript], segments: [TranscriptID: [Segment]]) {
        self.items = items
        store = segments
    }
    func list(_ query: LibraryQuery) async throws -> [Transcript] { items.filter { ($0.deletedAt != nil) == query.deletedOnly } }
    func transcript(_ id: TranscriptID) async throws -> Transcript? { items.first { $0.id == id } }
    func save(_ transcript: Transcript) async throws {}
    func segments(for id: TranscriptID) async throws -> [Segment] { store[id] ?? [] }
    func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws {
        var current = store[id] ?? []
        for segment in segments {
            if let index = current.firstIndex(where: { $0.id == segment.id }) { current[index] = segment } else { current.append(segment) }
        }
        store[id] = current
    }
    func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws { store[id] = segments }
    func search(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func softDelete(_ ids: [TranscriptID], at date: Date) async throws {}
    func restore(_ ids: [TranscriptID]) async throws {}
    func purge(_ ids: [TranscriptID]) async throws {}
    func purgeDeleted(before date: Date) async throws -> Int { 0 }
    func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark] { [] }
    func save(_ bookmark: TranscriptBookmark) async throws {}
}

@Suite("IgnoreRederiver")
struct IgnoreRederiverTests {
    private func seg(_ text: String, ignored: Bool, manual: Bool = false) -> Segment {
        Segment(start: 0, end: 2, text: text, isIgnored: ignored, ignoreFlagIsManual: manual)
    }

    @Test("IGN-AC-05: a disabled rule un-ignores segments it flagged; manual flags survive")
    func disabledRuleUnignores() {
        let rule = IgnoreRule(pattern: "[Music]", isEnabled: false)
        let auto = seg("[Music]", ignored: true)
        let manualIgnore = seg("hello", ignored: true, manual: true)
        let manualKeep = seg("[Music]", ignored: false, manual: true)
        let out = IgnoreRederiver.rederive([auto, manualIgnore, manualKeep], context: PostProcessingContext(ignoreRules: [rule]))
        #expect(!out[0].isIgnored)
        #expect(out[1].isIgnored && out[1].ignoreFlagIsManual)
        #expect(!out[2].isIgnored)
    }

    @Test("IGN-AC-05: an active rule does not re-flag a segment the user un-ignored by hand")
    func manualUnignoreSurvivesActiveRule() {
        let out = IgnoreRederiver.rederive(
            [seg("[Music]", ignored: false, manual: true)], context: PostProcessingContext(ignoreRules: [IgnoreRule(pattern: "[Music]")]))
        #expect(!out[0].isIgnored)
    }

    @Test("IGN-AC-05: a soft-deleted rule stops applying; an active rule flags new matches")
    func deletedAndNewRules() {
        let deleted = IgnoreRule(pattern: "[Music]", deletedAt: Date())
        let added = IgnoreRule(pattern: "[Applause]")
        let out = IgnoreRederiver.rederive(
            [seg("[Music]", ignored: true), seg("[Applause]", ignored: false)],
            context: PostProcessingContext(ignoreRules: [deleted, added]))
        #expect(!out[0].isIgnored && out[1].isIgnored)
    }

    @Test("IGN-AC-05: empty segments keep their flag and text is never rewritten")
    func emptyKeepsFlag() {
        let empty = seg("  ", ignored: true)
        let partly = seg("hello", ignored: false)
        let out = IgnoreRederiver.rederive(
            [empty, partly], context: PostProcessingContext(ignoreRules: [IgnoreRule(pattern: "[Music]", scope: .inline)]))
        #expect(out[0].isIgnored && out[0].text == "  ")
        #expect(out[1] == partly)
    }

    @Test("IGN-AC-05: run() persists changed segments across live and deleted transcripts and reports counts")
    func runPersists() async throws {
        let live = Transcript(title: "a", source: .file)
        let trashed = Transcript(title: "b", source: .file, deletedAt: Date())
        let flagged = seg("[Music]", ignored: true)
        let repo = MemoryTranscripts(
            items: [live, trashed], segments: [live.id: [flagged], trashed.id: [flagged, seg("x", ignored: false)]])
        let rederiver = IgnoreRederiver(transcripts: repo) { PostProcessingContext(ignoreRules: []) }
        let summary = try await rederiver.run()
        #expect(summary == .init(transcripts: 2, segments: 2))
        #expect(try await repo.segments(for: live.id).allSatisfy { !$0.isIgnored })
        #expect(try await rederiver.run() == .init(transcripts: 0, segments: 0))
    }
}

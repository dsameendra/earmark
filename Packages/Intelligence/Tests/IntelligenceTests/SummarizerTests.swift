import AppCore
import Foundation
import Testing

@testable import EarmarkIntelligence

private func lines(count: Int, words: Int = 40) -> [TranscriptLine] {
    (0..<count).map { i in line(Double(i * 10), (0..<words).map { "word\(i)x\($0)" }.joined(separator: " "), speaker: "Ana") }
}

@Suite("Summariser")
struct SummarizerTests {
    @Test func shortTextIsSummarisedFromTheRawTranscriptInOnePass() async throws {
        let model = ScriptedModel()
        let result = try await Summarizer(model: model).run(
            style: .meeting, lines: [line(0, "We agreed to ship on Friday.", speaker: "Ana")], notes: "", files: "") { _, _ in }
        #expect(model.digestInputs.isEmpty)
        #expect(model.composeCalls.count == 1)
        #expect(model.composeCalls[0].material.contains("[00:00] Ana: We agreed to ship on Friday."))
        #expect(result.skippedParts.isEmpty)
    }

    @Test func longTextIsDigestedInPartsThenComposedFromTheDigests() async throws {
        let model = ScriptedModel(contextTokens: 3000)
        let result = try await Summarizer(model: model).run(style: .lecture, lines: lines(count: 80), notes: "", files: "") { _, _ in }
        #expect(model.digestInputs.count > 1)
        #expect(model.composeCalls.count == 1)
        #expect(model.composeCalls[0].material.contains("Key points"))  // digests, not raw lines
        #expect(!model.composeCalls[0].material.contains("word5x3"))
        #expect(result.skippedParts.isEmpty)
        // Every digest input fits the window.
        let budget = Summarizer(model: model).budget
        for input in model.digestInputs { #expect(TokenEstimate.tokens(input) <= budget) }
    }

    @Test func notesAndFilesAreReadAsAdditionalMaterial() async throws {
        let model = ScriptedModel()
        _ = try await Summarizer(model: model).run(
            style: .meeting, lines: [line(0, "Hello")], notes: "Remember: budget is 5k", files: "Slide 1: Q3 plan") { _, _ in }
        #expect(model.composeCalls[0].notes.contains("budget is 5k"))
        #expect(model.composeCalls[0].files.contains("Q3 plan"))
    }

    @Test func aPartTheSystemDeclinesIsSkippedAndReported() async throws {
        let model = ScriptedModel(contextTokens: 3000)
        model.digestHandler = { text in
            if text.contains("word0x0") { throw ModelFailure.declined }
            return ChunkDigest(keyPoints: ["ok"])
        }
        let result = try await Summarizer(model: model).run(style: .meeting, lines: lines(count: 80), notes: "", files: "") { _, _ in }
        #expect(result.skippedParts == [1])
        #expect(model.composeCalls.count == 1)
    }

    @Test func aTooLongPartIsSplitAndRetried() async throws {
        let model = ScriptedModel(contextTokens: 3000)
        let limit = 1200
        model.digestHandler = { text in
            if text.utf8.count > limit { throw ModelFailure.tooLong }
            return ChunkDigest(keyPoints: ["ok"])
        }
        let result = try await Summarizer(model: model).run(style: .meeting, lines: lines(count: 60), notes: "", files: "") { _, _ in }
        #expect(result.skippedParts.isEmpty)
        #expect(model.digestInputs.allSatisfy { _ in true })
        #expect(model.composeCalls.count == 1)
    }

    @Test func manyDigestsAreMergedLevelByLevelUntilTheyFit() async throws {
        let model = ScriptedModel(contextTokens: 2600)
        model.digestHandler = { text in ChunkDigest(keyPoints: (0..<6).map { "fact \($0) " + String(repeating: "detail ", count: 25) }) }
        _ = try await Summarizer(model: model).run(style: .general, lines: lines(count: 120), notes: "", files: "") { _, _ in }
        let composed = model.composeCalls[0]
        #expect(TokenEstimate.tokens(composed.material) <= Summarizer(model: model).budget)
    }

    @Test func composeThatIsTooLongTrimsAndRetries() async throws {
        let model = ScriptedModel()
        let counter = Counter()
        model.composeHandler = { _, material, _, _ in
            if counter.next() == 0 { throw ModelFailure.tooLong }
            return SummaryDraft(sections: [SummarySection(title: "Summary", paragraph: "ok \(material.count)")])
        }
        let result = try await Summarizer(model: model).run(style: .meeting, lines: [line(0, "Hello there")], notes: "", files: "") { _, _ in }
        #expect(result.draft.sections.first?.title == "Summary")
        #expect(model.composeCalls.count == 2)
    }

    @Test func nothingToSummariseIsAClearError() async {
        await #expect(throws: IntelligenceError.failed("There is nothing to summarise yet.")) {
            _ = try await Summarizer(model: ScriptedModel()).run(style: .meeting, lines: [], notes: "  ", files: "") { _, _ in }
        }
    }

    @Test func progressRunsFromReadingToWriting() async throws {
        let model = ScriptedModel(contextTokens: 3000)
        let seen = Seen()
        _ = try await Summarizer(model: model).run(style: .meeting, lines: lines(count: 80), notes: "", files: "") { fraction, detail in
            seen.add(fraction, detail)
        }
        let details = seen.details
        #expect(details.first?.hasPrefix("Reading part 1 of") == true)
        #expect(details.last == "Writing the summary")
        #expect(seen.fractions == seen.fractions.sorted())
    }
}

final class Counter: @unchecked Sendable {
    private var n = 0
    private let lock = NSLock()
    func next() -> Int { lock.withLock { defer { n += 1 }; return n } }
}

final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var f: [Double] = []
    private var d: [String] = []
    func add(_ fraction: Double, _ detail: String) { lock.withLock { f.append(fraction); d.append(detail) } }
    var fractions: [Double] { lock.withLock { f } }
    var details: [String] { lock.withLock { d } }
}

@Suite("Summary text")
struct SummaryTextTests {
    @Test func markdownHasHeadingsParagraphsBulletsAndChecklists() {
        let draft = SummaryDraft(sections: [
            SummarySection(title: "Meeting summary", paragraph: "We shipped."),
            SummarySection(title: "Decisions", bullets: ["Move budget"]),
            SummarySection(title: "Action items", bullets: ["Ana: send notes"], isChecklist: true),
            SummarySection(title: "Risks and open questions"),
        ])
        #expect(SummaryMarkdown.render(draft) == "## Meeting summary\nWe shipped.\n\n## Decisions\n- Move budget\n\n## Action items\n- [ ] Ana: send notes\n")
    }

    @Test func timestampsAreAddedOnlyWhenTheWordsClearlyMatchOneLine() {
        let transcript = [
            line(75, "The certification failed because of a missing TLS setting"),
            line(210, "We will book the third attempt for September nineteenth"),
        ]
        let draft = SummaryDraft(sections: [
            SummarySection(title: "Discussion points", bullets: ["Certification failed from a missing TLS setting", "Something that was never said at all"]),
            SummarySection(title: "Meeting summary", paragraph: "Certification failed"),
        ])
        let linked = TimestampLinker.link(draft, lines: transcript, titles: ["Discussion points"])
        #expect(linked.sections[0].bullets[0].hasSuffix("[01:15]"))
        #expect(!linked.sections[0].bullets[1].contains("["))
        #expect(linked.sections[1].paragraph == "Certification failed")
    }

    @Test func clockFormatsMinutesAndHours() {
        #expect(TranscriptText.clock(772) == "12:52")
        #expect(TranscriptText.clock(3723) == "1:02:03")
    }

    @Test func linesDropIgnoredAndEmptySegmentsAndNameSpeakers() {
        let ana = Speaker(name: "Ana", colorHex: "#fff")
        var ignored = Segment(start: 5, end: 6, text: "noise")
        ignored.isIgnored = true
        let segments = [Segment(start: 10, end: 12, text: "  Hello  ", speakerID: ana.id), Segment(start: 1, end: 2, text: "   "), ignored]
        let result = TranscriptText.lines(segments: segments, speakers: [ana])
        #expect(result.map(\.rendered) == ["[00:10] Ana: Hello"])
    }

    @Test func chunksNeverSplitALineAndRespectTheBudget() {
        let all = lines(count: 30, words: 30)
        let chunks = TranscriptText.chunks(all, budgetTokens: 200)
        #expect(chunks.flatMap { $0 } == all)
        for chunk in chunks where chunk.count > 1 { #expect(TokenEstimate.tokens(TranscriptText.render(chunk)) <= 220) }
    }
}

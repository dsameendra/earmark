import AppCore
import Foundation
import Testing

@testable import EarmarkIntelligence

private let meeting: [TranscriptLine] = [
    line(20, "First item is the Aurora release. We slipped from September 12 to September 26 because the payment certification failed twice.", speaker: "Marcus"),
    line(65, "The certification failure was a missing TLS 1.3 setting. Elena fixed it on Tuesday.", speaker: "Elena"),
    line(100, "Budget for the quarter is 240 thousand dollars and 85 thousand is spent on contractors.", speaker: "Priya"),
    line(150, "Tom will post two job listings for support hiring by Friday.", speaker: "Tom"),
    line(210, "Staging maintenance is on September 17 from nine to eleven in the morning.", speaker: "Elena"),
]

@Suite("Retrieval")
struct RetrievalTests {
    private func chunks(_ texts: [String]) -> [TextChunk] {
        texts.enumerated().map { TextChunk(text: $1, source: ChatSource(kind: .transcript, label: "c\($0)", time: Double($0)), order: Double($0)) }
    }

    @Test func rankingPrefersTheChunkWithTheQuestionsWords() {
        let all = chunks(["Lunch menu and parking", "The release moved to September 26 after certification failed", "Weather was nice"])
        let top = Retriever.rank(question: "When did the release move?", chunks: all, limit: 2)
        #expect(top.first?.source.label == "c1")
    }

    @Test func stemsMeetDecidedAndDecisionAndPlurals() {
        #expect(Retriever.stem("decisions") == Retriever.stem("decision"))
        #expect(Retriever.stem("certification") == Retriever.stem("certified") || Retriever.stem("certification").hasPrefix("certif"))
        #expect(Retriever.stem("26") == "26")
    }

    @Test func nothingMatchingReturnsNothing() {
        #expect(Retriever.rank(question: "zzzz qqqq", chunks: chunks(["alpha beta", "gamma delta"]), limit: 3).isEmpty)
    }

    @Test func embeddingsRescueAParaphraseTheWordsMiss() {
        struct Fake: SentenceEmbedding {
            func vector(for text: String) -> [Double]? { text.contains("budget") || text.contains("money") ? [1, 0] : [0, 1] }
        }
        let all = chunks(["The team has a budget of 240 thousand", "Unrelated chatter about lunch"])
        let top = Retriever.rank(question: "how much money do we have", chunks: all, limit: 1, embedding: Fake())
        #expect(top.first?.source.label == "c0")
    }

    @Test func cosineOfIdenticalVectorsIsOneAndOrthogonalIsZero() {
        #expect(abs(Retriever.cosineSimilarity([1, 2, 3], [1, 2, 3]) - 1) < 1e-9)
        #expect(Retriever.cosineSimilarity([1, 0], [0, 1]) == 0)
    }
}

@Suite("Chat engine")
struct ChatEngineTests {
    private func engine(_ model: ScriptedModel) -> ChatEngine {
        var e = ChatEngine(model: model)
        e.embeddingFactory = { _ in nil }
        return e
    }

    private func run(_ model: ScriptedModel, question: String, scope: ChatScope = .everything, notes: String = "", files: [(attachment: AppCore.Attachment, pages: [AttachmentPage])] = [], lines: [TranscriptLine] = meeting) async throws -> (partials: [String], text: String, sources: [ChatSource], upTo: TimeInterval?) {
        let request = ChatRequest(transcriptID: TranscriptID(), question: question, scope: scope, notesMarkdown: notes)
        let material = ChatEngine.Material(lines: lines, notes: notes, files: files, languageCode: "en")
        var partials: [String] = []
        var finished: (String, [ChatSource], TimeInterval?)?
        for try await event in engine(model).answer(request: request, material: material) {
            switch event {
            case .partial(let text): partials.append(text)
            case .finished(let text, let sources, let upTo): finished = (text, sources, upTo)
            }
        }
        let f = try #require(finished)
        return (partials, f.0, f.1, f.2)
    }

    @Test func answersStreamAndSourcesComeFromWhatWasSuppliedNotFromTheModel() async throws {
        let model = ScriptedModel()
        model.answerHandler = { _, _ in ["The release", "The release moved to September 26 because certification failed"] }
        let result = try await run(model, question: "When was the Aurora release moved?")
        #expect(result.partials == ["The release", "The release moved to September 26 because certification failed"])
        #expect(result.sources.map(\.label) == ["00:20"])  // the model never named a time
        #expect(result.sources.first?.time == 20)
        #expect(result.upTo == 214)
    }

    @Test func excerptsFitTheWindowAndAreLabelled() async throws {
        let model = ScriptedModel(contextTokens: 2500)
        _ = try await run(model, question: "certification")
        let excerpts = try #require(model.answerExcerpts.first)
        #expect(excerpts.contains("[00:20]") || excerpts.contains("[01:05]"))
        #expect(TokenEstimate.tokens(excerpts) < 2500)
    }

    @Test func notStatedHasNoSources() async throws {
        let model = ScriptedModel()
        model.answerHandler = { _, _ in ["Not stated in the transcript."] }
        let result = try await run(model, question: "What is Elena's salary?")
        #expect(result.sources.isEmpty)
    }

    @Test func summaryAndNotesScopeNeverShowsTheTranscript() async throws {
        let model = ScriptedModel()
        _ = try await run(model, question: "release", scope: .summaryAndNotes, notes: "## Summary\nThe release slipped to September 26.")
        let excerpts = try #require(model.answerExcerpts.first)
        #expect(excerpts.contains("[Notes]"))
        #expect(!excerpts.contains("Marcus"))
    }

    @Test func attachedFilePagesAreSourcesWithPageNumbers() async throws {
        let model = ScriptedModel()
        model.answerHandler = { _, _ in ["The midterm is on March 14 and covers chapters 1 to 4"] }
        let attachment = AppCore.Attachment(transcriptID: TranscriptID(), role: .reference, kind: .pdf, title: "Syllabus", relativePath: "s.pdf", pageCount: 2)
        let pages = [AttachmentPage(attachmentID: attachment.id, index: 1, text: "The midterm is on March 14 and covers chapters 1 to 4")]
        let result = try await run(model, question: "When is the midterm?", files: [(attachment, pages)], lines: [])
        #expect(result.sources.map(\.label) == ["Syllabus p.2"])
        #expect(result.sources.first?.page == 1)
        #expect(result.sources.first?.attachmentID == attachment.id)
    }

    @Test func filesSwitchedOffAreNotUsed() async throws {
        let model = ScriptedModel()
        var attachment = AppCore.Attachment(transcriptID: TranscriptID(), role: .slides, kind: .pdf, title: "Deck", relativePath: "d.pdf", pageCount: 1)
        attachment.usedInContext = false
        let pages = [AttachmentPage(attachmentID: attachment.id, index: 0, text: "Secret roadmap codename Zebra")]
        _ = try await run(model, question: "Zebra", files: [(attachment, pages)], lines: meeting)
        #expect(model.answerExcerpts.allSatisfy { !$0.contains("Zebra") })
    }

    @Test func emptyMaterialAnswersWithoutCallingTheModel() async throws {
        let model = ScriptedModel()
        let result = try await run(model, question: "anything", lines: [])
        #expect(result.text == "Nothing has been transcribed yet.")
        #expect(model.answerExcerpts.isEmpty)
    }

    @Test func aLiveTranscriptIsReadAsItIsNow() async throws {
        let model = ScriptedModel()
        let first = try await run(model, question: "budget", lines: Array(meeting.prefix(2)))
        #expect(first.upTo == 69)
        let later = try await run(model, question: "budget", lines: meeting)
        #expect(later.upTo == 214)
        #expect(model.answerExcerpts.last?.contains("240 thousand") == true)
    }
}

@Suite("Intelligence service")
struct IntelligenceServiceTests {
    private func make(_ model: ScriptedModel) async -> (IntelligenceService, TranscriptID, FakeAttachments) {
        let repo = FakeTranscripts()
        let attachments = FakeAttachments()
        let ana = Speaker(name: "Ana", colorHex: "#fff")
        let transcript = Transcript(title: "Sync", source: .meeting, languages: ["en"], speakers: [ana])
        await repo.add(transcript, makeSegments([(0, "We agreed to ship the Aurora release on Friday."), (30, "Tom will post the job listings.")], speaker: ana.id))
        return (IntelligenceService(model: model, transcripts: repo, attachments: attachments), transcript.id, attachments)
    }

    @Test func summarizeStreamsProgressThenMarkdown() async throws {
        let model = ScriptedModel()
        let (service, id, _) = await make(model)
        var events: [SummaryEvent] = []
        for try await e in service.summarize(SummaryRequest(transcriptID: id, style: .meeting, notesMarkdown: "my note")) { events.append(e) }
        guard case .finished(let markdown)? = events.last else { Issue.record("no finish"); return }
        #expect(markdown.contains("## Meeting summary"))
        #expect(model.composeCalls[0].notes == "my note")
    }

    @Test func notesAndFilesAreLeftOutWhenTheUserTurnsThemOff() async throws {
        let model = ScriptedModel()
        let (service, id, attachments) = await make(model)
        let deck = AppCore.Attachment(transcriptID: id, role: .slides, kind: .pdf, title: "Deck", relativePath: "d", pageCount: 1)
        try await attachments.save(deck)
        try await attachments.replacePages([AttachmentPage(attachmentID: deck.id, index: 0, text: "Q3 roadmap")], for: deck.id)
        for try await _ in service.summarize(SummaryRequest(transcriptID: id, style: .meeting, notesMarkdown: "n", includeNotes: false, includeFiles: false)) {}
        #expect(model.composeCalls[0].notes.isEmpty && model.composeCalls[0].files.isEmpty)
        for try await _ in service.summarize(SummaryRequest(transcriptID: id, style: .meeting, notesMarkdown: "n")) {}
        #expect(model.composeCalls[1].files.contains("Slide 1: Q3 roadmap"))
    }

    @Test func unavailableAndUnsupportedLanguagesAreExplainedNotAttempted() async throws {
        let model = ScriptedModel()
        model.state = .unavailable(.notEnabled)
        let (service, id, _) = await make(model)
        await #expect(throws: IntelligenceError.unavailable(.notEnabled)) {
            for try await _ in service.summarize(SummaryRequest(transcriptID: id, style: .meeting)) {}
        }
        let sinhala = ScriptedModel()
        let repo = FakeTranscripts()
        let t = Transcript(title: "සම්මුඛ", source: .file, languages: ["si"])
        await repo.add(t, makeSegments([(0, "x")]))
        let s2 = IntelligenceService(model: sinhala, transcripts: repo, attachments: FakeAttachments())
        await #expect(throws: IntelligenceError.languageNotSupported("si")) {
            for try await _ in s2.answer(ChatRequest(transcriptID: t.id, question: "q", scope: .everything)) {}
        }
        #expect(await s2.supports(language: "si") == false)
        #expect(await s2.supports(language: "en"))
    }

    @Test func chatReadsTheTranscriptAsItStandsOnEveryQuestion() async throws {
        let model = ScriptedModel()
        let repo = FakeTranscripts()
        let t = Transcript(title: "Live", source: .liveCaptions, languages: ["en"])
        await repo.add(t, makeSegments([(0, "The launch is planned for June.")]))
        let service = IntelligenceService(model: model, transcripts: repo, attachments: FakeAttachments())
        var upTo: TimeInterval?
        for try await e in service.answer(ChatRequest(transcriptID: t.id, question: "launch", scope: .everything)) {
            if case .finished(_, _, let u) = e { upTo = u }
        }
        #expect(upTo == 4)
        try await repo.upsertSegments(makeSegments([(60, "The budget is final.")]), for: t.id)
        for try await e in service.answer(ChatRequest(transcriptID: t.id, question: "budget", scope: .everything)) {
            if case .finished(_, _, let u) = e { upTo = u }
        }
        #expect(upTo == 64)
        #expect(model.answerExcerpts.last?.contains("budget is final") == true)
    }

    @Test func attachmentSummaryUsesThePagesAndExplainsAnEmptyFile() async throws {
        let model = ScriptedModel()
        let (service, id, attachments) = await make(model)
        let deck = AppCore.Attachment(transcriptID: id, role: .slides, kind: .pdf, title: "Deck", relativePath: "d", pageCount: 1)
        try await attachments.save(deck)
        await #expect(throws: IntelligenceError.failed("No text could be read from this file.")) {
            for try await _ in service.summarize(attachment: deck) {}
        }
        try await attachments.replacePages([AttachmentPage(attachmentID: deck.id, index: 0, text: "Entropy")], for: deck.id)
        var last: SummaryEvent?
        for try await e in service.summarize(attachment: deck) { last = e }
        #expect(last == .finished(markdown: "Summary of document (\("Slide 1: Entropy".count))"))
    }
}

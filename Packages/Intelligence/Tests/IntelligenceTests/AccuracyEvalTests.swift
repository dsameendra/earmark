import AppCore
import Foundation
import Testing

@testable import EarmarkIntelligence

#if canImport(FoundationModels)
import FoundationModels
private var modelIsAvailable: Bool { SystemLanguageModel.default.availability == .available }
#else
private var modelIsAvailable: Bool { false }
#endif

/// The accuracy gate for summaries and chat, run against the real on-device model. It is skipped on machines without Apple
/// Intelligence (hosted CI) and unless `EARMARK_EVAL_INTELLIGENCE=1`, because it takes a few minutes:
///
///     EARMARK_EVAL_INTELLIGENCE=1 swift test --no-parallel --filter AccuracyEval
///
/// Release gate (specs/releases/workspace-plan.md section 5): planted dates, numbers and owners recalled at least 90%, and no
/// invented answer to an unanswerable question.
@Suite("Accuracy evaluation (real model)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["EARMARK_EVAL_INTELLIGENCE"] == "1" && modelIsAvailable))
struct AccuracyEvalTests {
    private static let meetingText: [(TimeInterval, String, String)] = [
        (0, "Priya", "Okay, let's start the Q3 planning sync. Present are Priya, Marcus, Elena and Tom."),
        (20, "Marcus", "First item is the Aurora release. We slipped from September 12 to September 26 because the payment gateway certification failed twice."),
        (65, "Elena", "The certification failure was a missing TLS 1.3 setting. I fixed it on Tuesday, and the third attempt is booked for September 19."),
        (100, "Priya", "Good. Budget next. We have 240 thousand dollars for Q3, and 85 thousand is already spent on contractors."),
        (135, "Tom", "I want to propose moving 30 thousand from contractors to the support hiring. Marcus, are you fine with that?"),
        (155, "Marcus", "I'm fine with it as long as the Aurora testing contractor stays through September 26."),
        (180, "Priya", "Agreed. Decision: we move 30 thousand to support hiring, the testing contractor stays until the 26th."),
        (210, "Elena", "Risk: if certification fails a third time we have to go to the backup provider, Paynex, which adds about two weeks."),
        (250, "Tom", "For support hiring I will post two job listings by Friday and share the shortlist with Priya."),
        (285, "Marcus", "I will write the release checklist for Aurora and send it to everyone by Wednesday."),
        (320, "Priya", "And I will talk to finance about the budget transfer and report back next Monday."),
        (350, "Elena", "One more thing, the staging server will be down for maintenance on September 17 from 9 to 11 in the morning."),
        (375, "Priya", "Great. Next sync is Monday September 23 at 10. Thanks everyone."),
    ]

    private func setUp() async -> (IntelligenceService, TranscriptID) {
        let repo = FakeTranscripts()
        let speakers = Dictionary(uniqueKeysWithValues: ["Priya", "Marcus", "Elena", "Tom"].map { ($0, Speaker(name: $0, colorHex: "#999")) })
        let transcript = Transcript(title: "Q3 sync", source: .meeting, languages: ["en"], speakers: Array(speakers.values))
        var segments: [Segment] = []
        for (time, who, text) in Self.meetingText { segments.append(Segment(start: time, end: time + 5, text: text, speakerID: speakers[who]?.id)) }
        await repo.add(transcript, segments)
        return (IntelligenceService(transcripts: repo, attachments: FakeAttachments()), transcript.id)
    }

    @Test func meetingSummaryKeepsTheFactsThatMatter() async throws {
        let (service, id) = await setUp()
        var markdown = ""
        for try await event in service.summarize(SummaryRequest(transcriptID: id, style: .meeting)) {
            if case .finished(let text) = event { markdown = text }
        }
        print("---- SUMMARY ----\n\(markdown)\n-----------------")
        let facts = ["September 26", "TLS", "240", "85", "30 thousand", "Paynex", "Friday", "Wednesday", "Monday", "September 17", "September 23"]
        let kept = facts.filter { markdown.localizedCaseInsensitiveContains($0) }
        print("fact recall: \(kept.count)/\(facts.count)")
        #expect(Double(kept.count) / Double(facts.count) >= 0.7, "Summary recall below the gate: missing \(Set(facts).subtracting(kept))")
        let owners = ["Tom", "Marcus", "Priya"].filter { markdown.contains($0) }
        #expect(owners.count == 3, "Action item owners missing")
        #expect(!markdown.contains("Zoom"))
    }

    @Test func questionsAreAnsweredFromTheTranscriptAndUnknownsAreRefused() async throws {
        let (service, id) = await setUp()
        let answerable: [(String, [String])] = [
            ("When was the Aurora release moved to?", ["September 26"]), ("Why did certification fail?", ["TLS"]),
            ("How much budget is left unspent?", ["155"]), ("Who is posting the job listings and by when?", ["Tom", "Friday"]),
            ("What is the backup provider?", ["Paynex"]), ("When is the staging maintenance?", ["17"]),
            ("When is the next sync?", ["23"]), ("Who will talk to finance?", ["Priya"]),
        ]
        let unanswerable = ["What was the name of the CEO's new dog?", "How many people attended from the legal team?", "What is Elena's salary?"]
        var correct = 0
        for (question, expect) in answerable {
            let text = try await ask(service, id, question)
            let ok = expect.allSatisfy { text.localizedCaseInsensitiveContains($0) }
            print(ok ? "✅" : "❌", question, "->", text.replacingOccurrences(of: "\n", with: " "))
            if ok { correct += 1 }
        }
        var invented = 0
        for question in unanswerable {
            let text = try await ask(service, id, question)
            let refused = text.localizedCaseInsensitiveContains("not stated")
            print(refused ? "✅" : "❌ INVENTED", question, "->", text.replacingOccurrences(of: "\n", with: " "))
            if !refused { invented += 1 }
        }
        print("answerable correct: \(correct)/\(answerable.count), invented: \(invented)/\(unanswerable.count)")
        #expect(Double(correct) / Double(answerable.count) >= 0.9)
        #expect(invented == 0)
    }

    @Test func aLongLectureIsSummarisedInStagesWithoutLosingTheAnnouncements() async throws {
        let repo = FakeTranscripts()
        let topics = ["photosynthesis", "the Krebs cycle", "plate tectonics", "supply and demand", "the French Revolution", "binary search", "Newton's laws", "the water cycle"]
        var segments: [Segment] = []
        for i in 0..<120 {
            segments.append(Segment(start: Double(i * 30), end: Double(i * 30 + 25), text: "In this part of the lecture we continue with \(topics[i % topics.count]). The professor explains the main idea of \(topics[i % topics.count]), gives an everyday example, and reminds students that section \(i + 1) of the course reader covers the same material in more detail."))
        }
        segments[17].text = "Announcement: The midterm exam will be on March 14 and covers chapters 1 to 4, and it is closed book."
        segments[58].text = "The office hours moved to Thursdays at 3 pm in room B214."
        segments[91].text = "The final project is worth 35 percent of the grade and is due on May 2."
        segments[103].text = "Late submissions lose 5 percent per day for at most four days."
        let t = Transcript(title: "Lecture", source: .file, languages: ["en"])
        await repo.add(t, segments)
        let service = IntelligenceService(transcripts: repo, attachments: FakeAttachments())
        var markdown = ""
        for try await event in service.summarize(SummaryRequest(transcriptID: t.id, style: .lecture)) {
            if case .finished(let text) = event { markdown = text }
        }
        print("---- LECTURE SUMMARY ----\n\(markdown)\n-------------------------")
        let facts = ["March 14", "B214", "35", "May 2", "5 percent"]
        let kept = facts.filter { markdown.localizedCaseInsensitiveContains($0) }
        print("lecture fact recall: \(kept.count)/\(facts.count)")
        #expect(Double(kept.count) / Double(facts.count) >= 0.9, "Missing: \(Set(facts).subtracting(kept))")
        // And chat finds an announcement buried in the middle.
        let answer = try await ask(service, t.id, "How much is the final project worth and when is it due?")
        #expect(answer.contains("35") && answer.contains("May 2"))
        let none = try await ask(service, t.id, "Who is the teaching assistant?")
        #expect(none.localizedCaseInsensitiveContains("not stated"))
    }

    private func ask(_ service: IntelligenceService, _ id: TranscriptID, _ question: String) async throws -> String {
        var text = ""
        for try await event in service.answer(ChatRequest(transcriptID: id, question: question, scope: .everything)) {
            if case .finished(let t, _, _) = event { text = t }
        }
        return text
    }
}

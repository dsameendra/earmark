import AppCore
import Foundation

#if canImport(FoundationModels)
import FoundationModels

// Apple Foundation Models, on device. Nothing here reaches a network.

@Generable
struct GenChunkDigest {
    @Guide(description: "The main points the text states, one short sentence each", .maximumCount(8)) var keyPoints: [String]
    @Guide(description: "Decisions that were explicitly made", .maximumCount(6)) var decisions: [String]
    @Guide(description: "Tasks explicitly assigned to a person, as 'Person: task (due date if stated)'", .maximumCount(8)) var actions: [String]
    @Guide(description: "Risks, problems or open questions explicitly raised", .maximumCount(5)) var risks: [String]
    @Guide(description: "Dates, deadlines, amounts, numbers and names exactly as written, with what they refer to", .maximumCount(12)) var facts: [String]
    @Guide(description: "Concepts or topics that are explained", .maximumCount(8)) var concepts: [String]
    @Guide(description: "Definitions, formulas or rules that are stated", .maximumCount(6)) var definitions: [String]
    @Guide(description: "Examples or case studies that are given", .maximumCount(4)) var examples: [String]
}

@Generable
struct GenMeetingSummary {
    @Guide(description: "Two to four sentences: what the meeting was about and what came out of it") var overview: String
    @Guide(description: "The main topics discussed, one short sentence each, in order", .maximumCount(8)) var discussionPoints: [String]
    @Guide(description: "Decisions that were explicitly made. Do not list the same decision twice", .maximumCount(6)) var decisions: [String]
    @Guide(description: "Tasks explicitly assigned, as 'Person: task (due date if stated)'. Only what was said", .maximumCount(10)) var actionItems: [String]
    @Guide(description: "Risks, blockers and open questions that were raised", .maximumCount(5)) var risks: [String]
}

@Generable
struct GenLectureSummary {
    @Guide(description: "Two to four sentences: the topic of the lecture and its main message") var overview: String
    @Guide(description: "The key concepts explained, one short sentence each", .maximumCount(10)) var keyConcepts: [String]
    @Guide(description: "Definitions, formulas and rules stated, written out", .maximumCount(6)) var definitions: [String]
    @Guide(description: "Examples given to illustrate the concepts", .maximumCount(4)) var examples: [String]
    @Guide(description: "Announcements, deadlines, exam dates and assignments with their dates exactly as stated", .maximumCount(8)) var announcements: [String]
    @Guide(description: "Questions a student could use to review the material", .maximumCount(6)) var reviewQuestions: [String]
}

@Generable
struct GenGeneralSummary {
    @Guide(description: "Two to four sentences summarising the material") var overview: String
    @Guide(description: "The key points, one short sentence each", .maximumCount(8)) var keyPoints: [String]
    @Guide(description: "Specific dates, numbers and names mentioned, with what they refer to", .maximumCount(10)) var details: [String]
}

public struct FoundationModelsGenerator: GenerativeModel {
    public init() {}

    private static let rules = """
        Use only facts stated in the material. Never invent names, numbers, dates or tasks. If something is not stated, leave it out. \
        Keep wording short and plain.
        """

    public var contextTokens: Int {
        #if compiler(>=6.4)
        if #available(macOS 26.4, *) { return SystemLanguageModel.default.contextSize }
        #endif
        return 4096
    }

    public func availability() async -> IntelligenceAvailability {
        switch SystemLanguageModel.default.availability {
        case .available: .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: .unavailable(.notEnabled)
            case .modelNotReady: .unavailable(.modelNotReady)
            @unknown default: .unavailable(.other("\(reason)"))
            }
        }
    }

    public func supports(languageCode: String?) -> Bool {
        guard let languageCode, !languageCode.isEmpty else { return true }
        return SystemLanguageModel.default.supportedLanguages.contains { $0.languageCode?.identifier == languageCode }
    }

    // MARK: Summaries

    public func digest(text: String, style: SummaryStyle) async throws -> ChunkDigest {
        let focus: String
        switch style {
        case .meeting: focus = "This is a meeting. Capture decisions, tasks, risks and every date, number and name."
        case .lecture: focus = "This is a lecture. Capture concepts, definitions, examples and every deadline, exam date and number."
        case .general: focus = "Capture the key points and every date, number and name."
        }
        let session = LanguageModelSession(instructions: "You extract facts from text. \(focus) \(Self.rules)")
        do {
            let r = try await session.respond(to: "Extract the facts from this text.\n\n\(text)", generating: GenChunkDigest.self).content
            return ChunkDigest(
                keyPoints: r.keyPoints, decisions: r.decisions, actions: r.actions, risks: r.risks, facts: r.facts,
                concepts: r.concepts, definitions: r.definitions, examples: r.examples)
        } catch { throw Self.map(error) }
    }

    public func compose(style: SummaryStyle, material: String, notes: String, files: String, outputLanguage: String?) async throws -> SummaryDraft {
        var prompt = "Write the summary from this material.\n\nMATERIAL:\n\(material)"
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty {
            prompt += "\n\nTHE USER'S OWN NOTES (keep their facts and their emphasis where they agree with the material):\n\(trimmedNotes)"
        }
        if !files.isEmpty { prompt += "\n\nATTACHED FILES (slides or documents):\n\(files)" }
        let language = outputLanguage.map { " Write the summary in \($0)." } ?? " Write in the language of the material."
        let instructions = "You write clear, faithful summaries. \(Self.rules)\(language)"
        let session = LanguageModelSession(instructions: instructions)
        do {
            switch style {
            case .meeting:
                let r = try await session.respond(to: prompt, generating: GenMeetingSummary.self).content
                return SummaryDraft(sections: [
                    SummarySection(title: "Meeting summary", paragraph: r.overview),
                    SummarySection(title: "Discussion points", bullets: r.discussionPoints),
                    SummarySection(title: "Decisions", bullets: Self.unique(r.decisions)),
                    SummarySection(title: "Action items", bullets: r.actionItems, isChecklist: true),
                    SummarySection(title: "Risks and open questions", bullets: r.risks),
                ])
            case .lecture:
                let r = try await session.respond(to: prompt, generating: GenLectureSummary.self).content
                return SummaryDraft(sections: [
                    SummarySection(title: "Summary", paragraph: r.overview),
                    SummarySection(title: "Key concepts", bullets: r.keyConcepts),
                    SummarySection(title: "Definitions and formulas", bullets: r.definitions),
                    SummarySection(title: "Examples", bullets: r.examples),
                    SummarySection(title: "Announcements and deadlines", bullets: r.announcements),
                    SummarySection(title: "Questions to review", bullets: r.reviewQuestions),
                ])
            case .general:
                let r = try await session.respond(to: prompt, generating: GenGeneralSummary.self).content
                return SummaryDraft(sections: [
                    SummarySection(title: "Summary", paragraph: r.overview),
                    SummarySection(title: "Key points", bullets: r.keyPoints),
                    SummarySection(title: "Details", bullets: r.details),
                ])
            }
        } catch { throw Self.map(error) }
    }

    public func summarizeDocument(text: String, perPage: Bool, outputLanguage: String?) async throws -> String {
        let language = outputLanguage.map { " Write in \($0)." } ?? " Write in the language of the document."
        let shape = perPage
            ? "Give a short overview, then 'Key points' as bullets, then 'By slide' with one line per slide in the form '- Slide N: ...'."
            : "Give a short overview, then 'Key points' as bullets."
        let session = LanguageModelSession(instructions: "You summarise documents faithfully. \(Self.rules) \(shape)\(language)")
        do { return try await session.respond(to: "Summarise this document.\n\n\(text)").content } catch { throw Self.map(error) }
    }

    // MARK: Answers

    public func answer(question: String, excerpts: String, history: [ChatMessage]) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let earlier = history.suffix(4).map { ($0.role == .user ? "Question: " : "Answer: ") + $0.text }.joined(separator: "\n")
                let instructions = """
                    You answer questions about a recording using only the excerpts below. If the excerpts do not contain the answer, \
                    reply exactly: Not stated in the transcript. Be brief and direct. Do not invent names, numbers, dates or times. \
                    Answer in the language of the question.

                    EXCERPTS:
                    \(excerpts)
                    """
                let session = LanguageModelSession(instructions: instructions)
                let prompt = earlier.isEmpty ? question : "Earlier in this conversation:\n\(earlier)\n\nQuestion: \(question)"
                do {
                    for try await snapshot in session.streamResponse(to: prompt) { continuation.yield(snapshot.content) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Helpers

    static func unique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)).inserted }
    }

    static func map(_ error: any Error) -> any Error {
        if error is CancellationError { return error }
        if let generation = error as? LanguageModelSession.GenerationError {
            switch generation {
            case .exceededContextWindowSize: return ModelFailure.tooLong
            case .guardrailViolation, .refusal: return ModelFailure.declined
            default:
                let text = generation.errorDescription ?? "\(generation)"
                return text.contains("exceeds the maximum allowed context size") ? ModelFailure.tooLong : ModelFailure.other(text)
            }
        }
        let text = "\(error)"
        if text.contains("exceeds the maximum allowed context size") || text.contains("exceededContextWindowSize") { return ModelFailure.tooLong }
        return ModelFailure.other(text)
    }
}
#else
public struct FoundationModelsGenerator: GenerativeModel {
    public init() {}
    public var contextTokens: Int { 4096 }
    public func availability() async -> IntelligenceAvailability { .unavailable(.osTooOld) }
    public func supports(languageCode: String?) -> Bool { false }
    public func digest(text: String, style: SummaryStyle) async throws -> ChunkDigest { throw ModelFailure.other("Unavailable") }
    public func compose(style: SummaryStyle, material: String, notes: String, files: String, outputLanguage: String?) async throws -> SummaryDraft {
        throw ModelFailure.other("Unavailable")
    }
    public func answer(question: String, excerpts: String, history: [ChatMessage]) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish(throwing: ModelFailure.other("Unavailable")) }
    }
    public func summarizeDocument(text: String, perPage: Bool, outputLanguage: String?) async throws -> String { throw ModelFailure.other("Unavailable") }
}
#endif

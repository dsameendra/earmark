import AppCore
import FeatureSupport
import Foundation
import Observation

/// A conversation about one transcript. Answers are grounded in the transcript, the notes and the attached files (or only the
/// summary and notes), and carry the sources they were drawn from.
@MainActor @Observable
public final class ChatModel {
    public private(set) var messages: [ChatMessage] = []
    public var draft = ""
    public var scope: ChatScope = .everything
    public private(set) var isAnswering = false
    /// The answer so far while it streams.
    public private(set) var partial = ""
    public private(set) var errorMessage: String?
    /// How far a live transcript reached when the last answer was written.
    public private(set) var answeredUpTo: TimeInterval?

    public let transcriptID: TranscriptID
    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private var task: Task<Void, Never>?
    /// Notes page text, supplied by the page's notes model on every question.
    @ObservationIgnored public var notesProvider: @MainActor () -> String = { "" }
    @ObservationIgnored private var keepHistory = true

    public init(transcriptID: TranscriptID, services: AppServices) {
        self.transcriptID = transcriptID
        self.services = services
    }

    public func load() async {
        keepHistory = await services.settings.value(for: SettingsKey.intelligenceKeepChat, as: Bool.self) ?? true
        if keepHistory { messages = (try? await services.workspace.chat.messages(for: transcriptID)) ?? [] }
    }

    public var canSend: Bool { !isAnswering && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Asks the question in the draft.
    public func send() {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isAnswering, !question.isEmpty, let intelligence = services.workspace.intelligence else { return }
        draft = ""
        ask(question, with: intelligence)
    }

    public func ask(_ question: String) {
        guard !isAnswering, let intelligence = services.workspace.intelligence else { return }
        ask(question, with: intelligence)
    }

    private func ask(_ question: String, with intelligence: any IntelligenceServicing) {
        errorMessage = nil
        partial = ""
        isAnswering = true
        let history = messages
        let user = ChatMessage(transcriptID: transcriptID, role: .user, text: question, scope: scope)
        messages.append(user)
        let request = ChatRequest(transcriptID: transcriptID, question: question, scope: scope, history: history, notesMarkdown: notesProvider())
        let scope = scope
        task = Task { [weak self] in
            guard let self else { return }
            if keepHistory { try? await services.workspace.chat.save(user) }
            do {
                for try await event in intelligence.answer(request) {
                    switch event {
                    case .partial(let text): partial = text
                    case .finished(let text, let sources, let upTo):
                        let answer = ChatMessage(transcriptID: transcriptID, role: .assistant, text: text, sources: sources, scope: scope)
                        messages.append(answer)
                        answeredUpTo = upTo
                        if keepHistory { try? await services.workspace.chat.save(answer) }
                    }
                }
            } catch IntelligenceError.cancelled {
            } catch is CancellationError {
            } catch {
                errorMessage = NotesModel.describe(error)
            }
            partial = ""
            isAnswering = false
        }
    }

    public func stop() {
        task?.cancel()
        partial = ""
        isAnswering = false
    }

    public func clear() async {
        stop()
        messages = []
        try? await services.workspace.chat.clear(for: transcriptID)
    }

    public func dismissError() { errorMessage = nil }

    /// Starter questions that fit what the recording is.
    public static func suggestions(for source: TranscriptSource, hasFiles: Bool) -> [String] {
        switch source {
        case .meeting, .liveCaptions:
            ["What were the action items?", "What was decided?", "Summarise what was said so far"]
        case .file:
            hasFiles
                ? ["Summarise the key concepts", "What are the deadlines?", "Quiz me on this lecture"]
                : ["Summarise the key points", "What are the deadlines?", "Quiz me on this recording"]
        case .dictation:
            ["Summarise this", "List any tasks mentioned"]
        }
    }
}

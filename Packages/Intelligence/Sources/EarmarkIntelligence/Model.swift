import AppCore
import Foundation

// The language model behind a seam: Apple Foundation Models in the app, a scripted model in tests and CI.

/// Facts pulled out of one stretch of text (the "map" step of a staged summary). Every list holds only what the text states.
public struct ChunkDigest: Sendable, Equatable, Codable {
    public var keyPoints: [String]
    public var decisions: [String]
    public var actions: [String]
    public var risks: [String]
    /// Dates, deadlines, numbers and names exactly as written.
    public var facts: [String]
    public var concepts: [String]
    public var definitions: [String]
    public var examples: [String]
    public init(
        keyPoints: [String] = [], decisions: [String] = [], actions: [String] = [], risks: [String] = [], facts: [String] = [],
        concepts: [String] = [], definitions: [String] = [], examples: [String] = []
    ) {
        self.keyPoints = keyPoints
        self.decisions = decisions
        self.actions = actions
        self.risks = risks
        self.facts = facts
        self.concepts = concepts
        self.definitions = definitions
        self.examples = examples
    }

    public var isEmpty: Bool { self == ChunkDigest() }

    /// Plain text for the merge step.
    public var rendered: String {
        func block(_ title: String, _ items: [String]) -> String { items.isEmpty ? "" : "\(title):\n" + items.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return [
            block("Key points", keyPoints), block("Decisions", decisions), block("Action items", actions), block("Risks and open questions", risks),
            block("Dates, numbers and names", facts), block("Concepts", concepts), block("Definitions", definitions), block("Examples", examples),
        ].joined()
    }

    public static func merged(_ digests: [ChunkDigest]) -> ChunkDigest {
        var out = ChunkDigest()
        for d in digests {
            out.keyPoints += d.keyPoints
            out.decisions += d.decisions
            out.actions += d.actions
            out.risks += d.risks
            out.facts += d.facts
            out.concepts += d.concepts
            out.definitions += d.definitions
            out.examples += d.examples
        }
        return out
    }
}

/// One section of a finished summary.
public struct SummarySection: Sendable, Equatable {
    public var title: String
    public var paragraph: String?
    public var bullets: [String]
    /// Rendered as `- [ ]` task items (action items).
    public var isChecklist: Bool
    public init(title: String, paragraph: String? = nil, bullets: [String] = [], isChecklist: Bool = false) {
        self.title = title
        self.paragraph = paragraph
        self.bullets = bullets
        self.isChecklist = isChecklist
    }
    public var isEmpty: Bool { (paragraph ?? "").isEmpty && bullets.isEmpty }
}

public struct SummaryDraft: Sendable, Equatable {
    public var sections: [SummarySection]
    public init(sections: [SummarySection]) { self.sections = sections }
}

/// What the summariser and chat need from a language model.
public protocol GenerativeModel: Sendable {
    /// Tokens the model can hold in one request (prompt and answer together).
    var contextTokens: Int { get }
    func availability() async -> IntelligenceAvailability
    func supports(languageCode: String?) -> Bool
    /// Extracts the facts from `text`.
    func digest(text: String, style: SummaryStyle) async throws -> ChunkDigest
    /// Writes the final summary from `material` (raw text that fits the window, or merged digests). `notes` and `files` are the
    /// user's own notes and attached-file text, read as additional material.
    /// `outputLanguage` is an English language name ("German") or nil to write in the material's own language.
    func compose(style: SummaryStyle, material: String, notes: String, files: String, outputLanguage: String?) async throws -> SummaryDraft
    /// Answers from the excerpts only; each yield is the whole answer so far.
    func answer(question: String, excerpts: String, history: [ChatMessage]) -> AsyncThrowingStream<String, any Error>
    /// A short summary of one attached file's text (key points, one line per page for slides).
    func summarizeDocument(text: String, perPage: Bool, outputLanguage: String?) async throws -> String
}

public enum ModelFailure: Error, Sendable, Equatable {
    /// The text is too long for the window; split and retry.
    case tooLong
    /// The system declined to process this text.
    case declined
    case other(String)
}

enum TokenEstimate {
    /// A conservative token count (English runs about 4.8 characters per token; CJK about one): bytes / 3.
    static func tokens(_ text: String) -> Int { max(1, text.utf8.count / 3) }
}

/// Set `EARMARK_INTELLIGENCE_DEBUG=1` to see how a summary was staged (parts, merge levels, sizes) on stderr.
func debugLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["EARMARK_INTELLIGENCE_DEBUG"] == "1" else { return }
    FileHandle.standardError.write(Data(("[intelligence] " + message() + "\n").utf8))
}

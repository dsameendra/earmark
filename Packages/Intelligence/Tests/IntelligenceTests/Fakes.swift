import AppCore
import Foundation

@testable import EarmarkIntelligence

/// A scripted model: records what it was asked and answers from closures.
final class ScriptedModel: GenerativeModel, @unchecked Sendable {
    var contextTokens: Int
    var state: IntelligenceAvailability = .available
    var unsupported: Set<String> = ["si"]
    var digestHandler: @Sendable (String) throws -> ChunkDigest = { text in ChunkDigest(keyPoints: ["point from \(text.prefix(12))"]) }
    var composeHandler: @Sendable (SummaryStyle, String, String, String) throws -> SummaryDraft = { _, material, _, _ in
        SummaryDraft(sections: [SummarySection(title: "Meeting summary", paragraph: "Summary of \(material.count) chars")])
    }
    var answerHandler: @Sendable (String, String) -> [String] = { _, _ in ["Release", "Release is on September 26"] }
    private(set) var digestInputs: [String] = []
    private(set) var composeCalls: [(material: String, notes: String, files: String)] = []
    private(set) var answerExcerpts: [String] = []
    private let lock = NSLock()

    init(contextTokens: Int = 8192) { self.contextTokens = contextTokens }

    func availability() async -> IntelligenceAvailability { state }
    func supports(languageCode: String?) -> Bool { languageCode.map { !unsupported.contains($0) } ?? true }

    func digest(text: String, style: SummaryStyle) async throws -> ChunkDigest {
        lock.withLock { digestInputs.append(text) }
        return try digestHandler(text)
    }

    func compose(style: SummaryStyle, material: String, notes: String, files: String, outputLanguage: String?) async throws -> SummaryDraft {
        lock.withLock { composeCalls.append((material, notes, files)) }
        return try composeHandler(style, material, notes, files)
    }

    func answer(question: String, excerpts: String, history: [ChatMessage]) -> AsyncThrowingStream<String, any Error> {
        lock.withLock { answerExcerpts.append(excerpts) }
        let parts = answerHandler(question, excerpts)
        return AsyncThrowingStream { continuation in
            for part in parts { continuation.yield(part) }
            continuation.finish()
        }
    }

    func summarizeDocument(text: String, perPage: Bool, outputLanguage: String?) async throws -> String { "Summary of document (\(text.count))" }
}

func line(_ time: TimeInterval, _ text: String, speaker: String? = nil) -> TranscriptLine {
    TranscriptLine(start: time, end: time + 4, speaker: speaker, text: text)
}

actor FakeTranscripts: TranscriptRepository {
    var headers: [TranscriptID: Transcript] = [:]
    var segs: [TranscriptID: [Segment]] = [:]
    func add(_ transcript: Transcript, _ segments: [Segment]) {
        headers[transcript.id] = transcript
        segs[transcript.id] = segments
    }
    func list(_ query: LibraryQuery) async throws -> [Transcript] { Array(headers.values) }
    func transcript(_ id: TranscriptID) async throws -> Transcript? { headers[id] }
    func save(_ transcript: Transcript) async throws { headers[transcript.id] = transcript }
    func segments(for id: TranscriptID) async throws -> [Segment] { segs[id] ?? [] }
    func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws { segs[id, default: []] += segments }
    func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws { segs[id] = segments }
    func search(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func softDelete(_ ids: [TranscriptID], at date: Date) async throws {}
    func restore(_ ids: [TranscriptID]) async throws {}
    func purge(_ ids: [TranscriptID]) async throws {}
    func purgeDeleted(before date: Date) async throws -> Int { 0 }
    func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark] { [] }
    func save(_ bookmark: TranscriptBookmark) async throws {}
}

actor FakeAttachments: AttachmentRepository {
    var items: [AppCore.Attachment] = []
    var pageStore: [AttachmentID: [AttachmentPage]] = [:]
    func attachments(for transcript: TranscriptID) async throws -> [AppCore.Attachment] { items.filter { $0.transcriptID == transcript && $0.deletedAt == nil } }
    func save(_ attachment: AppCore.Attachment) async throws {
        items.removeAll { $0.id == attachment.id }
        items.append(attachment)
    }
    func softDelete(_ id: AttachmentID) async throws { items.removeAll { $0.id == id } }
    func pages(for attachment: AttachmentID) async throws -> [AttachmentPage] { pageStore[attachment] ?? [] }
    func replacePages(_ pages: [AttachmentPage], for attachment: AttachmentID) async throws { pageStore[attachment] = pages }
    func links(for attachment: AttachmentID) async throws -> [SlideLink] { [] }
    func replaceLinks(_ links: [SlideLink], for attachment: AttachmentID) async throws {}
}

func makeSegments(_ texts: [(TimeInterval, String)], speaker: SpeakerID? = nil) -> [Segment] {
    texts.map { Segment(start: $0.0, end: $0.0 + 4, text: $0.1, speakerID: speaker) }
}

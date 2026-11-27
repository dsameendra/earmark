import AppCore
import Foundation

/// On-device summaries and chat over the library's transcripts, notes and attached files.
public struct IntelligenceService: IntelligenceServicing {
    private let model: any GenerativeModel
    private let transcripts: any TranscriptRepository
    private let attachments: any AttachmentRepository
    private let outputLanguage: @Sendable () async -> String?

    public init(
        model: any GenerativeModel = FoundationModelsGenerator(), transcripts: any TranscriptRepository,
        attachments: any AttachmentRepository, outputLanguage: @escaping @Sendable () async -> String? = { nil }
    ) {
        self.model = model
        self.transcripts = transcripts
        self.attachments = attachments
        self.outputLanguage = outputLanguage
    }

    public func availability() async -> IntelligenceAvailability { await model.availability() }
    public func supports(language: LanguageCode?) async -> Bool { model.supports(languageCode: language?.rawValue) }

    // MARK: Summaries

    public func summarize(_ request: SummaryRequest) -> AsyncThrowingStream<SummaryEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await requireReady()
                    let (lines, language) = try await loadTranscript(request.transcriptID)
                    guard model.supports(languageCode: language) else { throw IntelligenceError.languageNotSupported(language ?? "") }
                    let files = request.includeFiles ? try await fileText(for: request.transcriptID) : ""
                    let notes = request.includeNotes ? request.notesMarkdown : ""
                    let summarizer = Summarizer(model: model)
                    let output = try await summarizer.run(
                        style: request.style, lines: lines, notes: notes, files: files, outputLanguage: await outputLanguage()
                    ) { fraction, detail in continuation.yield(.progress(fraction: fraction, detail: detail)) }
                    for part in output.skippedParts { continuation.yield(.skipped(part: part)) }
                    let linked = TimestampLinker.link(output.draft, lines: lines, titles: Self.timestampedSections)
                    continuation.yield(.finished(markdown: SummaryMarkdown.render(linked)))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: IntelligenceError.cancelled)
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func summarize(attachment: Attachment) -> AsyncThrowingStream<SummaryEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await requireReady()
                    let pages = try await attachments.pages(for: attachment.id)
                    let label = attachment.role == .slides ? "Slide" : "Page"
                    let text = pages.filter { !$0.text.isEmpty }.map { "\(label) \($0.index + 1): \($0.text)" }.joined(separator: "\n\n")
                    guard !text.isEmpty else { throw IntelligenceError.failed("No text could be read from this file.") }
                    let summarizer = Summarizer(model: model)
                    let language = await outputLanguage()
                    var material = text
                    if TokenEstimate.tokens(text) > summarizer.budget {
                        // Long file: digest parts first, then summarise the digests.
                        var digests: [ChunkDigest] = []
                        let parts = summarizer.split(text, tokens: Int(Double(summarizer.budget) * 0.6))
                        for (index, part) in parts.enumerated() {
                            try Task.checkCancellation()
                            continuation.yield(.progress(fraction: Double(index) / Double(parts.count), detail: "Reading part \(index + 1) of \(parts.count)"))
                            if let digest = try? await model.digest(text: part, style: .general) { digests.append(digest) }
                        }
                        material = ChunkDigest.merged(digests).rendered
                    }
                    continuation.yield(.progress(fraction: 0.9, detail: "Writing the summary"))
                    let summary = try await model.summarizeDocument(text: material, perPage: attachment.role == .slides, outputLanguage: language)
                    continuation.yield(.finished(markdown: summary))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: IntelligenceError.cancelled)
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Chat

    public func answer(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await requireReady()
                    let (lines, language) = try await loadTranscript(request.transcriptID)
                    guard model.supports(languageCode: language) else { throw IntelligenceError.languageNotSupported(language ?? "") }
                    var files: [(attachment: Attachment, pages: [AttachmentPage])] = []
                    if request.scope == .everything {
                        for attachment in try await attachments.attachments(for: request.transcriptID) where attachment.usedInContext {
                            files.append((attachment, try await attachments.pages(for: attachment.id)))
                        }
                    }
                    let material = ChatEngine.Material(lines: lines, notes: request.notesMarkdown, files: files, languageCode: language)
                    for try await event in ChatEngine(model: model).answer(request: request, material: material) { continuation.yield(event) }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: IntelligenceError.cancelled)
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: Loading

    static let timestampedSections: Set<String> = [
        "Discussion points", "Decisions", "Action items", "Risks and open questions", "Key concepts", "Announcements and deadlines",
        "Key points", "Details",
    ]

    private func requireReady() async throws {
        let state = await model.availability()
        if case .unavailable(let reason) = state { throw IntelligenceError.unavailable(reason) }
    }

    private func loadTranscript(_ id: TranscriptID) async throws -> ([TranscriptLine], String?) {
        let header = try await transcripts.transcript(id)
        let segments = try await transcripts.segments(for: id)
        let lines = TranscriptText.lines(segments: segments, speakers: header?.speakers ?? [])
        let language = header?.languages.map(\.rawValue).sorted().first ?? segments.compactMap(\.languageCode?.rawValue).first
        return (lines, language)
    }

    /// Slides and files marked for use, as "Title, Slide N: text" blocks.
    private func fileText(for transcript: TranscriptID) async throws -> String {
        var blocks: [String] = []
        for attachment in try await attachments.attachments(for: transcript) where attachment.usedInContext {
            let label = attachment.role == .slides ? "Slide" : "Page"
            let pages = try await attachments.pages(for: attachment.id).filter { !$0.text.isEmpty }
            guard !pages.isEmpty else { continue }
            blocks.append("FILE \(attachment.title):\n" + pages.map { "\(label) \($0.index + 1): \($0.text)" }.joined(separator: "\n"))
        }
        return blocks.joined(separator: "\n\n")
    }

    static func normalize(_ error: any Error) -> any Error {
        if let known = error as? IntelligenceError { return known }
        if let failure = error as? ModelFailure {
            switch failure {
            case .tooLong: return IntelligenceError.failed("The text is too long to process on this Mac.")
            case .declined: return IntelligenceError.declined(part: 0)
            case .other(let reason): return IntelligenceError.failed(reason)
            }
        }
        return IntelligenceError.failed(String(describing: error))
    }
}

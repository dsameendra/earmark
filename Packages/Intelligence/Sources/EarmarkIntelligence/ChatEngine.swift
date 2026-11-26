import AppCore
import Foundation

/// Grounded question answering: pick the few passages that matter, let the model answer from them only, then work out the
/// sources from what was supplied (the model's own timestamps are not trusted).
struct ChatEngine: Sendable {
    let model: any GenerativeModel
    var embeddingFactory: @Sendable (String?) -> (any SentenceEmbedding)? = { code in
        let e = NaturalLanguageEmbedding(languageCode: code)
        return e.isAvailable ? e : nil
    }

    struct Material: Sendable {
        var lines: [TranscriptLine]
        var notes: String
        var files: [(attachment: Attachment, pages: [AttachmentPage])]
        var languageCode: String?
    }

    /// Passages in reading order: transcript windows by time, then notes, then file pages.
    func chunks(_ material: Material, scope: ChatScope) -> [TextChunk] {
        var out: [TextChunk] = []
        if scope == .everything {
            var window: [TranscriptLine] = []
            var tokens = 0
            func flush() {
                guard let first = window.first else { return }
                out.append(
                    TextChunk(
                        text: window.map(\.rendered).joined(separator: "\n"),
                        source: ChatSource(kind: .transcript, label: TranscriptText.clock(first.start), time: first.start), order: first.start))
                window = []
                tokens = 0
            }
            for line in material.lines {
                let cost = TokenEstimate.tokens(line.rendered)
                if tokens + cost > 260, !window.isEmpty { flush() }
                window.append(line)
                tokens += cost
            }
            flush()
        }
        var position = 1_000_000.0
        for block in Self.blocks(material.notes, tokens: 240) {
            out.append(TextChunk(text: block, source: ChatSource(kind: .notes, label: "Notes"), order: position))
            position += 1
        }
        if scope == .everything {
            for (attachment, pages) in material.files where attachment.usedInContext {
                for page in pages {
                    for (part, block) in Self.blocks(page.text, tokens: 300).enumerated() {
                        let label = attachment.role == .slides ? "Slide \(page.index + 1)" : "\(attachment.title) p.\(page.index + 1)"
                        out.append(
                            TextChunk(
                                text: "\(label): \(block)",
                                source: ChatSource(kind: .page, label: label, attachmentID: attachment.id, page: page.index),
                                order: 2_000_000 + Double(page.index) + Double(part) * 0.01))
                    }
                }
            }
        }
        return out
    }

    /// Splits text into paragraph blocks of about `tokens` tokens.
    static func blocks(_ text: String, tokens: Int) -> [String] {
        let paragraphs = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var result: [String] = []
        var current = ""
        for paragraph in paragraphs {
            if TokenEstimate.tokens(current + "\n" + paragraph) > tokens, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + paragraph
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    func answer(request: ChatRequest, material: Material) -> AsyncThrowingStream<ChatEvent, any Error> {
        let model = model
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let all = chunks(material, scope: request.scope)
                    let upTo = material.lines.last?.end
                    guard !all.isEmpty else {
                        let text = request.scope == .summaryAndNotes
                            ? "There is no summary or notes yet. Write notes or summarise the recording first."
                            : "Nothing has been transcribed yet."
                        continuation.yield(.finished(text: text, sources: [], upTo: upTo))
                        continuation.finish()
                        return
                    }
                    let history = Array(request.history.suffix(4))
                    let historyTokens = history.reduce(0) { $0 + TokenEstimate.tokens($1.text) }
                    let reserve = 700 + 900 + historyTokens + TokenEstimate.tokens(request.question)
                    var budget = max(400, model.contextTokens - reserve)
                    let ranked = Retriever.rank(
                        question: request.question, chunks: all, limit: 24, embedding: embeddingFactory(material.languageCode))
                    // When nothing matches the words, fall back to the start of the notes/summary rather than answering blind.
                    let pool = ranked.isEmpty ? Array(all.filter { $0.source.kind == .notes }.prefix(6)) : ranked
                    var used: [TextChunk] = []
                    for chunk in pool {
                        guard chunk.tokens <= budget else { continue }
                        used.append(chunk)
                        budget -= chunk.tokens
                    }
                    guard !used.isEmpty else {
                        continuation.yield(.finished(text: "Not stated in the transcript.", sources: [], upTo: upTo))
                        continuation.finish()
                        return
                    }
                    let excerpts = used.sorted { $0.order < $1.order }.map { "[\($0.source.label)] \($0.text)" }.joined(separator: "\n\n")
                    var final = ""
                    for try await partial in model.answer(question: request.question, excerpts: excerpts, history: history) {
                        try Task.checkCancellation()
                        final = partial
                        continuation.yield(.partial(partial))
                    }
                    continuation.yield(.finished(text: final, sources: Self.sources(for: final, among: used), upTo: upTo))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The supplied passages that the answer visibly draws on (shared words), strongest first, at most four, in reading order.
    static func sources(for answer: String, among used: [TextChunk]) -> [ChatSource] {
        let lower = answer.lowercased()
        if lower.contains("not stated") || lower.contains("nothing has been transcribed") { return [] }
        let words = Set(Words.content(answer).map(Retriever.stem))
        guard !words.isEmpty else { return [] }
        let scored = used.map { chunk -> (TextChunk, Int) in
            (chunk, Set(Words.content(chunk.text).map(Retriever.stem)).intersection(words).count)
        }.filter { $0.1 >= 2 }
        var seen = Set<String>()
        return scored.sorted { $0.1 > $1.1 }.prefix(4).sorted { $0.0.order < $1.0.order }.compactMap { entry in
            seen.insert(entry.0.source.id).inserted ? entry.0.source : nil
        }
    }
}

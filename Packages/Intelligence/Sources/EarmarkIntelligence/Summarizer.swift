import AppCore
import Foundation

/// Staged summarisation that fits a small context window: raw text when it fits, otherwise digest each chunk, merge the digests
/// (hierarchically if needed) and write the summary from the merge.
struct Summarizer: Sendable {
    let model: any GenerativeModel

    struct Output: Sendable {
        var draft: SummaryDraft
        var skippedParts: [Int]
    }

    /// Tokens of material one request may carry: the window minus instructions and the answer.
    var budget: Int { max(700, Int(Double(model.contextTokens - 2000) * 0.85)) }

    func run(
        style: SummaryStyle, lines: [TranscriptLine], notes: String, files: String, outputLanguage: String? = nil,
        progress: @Sendable (Double, String) -> Void
    ) async throws -> Output {
        guard !lines.isEmpty || !files.isEmpty || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntelligenceError.failed("There is nothing to summarise yet.")
        }
        var skipped: [Int] = []
        let transcript = TranscriptText.render(lines)
        let cappedNotes = cap(notes, tokens: budget / 5)

        // Raw when it all fits, so a short recording is summarised from its exact words.
        let allTokens = TokenEstimate.tokens(transcript) + TokenEstimate.tokens(files) + TokenEstimate.tokens(cappedNotes)
        if allTokens <= budget {
            progress(0.2, "Writing the summary")
            let draft = try await compose(style: style, material: transcript, notes: cappedNotes, files: files, language: outputLanguage)
            return Output(draft: draft, skippedParts: [])
        }

        // Transcript: raw if it leaves room for the rest, else digested in parts.
        let transcriptMaterial: String
        if TokenEstimate.tokens(transcript) <= Int(Double(budget) * 0.55) {
            transcriptMaterial = transcript
        } else {
            let parts = TranscriptText.chunks(lines, budgetTokens: Int(Double(budget) * 0.6)).map(TranscriptText.render)
            transcriptMaterial = try await digestAll(parts, style: style, label: "Reading part", base: 0, span: 0.7, skipped: &skipped, progress: progress)
        }
        let filesMaterial: String
        if TokenEstimate.tokens(files) <= Int(Double(budget) * 0.2) || files.isEmpty {
            filesMaterial = files
        } else {
            let parts = split(files, tokens: Int(Double(budget) * 0.6))
            filesMaterial = try await digestAll(parts, style: style, label: "Reading file part", base: 0.7, span: 0.15, skipped: &skipped, progress: progress)
        }
        progress(0.9, "Writing the summary")
        let draft = try await compose(style: style, material: transcriptMaterial, notes: cappedNotes, files: filesMaterial, language: outputLanguage)
        return Output(draft: draft, skippedParts: skipped)
    }

    // MARK: Map and merge

    /// Digests each part, then merges. When the merged digests are still too long they are digested again, level by level.
    private func digestAll(
        _ parts: [String], style: SummaryStyle, label: String, base: Double, span: Double, skipped: inout [Int],
        progress: @Sendable (Double, String) -> Void
    ) async throws -> String {
        var digests: [ChunkDigest] = []
        for (index, part) in parts.enumerated() {
            try Task.checkCancellation()
            progress(base + span * Double(index) / Double(max(parts.count, 1)), "\(label) \(index + 1) of \(parts.count)")
            do {
                digests.append(try await digestSplittingIfTooLong(part, style: style, depth: 0))
            } catch ModelFailure.declined {
                skipped.append(index + 1)
            }
        }
        var rendered = ChunkDigest.merged(digests).rendered
        debugLog("\(label): \(parts.count) parts, \(digests.count) digests, merged ~\(TokenEstimate.tokens(rendered)) tokens, budget \(budget)")
        var level = 0
        // Hierarchical merge: digest the digests until they fit.
        while TokenEstimate.tokens(rendered) > Int(Double(budget) * 0.55), level < 4 {
            let groups = split(rendered, tokens: Int(Double(budget) * 0.6))
            guard groups.count > 1 || TokenEstimate.tokens(rendered) > budget else { break }
            var next: [ChunkDigest] = []
            for group in groups {
                try Task.checkCancellation()
                if let d = try? await digestSplittingIfTooLong(group, style: style, depth: 0) { next.append(d) }
            }
            let merged = ChunkDigest.merged(next).rendered
            if merged.count >= rendered.count { rendered = String(merged.prefix(max(1, budget * 2))); break }
            rendered = merged
            level += 1
            debugLog("merge level \(level): ~\(TokenEstimate.tokens(rendered)) tokens")
        }
        return rendered
    }

    private func digestSplittingIfTooLong(_ text: String, style: SummaryStyle, depth: Int) async throws -> ChunkDigest {
        do {
            return try await model.digest(text: text, style: style)
        } catch ModelFailure.tooLong where depth < 4 && text.count > 400 {
            let (first, second) = halves(text)
            let a = try await digestSplittingIfTooLong(first, style: style, depth: depth + 1)
            let b = try await digestSplittingIfTooLong(second, style: style, depth: depth + 1)
            return ChunkDigest.merged([a, b])
        }
    }

    private func compose(style: SummaryStyle, material: String, notes: String, files: String, language: String?) async throws -> SummaryDraft {
        var notes = notes
        var files = files
        var material = material
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                debugLog("compose attempt \(attempt): material ~\(TokenEstimate.tokens(material)), notes ~\(TokenEstimate.tokens(notes)), files ~\(TokenEstimate.tokens(files)) tokens")
                return try await model.compose(style: style, material: material, notes: notes, files: files, outputLanguage: language)
            } catch ModelFailure.tooLong where attempt < 2 {
                // Trim the extras first, then the material, and try again.
                notes = cap(notes, tokens: max(50, TokenEstimate.tokens(notes) / 2))
                files = cap(files, tokens: max(50, TokenEstimate.tokens(files) / 2))
                material = cap(material, tokens: max(200, Int(Double(TokenEstimate.tokens(material)) * 0.7)))
            } catch ModelFailure.declined {
                throw IntelligenceError.failed("The system declined to summarise this text.")
            } catch ModelFailure.other(let reason) {
                throw IntelligenceError.failed(reason)
            }
        }
        throw IntelligenceError.failed("The text is too long to summarise on this Mac.")
    }

    // MARK: Text helpers

    func cap(_ text: String, tokens: Int) -> String {
        let limit = tokens * 3
        guard text.utf8.count > limit else { return text }
        var out = ""
        var bytes = 0
        for character in text {
            let size = String(character).utf8.count
            if bytes + size > limit { break }
            out.append(character)
            bytes += size
        }
        return out + "…"
    }

    /// Splits text on paragraph and line boundaries into pieces of about `tokens` tokens.
    func split(_ text: String, tokens: Int) -> [String] {
        var pieces: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if TokenEstimate.tokens(current + "\n" + line) > tokens, !current.isEmpty {
                pieces.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private func halves(_ text: String) -> (String, String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > 1 {
            let mid = lines.count / 2
            return (lines[..<mid].joined(separator: "\n"), lines[mid...].joined(separator: "\n"))
        }
        let mid = text.index(text.startIndex, offsetBy: text.count / 2)
        return (String(text[..<mid]), String(text[mid...]))
    }
}

// MARK: - Markdown and timestamps

enum SummaryMarkdown {
    static func render(_ draft: SummaryDraft) -> String {
        draft.sections.filter { !$0.isEmpty }.map { section in
            var block = "## \(section.title)\n"
            if let paragraph = section.paragraph, !paragraph.isEmpty { block += paragraph + "\n" }
            if !section.bullets.isEmpty {
                if section.paragraph?.isEmpty == false { block += "\n" }
                block += section.bullets.map { (section.isChecklist ? "- [ ] " : "- ") + $0 }.joined(separator: "\n") + "\n"
            }
            return block
        }.joined(separator: "\n")
    }
}

/// Adds a `[mm:ss]` to a bullet only when its words clearly appear on one transcript line. The model's own timestamps are never
/// used: they proved unreliable.
enum TimestampLinker {
    static func link(_ draft: SummaryDraft, lines: [TranscriptLine], titles: Set<String>) -> SummaryDraft {
        guard !lines.isEmpty else { return draft }
        let indexed = lines.map { (line: $0, words: Set(Words.content($0.text))) }
        var out = draft
        for s in out.sections.indices where titles.contains(out.sections[s].title) {
            out.sections[s].bullets = out.sections[s].bullets.map { bullet in
                let words = Set(Words.content(bullet))
                guard words.count >= 2 else { return bullet }
                var best: (score: Double, shared: Int, time: TimeInterval)?
                for entry in indexed {
                    let shared = words.intersection(entry.words).count
                    guard shared >= 2 else { continue }
                    let score = Double(shared) / Double(words.count)
                    if score > (best?.score ?? 0) { best = (score, shared, entry.line.start) }
                }
                guard let best, best.score >= 0.5 else { return bullet }
                return "\(bullet) [\(TranscriptText.clock(best.time))]"
            }
        }
        return out
    }
}

import AppCore
import Foundation

/// A subtitle cue (times in integer milliseconds).
struct Cue: Sendable, Hashable {
    var startMS: Int
    var endMS: Int
    var lines: [String]
    var translationLines: [String]
    var speaker: Speaker?
    var language: LanguageCode?
    var translationLanguage: LanguageCode?
    /// True when this is the first cue after a speaker change.
    var isTurnStart: Bool
}

/// Turns entries into constraint-respecting cues (EXP-AC-07).
///
/// Lines wrap at `maxCharsPerLine` counted in grapheme clusters, so Sinhala vowel signs and conjuncts (al-lakuna + ZWJ)
/// are never separated from their base letter. Cues split at punctuation when `splitOnPunctuation` is set, else at spaces.
enum CueBuilder {
    struct Token: Hashable {
        var text: String
        /// No space before this token (continuation of an over-long word).
        var glued: Bool
    }

    private static let minimumCueMS = 40

    static func build(_ entries: [Entry], constraints: SubtitleConstraints, bilingual: Bool) -> [Cue] {
        var result: [Cue] = []
        var previousSpeaker: SpeakerID?
        var isFirst = true
        for entry in entries {
            let turnStart = isFirst || previousSpeaker != entry.speakerID
            previousSpeaker = entry.speakerID
            isFirst = false
            result += cues(for: entry, constraints: constraints, bilingual: bilingual, turnStart: turnStart)
        }
        return resolveTiming(result, constraints: constraints)
    }

    // MARK: Per-entry splitting

    private static func cues(for entry: Entry, constraints: SubtitleConstraints, bilingual: Bool, turnStart: Bool) -> [Cue] {
        let startMS = Format.ms(entry.start)
        let endMS = max(startMS + 1, Format.ms(entry.end))
        let maxMS = max(1, Int((constraints.maxCueDuration * 1000).rounded()))
        let durationPieces = max(1, Int((Double(endMS - startMS) / Double(maxMS)).rounded(.up)))

        var original = tokens(entry.text, maxChars: constraints.maxCharsPerLine)
        var pieces = split(original.tokens, constraints: constraints, minPieces: durationPieces)
        var secondary: (tokens: [Token], broken: Bool)?
        var secondaryPieces: [[Token]] = []
        if bilingual, let translation = entry.translation {
            var other = tokens(translation, maxChars: constraints.maxCharsPerLine)
            var count = max(pieces.count, split(other.tokens, constraints: constraints, minPieces: 1).count)
            for _ in 0..<4 {
                pieces = split(original.tokens, constraints: constraints, minPieces: count)
                secondaryPieces = split(other.tokens, constraints: constraints, minPieces: count)
                let next = max(pieces.count, secondaryPieces.count)
                if next == count && pieces.count == secondaryPieces.count { break }
                count = next
            }
            original.broken = true  // bilingual timing is proportional
            other.broken = true
            secondary = other
        }
        guard !pieces.isEmpty else { return [] }

        // Time boundaries per piece.
        var bounds: [(Int, Int)] = []
        let wordTimed = !original.broken && entry.words.count == original.tokens.count && !entry.words.isEmpty
        if wordTimed {
            var cursor = 0
            for piece in pieces {
                let first = entry.words[cursor], last = entry.words[cursor + piece.count - 1]
                bounds.append((max(startMS, Format.ms(first.start)), min(endMS, max(Format.ms(last.end), Format.ms(first.start) + 1))))
                cursor += piece.count
            }
            bounds[0].0 = startMS
        } else {
            let weights = pieces.indices.map { index -> Int in
                let a = pieces[index].reduce(0) { $0 + $1.text.count + 1 }
                let b = index < secondaryPieces.count ? secondaryPieces[index].reduce(0) { $0 + $1.text.count + 1 } : 0
                return max(1, a + b)
            }
            let total = weights.reduce(0, +)
            var consumed = 0
            var cursor = startMS
            for weight in weights {
                consumed += weight
                let next = startMS + (endMS - startMS) * consumed / total
                bounds.append((cursor, max(cursor + 1, next)))
                cursor = max(cursor + 1, next)
            }
        }

        return pieces.indices.map { index in
            Cue(
                startMS: bounds[index].0, endMS: bounds[index].1, lines: wrap(pieces[index], maxChars: constraints.maxCharsPerLine),
                translationLines: index < secondaryPieces.count ? wrap(secondaryPieces[index], maxChars: constraints.maxCharsPerLine) : [],
                speaker: entry.speaker, language: entry.language, translationLanguage: secondary == nil ? nil : entry.translationLanguage,
                isTurnStart: turnStart && index == 0)
        }
    }

    // MARK: Tokenising and wrapping

    /// Characters after which a break would split a Sinhala conjunct (al-lakuna, ZWJ).
    private static func isUnsafeBreakAfter(_ ch: Character) -> Bool {
        guard let last = ch.unicodeScalars.last else { return false }
        return last.value == 0x200D || last.value == 0x0DCA
    }

    static func tokens(_ text: String, maxChars: Int) -> (tokens: [Token], broken: Bool) {
        var out: [Token] = []
        var broken = false
        for word in text.split(whereSeparator: \.isWhitespace) {
            let chars = Array(word)
            if chars.count <= maxChars {
                out.append(Token(text: String(word), glued: false))
                continue
            }
            broken = true
            var start = 0
            var first = true
            while chars.count - start > maxChars {
                var cut = start + maxChars
                while cut > start + 1 && isUnsafeBreakAfter(chars[cut - 1]) { cut -= 1 }
                out.append(Token(text: String(chars[start..<cut]), glued: !first))
                start = cut
                first = false
            }
            out.append(Token(text: String(chars[start...]), glued: !first))
        }
        return (out, broken)
    }

    static func wrap(_ tokens: [Token], maxChars: Int) -> [String] {
        var lines: [String] = []
        var current = ""
        var count = 0
        for token in tokens {
            let width = token.text.count
            if current.isEmpty {
                current = token.text
                count = width
            } else {
                let sep = token.glued ? 0 : 1
                if count + sep + width <= maxChars {
                    if sep == 1 { current += " " }
                    current += token.text
                    count += sep + width
                } else {
                    lines.append(current)
                    current = token.text
                    count = width
                }
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func endsSentence(_ token: Token) -> Bool {
        guard let last = token.text.last else { return false }
        return ".?!।…෴".contains(last)
    }
    private static func endsClause(_ token: Token) -> Bool {
        guard let last = token.text.last else { return false }
        return ",;:،".contains(last)
    }

    /// Splits tokens into pieces that each fit `maxLinesPerCue` lines, with at least `minPieces` pieces when possible.
    static func split(_ tokens: [Token], constraints: SubtitleConstraints, minPieces: Int) -> [[Token]] {
        guard !tokens.isEmpty else { return [] }
        var pieces = fit(tokens, constraints: constraints)
        if minPieces > pieces.count && tokens.count >= minPieces {
            // Balanced split by character weight, then re-fit each part.
            let weights = tokens.map { $0.text.count + 1 }
            let total = weights.reduce(0, +)
            var groups: [[Token]] = []
            var current: [Token] = []
            var consumed = 0
            for (index, token) in tokens.enumerated() {
                current.append(token)
                consumed += weights[index]
                let remainingTokens = tokens.count - index - 1
                let remainingGroups = minPieces - groups.count - 1
                if groups.count < minPieces - 1, consumed * minPieces >= total * (groups.count + 1) || remainingTokens == remainingGroups {
                    groups.append(current)
                    current = []
                }
            }
            if !current.isEmpty { groups.append(current) }
            pieces = groups.flatMap { fit($0, constraints: constraints) }
        }
        return pieces
    }

    /// Greedy fit: as many tokens as fit in `maxLinesPerCue` lines, preferring punctuation boundaries when asked.
    private static func fit(_ tokens: [Token], constraints: SubtitleConstraints) -> [[Token]] {
        let maxChars = constraints.maxCharsPerLine
        let maxLines = constraints.maxLinesPerCue
        var pieces: [[Token]] = []
        var start = 0
        while start < tokens.count {
            var end = start + 1
            while end < tokens.count, wrap(Array(tokens[start...end]), maxChars: maxChars).count <= maxLines { end += 1 }
            if end < tokens.count, constraints.splitOnPunctuation {
                let minimum = start + max(1, (end - start) / 3)
                let range = (minimum..<end).reversed()
                if let cut = range.first(where: { endsSentence(tokens[$0 - 1]) }) ?? range.first(where: { endsClause(tokens[$0 - 1]) }) {
                    end = cut
                }
            }
            pieces.append(Array(tokens[start..<end]))
            start = end
        }
        return pieces
    }

    // MARK: Timing constraints

    /// Enforces min/max duration and min gap, and guarantees no overlapping cues.
    static func resolveTiming(_ input: [Cue], constraints: SubtitleConstraints) -> [Cue] {
        var cues = input
        guard !cues.isEmpty else { return cues }
        let gap = Int((constraints.minGap * 1000).rounded())
        let minMS = Int((constraints.minCueDuration * 1000).rounded())
        let maxMS = Int((constraints.maxCueDuration * 1000).rounded())
        for index in cues.indices {
            if cues[index].endMS - cues[index].startMS < minMS {
                let limit = index + 1 < cues.count ? cues[index + 1].startMS - gap : Int.max
                cues[index].endMS = max(cues[index].endMS, min(cues[index].startMS + minMS, limit))
            }
            if cues[index].endMS - cues[index].startMS > maxMS { cues[index].endMS = cues[index].startMS + maxMS }
        }
        for index in 0..<(cues.count - 1) where cues[index].endMS + gap > cues[index + 1].startMS {
            let trimmed = cues[index + 1].startMS - gap
            if trimmed >= cues[index].startMS + minimumCueMS {
                cues[index].endMS = trimmed
            } else {
                cues[index].endMS = max(cues[index].endMS, cues[index].startMS + minimumCueMS)
                cues[index + 1].startMS = cues[index].endMS + gap
                cues[index + 1].endMS = max(cues[index + 1].endMS, cues[index + 1].startMS + minimumCueMS)
            }
        }
        return cues
    }
}

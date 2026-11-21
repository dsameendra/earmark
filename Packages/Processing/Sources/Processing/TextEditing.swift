import AppCore
import Foundation

/// Text normalisation shared by every processor (NFC so Sinhala combining sequences compare equal).
public enum TextNormalizer {
    /// Canonical composition (NFC).
    public static func nfc(_ text: String) -> String { text.precomposedStringWithCanonicalMapping }

    /// NFC, trimmed, internal whitespace collapsed to single spaces, case-folded. Brackets are never stripped.
    public static func normalizeForMatching(_ text: String) -> String {
        let collapsed = nfc(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return nfc(collapsed.folding(options: [.caseInsensitive], locale: nil))
    }
}

/// One replacement of a UTF-16 range of a segment's text.
public struct TextEdit: Sendable, Hashable {
    /// Range in the (NFC) source text, in UTF-16 units.
    public var range: NSRange
    public var replacement: String
    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }
}

/// Applies text edits to a segment while keeping word timings coherent.
///
/// Words untouched by an edit keep their timings. Words an edit touches are re-tokenised and the time span of the
/// affected words is distributed over the new tokens in proportion to their length (interpolation), so growing,
/// shrinking, merging and splitting words all keep click-to-seek working. Segment `start`/`end` never change.
public enum SegmentEditor {
    /// Returns `segment` with `edits` applied. `edits` must not overlap; they are interpreted against the NFC form of `segment.text`.
    public static func apply(_ edits: [TextEdit], to segment: Segment) -> Segment {
        guard !edits.isEmpty else { return segment }
        var result = nfcSegment(segment)
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        let newText = applyToText(sorted, text: result.text)
        if !result.words.isEmpty {
            result.words = realign(
                words: result.words, text: result.text, edits: sorted, newText: newText, start: result.start, end: result.end)
        }
        result.text = newText
        return result
    }

    /// Applies edits to plain text (no words).
    public static func applyToText(_ edits: [TextEdit], text: String) -> String {
        let ns = text as NSString
        var out = ""
        var cursor = 0
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            let loc = max(cursor, edit.range.location)
            out += ns.substring(with: NSRange(location: cursor, length: loc - cursor))
            out += edit.replacement
            cursor = max(loc, edit.range.upperBound)
        }
        return out + ns.substring(from: min(cursor, ns.length))
    }

    /// The segment with text and word text in NFC.
    public static func nfcSegment(_ segment: Segment) -> Segment {
        var copy = segment
        copy.text = TextNormalizer.nfc(segment.text)
        copy.words = segment.words.map {
            var word = $0
            word.text = TextNormalizer.nfc($0.text)
            return word
        }
        return copy
    }

    /// UTF-16 ranges of each word's (trimmed) text inside `text`, matched left to right; nil when they cannot be aligned.
    static func wordRanges(text: String, words: [Word]) -> [NSRange]? {
        let ns = text as NSString
        var cursor = 0
        var ranges: [NSRange] = []
        for word in words {
            let trimmed = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, cursor <= ns.length else { return nil }
            let found = ns.range(of: trimmed, options: .literal, range: NSRange(location: cursor, length: ns.length - cursor))
            guard found.location != NSNotFound else { return nil }
            ranges.append(found)
            cursor = found.upperBound
        }
        return ranges
    }

    static func realign(words: [Word], text: String, edits: [TextEdit], newText: String, start: TimeInterval, end: TimeInterval) -> [Word] {
        guard let ranges = wordRanges(text: text, words: words) else {
            return interpolate(tokens: tokens(of: newText), start: start, end: end, confidence: nil)
        }
        // Group edits into clusters of overlapping word index intervals.
        struct Cluster {
            var lo: Int
            var hi: Int
            var edits: [TextEdit]
        }
        var clusters: [Cluster] = []
        for edit in edits {
            let hits = ranges.indices.filter { overlaps(ranges[$0], edit.range) }
            guard let lo = hits.first, let hi = hits.last else { continue }
            if let last = clusters.last, lo <= last.hi {
                clusters[clusters.count - 1].hi = max(last.hi, hi)
                clusters[clusters.count - 1].edits.append(edit)
            } else {
                clusters.append(Cluster(lo: lo, hi: hi, edits: [edit]))
            }
        }
        let ns = text as NSString
        var out: [Word] = []
        var index = 0
        var clusterIndex = 0
        while index < words.count {
            guard clusterIndex < clusters.count, clusters[clusterIndex].lo == index else {
                out.append(words[index])
                index += 1
                continue
            }
            let cluster = clusters[clusterIndex]
            var lower = ranges[cluster.lo].location
            var upper = ranges[cluster.hi].upperBound
            for edit in cluster.edits {
                lower = min(lower, edit.range.location)
                upper = max(upper, edit.range.upperBound)
            }
            let span = NSRange(location: lower, length: upper - lower)
            let shifted = cluster.edits.map {
                TextEdit(range: NSRange(location: $0.range.location - lower, length: $0.range.length), replacement: $0.replacement)
            }
            let newSpanText = applyToText(shifted, text: ns.substring(with: span))
            let group = words[cluster.lo...cluster.hi]
            let confidences = group.compactMap(\.confidence)
            let confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
            out += interpolate(
                tokens: tokens(of: newSpanText), start: words[cluster.lo].start, end: words[cluster.hi].end, confidence: confidence)
            index = cluster.hi + 1
            clusterIndex += 1
        }
        return out
    }

    private static func overlaps(_ word: NSRange, _ edit: NSRange) -> Bool {
        if edit.length == 0 { return word.location < edit.location && edit.location < word.upperBound }
        return max(word.location, edit.location) < min(word.upperBound, edit.upperBound)
    }

    private static func tokens(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Spreads `[start, end]` over tokens in proportion to their grapheme count.
    static func interpolate(tokens: [String], start: TimeInterval, end: TimeInterval, confidence: Double?) -> [Word] {
        guard !tokens.isEmpty else { return [] }
        let weights = tokens.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        let span = max(0, end - start)
        var cursor = start
        var consumed = 0.0
        var words: [Word] = []
        for (index, token) in tokens.enumerated() {
            consumed += weights[index]
            let next = index == tokens.count - 1 ? end : start + span * consumed / total
            words.append(Word(text: token, start: cursor, end: next, confidence: confidence))
            cursor = next
        }
        return words
    }
}

/// Errors from compiling user patterns.
public enum PatternError: Error, Sendable, Equatable {
    case empty
    case invalid(String)
}

/// A compiled literal-or-regex pattern with match-case and Unicode whole-word options.
public struct CompiledPattern: Sendable {
    let regex: NSRegularExpression
    let isRegex: Bool
    /// Characters that count as part of a word: letters, marks (Sinhala vowel signs), digits, `_`, ZWJ/ZWNJ.
    static let wordClass = "[\\p{L}\\p{M}\\p{N}_\\u200C\\u200D]"

    /// Compiles `pattern`. Literal patterns are NFC-normalised; whole-word uses Unicode-aware boundaries (not ASCII `\b`).
    public init(pattern: String, matchCase: Bool, wholeWord: Bool, isRegex: Bool) throws {
        guard !pattern.isEmpty else { throw PatternError.empty }
        var body = isRegex ? pattern : NSRegularExpression.escapedPattern(for: TextNormalizer.nfc(pattern))
        if wholeWord { body = "(?<!\(Self.wordClass))(?:\(body))(?!\(Self.wordClass))" }
        do {
            regex = try NSRegularExpression(pattern: body, options: matchCase ? [] : [.caseInsensitive])
        } catch {
            throw PatternError.invalid(error.localizedDescription)
        }
        self.isRegex = isRegex
    }

    /// Non-overlapping, non-empty matches. `timeout` (seconds) aborts evaluation and yields what was found so far.
    func matches(in text: String, timeout: TimeInterval? = nil) -> [NSTextCheckingResult] {
        let ns = text as NSString
        var found: [NSTextCheckingResult] = []
        let started = Date()
        regex.enumerateMatches(
            in: text, options: timeout == nil ? [] : [.reportProgress], range: NSRange(location: 0, length: ns.length)
        ) { result, _, stop in
            if let timeout, Date().timeIntervalSince(started) > timeout {
                found.removeAll()
                stop.pointee = true
                return
            }
            if let result, result.range.length > 0 { found.append(result) }
        }
        return found
    }

    /// The replacement text for `match`: regex capture groups (`$1`) are expanded, literal mode is verbatim.
    func replacement(_ template: String, for match: NSTextCheckingResult, in text: String) -> String {
        isRegex ? regex.replacementString(for: match, in: text, offset: 0, template: template) : template
    }
}

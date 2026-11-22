import AppCore
import Foundation
import Processing

/// Pure segment transformations used by the editor (EDIT-AC-06, EDIT-AC-07). No I/O, no UI.
public enum SegmentOps {
    // MARK: Text editing

    /// `segment` with its text replaced by `newText`. Unchanged words keep their timings; the changed span is
    /// re-aligned by interpolation inside the segment's time range (EDIT-AC-06). Returns `segment` when nothing changed.
    public static func editText(_ segment: Segment, to newText: String) -> Segment {
        let old = TextNormalizer.nfc(segment.text)
        let new = TextNormalizer.nfc(newText)
        guard old != new else { return segment }
        let oldUnits = Array(old.utf16)
        let newUnits = Array(new.utf16)
        var prefix = 0
        while prefix < min(oldUnits.count, newUnits.count), oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldUnits.count, newUnits.count) - prefix,
            oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix]
        {
            suffix += 1
        }
        let removed = NSRange(location: prefix, length: oldUnits.count - prefix - suffix)
        let inserted = String(decoding: newUnits[prefix..<(newUnits.count - suffix)], as: UTF16.self)
        var result = SegmentEditor.apply([TextEdit(range: removed, replacement: inserted)], to: segment)
        if segment.words.isEmpty { result.words = [] }
        return result
    }

    // MARK: Split

    /// Splits `segment` before word `wordIndex`. The first half keeps the segment's ID, the second gets a new one.
    /// Both halves keep speaker and language; translations are dropped (they no longer match). Returns nil when the
    /// index is out of range or either half would be empty.
    public static func split(_ segment: Segment, beforeWord wordIndex: Int, newID: SegmentID = SegmentID()) -> (Segment, Segment)? {
        let words = segment.words.isEmpty ? synthesizedWords(for: segment) : segment.words
        guard wordIndex > 0, wordIndex < words.count else { return nil }
        let leftWords = Array(words[..<wordIndex])
        let rightWords = Array(words[wordIndex...])
        let (leftText, rightText) = splitText(segment.text, words: words, at: wordIndex)
        var first = segment
        first.text = leftText
        first.words = leftWords
        first.end = max(segment.start, min(segment.end, leftWords.last?.end ?? segment.start))
        first.translations = []
        var second = segment
        second.id = newID
        second.text = rightText
        second.words = rightWords
        second.start = min(segment.end, max(first.end, rightWords.first?.start ?? first.end))
        second.translations = []
        return (first, second)
    }

    /// Splits at a UTF-16 offset of the NFC text (the caret in an inline edit). The offset snaps to the next word boundary.
    public static func split(_ segment: Segment, atCharacterOffset offset: Int, newID: SegmentID = SegmentID()) -> (Segment, Segment)? {
        let words = segment.words.isEmpty ? synthesizedWords(for: segment) : segment.words
        let text = TextNormalizer.nfc(segment.text)
        guard let ranges = wordRanges(in: text, words: words),
            let index = ranges.firstIndex(where: { $0.location >= offset })
        else { return nil }
        var prepared = segment
        prepared.words = words
        return split(prepared, beforeWord: index, newID: newID)
    }

    private static func splitText(_ text: String, words: [Word], at index: Int) -> (String, String) {
        let nfc = TextNormalizer.nfc(text)
        let ns = nfc as NSString
        if let ranges = wordRanges(in: nfc, words: words) {
            let cut = ranges[index].location
            return (
                ns.substring(to: cut).trimmingCharacters(in: .whitespacesAndNewlines),
                ns.substring(from: cut).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        let join: ([Word]) -> String = { $0.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ") }
        return (join(Array(words[..<index])), join(Array(words[index...])))
    }

    // MARK: Merge

    /// Merges `second` into `first` (first's ID and speaker; if the languages differ, the longer segment's language).
    /// Words are concatenated and made monotonic (EDIT-AC-07).
    public static func merge(_ first: Segment, _ second: Segment) -> Segment {
        var merged = first
        let firstText = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let secondText = second.text.trimmingCharacters(in: .whitespacesAndNewlines)
        merged.text = [firstText, secondText].filter { !$0.isEmpty }.joined(separator: " ")
        merged.start = min(first.start, second.start)
        merged.end = max(first.end, second.end)
        merged.words = makeMonotonic(first.words + second.words, lowerBound: merged.start, upperBound: merged.end)
        if first.languageCode != second.languageCode {
            let longer = (second.end - second.start) > (first.end - first.start) ? second : first
            merged.languageCode = longer.languageCode
            merged.languageConfidence = longer.languageConfidence
        }
        let confidences = [first.confidence, second.confidence].compactMap { $0 }
        merged.confidence = confidences.isEmpty ? nil : confidences.reduce(0, +) / Double(confidences.count)
        merged.isIgnored = first.isIgnored && second.isIgnored
        merged.ignoreFlagIsManual = first.ignoreFlagIsManual || second.ignoreFlagIsManual
        merged.isUserEdited = first.isUserEdited || second.isUserEdited
        merged.translations = []
        return merged
    }

    // MARK: Timing helpers

    /// Clamps words into `[lowerBound, upperBound]` and makes starts/ends non-decreasing.
    public static func makeMonotonic(_ words: [Word], lowerBound: TimeInterval, upperBound: TimeInterval) -> [Word] {
        var cursor = lowerBound
        return words.map { word in
            var fixed = word
            fixed.start = min(upperBound, max(cursor, word.start))
            fixed.end = min(upperBound, max(fixed.start, word.end))
            cursor = fixed.end
            return fixed
        }
    }

    /// Whether word starts and ends never decrease and stay inside the segment (invariant checked by tests).
    public static func isMonotonic(_ segment: Segment) -> Bool {
        var cursor = segment.start
        for word in segment.words {
            if word.start < cursor - 1e-9 || word.end < word.start - 1e-9 { return false }
            cursor = word.end
        }
        return segment.words.isEmpty || cursor <= segment.end + 1e-9
    }

    /// Whitespace tokens of the text given proportional timings, for segments without word data.
    static func synthesizedWords(for segment: Segment) -> [Word] {
        let tokens = TextNormalizer.nfc(segment.text).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else { return [] }
        let weights = tokens.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        let span = max(0, segment.end - segment.start)
        var consumed = 0.0
        var cursor = segment.start
        var words: [Word] = []
        for (index, token) in tokens.enumerated() {
            consumed += weights[index]
            let next = index == tokens.count - 1 ? segment.end : segment.start + span * consumed / total
            words.append(Word(text: token, start: cursor, end: next))
            cursor = next
        }
        return words
    }

    /// UTF-16 ranges of each word in `text` (left to right); nil when they cannot be aligned.
    static func wordRanges(in text: String, words: [Word]) -> [NSRange]? {
        let ns = text as NSString
        var cursor = 0
        var out: [NSRange] = []
        for word in words {
            let trimmed = TextNormalizer.nfc(word.text).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, cursor <= ns.length else { return nil }
            let found = ns.range(of: trimmed, options: .literal, range: NSRange(location: cursor, length: ns.length - cursor))
            guard found.location != NSNotFound else { return nil }
            out.append(found)
            cursor = found.upperBound
        }
        return out
    }
}

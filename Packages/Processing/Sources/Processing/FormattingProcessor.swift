import AppCore
import Foundation

/// Which formatting clean-ups ``FormattingProcessor`` performs. Everything is opt-in at the chain level.
public struct FormattingOptions: Sendable, Hashable {
    /// Collapse runs of whitespace to one space and trim both ends.
    public var collapseWhitespace: Bool
    /// Remove spaces before `, . ; : ! ?` and add a space after `, ; ! ?` when a letter follows directly.
    public var fixPunctuationSpacing: Bool
    /// Capitalise the first lowercase letter after `. ! ?`.
    public var capitalizeSentences: Bool
    /// Also capitalise the first letter of the segment (off by default: segments can start mid-sentence).
    public var capitalizeSegmentStart: Bool

    public init(
        collapseWhitespace: Bool = true, fixPunctuationSpacing: Bool = true, capitalizeSentences: Bool = true,
        capitalizeSegmentStart: Bool = false
    ) {
        self.collapseWhitespace = collapseWhitespace
        self.fixPunctuationSpacing = fixPunctuationSpacing
        self.capitalizeSentences = capitalizeSentences
        self.capitalizeSegmentStart = capitalizeSegmentStart
    }
}

/// Optional punctuation/capitalisation clean-up. Scripts without case (Sinhala) are left untouched by capitalisation.
public struct FormattingProcessor: Sendable {
    public var options: FormattingOptions
    public init(options: FormattingOptions = FormattingOptions()) { self.options = options }

    /// Formats each non-ignored segment.
    public func apply(to segments: [Segment]) -> [Segment] {
        segments.map { $0.isIgnored ? $0 : apply(to: $0) }
    }

    /// Formats one segment, preserving word timings.
    public func apply(to segment: Segment) -> Segment {
        var current = segment
        if options.collapseWhitespace {
            current = pass(current, "[ \\t\\u00A0]{2,}", { _, _ in " " })
            current = pass(current, "^\\s+|\\s+$", { _, _ in "" })
        }
        if options.fixPunctuationSpacing {
            current = pass(current, "\\s+(?=[,.;:!?](?:\\s|$))", { _, _ in "" })
            current = pass(current, "(?<=[\\p{L}])(?=[,;!?]\\p{L})", { _, _ in "" }, insertSpaceAfter: 1)
        }
        if options.capitalizeSentences || options.capitalizeSegmentStart {
            var pattern = "(?<=[.!?]\\s)\\p{Ll}"
            if options.capitalizeSegmentStart { pattern = "(?:^\\p{Ll}|" + pattern + ")" }
            if !options.capitalizeSentences { pattern = "^\\p{Ll}" }
            current = pass(current, pattern, { match, _ in match.uppercased() })
        }
        return current
    }

    /// Applies one regex pass. `insertSpaceAfter` turns the match (zero-length) into a one-space insertion `n` characters on.
    private func pass(
        _ segment: Segment, _ pattern: String, _ transform: (String, NSTextCheckingResult) -> String, insertSpaceAfter: Int? = nil
    ) -> Segment {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return segment }
        let text = TextNormalizer.nfc(segment.text)
        let ns = text as NSString
        var edits: [TextEdit] = []
        regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, _ in
            guard let result else { return }
            if let shift = insertSpaceAfter {
                let position = result.range.location + shift
                edits.append(TextEdit(range: NSRange(location: position, length: 0), replacement: " "))
            } else if result.range.length > 0 {
                edits.append(TextEdit(range: result.range, replacement: transform(ns.substring(with: result.range), result)))
            }
        }
        guard !edits.isEmpty else { return segment }
        return SegmentEditor.apply(edits, to: segment)
    }
}

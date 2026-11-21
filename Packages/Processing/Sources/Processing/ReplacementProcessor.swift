import AppCore
import Foundation

/// Applies global replacement rules (FR-AC-10...16) in list order, each rule once (no recursive re-application).
///
/// Matching runs on NFC text; whole-word boundaries are Unicode-aware so Sinhala works. Word timings are preserved
/// by interpolation (see ``SegmentEditor``).
public struct ReplacementProcessor: Sendable {
    private struct Compiled: Sendable {
        var pattern: CompiledPattern
        var replacement: String
    }

    private let rules: [Compiled]

    /// Builds a processor. Disabled, soft-deleted and invalid rules are skipped.
    public init(rules: [ReplacementRule]) {
        self.rules = rules.compactMap { rule in
            guard rule.isEnabled, rule.deletedAt == nil,
                let pattern = try? CompiledPattern(
                    pattern: rule.find, matchCase: rule.matchCase, wholeWord: rule.wholeWord, isRegex: rule.isRegex)
            else { return nil }
            return Compiled(pattern: pattern, replacement: rule.isRegex ? rule.replacement : TextNormalizer.nfc(rule.replacement))
        }
    }

    /// True when no rule is active.
    public var isEmpty: Bool { rules.isEmpty }

    /// Applies the rules to each non-ignored segment.
    public func apply(to segments: [Segment]) -> [Segment] {
        guard !rules.isEmpty else { return segments }
        return segments.map { $0.isIgnored ? $0 : apply(to: $0) }
    }

    /// Applies the rules to one segment (text and word timings).
    public func apply(to segment: Segment) -> Segment {
        var current = segment
        for rule in rules {
            let text = TextNormalizer.nfc(current.text)
            let edits = rule.pattern.matches(in: text).map {
                TextEdit(range: $0.range, replacement: rule.pattern.replacement(rule.replacement, for: $0, in: text))
            }
            if !edits.isEmpty { current = SegmentEditor.apply(edits, to: current) }
        }
        return current
    }

    /// Applies the rules to plain text (live captions, dictation).
    public func apply(to text: String) -> String {
        var current = TextNormalizer.nfc(text)
        for rule in rules {
            let edits = rule.pattern.matches(in: current).map {
                TextEdit(range: $0.range, replacement: rule.pattern.replacement(rule.replacement, for: $0, in: current))
            }
            current = SegmentEditor.applyToText(edits, text: current)
        }
        return current
    }

    /// IDs of rules whose replacement contains their own pattern (would loop if applied recursively; FR-AC-14 warning).
    public static func loopWarnings(for rules: [ReplacementRule]) -> [RuleID] {
        rules.filter { rule in
            guard rule.isEnabled, rule.deletedAt == nil,
                let pattern = try? CompiledPattern(pattern: rule.find, matchCase: rule.matchCase, wholeWord: false, isRegex: rule.isRegex)
            else { return false }
            return !pattern.matches(in: TextNormalizer.nfc(rule.replacement)).isEmpty
        }.map(\.id)
    }
}

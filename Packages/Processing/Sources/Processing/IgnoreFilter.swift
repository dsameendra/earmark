import AppCore
import Foundation

/// Rule-based, non-destructive flagging of non-speech markers and (gated) hallucinations (IGN).
///
/// Segments are flagged via `isIgnored`, never deleted. A `wholeSegment` rule flags the segment; an `inline` rule removes
/// the matched span (keeping the remaining words' timings) and flags the segment only if nothing is left.
/// Hallucination-list rules apply only when the filter is enabled **and** the segment is low-confidence
/// (`confidence < lowConfidenceThreshold` or `noSpeechProbability >= noSpeechThreshold`).
public struct IgnoreFilter: Sendable {
    /// How existing `isIgnored` flags are treated when processing.
    public enum FlagMode: Sendable, Equatable {
        /// Only ever sets flags; existing flags are kept.
        case additive
        /// Recomputes flags (IGN-AC-05): flags no longer matched are cleared, except for `preserving` (manual flags).
        case rederive(preserving: Set<SegmentID>)
    }

    /// Maximum time a single regex may spend on one segment before it is treated as a non-match.
    public static let regexTimeout: TimeInterval = 0.05

    private struct Compiled: Sendable {
        var scope: RuleScope
        var isHallucination: Bool
        var exact: String?
        var pattern: CompiledPattern?
    }

    private let exactWhole: Set<String>
    private let rules: [Compiled]
    private let hallucinationEnabled: Bool
    private let lowConfidence: Double
    private let noSpeech: Double
    private let mode: FlagMode

    /// Builds a filter. Disabled, soft-deleted and invalid-regex rules are skipped (an invalid rule never crashes processing).
    public init(
        rules: [IgnoreRule], enableHallucinationFilter: Bool = false, lowConfidenceThreshold: Double = 0.5,
        noSpeechThreshold: Double = 0.6, mode: FlagMode = .additive
    ) {
        var compiled: [Compiled] = []
        var whole = Set<String>()
        for rule in rules where rule.deletedAt == nil {
            // Hallucination rules are governed by the global toggle; the shipped defaults are stored disabled.
            if rule.isHallucinationRule {
                guard enableHallucinationFilter else { continue }
            } else {
                guard rule.isEnabled else { continue }
            }
            guard let entry = Self.compile(rule) else { continue }
            if entry.exact != nil, entry.scope == .wholeSegment, !entry.isHallucination, let key = entry.exact {
                whole.insert(key)
            } else {
                compiled.append(entry)
            }
        }
        self.exactWhole = whole
        self.rules = compiled
        self.hallucinationEnabled = enableHallucinationFilter
        self.lowConfidence = lowConfidenceThreshold
        self.noSpeech = noSpeechThreshold
        self.mode = mode
    }

    /// Builds a filter from a post-processing context.
    public init(context: PostProcessingContext, mode: FlagMode = .additive) {
        self.init(
            rules: context.ignoreRules, enableHallucinationFilter: context.enableHallucinationFilter,
            lowConfidenceThreshold: context.lowConfidenceThreshold, noSpeechThreshold: context.noSpeechThreshold, mode: mode)
    }

    private static func compile(_ rule: IgnoreRule) -> Compiled? {
        guard !TextNormalizer.normalizeForMatching(rule.pattern).isEmpty else { return nil }
        switch rule.match {
        case .exact:
            return Compiled(
                scope: rule.scope, isHallucination: rule.isHallucinationRule, exact: TextNormalizer.normalizeForMatching(rule.pattern),
                pattern: nil)
        case .contains:
            let tokens = TextNormalizer.nfc(rule.pattern).split(whereSeparator: \.isWhitespace).map {
                NSRegularExpression.escapedPattern(for: String($0))
            }
            guard
                let pattern = try? CompiledPattern(
                    pattern: tokens.joined(separator: "\\s+"), matchCase: false, wholeWord: false, isRegex: true)
            else { return nil }
            return Compiled(scope: rule.scope, isHallucination: rule.isHallucinationRule, exact: nil, pattern: pattern)
        case .regex:
            guard let pattern = try? CompiledPattern(pattern: rule.pattern, matchCase: true, wholeWord: false, isRegex: true) else {
                return nil
            }
            return Compiled(scope: rule.scope, isHallucination: rule.isHallucinationRule, exact: nil, pattern: pattern)
        }
    }

    /// Validates a rule at save time (IGN-AC-03): empty patterns and invalid regexes are rejected.
    public static func validate(_ rule: IgnoreRule) throws {
        if TextNormalizer.normalizeForMatching(rule.pattern).isEmpty { throw PatternError.empty }
        if rule.match == .regex { _ = try CompiledPattern(pattern: rule.pattern, matchCase: true, wholeWord: false, isRegex: true) }
    }

    // MARK: Applying

    /// Returns `segments` with ignore flags (and inline removals) applied.
    public func apply(to segments: [Segment]) -> [Segment] {
        segments.map(apply(to:))
    }

    /// Applies the filter to one segment.
    public func apply(to segment: Segment) -> Segment {
        var seg = segment
        if case .rederive(let preserving) = mode, !preserving.contains(seg.id) { seg.isIgnored = false }
        let normalized = TextNormalizer.normalizeForMatching(seg.text)
        if normalized.isEmpty { return seg }
        if exactWhole.contains(normalized) {
            seg.isIgnored = true
            return seg
        }
        let gateOpen = hallucinationEnabled && isLowConfidence(seg)
        var inline: [Compiled] = []
        for rule in rules where !rule.isHallucination || gateOpen {
            if rule.scope == .inline {
                inline.append(rule)
            } else if matchesWhole(rule, text: seg.text, normalized: normalized) {
                seg.isIgnored = true
                return seg
            }
        }
        for rule in inline { seg = applyInline(rule, to: seg, normalized: normalized) }
        return seg
    }

    private func isLowConfidence(_ seg: Segment) -> Bool {
        if let confidence = seg.confidence, confidence < lowConfidence { return true }
        if let probability = seg.noSpeechProbability, probability >= noSpeech { return true }
        return false
    }

    private func matchesWhole(_ rule: Compiled, text: String, normalized: String) -> Bool {
        if let exact = rule.exact { return exact == normalized }
        guard let pattern = rule.pattern else { return false }
        return !pattern.matches(in: TextNormalizer.nfc(text), timeout: Self.regexTimeout).isEmpty
    }

    private func applyInline(_ rule: Compiled, to seg: Segment, normalized: String) -> Segment {
        let text = TextNormalizer.nfc(seg.text)
        var ranges: [NSRange] = []
        if let exact = rule.exact {
            if exact == normalized { ranges = [NSRange(location: 0, length: (text as NSString).length)] }
        } else if let pattern = rule.pattern {
            ranges = pattern.matches(in: text, timeout: Self.regexTimeout).map(\.range)
        }
        guard !ranges.isEmpty else { return seg }
        let ns = text as NSString
        let edits = ranges.map { range -> TextEdit in
            var upper = range.upperBound
            var lower = range.location
            // Swallow the whitespace that follows (or, at the end of the text, precedes) so no double spaces remain.
            while upper < ns.length, isSpace(ns.character(at: upper)) { upper += 1 }
            if upper == ns.length { while lower > 0, isSpace(ns.character(at: lower - 1)) { lower -= 1 } }
            return TextEdit(range: NSRange(location: lower, length: upper - lower), replacement: "")
        }
        var result = SegmentEditor.apply(Self.mergeOverlaps(edits), to: seg)
        result.text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.text.isEmpty { result.isIgnored = true }
        return result
    }

    private func isSpace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func mergeOverlaps(_ edits: [TextEdit]) -> [TextEdit] {
        var merged: [TextEdit] = []
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            if let last = merged.last, edit.range.location < last.range.upperBound {
                let upper = max(last.range.upperBound, edit.range.upperBound)
                merged[merged.count - 1].range = NSRange(location: last.range.location, length: upper - last.range.location)
            } else {
                merged.append(edit)
            }
        }
        return merged
    }
}

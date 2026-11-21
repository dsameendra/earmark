import AppCore
import Foundation

/// The shipped ignore-rule defaults (specs/features/17-ignored-segments.md). Never auto-inserted:
/// call ``seed(into:)`` explicitly (first launch, or "Restore defaults").
public enum DefaultIgnoreRules {
    /// Exact, whole-segment, enabled non-speech markers.
    public static let markerPatterns: [String] = [
        "[BLANK_AUDIO]", "[ BLANK_AUDIO ]", "[Music]", "[music]", "[MUSIC PLAYING]", "[MUSIC]", "(music)", "[no audio]",
        "[ Silence ]", "[silence]", "[inaudible]", "[GASP]", "[ Pause ]", "( retirement bell rang )", "( silence )",
        "(crunching)", "(door slams)", "(silence)", "[Pause]", "[Silencio]", "(scissors snipping)", "(Applause.)",
        "(Pause)", "[APPLAUSE]", "[LAUGHTER]", "(laughs)", "[NOISE]", "*music*", "♪", "♪♪",
    ]

    /// Known Whisper hallucinations; shipped disabled and gated by confidence (IGN-AC-06).
    public static let hallucinationPatterns: [String] = [
        "Thank you for watching.", "Subtitles by the Amara.org community",
    ]

    /// Builds fresh rule values for the full default set (new ids each call).
    public static func make() -> [IgnoreRule] {
        markerPatterns.map { IgnoreRule(pattern: $0, match: .exact, scope: .wholeSegment, isEnabled: true) }
            + hallucinationPatterns.map {
                IgnoreRule(pattern: $0, match: .exact, scope: .wholeSegment, isEnabled: false, isHallucinationRule: true)
            }
    }

    /// Inserts every default rule that is not already present (matched on pattern + match + scope among live rules).
    ///
    /// Idempotent, so it doubles as "Restore defaults": user-added rules are untouched and defaults the user removed
    /// are re-added.
    /// - Returns: The number of rules inserted.
    @discardableResult
    public static func seed(into repository: any RuleRepository) async throws -> Int {
        let existing = try await repository.ignoreRules()
        let present = Set(existing.map { Key(pattern: $0.pattern, match: $0.match, scope: $0.scope) })
        var inserted = 0
        for rule in make() where !present.contains(Key(pattern: rule.pattern, match: rule.match, scope: rule.scope)) {
            try await repository.saveIgnoreRule(rule)
            inserted += 1
        }
        return inserted
    }

    private struct Key: Hashable {
        var pattern: String
        var match: RuleMatch
        var scope: RuleScope
    }
}

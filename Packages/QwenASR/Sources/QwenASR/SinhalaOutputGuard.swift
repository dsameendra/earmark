import Foundation

/// Pure guards around Qwen3-ASR output (pre-processing limits and post-processing clean-up). No MLX dependency, so they are
/// unit-tested with `swift test`.
///
/// The research spike (`specs/research/sinhala-asr.md`) found runaway repetition loops (one in 566 held-out clips with the
/// library's own backstop, which only catches loops of at most three distinct tokens), so every call is bounded by a
/// length-based token cap and the text is checked for repetition while it streams.
public enum SinhalaOutputGuard {
    /// Token cap for `seconds` of audio, as recommended by the model card: `64 + 30 * seconds`.
    public static func maxTokens(forSeconds seconds: TimeInterval) -> Int {
        64 + Int((30 * max(0, seconds)).rounded(.up))
    }

    /// Result of ``truncateRepetition(_:)``.
    public struct Cleaned: Equatable, Sendable {
        public var text: String
        /// `true` when a repetition loop was cut off.
        public var truncated: Bool
    }

    /// Cuts a degenerate repetition loop: a unit of 1 to 40 characters repeated back to back at least
    /// `minimumRepeats(unitLength:)` times (and covering at least 24 characters) is reduced to a single occurrence and
    /// everything after the loop is dropped (a looping decoder rarely recovers).
    public static func truncateRepetition(_ text: String) -> Cleaned {
        let chars = Array(text)
        guard chars.count >= 24 else { return Cleaned(text: text, truncated: false) }
        var cut: Int?  // index just after the first copy of the earliest loop
        for unit in 1...min(40, chars.count / 2) {
            let required = max(minimumRepeats(unitLength: unit) * unit, 24)  // characters covered by the periodic region
            var run = 0  // consecutive positions equal to the one `unit` characters earlier
            for index in unit..<chars.count {
                run = chars[index] == chars[index - unit] ? run + 1 : 0
                if run + unit >= required {
                    let regionStart = index - run - unit + 1
                    let candidate = regionStart + unit
                    if cut == nil || candidate < cut! { cut = candidate }
                    break
                }
            }
        }
        guard let cut else { return Cleaned(text: text, truncated: false) }
        return Cleaned(text: String(chars[0..<cut]).trimmingCharacters(in: .whitespacesAndNewlines), truncated: true)
    }

    /// How many back-to-back repeats of a `unitLength`-character unit count as a loop.
    static func minimumRepeats(unitLength: Int) -> Int {
        switch unitLength {
        case 1: return 12
        case 2...3: return 8
        case 4...8: return 5
        default: return 4
        }
    }

    /// `true` when most letters are neither Sinhala nor Latin (a model emitting Devanagari/Gujarati/Gurmukhi is failing, as
    /// stock Whisper does on Sinhala). Digits, punctuation and whitespace are ignored.
    public static func isWrongScript(_ text: String) -> Bool {
        var wanted = 0
        var other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x0D80...0x0DFF, 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x200D: wanted += 1
            default: other += 1
            }
        }
        return other > 0 && other > wanted
    }

    /// Normalises model output for storage: NFC, trimmed. ZWJ (U+200D) is kept (it changes conjunct glyphs).
    public static func normalise(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

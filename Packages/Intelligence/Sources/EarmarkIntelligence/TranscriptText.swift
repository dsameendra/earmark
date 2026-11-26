import AppCore
import Foundation

/// One spoken line with its time and speaker, ready to be shown to the model or retrieved.
struct TranscriptLine: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var speaker: String?
    var text: String

    var rendered: String {
        let who = speaker.map { "\($0): " } ?? ""
        return "[\(TranscriptText.clock(start))] \(who)\(text)"
    }
}

enum TranscriptText {
    /// Non-ignored, non-empty segments in time order, with speaker names.
    static func lines(segments: [Segment], speakers: [Speaker]) -> [TranscriptLine] {
        let names = Dictionary(speakers.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return segments
            .filter { !$0.isIgnored && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            .map {
                TranscriptLine(
                    start: $0.start, end: $0.end, speaker: $0.speakerID.flatMap { names[$0] },
                    text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
    }

    /// "12:52" or "1:02:03".
    static func clock(_ time: TimeInterval) -> String {
        let total = max(0, Int(time))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    static func render(_ lines: [TranscriptLine]) -> String { lines.map(\.rendered).joined(separator: "\n") }

    /// Splits lines into runs that each fit `budgetTokens`, never splitting a line (a single oversized line is its own run).
    static func chunks(_ lines: [TranscriptLine], budgetTokens: Int) -> [[TranscriptLine]] {
        var result: [[TranscriptLine]] = []
        var current: [TranscriptLine] = []
        var used = 0
        for line in lines {
            let cost = TokenEstimate.tokens(line.rendered) + 1
            if used + cost > budgetTokens, !current.isEmpty {
                result.append(current)
                current = []
                used = 0
            }
            current.append(line)
            used += cost
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

/// Words that carry meaning for matching (lowercased letters and digits, short and common words removed).
enum Words {
    private static let stop: Set<String> = [
        "the", "and", "for", "are", "was", "were", "that", "this", "with", "from", "have", "has", "had", "will", "would", "could",
        "should", "about", "into", "than", "then", "them", "they", "their", "there", "what", "when", "where", "which", "who", "how",
        "not", "but", "you", "your", "our", "out", "all", "any", "can", "did", "does", "its", "also", "been", "being", "more", "some",
    ]

    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var word = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if !word.isEmpty {
                out.append(word)
                word = ""
            }
        }
        if !word.isEmpty { out.append(word) }
        return out
    }

    /// Tokens worth matching on: at least three characters (digits any length) and not a stop word.
    static func content(_ text: String) -> [String] {
        tokens(text).filter { ($0.count >= 3 || $0.contains(where: \.isNumber)) && !stop.contains($0) }
    }
}

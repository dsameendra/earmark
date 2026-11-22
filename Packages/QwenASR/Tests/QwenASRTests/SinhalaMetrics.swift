import Foundation

/// Swift port of `spikes/sinhala/sinmetrics.py` (same normaliser as the research numbers, so results are comparable):
/// NFC, strip ZWJ/ZWNJ, lower-case, punctuation and symbols to spaces, whitespace collapsed; CER ignores spaces.
enum SinhalaMetrics {
    static func normalise(_ text: String, stripZeroWidth: Bool = true) -> String {
        var s = text.precomposedStringWithCanonicalMapping
        if stripZeroWidth { s.removeAll { $0 == "\u{200D}" || $0 == "\u{200C}" } }
        s = s.lowercased()
        let mapped = s.unicodeScalars.map { scalar -> Character in
            switch scalar.properties.generalCategory {
            case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
                .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
                return " "
            default: return Character(scalar)
            }
        }
        return String(mapped).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Levenshtein distance over unicode scalars (the python scorer works on code points).
    static func distance<T: Equatable>(_ a: [T], _ b: [T]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var row = [i + 1]
            for (j, y) in b.enumerated() {
                row.append(min(previous[j + 1] + 1, row[j] + 1, previous[j] + (x == y ? 0 : 1)))
            }
            previous = row
        }
        return previous[b.count]
    }

    /// (errors, reference length) at character level, spaces removed.
    static func characterCounts(reference: String, hypothesis: String) -> (errors: Int, total: Int) {
        let r = Array(normalise(reference).unicodeScalars.filter { $0 != " " })
        let h = Array(normalise(hypothesis).unicodeScalars.filter { $0 != " " })
        return (distance(r, h), r.count)
    }

    static func wordCounts(reference: String, hypothesis: String) -> (errors: Int, total: Int) {
        let r = normalise(reference).split(separator: " ").map(String.init)
        let h = normalise(hypothesis).split(separator: " ").map(String.init)
        return (distance(r, h), r.count)
    }
}

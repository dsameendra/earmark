import AppCore
import Foundation
import Testing

@testable import Processing

private func seg(_ text: String, confidence: Double? = nil, noSpeech: Double? = nil, words: [Word] = [], ignored: Bool = false) -> Segment {
    Segment(
        start: 0, end: 4, text: text, confidence: confidence, noSpeechProbability: noSpeech, isIgnored: ignored, words: words)
}

private let defaultMarkers: [String] = [
    "[BLANK_AUDIO]", "[ BLANK_AUDIO ]", "[Music]", "[music]", "[MUSIC PLAYING]", "[MUSIC]", "(music)", "[no audio]",
    "[ Silence ]", "[silence]", "[inaudible]", "[GASP]", "[ Pause ]", "( retirement bell rang )", "( silence )",
    "(crunching)", "(door slams)", "(silence)", "[Pause]", "[Silencio]", "(scissors snipping)", "(Applause.)",
    "(Pause)", "[APPLAUSE]", "[LAUGHTER]", "(laughs)", "[NOISE]", "*music*", "♪", "♪♪",
]

@Suite("IgnoreFilter")
struct IgnoreFilterTests {
    @Test("IGN-AC-01/04: every default marker is flagged, never deleted", arguments: defaultMarkers)
    func defaultMarkerFlagged(marker: String) {
        let filter = IgnoreFilter(rules: [IgnoreRule(pattern: marker)])
        let out = filter.apply(to: [seg(marker)])
        #expect(out.count == 1)
        #expect(out[0].isIgnored)
        #expect(out[0].text == marker)
    }

    @Test("IGN-AC-02: exact normalises whitespace, case and trimming but never strips brackets")
    func exactNormalisation() {
        let filter = IgnoreFilter(rules: [IgnoreRule(pattern: "[Music]")])
        #expect(filter.apply(to: seg("  [music]  ")).isIgnored)
        #expect(filter.apply(to: seg("[MUSIC]")).isIgnored)
        #expect(!filter.apply(to: seg("Music")).isIgnored)
        #expect(!filter.apply(to: seg("[ Music ]")).isIgnored)
        #expect(!filter.apply(to: seg("[Music] and talk")).isIgnored)
        let spaced = IgnoreFilter(rules: [IgnoreRule(pattern: "( retirement   bell rang )")])
        #expect(spaced.apply(to: seg("( retirement bell\n rang )")).isIgnored)
    }

    @Test("IGN-AC-03: contains matches normalised substrings, including inside Sinhala")
    func containsMatch() {
        let filter = IgnoreFilter(rules: [IgnoreRule(pattern: "♪", match: .contains)])
        #expect(filter.apply(to: seg("la la ♪ la ♪")).isIgnored)
        #expect(!filter.apply(to: seg("plain words")).isIgnored)
        let si = IgnoreFilter(rules: [IgnoreRule(pattern: "සංගීතය", match: .contains)])
        #expect(si.apply(to: seg("[සංගීතය වාදනය වේ]")).isIgnored)
    }

    @Test("IGN-AC-03: regex rules evaluate; invalid regex is rejected at save time and never crashes processing")
    func regexRules() throws {
        let rule = IgnoreRule(pattern: "^\\[.*\\]$", match: .regex)
        try IgnoreFilter.validate(rule)
        #expect(IgnoreFilter(rules: [rule]).apply(to: seg("[anything]")).isIgnored)
        #expect(!IgnoreFilter(rules: [rule]).apply(to: seg("x [anything]")).isIgnored)

        let bad = IgnoreRule(pattern: "([unclosed", match: .regex)
        #expect(throws: PatternError.self) { try IgnoreFilter.validate(bad) }
        #expect(throws: PatternError.self) { try IgnoreFilter.validate(IgnoreRule(pattern: "   ")) }
        #expect(!IgnoreFilter(rules: [bad]).apply(to: seg("([unclosed")).isIgnored)
    }

    @Test("Catastrophic regex is cut off and treated as a non-match")
    func regexTimeout() {
        let rule = IgnoreRule(pattern: "(a+)+$", match: .regex)
        let text = String(repeating: "a", count: 40) + "b"
        let started = Date()
        let out = IgnoreFilter(rules: [rule]).apply(to: seg(text))
        #expect(!out.isIgnored)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("IGN-AC-04: inline removes the span, keeps remaining word timings, flags only when empty")
    func inlineRemoval() {
        let words = [
            Word(text: " Hello", start: 0, end: 1), Word(text: " [Music]", start: 1, end: 2), Word(text: " world", start: 2, end: 3),
        ]
        let rule = IgnoreRule(pattern: "[Music]", match: .contains, scope: .inline)
        let out = IgnoreFilter(rules: [rule]).apply(to: seg("Hello [Music] world", words: words))
        #expect(out.text == "Hello world")
        #expect(!out.isIgnored)
        #expect(out.words.map(\.text).map { $0.trimmingCharacters(in: .whitespaces) } == ["Hello", "world"])
        #expect(out.words[0].start == 0 && out.words[0].end == 1)
        #expect(out.words[1].start == 2 && out.words[1].end == 3)

        let only = IgnoreFilter(rules: [rule]).apply(to: seg("[Music]", words: [Word(text: "[Music]", start: 0, end: 4)]))
        #expect(only.isIgnored)
        #expect(only.text.isEmpty)
        #expect(only.words.isEmpty)

        let trailing = IgnoreFilter(rules: [rule]).apply(to: seg("Hello [Music]"))
        #expect(trailing.text == "Hello")
    }

    @Test("IGN-AC-05: disabled and soft-deleted rules stop applying; re-derive un-ignores except manual flags")
    func disabledAndRederive() {
        let on = IgnoreRule(pattern: "[Music]")
        var off = on
        off.isEnabled = false
        var deleted = on
        deleted.deletedAt = Date()
        #expect(!IgnoreFilter(rules: [off]).apply(to: seg("[Music]")).isIgnored)
        #expect(!IgnoreFilter(rules: [deleted]).apply(to: seg("[Music]")).isIgnored)

        let stale = seg("real speech", ignored: true)
        let manual = seg("also real", ignored: true)
        let additive = IgnoreFilter(rules: [on]).apply(to: [stale, manual])
        #expect(additive.allSatisfy { $0.isIgnored })
        let re = IgnoreFilter(rules: [on], mode: .rederive(preserving: [manual.id])).apply(to: [stale, manual])
        #expect(!re[0].isIgnored)
        #expect(re[1].isIgnored)
    }

    @Test("IGN-AC-06: hallucination gating matrix (filter on/off x confidence x noSpeech)")
    func hallucinationMatrix() {
        let rule = IgnoreRule(pattern: "Thank you for watching.", isEnabled: false, isHallucinationRule: true)
        let phrase = "Thank you for watching."
        struct Case {
            var enabled: Bool
            var confidence: Double?
            var noSpeech: Double?
            var flagged: Bool
        }
        let cases: [Case] = [
            Case(enabled: false, confidence: 0.1, noSpeech: 0.99, flagged: false),
            Case(enabled: true, confidence: 0.9, noSpeech: 0.1, flagged: false),
            Case(enabled: true, confidence: 0.49, noSpeech: 0.1, flagged: true),
            Case(enabled: true, confidence: 0.5, noSpeech: 0.1, flagged: false),
            Case(enabled: true, confidence: 0.9, noSpeech: 0.6, flagged: true),
            Case(enabled: true, confidence: 0.9, noSpeech: 0.59, flagged: false),
            Case(enabled: true, confidence: nil, noSpeech: nil, flagged: false),
            Case(enabled: true, confidence: nil, noSpeech: 0.8, flagged: true),
        ]
        for c in cases {
            let out = IgnoreFilter(rules: [rule], enableHallucinationFilter: c.enabled).apply(
                to: seg(phrase, confidence: c.confidence, noSpeech: c.noSpeech))
            #expect(out.isIgnored == c.flagged, "\(c)")
        }
    }

    @Test("A hallucination rule never flags text that does not match")
    func hallucinationNonMatching() {
        let rule = IgnoreRule(pattern: "Thank you for watching.", isHallucinationRule: true)
        let out = IgnoreFilter(rules: [rule], enableHallucinationFilter: true).apply(to: seg("Thank you", confidence: 0.1))
        #expect(!out.isIgnored)
    }

    @Test("Rule order independence")
    func orderIndependence() {
        let rules = [IgnoreRule(pattern: "[Music]"), IgnoreRule(pattern: "zzz", match: .contains), IgnoreRule(pattern: "♪")]
        let segments = [seg("[Music]"), seg("a zzz b"), seg("♪"), seg("keep me")]
        let a = IgnoreFilter(rules: rules).apply(to: segments).map(\.isIgnored)
        let b = IgnoreFilter(rules: rules.reversed()).apply(to: segments).map(\.isIgnored)
        #expect(a == [true, true, true, false])
        #expect(a == b)
    }

    @Test("Unicode: decomposed Sinhala matches a precomposed rule after NFC")
    func sinhalaNFC() {
        let decomposed = "\u{0DD9}\u{0DDF}"  // e + au length mark -> U+0DDE (kombuva + gaetta-pilla)
        let precomposed = "\u{0DDE}"
        #expect(TextNormalizer.nfc(decomposed) == precomposed)
        let filter = IgnoreFilter(rules: [IgnoreRule(pattern: "ක\(precomposed)", match: .exact)])
        #expect(filter.apply(to: seg("ක\(decomposed)")).isIgnored)
        let contains = IgnoreFilter(rules: [IgnoreRule(pattern: "ක\(precomposed)", match: .contains)])
        #expect(contains.apply(to: seg("අ ක\(decomposed) ආ")).isIgnored)
    }

    @Test("Mixed English + Sinhala segment: near-miss is not flagged, inline removes only the marker")
    func mixedLanguage() {
        let filter = IgnoreFilter(rules: [
            IgnoreRule(pattern: "[Music]"), IgnoreRule(pattern: "[laughs]", match: .contains, scope: .inline),
        ])
        #expect(!filter.apply(to: seg("[Music] ආයුබෝවන්")).isIgnored)
        let out = filter.apply(to: seg("ආයුබෝවන් [laughs] hello"))
        #expect(out.text == "ආයුබෝවන් hello")
    }

    @Test("Multi-line segments normalise whitespace for exact matching")
    func multiline() {
        #expect(IgnoreFilter(rules: [IgnoreRule(pattern: "[ Pause ]")]).apply(to: seg("[\nPause\n]")).isIgnored)
        #expect(IgnoreFilter(rules: [IgnoreRule(pattern: "( silence )")]).apply(to: seg("(\nsilence\n)")).isIgnored)
    }

    @Test("NFR: 10 000 segments x 100 rules stays fast")
    func performance() {
        var rules = (0..<97).map { IgnoreRule(pattern: "marker-\($0)", match: .contains) }
        rules.append(IgnoreRule(pattern: "[Music]"))
        rules.append(IgnoreRule(pattern: "^\\(.*\\)$", match: .regex))
        rules.append(IgnoreRule(pattern: "♪", match: .contains, scope: .inline))
        let segments = (0..<10_000).map { seg($0 % 10 == 0 ? "[Music]" : "ordinary sentence number \($0)") }
        let started = Date()
        let out = IgnoreFilter(rules: rules).apply(to: segments)
        let elapsed = Date().timeIntervalSince(started)
        #expect(out.filter(\.isIgnored).count == 1000)
        #expect(elapsed < 5, "took \(elapsed)s (debug build; release target is 200 ms)")
    }
}

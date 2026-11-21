import AppCore
import Foundation
import Testing

@testable import Processing

private func words(_ pairs: [(String, Double, Double)]) -> [Word] {
    pairs.map { Word(text: $0.0, start: $0.1, end: $0.2) }
}

private func seg(_ text: String, words: [Word] = [], lang: LanguageCode? = nil, ignored: Bool = false) -> Segment {
    Segment(start: 10, end: 20, text: text, languageCode: lang, isIgnored: ignored, words: words)
}

@Suite("ReplacementProcessor")
struct ReplacementProcessorTests {
    @Test("FR-AC-10: global rule applies; word timings preserved by interpolation")
    func basicReplacementKeepsTiming() {
        let input = seg(
            "Hi Doomindu here",
            words: words([(" Hi", 10, 12), (" Doomindu", 12, 16), (" here", 16, 20)]))
        let out = ReplacementProcessor(rules: [ReplacementRule(find: "Doomindu", replacement: "Dumindu")]).apply(to: input)
        #expect(out.text == "Hi Dumindu here")
        #expect(out.words.count == 3)
        #expect(out.words[1].text == "Dumindu")
        #expect(out.words[1].start == 12 && out.words[1].end == 16)
        #expect(out.start == 10 && out.end == 20)
    }

    @Test("FR-AC-05/07: growing into several words splits timing proportionally; merging joins spans")
    func splitAndMerge() {
        let input = seg("see you tomorrow", words: words([("see", 10, 12), ("you", 12, 14), ("tomorrow", 14, 20)]))
        let grown = ReplacementProcessor(rules: [ReplacementRule(find: "tomorrow", replacement: "the day after")]).apply(to: input)
        #expect(grown.words.map(\.text) == ["see", "you", "the", "day", "after"])
        #expect(grown.words[2].start == 14)
        #expect(grown.words[4].end == 20)
        for (a, b) in zip(grown.words, grown.words.dropFirst()) { #expect(a.end == b.start) }

        let merged = ReplacementProcessor(rules: [ReplacementRule(find: "see you", replacement: "bye")]).apply(to: input)
        #expect(merged.text == "bye tomorrow")
        #expect(merged.words.map(\.text) == ["bye", "tomorrow"])
        #expect(merged.words[0].start == 10 && merged.words[0].end == 14)
        #expect(merged.words[1].start == 14 && merged.words[1].end == 20)

        let removed = ReplacementProcessor(rules: [ReplacementRule(find: "you ", replacement: "")]).apply(to: input)
        #expect(removed.text == "see tomorrow")
        #expect(removed.words.map(\.text) == ["see", "tomorrow"].map { $0 })
    }

    @Test("FR-AC-02: matchCase and wholeWord are independent")
    func options() {
        let text = "Cat concat cat"
        func run(_ matchCase: Bool, _ wholeWord: Bool) -> String {
            ReplacementProcessor(rules: [ReplacementRule(find: "cat", replacement: "dog", matchCase: matchCase, wholeWord: wholeWord)])
                .apply(to: text)
        }
        #expect(run(false, false) == "dog condog dog")
        #expect(run(true, false) == "Cat condog dog")
        #expect(run(false, true) == "dog concat dog")
        #expect(run(true, true) == "Cat concat dog")
    }

    @Test("FR-AC-08: regex capture groups expand; literal mode keeps $ verbatim")
    func captureGroups() {
        let regex = ReplacementRule(find: "(\\w+)@(\\w+)", replacement: "$2 at $1", isRegex: true)
        #expect(ReplacementProcessor(rules: [regex]).apply(to: "bob@home") == "home at bob")
        let literal = ReplacementRule(find: "price", replacement: "$1 \\n $0")
        #expect(ReplacementProcessor(rules: [literal]).apply(to: "the price") == "the $1 \\n $0")
    }

    @Test("FR-AC-14: rules apply once each in list order, no recursion; loop warnings flag self-containing rules")
    func orderAndLoops() {
        let chain = [ReplacementRule(find: "a", replacement: "b"), ReplacementRule(find: "b", replacement: "c")]
        #expect(ReplacementProcessor(rules: chain).apply(to: "a") == "c")
        let selfRef = ReplacementRule(find: "cat", replacement: "cat food")
        #expect(ReplacementProcessor(rules: [selfRef]).apply(to: "cat") == "cat food")
        #expect(ReplacementProcessor.loopWarnings(for: [selfRef, chain[0]]) == [selfRef.id])
    }

    @Test("FR-AC-11: disabled and soft-deleted rules are not applied; ignored segments are skipped")
    func disabledRules() {
        var disabled = ReplacementRule(find: "x", replacement: "y")
        disabled.isEnabled = false
        var deleted = ReplacementRule(find: "x", replacement: "z")
        deleted.deletedAt = Date()
        #expect(ReplacementProcessor(rules: [disabled, deleted]).isEmpty)
        let live = ReplacementProcessor(rules: [ReplacementRule(find: "x", replacement: "y")])
        #expect(live.apply(to: [seg("x", ignored: true)])[0].text == "x")
    }

    @Test("FR-AC-16: Sinhala matches on NFC text and whole-word uses Unicode boundaries")
    func sinhala() {
        let decomposed = "ක\u{0DD9}\u{0DCF}"  // ක + kombuva + aelapilla == "කො"
        let precomposed = "ක\u{0DDC}"
        #expect(TextNormalizer.nfc(decomposed) == precomposed)
        let rule = ReplacementRule(find: precomposed, replacement: "X")
        #expect(ReplacementProcessor(rules: [rule]).apply(to: "a \(decomposed) b") == "a X b")

        // "කොහොමද" contains "කො" as a prefix: whole-word must not match inside it, while a free-standing one matches.
        let word = ReplacementRule(find: "කො", replacement: "X", wholeWord: true)
        #expect(ReplacementProcessor(rules: [word]).apply(to: "කොහොමද කො") == "කොහොමද X")
        let plain = ReplacementRule(find: "කො", replacement: "X")
        #expect(ReplacementProcessor(rules: [plain]).apply(to: "කොහොමද") == "Xහොමද")

        let name = ReplacementRule(find: "ඩුමින්දු", replacement: "දුමින්දු", wholeWord: true)
        let out = ReplacementProcessor(rules: [name]).apply(to: seg("මම ඩුමින්දු.", words: words([("මම", 10, 12), (" ඩුමින්දු.", 12, 20)])))
        #expect(out.text == "මම දුමින්දු.")
        #expect(out.words.count == 2)
        #expect(out.words[1].start == 12 && out.words[1].end == 20)
    }

    @Test("Words that cannot be aligned fall back to interpolation inside unchanged segment bounds")
    func misalignedWords() {
        let input = seg("alpha beta gamma", words: words([("zzz", 10, 14), ("yyy", 14, 20)]))
        let out = ReplacementProcessor(rules: [ReplacementRule(find: "beta", replacement: "delta")]).apply(to: input)
        #expect(out.words.map(\.text) == ["alpha", "delta", "gamma"])
        #expect(out.words.first?.start == 10)
        #expect(out.words.last?.end == 20)
    }

    @Test("Live/dictation text path")
    func plainText() {
        let p = ReplacementProcessor(rules: [ReplacementRule(find: "teh", replacement: "the", wholeWord: true)])
        #expect(p.apply(to: "teh tehran") == "the tehran")
    }
}

@Suite("FormattingProcessor and chain")
struct FormattingTests {
    @Test("Whitespace, punctuation spacing and sentence capitalisation")
    func formatting() {
        let f = FormattingProcessor()
        #expect(f.apply(to: seg("  hello   world .  next one,ok ?  ")).text == "hello world. Next one, ok?")
        let start = FormattingProcessor(options: FormattingOptions(capitalizeSegmentStart: true))
        #expect(start.apply(to: seg("hello. bye")).text == "Hello. Bye")
        #expect(f.apply(to: seg("ආයුබෝවන් . හරි")).text == "ආයුබෝවන්. හරි")
    }

    @Test("Formatting keeps word timings")
    func formattingKeepsTimings() {
        let input = seg("one  two", words: words([("one", 10, 14), ("two", 16, 20)]))
        let out = FormattingProcessor().apply(to: input)
        #expect(out.text == "one two")
        #expect(out.words.map(\.start) == [10, 16])
    }

    @Test("FR-AC-10: chain order is ignore, then replacements, then formatting")
    func chainOrder() async {
        let ctx = PostProcessingContext(
            ignoreRules: [IgnoreRule(pattern: "[Music]")],
            replacementRules: [
                ReplacementRule(find: "Doomindu", replacement: "Dumindu"), ReplacementRule(find: "Music", replacement: "Song"),
            ])
        let segments = [seg("[Music]"), seg("hi doomindu")]
        let out = await PostProcessingChain(formatting: FormattingOptions(capitalizeSegmentStart: true)).process(segments, context: ctx)
        #expect(out[0].isIgnored)
        #expect(out[0].text == "[Music]", "ignored segments are skipped by replacements")
        #expect(out[1].text == "Hi Dumindu")
    }

    @Test("FR-AC-11: applyReplacements false skips replacements; formatting off by default")
    func chainSwitches() async {
        let ctx = PostProcessingContext(
            replacementRules: [ReplacementRule(find: "a", replacement: "b")], applyReplacements: false)
        let out = await PostProcessingChain().process([seg("a  a")], context: ctx)
        #expect(out[0].text == "a  a")
    }

    @Test("Chain honours the hallucination gate end to end")
    func chainHallucination() async {
        let rule = IgnoreRule(pattern: "Thank you for watching.", isEnabled: false, isHallucinationRule: true)
        var ctx = PostProcessingContext(ignoreRules: [rule], enableHallucinationFilter: true)
        var low = seg("Thank you for watching.")
        low.confidence = 0.1
        var high = seg("Thank you for watching.")
        high.confidence = 0.95
        let out = await PostProcessingChain().process([low, high], context: ctx)
        #expect(out.map(\.isIgnored) == [true, false])
        ctx.enableHallucinationFilter = false
        #expect(await PostProcessingChain().process([low], context: ctx)[0].isIgnored == false)
    }
}

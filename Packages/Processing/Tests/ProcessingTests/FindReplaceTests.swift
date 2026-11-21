import AppCore
import Foundation
import Testing

@testable import Processing

private let alice = SpeakerID()
private let bob = SpeakerID()

private func fixture() -> [Segment] {
    [
        Segment(
            start: 0, end: 4, text: "the cat sat on the mat", speakerID: alice, languageCode: "en",
            words: [("the", 0.0, 0.5), ("cat", 0.5, 1.5), ("sat", 1.5, 2.0), ("on", 2.0, 2.5), ("the", 2.5, 3.0), ("mat", 3.0, 4.0)].map {
                Word(text: $0.0, start: $0.1, end: $0.2)
            }),
        Segment(start: 4, end: 8, text: "The Cat again", speakerID: bob, languageCode: "en"),
        Segment(start: 8, end: 12, text: "ආයුබෝවන් cat හරි", speakerID: alice, languageCode: "si"),
        Segment(
            start: 12, end: 14, text: "cat ignored", speakerID: bob, languageCode: "en", isIgnored: true),
        Segment(
            start: 14, end: 16, text: "hello", speakerID: bob, languageCode: "en",
            translations: [SegmentTranslation(language: "si", text: "cat ආයුබෝවන්", engine: "mock")]),
    ]
}

@Suite("FindReplaceEngine")
struct FindReplaceEngineTests {
    @Test("FR-AC-02: options and invalid regex")
    func options() throws {
        let segments = fixture()
        #expect(try FindReplaceEngine(query: FindQuery(text: "cat")).matches(in: segments).count == 3)
        #expect(try FindReplaceEngine(query: FindQuery(text: "Cat", matchCase: true)).matches(in: segments).count == 1)
        #expect(try FindReplaceEngine(query: FindQuery(text: "the", wholeWord: true)).matches(in: segments).count == 3)
        #expect(try FindReplaceEngine(query: FindQuery(text: "c.t", isRegex: true)).matches(in: segments).count == 3)
        #expect(throws: PatternError.self) { try FindReplaceEngine(query: FindQuery(text: "(", isRegex: true)) }
        #expect(throws: PatternError.self) { try FindReplaceEngine(query: FindQuery(text: "")) }
    }

    @Test("FR-AC-03: scopes restrict matches; ignored excluded unless shown; translations opt in")
    func scopes() throws {
        let segments = fixture()
        func count(_ scope: FindScope, ignored: Bool = false, translations: Bool = false) throws -> Int {
            try FindReplaceEngine(
                query: FindQuery(text: "cat", scope: scope, includeIgnored: ignored, includeTranslations: translations)
            ).matches(in: segments).count
        }
        #expect(try count(.all) == 3)
        #expect(try count(.all, ignored: true) == 4)
        #expect(try count(.all, translations: true) == 4)
        #expect(try count(.speaker(alice)) == 2)
        #expect(try count(.speaker(bob)) == 1)
        #expect(try count(.language("si")) == 1)
        #expect(try count(.language("en-GB")) == 2)
        #expect(try count(.selection([segments[0].id])) == 1)
        #expect(try count(.selection([])) == 0)
    }

    @Test("Matches never span segments")
    func noSpan() throws {
        let segments = [Segment(start: 0, end: 1, text: "foo"), Segment(start: 1, end: 2, text: "bar")]
        #expect(try FindReplaceEngine(query: FindQuery(text: "foo bar")).matches(in: segments).isEmpty)
    }

    @Test("FR-AC-04/05: preview lists before and after; replace all keeps segment bounds and re-times words")
    func previewAndReplaceAll() throws {
        let segments = fixture()
        let engine = try FindReplaceEngine(query: FindQuery(text: "cat", wholeWord: true))
        let preview = engine.preview(in: segments, replacement: "kitten")
        #expect(preview.count == 3)
        #expect(preview[0].before == "the cat sat on the mat")
        #expect(preview[0].after == "the kitten sat on the mat")
        #expect(preview[0].matchCount == 1)

        let changes = engine.replaceAll(in: segments, replacement: "kitten")
        let after = changes.applied(to: segments)
        #expect(after[0].text == "the kitten sat on the mat")
        #expect(after[0].start == 0 && after[0].end == 4)
        #expect(after[0].words[1].text == "kitten")
        #expect(after[0].words[1].start == 0.5 && after[0].words[1].end == 1.5)
        #expect(after[3].text == "cat ignored", "ignored segments untouched when excluded")
        #expect(after[2].text == "ආයුබෝවන් kitten හරි")
    }

    @Test("FR-AC-06: replace all is one undoable change set; undo/redo restore text, words and flags exactly")
    func undoRedo() throws {
        let segments = fixture()
        let engine = try FindReplaceEngine(query: FindQuery(text: "the", wholeWord: true, includeIgnored: true))
        let set = engine.replaceAll(in: segments, replacement: "a longer phrase")
        #expect(!set.isEmpty)
        let applied = set.applied(to: segments)
        #expect(applied != segments)
        #expect(set.undone(on: applied) == segments)
        #expect(set.inverted.applied(to: applied) == segments)
        #expect(set.inverted.inverted.applied(to: segments) == applied)
    }

    @Test("Undo property: apply then undo equals the original over many queries")
    func undoProperty() throws {
        let segments = fixture()
        let queries = ["cat", "the", "a", "ෝ", "\\w+", "t", "at", "ආ", "o"]
        let replacements = ["", "X", "longer replacement", "කො", "$1"]
        for q in queries {
            for r in replacements {
                for regex in [false, true] {
                    let engine = try FindReplaceEngine(
                        query: FindQuery(text: q, isRegex: regex, includeIgnored: true, includeTranslations: true))
                    let set = engine.replaceAll(in: segments, replacement: r)
                    #expect(set.undone(on: set.applied(to: segments)) == segments, "q=\(q) r=\(r) regex=\(regex)")
                    for change in set.changes {
                        #expect(change.after.start == change.before.start && change.after.end == change.before.end)
                    }
                }
            }
        }
    }

    @Test("Replace one replaces only the chosen match")
    func replaceOne() throws {
        let segments = fixture()
        let engine = try FindReplaceEngine(query: FindQuery(text: "the", wholeWord: true))
        let matches = engine.matches(in: segments)
        let second = matches[1]
        let set = engine.replace(second, in: segments, replacement: "THE")
        let after = set.applied(to: segments)
        #expect(after[0].text == "the cat sat on THE mat")
        #expect(set.count == 1)
        // Stale match (text no longer matches at that range) is a no-op.
        var edited = segments
        edited[0].text = "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"
        #expect(engine.replace(second, in: edited, replacement: "Q").isEmpty)
    }

    @Test("FR-AC-07: a match spanning words merges them so click-to-seek still works")
    func multiWordMatch() throws {
        let segments = fixture()
        let engine = try FindReplaceEngine(query: FindQuery(text: "sat on"))
        let after = engine.replaceAll(in: segments, replacement: "stood").applied(to: segments)
        #expect(after[0].words.map(\.text) == ["the", "cat", "stood", "the", "mat"])
        #expect(after[0].words[2].start == 1.5 && after[0].words[2].end == 2.5)
    }

    @Test("FR-AC-08: capture groups expand in regex mode only")
    func captureGroups() throws {
        let segments = [Segment(start: 0, end: 1, text: "john smith")]
        let regex = try FindReplaceEngine(query: FindQuery(text: "(\\w+) (\\w+)", isRegex: true))
        #expect(regex.replaceAll(in: segments, replacement: "$2, $1").applied(to: segments)[0].text == "smith, john")
        let literal = try FindReplaceEngine(query: FindQuery(text: "john"))
        #expect(literal.replaceAll(in: segments, replacement: "$1").applied(to: segments)[0].text == "$1 smith")
    }

    @Test("Replacing inside translation tracks only when enabled")
    func translations() throws {
        let segments = fixture()
        let on = try FindReplaceEngine(query: FindQuery(text: "cat", scope: .all, includeTranslations: true))
        let after = on.replaceAll(in: segments, replacement: "pooch").applied(to: segments)
        #expect(after[4].translations[0].text == "pooch ආයුබෝවන්")
        let off = try FindReplaceEngine(query: FindQuery(text: "cat"))
        #expect(off.replaceAll(in: segments, replacement: "pooch").applied(to: segments)[4].translations[0].text == "cat ආයුබෝවන්")
    }

    @Test("FR-AC-16: Sinhala find on NFC text, decomposed query matches precomposed text")
    func sinhalaFind() throws {
        let segments = [Segment(start: 0, end: 1, text: "කොහොමද")]
        let engine = try FindReplaceEngine(query: FindQuery(text: "ක\u{0DD9}\u{0DCF}"))
        #expect(engine.matches(in: segments).count == 1)
        let whole = try FindReplaceEngine(query: FindQuery(text: "කො", wholeWord: true))
        #expect(whole.matches(in: segments).isEmpty)
    }

    @Test("NFR: find over 10 000 segments and replace all stay fast")
    func performance() throws {
        let segments = (0..<10_000).map { Segment(start: Double($0), end: Double($0) + 1, text: "segment \($0) has a cat in it") }
        let engine = try FindReplaceEngine(query: FindQuery(text: "cat"))
        let started = Date()
        #expect(engine.matches(in: segments).count == 10_000)
        #expect(engine.replaceAll(in: segments, replacement: "dog").count == 10_000)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

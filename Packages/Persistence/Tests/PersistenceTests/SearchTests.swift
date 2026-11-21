import AppCore
import Foundation
import Testing

@testable import Persistence

@Suite("Full-text search")
struct SearchTests {
    private func seeded() async throws -> (SQLiteTranscriptRepository, TranscriptID) {
        let repo = try makeDB().transcripts
        let t = makeTranscript("Mixed")
        try await repo.save(t)
        try await repo.upsertSegments(
            [
                makeSegment("Welcome to the Café meeting", start: 1),
                makeSegment("කොළඹ නගරයේ අද හවස වැස්ස ඇතිවේ", start: 5),
                makeSegment("ශ්‍රී ලංකාව සුන්දර රටකි", start: 9),
                makeSegment("[BLANK_AUDIO] hidden words", start: 12, ignored: true),
                makeSegment("mixed සිංහල and English sentence", start: 15),
            ], for: t.id)
        return (repo, t.id)
    }

    @Test func englishWordsPrefixAndDiacritics() async throws {
        let (repo, id) = try await seeded()
        let hits = try await repo.search("meet", limit: 10)
        #expect(hits.count == 1)
        #expect(hits.first?.transcriptID == id)
        #expect(hits.first?.time == 1)
        #expect(hits.first?.snippet.contains("meeting") == true)
        #expect(try await repo.search("cafe", limit: 10).count == 1)
        #expect(try await repo.search("welcome café", limit: 10).count == 1)
        #expect(try await repo.search("nothing here", limit: 10).isEmpty)
        #expect(try await repo.search("   ", limit: 10).isEmpty)
        #expect(try await repo.search("meeting", limit: 0).isEmpty)
    }

    @Test func sinhalaWholeWordsAreSearchable() async throws {
        let (repo, _) = try await seeded()
        let colombo = try await repo.search("කොළඹ", limit: 10)
        #expect(colombo.count == 1)
        #expect(colombo.first?.time == 5)
        // Word containing ZWJ (conjunct) stays a single token.
        let sri = try await repo.search("ශ්‍රී", limit: 10)
        #expect(sri.count == 1)
        #expect(sri.first?.time == 9)
        // Another word of the same sentence, and a prefix of a longer word.
        #expect(try await repo.search("වැස්ස", limit: 10).count == 1)
        #expect(try await repo.search("සුන්", limit: 10).count == 1)
        // Mixed-script sentence is found by either script.
        #expect(try await repo.search("සිංහල", limit: 10).count == 1)
        #expect(try await repo.search("english", limit: 10).count == 1)
        // A different Sinhala word must not match.
        #expect(try await repo.search("මහනුවර", limit: 10).isEmpty)
    }

    @Test func sinhalaVowelSignsDoNotSplitTokens() async throws {
        // Without the Sinhala token characters, "කො" + vowel signs would split and a bare consonant would match.
        let (repo, _) = try await seeded()
        #expect(try await repo.search("ක", limit: 10).isEmpty == false)  // prefix of කොළඹ
        #expect(try await repo.search("ළ", limit: 10).isEmpty)  // mid-word consonant is not a token on its own
    }

    @Test func ignoredSegmentsAreNotSearchableAndEditsReindex() async throws {
        let (repo, id) = try await seeded()
        #expect(try await repo.search("hidden", limit: 10).isEmpty)
        var segments = try await repo.segments(for: id)
        let index = try #require(segments.firstIndex { $0.text.contains("Welcome") })
        segments[index].text = "Replaced phrase zebra"
        try await repo.upsertSegments([segments[index]], for: id)
        #expect(try await repo.search("zebra", limit: 10).count == 1)
        #expect(try await repo.search("welcome", limit: 10).isEmpty)
        segments[0].isIgnored = false
        let hiddenIndex = try #require(segments.firstIndex { $0.text.contains("hidden") })
        segments[hiddenIndex].isIgnored = false
        try await repo.upsertSegments([segments[hiddenIndex]], for: id)
        #expect(try await repo.search("hidden", limit: 10).count == 1)
    }

    @Test func queryWithFTSSyntaxCharactersDoesNotThrow() async throws {
        let (repo, _) = try await seeded()
        for q in ["\"", "meeting AND", "NEAR(", "a\"b", "*", "(((", "col:on", "-minus"] {
            _ = try await repo.search(q, limit: 5)
        }
    }

    @Test func limitIsHonoured() async throws {
        let repo = try makeDB().transcripts
        let t = makeTranscript()
        try await repo.save(t)
        try await repo.upsertSegments((0..<20).map { makeSegment("common phrase \($0)", start: Double($0) * 3) }, for: t.id)
        #expect(try await repo.search("common", limit: 7).count == 7)
    }
}

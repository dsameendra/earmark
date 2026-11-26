import AppCore
import Foundation
import GRDB
import Testing

@testable import Persistence

@Suite("Infrastructure")
struct InfrastructureTests {
    @Test func wordBlobRoundTripsLosslessly() throws {
        let words = [
            Word(text: "Hello", start: 0.123456789, end: 0.5, confidence: 0.91),
            Word(text: "ශ්‍රී", start: 0.5, end: 1.0),
            Word(text: "", start: 1, end: 1, confidence: 0),
            Word(text: String(repeating: "é", count: 300), start: 1e6, end: 1e6 + 1),
        ]
        #expect(try WordBlob.decode(WordBlob.encode(words)) == words)
        #expect(try WordBlob.decode(WordBlob.encode([])).isEmpty)
    }

    @Test func wordBlobIsMuchSmallerThanJSON() throws {
        let words = (0..<200).map { Word(text: "word\($0)", start: Double($0), end: Double($0) + 0.4, confidence: 0.9) }
        #expect(WordBlob.encode(words).count < (try jsonEncode(words)).count * 2 / 3)
    }

    @Test func wordBlobRejectsCorruptData() {
        #expect(throws: AppError.self) { try WordBlob.decode(Data([9, 1, 2])) }
        let good = WordBlob.encode([Word(text: "abc", start: 0, end: 1)])
        #expect(throws: AppError.self) { try WordBlob.decode(good.prefix(good.count - 3)) }
    }

    @Test func fileDatabaseSurvivesReopenAndMigratesIdempotently() async throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let t = makeTranscript("persisted")
        do {
            let db = try AppDatabase.open(at: url)
            try await db.transcripts.save(t)
            try await db.transcripts.upsertSegments([makeSegment("durable text")], for: t.id)
        }
        let reopened = try AppDatabase.open(at: url)
        #expect(try await reopened.transcripts.transcript(t.id)?.title == "persisted")
        #expect(try await reopened.transcripts.search("durable", limit: 5).count == 1)
        #expect(AppDatabase.migrationIdentifiers == ["v1-initial", "v2-segment-manual-ignore", "v3-segment-user-edited", "v4-workspace"])
        // No backup is taken when nothing is pending.
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathExtension("premigration.bak").path))
    }

    @Test func databaseUsesWAL() throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        _ = try AppDatabase.open(at: url)
        let queue = try DatabaseQueue(path: url.path)
        let mode = try queue.read { try String.fetchOne($0, sql: "PRAGMA journal_mode") }
        #expect(mode == "wal")
    }

    @Test func pendingMigrationKeepsDataAndWritesBackup() async throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let t = makeTranscript("before")
        do {
            let db = try AppDatabase.open(at: url)
            try await db.transcripts.save(t)
        }
        var next = Schema.migrator()
        next.registerMigration("v2-test") { db in try db.execute(sql: "ALTER TABLE transcript ADD COLUMN extra TEXT") }
        let db = try AppDatabase.open(at: url, migrator: next)
        #expect(try await db.transcripts.transcript(t.id)?.title == "before")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("premigration.bak").path))
        let backup = try AppDatabase.open(at: url.appendingPathExtension("premigration.bak"))
        #expect(try await backup.transcripts.transcript(t.id)?.title == "before")
    }

    @Test func manualIgnoreMigrationKeepsExistingSegments() async throws {  // SCR-010, IGN-AC-05
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let t = makeTranscript("legacy")
        do {
            let db = try AppDatabase.open(at: url)
            try await db.transcripts.save(t)
            try await db.transcripts.upsertSegments([makeSegment("old row", ignored: true)], for: t.id)
        }
        // Rewind the file to the v1 shape.
        let raw = try DatabaseQueue(path: url.path)
        try await raw.write { db in
            try db.execute(sql: "ALTER TABLE segment DROP COLUMN ignoreFlagIsManual")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2-segment-manual-ignore'")
        }
        let upgraded = try AppDatabase.open(at: url)
        let rows = try await upgraded.transcripts.segments(for: t.id)
        #expect(rows.count == 1 && rows[0].isIgnored && !rows[0].ignoreFlagIsManual)
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("premigration.bak").path))
    }

    @Test func failedMigrationThrowsAndLeavesDataIntact() async throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let t = makeTranscript("safe")
        do { try await AppDatabase.open(at: url).transcripts.save(t) }
        var broken = Schema.migrator()
        broken.registerMigration("v2-broken") { db in try db.execute(sql: "THIS IS NOT SQL") }
        #expect(throws: AppError.self) { try AppDatabase.open(at: url, migrator: broken) }
        let ok = try AppDatabase.open(at: url)
        #expect(try await ok.transcripts.transcript(t.id)?.title == "safe")
    }

    @Test func committedSegmentsSurviveWithoutGracefulClose() async throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let t = makeTranscript()
        let db = try AppDatabase.open(at: url)
        try await db.transcripts.save(t)
        for i in 0..<5 {
            try await db.transcripts.upsertSegments([makeSegment("chunk \(i)", start: Double(i) * 2)], for: t.id)
        }
        // A second connection (as after a crash and relaunch) sees all committed segments while the first is still open.
        let other = try AppDatabase.open(at: url)
        #expect(try await other.transcripts.segments(for: t.id).count == 5)
    }

    @Test func seedDefaultIgnoreRules() async throws {
        let repo = try makeDB().rules
        #expect(try await repo.ignoreRules().isEmpty)  // never auto-inserted
        let inserted = try await DefaultIgnoreRules.seed(into: repo)
        #expect(inserted == 32)
        let rules = try await repo.ignoreRules()
        let markers = rules.filter { !$0.isHallucinationRule }
        #expect(markers.count == 30)
        #expect(markers.allSatisfy { $0.isEnabled && $0.match == .exact && $0.scope == .wholeSegment })
        #expect(markers.map(\.pattern).contains("[ BLANK_AUDIO ]"))
        #expect(markers.map(\.pattern).contains("♪♪"))
        let hallucinations = rules.filter(\.isHallucinationRule)
        #expect(hallucinations.count == 2)
        #expect(hallucinations.allSatisfy { !$0.isEnabled })

        // Restore defaults: idempotent, keeps user rules, re-adds removed defaults.
        let custom = IgnoreRule(pattern: "my rule")
        try await repo.saveIgnoreRule(custom)
        let removed = try #require(markers.first)
        try await repo.removeIgnoreRule(removed.id)
        #expect(try await DefaultIgnoreRules.seed(into: repo) == 1)
        let after = try await repo.ignoreRules()
        #expect(after.count == 33)
        #expect(after.contains(custom))
        #expect(try await DefaultIgnoreRules.seed(into: repo) == 0)
    }

    @Test func defaultsHaveUniquePatterns() {
        let all = DefaultIgnoreRules.markerPatterns + DefaultIgnoreRules.hallucinationPatterns
        #expect(Set(all).count == all.count)
    }
}

@Suite("Performance", .serialized)
struct PerformanceTests {
    @Test func listOf5000TranscriptsUnder500ms() async throws {
        let url = tempDBURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let db = try AppDatabase.open(at: url)
        let repo = db.transcripts
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let speakers = [Speaker(name: "Ann", colorHex: "#FF0000"), Speaker(name: "Bob", colorHex: "#00FF00")]
        for chunk in 0..<50 {
            for i in 0..<100 {
                let n = chunk * 100 + i
                var t = makeTranscript(
                    "Transcript \(n)", source: TranscriptSource.allCases[n % 4], duration: Double(n % 3600),
                    languages: n % 5 == 0 ? ["en", "si"] : ["en"], tags: ["tag\(n % 10)"], created: base + Double(n) * 60)
                t.speakers = speakers
                try await repo.save(t)
            }
        }
        // Warm-up so the pool and statement cache are primed, then measure the median of several runs.
        _ = try await repo.list(LibraryQuery())
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            let rows = try await repo.list(LibraryQuery())
            let elapsed = ContinuousClock.now - start
            #expect(rows.count == 5000)
            timings.append(Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15)
        }
        timings.sort()
        let median = timings[timings.count / 2]
        print("PERF list(5000 transcripts) median=\(median) ms, all=\(timings) ms")
        #expect(median < 500)
    }

    @Test func searchOver5000TranscriptsIsFast() async throws {
        let db = try makeDB()
        let repo = db.transcripts
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let words = ["alpha", "beta", "gamma", "delta", "කොළඹ", "ශ්‍රී", "ලංකාව", "meeting", "budget", "review"]
        for i in 0..<5000 {
            let t = makeTranscript("T\(i)", created: base + Double(i))
            try await repo.save(t)
            let segs = (0..<3).map { s in
                makeSegment("\(words[(i + s) % 10]) \(words[(i * 7 + s) % 10]) item\(i)", start: Double(s) * 3)
            }
            try await repo.upsertSegments(segs, for: t.id)
        }
        let start = ContinuousClock.now
        let hits = try await repo.search("කොළඹ", limit: 50)
        let elapsed = ContinuousClock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("PERF search(5000 transcripts, 15000 segments) = \(ms) ms")
        #expect(hits.count == 50)
        #expect(ms < 200)
    }
}

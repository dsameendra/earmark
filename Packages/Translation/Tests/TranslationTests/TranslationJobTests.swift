import AppCore
import Foundation
import Testing

@testable import EarmarkTranslation

actor MemoryTranscripts: TranscriptRepository {
    var headers: [TranscriptID: Transcript] = [:]
    var stored: [TranscriptID: [Segment]] = [:]
    var upserts = 0

    init(_ transcript: Transcript, segments: [Segment]) {
        headers[transcript.id] = transcript
        stored[transcript.id] = segments
    }

    func list(_ query: LibraryQuery) async throws -> [Transcript] { Array(headers.values) }
    func transcript(_ id: TranscriptID) async throws -> Transcript? { headers[id] }
    func save(_ transcript: Transcript) async throws { headers[transcript.id] = transcript }
    func segments(for id: TranscriptID) async throws -> [Segment] { stored[id] ?? [] }
    func upsertSegments(_ segments: [Segment], for id: TranscriptID) async throws {
        upserts += 1
        var current = stored[id] ?? []
        for segment in segments {
            if let i = current.firstIndex(where: { $0.id == segment.id }) { current[i] = segment } else { current.append(segment) }
        }
        stored[id] = current
    }
    func replaceSegments(_ segments: [Segment], for id: TranscriptID) async throws { stored[id] = segments }
    func search(_ text: String, limit: Int) async throws -> [SearchHit] { [] }
    func softDelete(_ ids: [TranscriptID], at date: Date) async throws {}
    func restore(_ ids: [TranscriptID]) async throws {}
    func purge(_ ids: [TranscriptID]) async throws {}
    func purgeDeleted(before date: Date) async throws -> Int { 0 }
    func bookmarks(for id: TranscriptID) async throws -> [TranscriptBookmark] { [] }
    func save(_ bookmark: TranscriptBookmark) async throws {}
}

struct FixedRouter: TranslationRouter {
    let engine: any TranslationEngine
    func engine(for pair: LanguagePair) async throws -> any TranslationEngine { engine }
}

@Suite("Translation job")
struct TranslationJobTests {
    private func fixture(languages: Set<LanguageCode> = ["en"], count: Int = 5) -> (Transcript, [Segment]) {
        let transcript = Transcript(title: "Talk", source: .file, duration: 10, languages: languages)
        let segments = (0..<count).map { Segment(start: Double($0), end: Double($0) + 1, text: "line \($0)") }
        return (transcript, segments)
    }

    @Test("TRN-AC-04: translations are stored per segment and the original text is untouched")
    func stores() async throws {
        let (transcript, segments) = fixture()
        let repo = MemoryTranscripts(transcript, segments: segments)
        let engine = FakeEngine(id: "apple.translation", pairs: [pair("en", "de")])
        let outcome = try await TranslationJob(transcripts: repo, router: FixedRouter(engine: engine), flushEvery: 2)
            .run(transcriptID: transcript.id, target: "de")
        #expect(outcome.translated == 5 && outcome.skippedMessage == nil)
        let saved = try await repo.segments(for: transcript.id)
        #expect(saved.map(\.text) == segments.map(\.text))
        #expect(saved.allSatisfy { $0.translations.first?.language == "de" && $0.translations.first?.text.hasPrefix("apple.translation:de:") == true })
        #expect(await repo.upserts == 3)  // 2 + 2 + 1: partial results are persisted as they stream (TRN-AC-05)
    }

    @Test("a translation job preserves an existing track in another Chinese writing system")
    func scriptTracksPersistSeparately() async throws {
        let (transcript, initial) = fixture(count: 1)
        var segment = try #require(initial.first)
        segment.translations = [SegmentTranslation(language: "zh-Hans", text: "简体", engine: "old")]
        let repo = MemoryTranscripts(transcript, segments: [segment])
        let engine = FakeEngine(id: "test", pairs: [pair("en", "zh-Hant")])
        _ = try await TranslationJob(transcripts: repo, router: FixedRouter(engine: engine)).run(transcriptID: transcript.id, target: "zh-Hant")
        let saved = try #require(try await repo.segments(for: transcript.id).first)
        #expect(saved.translations.map(\.language) == ["zh-Hans", "zh-Hant"])
        #expect(saved.translations.first?.text == "简体")
    }

    @Test("TRN-AC-06: identical source and target is skipped with a message and changes nothing")
    func sameLanguage() async throws {
        let (transcript, segments) = fixture()
        let repo = MemoryTranscripts(transcript, segments: segments)
        let engine = FakeEngine(id: "apple.translation", pairs: [])
        let outcome = try await TranslationJob(transcripts: repo, router: FixedRouter(engine: engine)).run(transcriptID: transcript.id, target: "en")
        #expect(outcome.translated == 0 && outcome.skippedMessage != nil)
        #expect(try await repo.segments(for: transcript.id).allSatisfy { $0.translations.isEmpty })
    }

    @Test("an unknown source language (mixed transcript without per-segment tags) is skipped")
    func unknownSource() async throws {
        let (transcript, segments) = fixture(languages: ["en", "si"])
        let repo = MemoryTranscripts(transcript, segments: segments)
        let engine = FakeEngine(id: "apple.translation", pairs: [])
        let outcome = try await TranslationJob(transcripts: repo, router: FixedRouter(engine: engine)).run(transcriptID: transcript.id, target: "de")
        #expect(outcome.translated == 0 && outcome.skippedMessage == TranslationFailure.unknownSource.description)
    }

    @Test("mixed transcripts translate each segment from its own language; selection restricts the pass")
    func perSegmentLanguage() async throws {
        let transcript = Transcript(title: "Mixed", source: .file, duration: 4, languages: ["en", "de"])
        let segments = [
            Segment(start: 0, end: 1, text: "Hello", languageCode: "en"), Segment(start: 1, end: 2, text: "Hallo", languageCode: "de"),
            Segment(start: 2, end: 3, text: "Again", languageCode: "en"),
        ]
        let repo = MemoryTranscripts(transcript, segments: segments)
        let engine = FakeEngine(id: "apple.translation", pairs: allPairs(["en", "de", "fr"]))
        let outcome = try await TranslationJob(transcripts: repo, router: FixedRouter(engine: engine))
            .run(transcriptID: transcript.id, target: "fr", only: [segments[0].id, segments[1].id])
        #expect(outcome.translated == 2)
        let saved = try await repo.segments(for: transcript.id)
        #expect(saved[0].translations.count == 1 && saved[1].translations.count == 1 && saved[2].translations.isEmpty)
    }

    @Test("TRN-AC-13: an engine failure keeps earlier translations and rethrows a retryable error")
    func failureKeepsPartial() async throws {
        let (transcript, segments) = fixture(count: 3)
        var first = segments[0]
        first.translations = [SegmentTranslation(language: "de", text: "alt", engine: "apple.translation")]
        let repo = MemoryTranscripts(transcript, segments: [first] + segments.dropFirst())
        let engine = FakeEngine(id: "apple.translation", pairs: [pair("en", "de")], failure: AppError.engineFailure("apple.translation", reason: "x"))
        await #expect(throws: AppError.self) {
            _ = try await TranslationJob(transcripts: repo, router: FixedRouter(engine: engine)).run(transcriptID: transcript.id, target: "de")
        }
        #expect(try await repo.segments(for: transcript.id)[0].translations.first?.text == "alt")
    }
}

@Suite("NLLB dev runtime flag")
struct NLLBDevRuntimeTests {
    @Test("off by default and for a missing interpreter")
    func off() {
        #expect(NLLBDevRuntime.pythonExecutable(environment: [:]) == nil)
        #expect(NLLBDevRuntime.pythonExecutable(environment: [NLLBDevRuntime.environmentKey: "/no/such/python"]) == nil)
        #expect(NLLBDevRuntime.runtime(environment: [:]) == nil)
    }

    @Test("an executable path from the environment or the setting enables it")
    func on() {
        #expect(NLLBDevRuntime.pythonExecutable(environment: [NLLBDevRuntime.environmentKey: "/bin/sh"])?.path == "/bin/sh")
        #expect(NLLBDevRuntime.pythonExecutable(environment: [:], settingValue: "/bin/sh")?.path == "/bin/sh")
    }

    @Test("a missing NLLB engine reports Sinhala as unavailable in this build")
    func message() async {
        let router = DefaultTranslationRouter(apple: FakeEngine(id: "apple.translation", pairs: allPairs(["en", "de"])), nllb: nil)
        await #expect(throws: TranslationFailure.noEngine(pair("en", "si"))) { _ = try await router.engine(for: pair("en", "si")) }
        #expect(TranslationFailure.noEngine(pair("en", "si")).description.contains("Sinhala translation unavailable in this build"))
    }
}

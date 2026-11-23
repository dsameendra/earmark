import AppCore
import Foundation
import Testing

@testable import Persistence

@Suite("Other repositories")
struct OtherRepositoryTests {
    @Test func mediaRepository() async throws {
        let repo = try makeDB().media
        let asset = MediaAsset(
            kind: .video, bookmark: Data([1, 2, 3]), libraryRelativePath: "a/b.mov", duration: 12.5, isOwnedByLibrary: true)
        try await repo.save(asset)
        #expect(try await repo.asset(asset.id) == asset)
        try await repo.softDelete(asset.id)
        #expect(try await repo.asset(asset.id)?.deletedAt != nil)
        #expect(try await repo.asset(MediaAssetID()) == nil)
    }

    @Test func jobRepository() async throws {
        let repo = try makeDB().jobs
        let low = Job(
            kind: .transcribeFile, input: URL(fileURLWithPath: "/tmp/a.wav"), priority: 0, createdAt: Date(timeIntervalSince1970: 1))
        var high = Job(
            kind: .export, settings: JobSettings(languageMode: .multilingual(["en", "si"]), diarize: true), priority: 5,
            createdAt: Date(timeIntervalSince1970: 2))
        high.checkpoint = JobCheckpoint(lastCompletedChunk: 3, mediaTime: 90)
        try await repo.save(low)
        try await repo.save(high)
        #expect(try await repo.allJobs() == [high, low])
        high.state = .running
        high.progress = 0.4
        try await repo.save(high)
        #expect(try await repo.allJobs().first?.state == .running)
        try await repo.remove(high.id)
        #expect(try await repo.allJobs() == [low])
    }

    @Test func jobRepositoryKeepsVoiceProcessing() async throws {
        let repo = try makeDB().jobs
        let job = Job(kind: .transcribeFile, settings: JobSettings(voiceProcessing: .strong), createdAt: Date(timeIntervalSince1970: 3))
        try await repo.save(job)
        #expect(try await repo.allJobs().first?.settings.voiceProcessing == .strong)
    }

    @Test func ruleRepository() async throws {
        let repo = try makeDB().rules
        let a = IgnoreRule(pattern: "[Music]")
        let b = IgnoreRule(pattern: "foo", match: .contains, scope: .inline, isEnabled: false)
        try await repo.saveIgnoreRule(a)
        try await repo.saveIgnoreRule(b)
        #expect(try await repo.ignoreRules() == [a, b])
        try await repo.removeIgnoreRule(a.id)
        #expect(try await repo.ignoreRules() == [b])

        let c = IgnoreRule(pattern: "c", isHallucinationRule: true)
        try await repo.replaceAllIgnoreRules([b, c])
        #expect(try await repo.ignoreRules() == [b, c])
        // Replacing undeletes a previously removed id.
        try await repo.replaceAllIgnoreRules([a])
        #expect(try await repo.ignoreRules() == [a])

        let r = ReplacementRule(find: "teh", replacement: "the", matchCase: true, wholeWord: true)
        try await repo.saveReplacementRule(r)
        #expect(try await repo.replacementRules() == [r])
        try await repo.removeReplacementRule(r.id)
        #expect(try await repo.replacementRules().isEmpty)
    }

    @Test func presetRepository() async throws {
        let repo = try makeDB().presets
        let caption = CaptionPreset(name: "Big", fontSize: 40, isBuiltIn: true)
        let export = ExportPreset(name: "SRT", options: ExportOptions(format: .srt))
        try await repo.save(caption)
        try await repo.save(export)
        #expect(try await repo.captionPresets() == [caption])
        #expect(try await repo.exportPresets() == [export])
        try await repo.softDeletePreset(caption.id)
        try await repo.softDeletePreset(export.id)
        #expect(try await repo.captionPresets().isEmpty)
        #expect(try await repo.exportPresets().isEmpty)
    }

    @Test func voiceProfileRepository() async throws {
        let repo = try makeDB().voiceProfiles
        let p = VoiceProfile(name: "Ann", embedding: SpeakerEmbedding(vector: [0.1, 0.2, 0.3]))
        try await repo.save(p)
        #expect(try await repo.profiles() == [p])
        try await repo.softDelete(p.id)
        #expect(try await repo.profiles().isEmpty)
    }

    @Test func meetingRepository() async throws {
        let repo = try makeDB().meetings
        let older = Meeting(app: .zoom, startedAt: Date(timeIntervalSince1970: 100))
        let newer = Meeting(app: .teams, startedAt: Date(timeIntervalSince1970: 200), transcriptID: TranscriptID())
        try await repo.save(older)
        try await repo.save(newer)
        #expect(try await repo.meetings() == [newer, older])
        try await repo.softDelete(newer.id)
        #expect(try await repo.meetings() == [older])
    }

    @Test func dictationHistory() async throws {
        let repo = try makeDB().dictationHistory
        let e1 = DictationEntry(text: "send the report", createdAt: Date(timeIntervalSince1970: 1))
        let e2 = DictationEntry(text: "කොළඹ යමු", language: "si", createdAt: Date(timeIntervalSince1970: 2))
        let e3 = DictationEntry(text: "100% done", createdAt: Date(timeIntervalSince1970: 3))
        for e in [e1, e2, e3] { try await repo.save(e) }
        #expect(try await repo.recent(limit: 10, matching: nil) == [e3, e2, e1])
        #expect(try await repo.recent(limit: 2, matching: nil) == [e3, e2])
        #expect(try await repo.recent(limit: 10, matching: "REPORT") == [e1])
        #expect(try await repo.recent(limit: 10, matching: "කොළඹ") == [e2])
        #expect(try await repo.recent(limit: 10, matching: "%") == [e3])
        try await repo.clear()
        #expect(try await repo.recent(limit: 10, matching: nil).isEmpty)
    }

    @Test func settingsStore() async throws {
        let store = try makeDB().makeSettingsStore()
        struct Prefs: Codable, Sendable, Equatable {
            var retention: Int
            var name: String
        }
        #expect(await store.value(for: "missing", as: Int.self) == nil)
        await store.set(30, for: "retentionDays")
        await store.set(Prefs(retention: 7, name: "x"), for: "prefs")
        await store.set(true, for: "flag")
        await store.set("ශ්‍රී", for: "text")
        #expect(await store.value(for: "retentionDays", as: Int.self) == 30)
        #expect(await store.value(for: "prefs", as: Prefs.self) == Prefs(retention: 7, name: "x"))
        #expect(await store.value(for: "flag", as: Bool.self) == true)
        #expect(await store.value(for: "text", as: String.self) == "ශ්‍රී")
        await store.set(45, for: "retentionDays")
        #expect(await store.value(for: "retentionDays", as: Int.self) == 45)
    }

    @Test func settingsChangesStream() async throws {
        let store = try makeDB().makeSettingsStore()
        var iterator = store.changes(for: "k").makeAsyncIterator()
        await store.set(1, for: "other")
        await store.set(1, for: "k")
        await iterator.next()
        #expect(await store.value(for: "k", as: Int.self) == 1)
    }
}

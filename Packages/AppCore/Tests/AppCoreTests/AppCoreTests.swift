import AppCore
import AppCoreTesting
import Foundation
import Testing

@Suite struct ContractSmokeTests {
    @Test func languageDefaultIsEnglish() {
        #expect(LanguageMode.default == .single(.english))
        #expect(LanguageCode("en-US").primary == .english)
    }

    @Test func tierBoundaries() {
        let gb: UInt64 = 1_073_741_824
        #expect(HardwareProfile.tier(forMemoryBytes: 8 * gb) == .tier8)
        #expect(HardwareProfile.tier(forMemoryBytes: 18 * gb) == .tier16)  // dev machine
        #expect(HardwareProfile.tier(forMemoryBytes: 36 * gb) == .tier32Plus)
    }

    @Test func capabilityTableBothDirections() {
        let apple = ModelDescriptor(
            id: "apple.speech", displayName: "Apple", kind: .asr, runtime: .appleAsset, languages: ["en", "fr"], sizeBytes: 0,
            license: LicenseInfo(spdx: "Apple"))
        let qwen = ModelDescriptor(
            id: "qwen-si", displayName: "Qwen Sinhala", kind: .asr, runtime: .mlx, languages: ["si", "en"], sizeBytes: 1,
            license: LicenseInfo(spdx: "CC-BY-SA-4.0"), isExperimental: true)
        let t = LanguageCapabilityTable(models: [apple, qwen])
        #expect(t.languages() == ["en", "fr", "si"])
        #expect(t.languages(forModel: "qwen-si") == ["si", "en"])
        #expect(t.models(coveringAll: ["si"]).map(\.id) == ["qwen-si"])
        #expect(t.models(coveringAll: ["en"]).count == 2)
    }

    @Test func reconcilerMapsByMaxOverlap() {
        let live = [
            SpeakerTurn(range: .init(start: 0, end: 10), slot: 0, isProvisional: true),
            SpeakerTurn(range: .init(start: 10, end: 20), slot: 1, isProvisional: true),
        ]
        let offline = [SpeakerTurn(range: .init(start: 0, end: 9), slot: 5), SpeakerTurn(range: .init(start: 9, end: 20), slot: 7)]
        #expect(SpeakerReconciler.mapLiveSlots(live: live, offline: offline) == [0: 5, 1: 7])
    }

    @Test func embeddingDistance() {
        let a = SpeakerEmbedding(vector: [1, 0])
        let b = SpeakerEmbedding(vector: [0, 1])
        #expect(a.distance(to: a) < 1e-6)
        #expect(abs(a.distance(to: b) - 1) < 1e-6)
    }

    @Test func meetingDefaultsToAskFirst() {
        #expect(MeetingPolicy(app: .zoom).behavior == .askFirst)
        #expect(MeetingPolicy(app: .teams).behavior == .askFirst)
    }

    @Test func segmentCodableRoundTrip() throws {
        let s = Segment(start: 0, end: 1, text: "hi", languageCode: .sinhala, words: [Word(text: "hi", start: 0, end: 1)])
        let d = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(Segment.self, from: d) == s)
    }

    @Test func mockEngineEmitsAndFails() async throws {
        let seg = Segment(start: 0, end: 1, text: "x")
        let ok = MockTranscriptionEngine(events: [.final(seg)])
        var n = 0
        for try await e in ok.transcribe(file: URL(fileURLWithPath: "/x"), options: .init(useCase: .file)) { if case .final = e { n += 1 } }
        #expect(n == 1)
        let bad = MockTranscriptionEngine(failure: .deviceUnavailable)
        await #expect(throws: AppError.self) {
            for try await _ in bad.transcribe(file: URL(fileURLWithPath: "/x"), options: .init(useCase: .file)) {}
        }
    }

    @Test func mockModelManagerDownloadsWithProgress() async throws {
        let m = MockModelManager()
        var fractions: [Double] = []
        for try await e in m.ensureAvailable("m1") { if case .progress(let f, _, _) = e { fractions.append(f) } }
        #expect(fractions.last == 1.0)
        #expect(await m.installedModels().contains("m1"))
    }
}

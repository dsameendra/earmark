import AppCore
import AppCoreTesting
@testable import FeatureEditor
import FeatureMenuBar
import FeatureSettings
import FeatureSupport
import Foundation
import Testing

// LANG-AC-06/07/08/10/14, EDIT-AC-09, TRN-AC-03/07/08/10, MTG-AC-17.

private struct FakeRetranscriber: SegmentRetranscriptionService {
    var result: Result<String, AppError>
    func retranscribe(segment: Segment, mediaURL: URL, language: LanguageCode) async throws -> Segment {
        var updated = segment
        updated.text = try result.get()
        updated.languageCode = language
        updated.languageConfidence = 1
        updated.words = []
        return updated
    }
}

private final class FakeTranslation: TranslationPreparing, @unchecked Sendable {
    var readiness: TranslationReadiness = .ready
    func targets(from source: LanguageCode) async -> [(language: LanguageCode, readiness: TranslationReadiness)] {
        [("de", readiness), ("si", .unavailable(reason: "Sinhala translation unavailable in this build"))]
    }
    func readiness(source: LanguageCode, target: LanguageCode) async -> TranslationReadiness { readiness }
    func prepareApplePack(source: LanguageCode, target: LanguageCode) async -> Bool { true }
}

@Suite("Language certainty") struct LanguageCertaintyTests {
    @Test func onlyMixedTranscriptsAreJudged() {
        var segment = Fixtures.segment("hello", start: 0, language: "en")
        #expect(!LanguageCertainty.isUncertain(segment, in: ["en"]))  // single language: engine-stamped, nothing to doubt
        #expect(LanguageCertainty.isUncertain(segment, in: ["en", "si"]))  // nil confidence in a mixed transcript
        segment.languageConfidence = 0.9
        #expect(!LanguageCertainty.isUncertain(segment, in: ["en", "si"]))
        segment.languageConfidence = 0.3
        #expect(LanguageCertainty.isUncertain(segment, in: ["en", "si"]))  // LANG-AC-06: below the threshold
        segment.languageCode = nil
        #expect(!LanguageCertainty.isUncertain(segment, in: ["en", "si"]))
    }
}

@Suite @MainActor struct EditorLanguageTests {
    private func mixedModel() async -> (TranscriptEditorModel, FakeTranscriptRepository, Segment) {
        var transcript = Fixtures.transcript()
        transcript.languages = ["en", "si"]
        var uncertain = Fixtures.segment("hello big world", start: 0, language: "si")
        uncertain.languageConfidence = nil
        let sure = Fixtures.segment("this is fine", start: 4, language: "en")
        let (model, repo) = await Fixtures.model(segments: [uncertain, sure], transcript: transcript)
        return (model, repo, uncertain)
    }

    @Test func uncertainSegmentsAreFlaggedAndCounted() async {  // LANG-AC-06
        let (model, _, uncertain) = await mixedModel()
        #expect(model.isLanguageUncertain(uncertain))
        #expect(model.uncertainLanguageCount == 2)  // both have no confidence in a mixed transcript
        model.setLanguage("si", for: [uncertain.id])  // the user's choice is certain
        #expect(!model.isLanguageUncertain(model.segment(uncertain.id)!))
        #expect(model.uncertainLanguageCount == 1)
    }

    @Test func retranscribeReplacesTextKeepsRevisionAndUndoes() async throws {  // LANG-AC-08, EDIT-AC-09
        let (model, _, uncertain) = await mixedModel()
        model.retranscriber = FakeRetranscriber(result: .success("ආයුබෝවන්"))
        model.mediaURL = URL(fileURLWithPath: "/tmp/x.wav")
        #expect(model.canRetranscribe)
        await model.retranscribe(uncertain.id, as: "si")
        let after = try #require(model.segment(uncertain.id))
        #expect(after.text == "ආයුබෝවන්" && after.languageCode == "si" && after.languageConfidence == 1)
        #expect(after.start == uncertain.start && after.end == uncertain.end && after.id == uncertain.id)
        let revision = try #require(model.revisions(for: uncertain.id).first)
        #expect(revision.text == "hello big world" && revision.languageCode == "si")
        model.undo()
        #expect(model.segment(uncertain.id)?.text == "hello big world")
    }

    @Test func retranscribeFailureExplainsAndChangesNothing() async {
        let (model, _, uncertain) = await mixedModel()
        model.retranscriber = FakeRetranscriber(result: .failure(.modelNotInstalled("mlx/qwen3-asr-0.6b-sinhala-8bit")))
        model.mediaURL = URL(fileURLWithPath: "/tmp/x.wav")
        await model.retranscribe(uncertain.id, as: "si")
        #expect(model.languageError?.contains("not downloaded") == true)
        #expect(model.segment(uncertain.id)?.text == "hello big world")
        #expect(model.revisions.isEmpty)
    }

    @Test func emptyResultIsNotAppliedAsEmptyText() async {
        let (model, _, uncertain) = await mixedModel()
        model.retranscriber = FakeRetranscriber(result: .success("  "))
        model.mediaURL = URL(fileURLWithPath: "/tmp/x.wav")
        await model.retranscribe(uncertain.id, as: "si")
        #expect(model.segment(uncertain.id)?.text == "hello big world")
        #expect(model.languageError != nil)
    }

    @Test func translationModeShowsTheTrackAndPersistsPerTranscript() async throws {  // TRN-AC-08, TRN-AC-07
        var s = Fixtures.segment("hello", start: 0, language: "en")
        s.translations = [SegmentTranslation(language: "si", text: "ආයුබෝවන්", engine: "nllb")]
        let store = InMemorySettingsStore()
        let (model, _) = await Fixtures.model(segments: [s], settings: store)
        #expect(model.translationDisplay(for: s) == nil)  // original mode
        model.setTranslationMode(.bilingual)
        let shown = try #require(model.translationDisplay(for: s))
        #expect(shown.text == "ආයුබෝවන්" && shown.isLowConfidence && !shown.isStale)
        await model.flush()
        let reopened = TranscriptEditorModel(
            transcriptID: model.transcriptID, repository: FakeTranscriptRepository(transcript: model.transcript!, segments: [s]),
            settings: store, engineFactory: { _ in nil })
        await reopened.load()
        #expect(reopened.translationChoice == TranslationDisplayChoice(mode: .bilingual, target: "si"))
    }

    @Test func editingTheOriginalMarksItsTranslationStale() async throws {  // TRN-AC-10
        var s = Fixtures.segment("hello world", start: 0, language: "en")
        s.translations = [SegmentTranslation(language: "de", text: "Hallo Welt", engine: "apple.translation")]
        let (model, _) = await Fixtures.model(segments: [s])
        model.setTranslationMode(.translated)
        #expect(model.translationDisplay(for: s)?.isStale == false)
        model.editText(s.id, to: "hello there")
        #expect(model.translationDisplay(for: model.segment(s.id)!)?.isStale == true)
        #expect(model.hasStaleTranslations)
    }

    @Test func translateEnqueuesATranslateJobAndFollowsItToCompletion() async throws {  // TRN-AC-05
        var transcript = Fixtures.transcript()
        transcript.languages = ["en"]
        let queue = PlaceholderJobQueue()
        let (model, repo) = await Fixtures.model(segments: [Fixtures.segment("hello", start: 0)], transcript: transcript)
        model.translationService = FakeTranslation()
        model.jobQueue = queue
        #expect(model.canTranslate && model.translationSource == "en")
        await model.translate(to: "de")
        let job = try #require(await queue.jobs().first)
        #expect(job.kind == .translate && job.transcriptID == model.transcriptID && job.settings.translateTo == "de")
        // The queue (T10) saves translations as it goes; simulate its result, then the completion event.
        var translated = Fixtures.segment("hello", start: 0)
        translated.id = model.segments[0].id
        translated.translations = [SegmentTranslation(language: "de", text: "Hallo", engine: "apple.translation")]
        try await repo.upsertSegments([translated], for: model.transcriptID)
        var done = job
        done.state = .completed
        await model.translationJobUpdated(done, target: "de")
        #expect(model.translationChoice.mode == .bilingual && model.translationChoice.target == "de")
        #expect(model.translationDisplay(for: model.segments[0])?.text == "Hallo")
    }

    @Test func aJobThatFinishesInsideEnqueueIsNotMissed() async throws {
        // The real queue starts the job inside `enqueue`; a failing or empty translation can end before any later subscription.
        var transcript = Fixtures.transcript()
        transcript.languages = ["en"]
        let (model, _) = await Fixtures.model(segments: [Fixtures.segment("hello", start: 0)], transcript: transcript)
        model.translationService = FakeTranslation()
        model.jobQueue = InstantlyFailingQueue()
        await model.translate(to: "de")
        #expect(await eventually { model.translationStatus != nil })
        #expect(model.translationStatus == "engine exploded")
        #expect(!model.isTranslating)
    }

    @Test func translateStopsWhenThePairNeedsADownload() async throws {  // TRN-AC-03
        let queue = PlaceholderJobQueue()
        var transcript = Fixtures.transcript()
        transcript.languages = ["en"]
        let (model, _) = await Fixtures.model(segments: [Fixtures.segment("hello", start: 0)], transcript: transcript)
        let service = FakeTranslation()
        service.readiness = .needsModel("nllb/200-distilled-600M")
        model.translationService = service
        model.jobQueue = queue
        await model.translate(to: "de")
        #expect(await queue.jobs().isEmpty)
        #expect(model.translationStatus?.contains("downloaded") == true)
    }

    @Test func translatePanelOffersTargetsWithReadinessAndDownloadsModels() async throws {  // TRN-AC-03
        var transcript = Fixtures.transcript()
        transcript.languages = ["en"]
        let (model, _) = await Fixtures.model(segments: [Fixtures.segment("hello", start: 0)], transcript: transcript)
        let service = FakeTranslation()
        service.readiness = .needsModel("nllb")
        model.translationService = service
        let descriptor = ModelDescriptor(
            id: "nllb", displayName: "NLLB", kind: .translation, runtime: .coreML, languages: ["en", "de"], sizeBytes: 600_000_000,
            license: LicenseInfo(spdx: "CC-BY-NC-4.0", isNonCommercial: true))
        let manager = MockModelManager(descriptors: [descriptor], installed: [])
        model.models = manager
        let panel = TranslatePanelModel(editor: model)
        await panel.load()
        #expect(panel.targets.map(\.language) == ["de", "si"])
        #expect(panel.selected == "de")
        #expect(panel.pendingModel?.id == "nllb")
        service.readiness = .ready
        await panel.downloadModel()
        #expect(await manager.state(of: "nllb") != .notInstalled)
        #expect(panel.selectedReadiness == .ready)
    }
}

@Suite @MainActor struct LanguageAvailabilityTests {
    private func model(catalog: [ModelDescriptor], installed: Set<ModelID> = []) async -> LanguageSelectionModel {
        let store = InMemorySettingsStore()
        let mock = MockModelManager(descriptors: catalog, installed: installed)
        let manager = ModelManagerModel(manager: mock, hardware: PlaceholderHardware(), store: store, freeDiskBytes: { Int64.max })
        let languages = LanguageSelectionModel(manager: manager, store: store)
        await languages.load()
        return languages
    }

    private func asr(_ id: String, _ languages: Set<LanguageCode>, tier: HardwareTier = .tier8, experimental: Bool = false) -> ModelDescriptor {
        ModelDescriptor(
            id: ModelID(id), displayName: id, kind: .asr, runtime: .mlx, languages: languages, sizeBytes: 1_100_000_000,
            license: LicenseInfo(spdx: "CC-BY-SA-4.0"), minTier: tier, isExperimental: experimental)
    }

    @Test func installedLanguageIsAvailable() async {
        let m = await model(catalog: [asr("w", ["en"])], installed: ["w"])
        #expect(m.availability(for: "en") == .available)
    }

    @Test func notDownloadedLanguageOffersDownloadWithSizeAndLicence() async {  // LANG-AC-10
        let qwen = asr("q", ["si"], experimental: true)
        let m = await model(catalog: [qwen])
        #expect(m.availability(for: "si") == .needsDownload(qwen))
    }

    @Test func languageNoModelCoversIsUnavailableWithAReason() async {  // LANG-AC-14
        let m = await model(catalog: [asr("w", ["en"])])
        guard case .unavailable(let reason) = m.availability(for: "ta") else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("No speech model"))
    }

    @Test func languageNeedingMoreMemoryIsUnavailableWithAReason() async {  // LANG-AC-14
        let m = await model(catalog: [asr("big", ["fr"], tier: .tier32Plus)])
        guard case .unavailable(let reason) = m.availability(for: "fr") else {
            Issue.record("expected unavailable")
            return
        }
        #expect(reason.contains("memory"))
    }
}

@Suite @MainActor struct MenuBarAutoRecordTests {
    @Test func toggleWritesEveryAppsPolicyAndReadsBack() async {  // MTG-AC-17
        let store = InMemorySettingsStore()
        var services = AppServices.preview()
        services.settings = store
        let menu = MenuBarModel(services: services)
        await menu.setAutoRecord(true)
        for app in MeetingApp.allCases {
            let policy = await store.value(for: SettingsKey.meetingPolicy(app.rawValue), as: MeetingPolicy.self)
            #expect(policy?.behavior == .autoTranscribeAndRecord)
        }
        await menu.setAutoRecord(false)
        for app in MeetingApp.allCases {
            let policy = await store.value(for: SettingsKey.meetingPolicy(app.rawValue), as: MeetingPolicy.self)
            #expect(policy?.behavior == .askFirst)
        }
    }

    @Test func otherBehavioursSurviveTurningItOff() async {
        let store = InMemorySettingsStore()
        await store.set(MeetingPolicy(app: .zoom, behavior: .autoTranscribe), for: SettingsKey.meetingPolicy("zoom"))
        var services = AppServices.preview()
        services.settings = store
        let menu = MenuBarModel(services: services)
        await menu.setAutoRecord(false)
        #expect(await store.value(for: SettingsKey.meetingPolicy("zoom"), as: MeetingPolicy.self)?.behavior == .autoTranscribe)
    }
}

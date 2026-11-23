import AppCore
import AppCoreTesting
import Export
import FeatureLibrary
import FeatureSupport
import Foundation
import Testing

@testable import FeatureEditor

/// SCR-013: the editor's Re-transcribe control, transcript language, user-edit tracking, speaker names in exports, and Library.
@Suite("Editor re-transcribe") @MainActor
struct RerunEditorTests {
    private func editor(queue: PlaceholderJobQueue = PlaceholderJobQueue()) async -> (TranscriptEditorModel, FakeTranscriptRepository) {
        let (model, repo) = await Fixtures.model()
        model.jobQueue = queue
        model.mediaURL = URL(fileURLWithPath: "/tmp/talk.m4a")
        return (model, repo)
    }

    @Test func wholeTranscriptRequestBuildsAMergeJobWithTheChosenLanguagesModelAndSpeakers() async throws {
        let (model, _) = await editor()
        let request = RerunRequest(
            scope: .wholeTranscript, languageMode: .multilingual([.english, .sinhala]), modelID: "whisper", identifySpeakers: true,
            speakerCount: .exact(3))
        let job = try #require(model.rerunJob(for: request))
        #expect(job.kind == .transcribeFile && job.transcriptID == model.transcriptID && job.input == model.mediaURL)
        #expect(job.settings.languageMode == .multilingual([.english, .sinhala]) && job.settings.modelID == "whisper")
        #expect(job.settings.diarize && job.settings.diarization == ["exact": 3])
        #expect(job.settings.rerun == RerunOptions(ranges: [], replaceEverything: false, speakersOnly: false))
    }

    @Test func voiceProcessingTravelsInTheRerunJob() async throws {
        let (model, _) = await editor()
        let plain = try #require(model.rerunJob(for: RerunRequest()))
        #expect(plain.settings.voiceProcessing == .off)
        let cleaned = try #require(model.rerunJob(for: RerunRequest(voiceProcessing: .standard)))
        #expect(cleaned.settings.voiceProcessing == .standard)
        let panel = RerunPanelModel(editor: model)
        panel.voiceProcessing = .light
        #expect(panel.request.voiceProcessing == .light)
    }

    @Test func selectionScopeSendsMergedTimeRanges() async throws {
        let (model, _) = await editor()
        model.selection = [model.segments[0].id, model.segments[2].id]
        let request = RerunRequest(scope: .selection, languageMode: .single(.english))
        let job = try #require(model.rerunJob(for: request))
        #expect(job.settings.rerun?.ranges == [model.segments[0].range, model.segments[2].range])
        model.selection = []
        #expect(model.rerunJob(for: request) == nil, "an empty selection cannot run")
    }

    @Test func replaceEverythingAndSpeakersOnlyAreExplicit() async throws {
        let (model, _) = await editor()
        let replace = try #require(model.rerunJob(for: RerunRequest(replaceEverything: true)))
        #expect(replace.settings.rerun?.replaceEverything == true)
        let speakers = try #require(
            model.rerunJob(for: RerunRequest(transcribe: false, identifySpeakers: true, speakerCount: .exact(2), replaceEverything: true)))
        #expect(speakers.settings.rerun?.speakersOnly == true && speakers.settings.rerun?.replaceEverything == false)
        #expect(model.rerunJob(for: RerunRequest(transcribe: false, identifySpeakers: false)) == nil)
    }

    @Test func rerunLocksTheEditorAndCompletionReloadsTheMergedResult() async throws {
        let queue = PlaceholderJobQueue()
        let (model, repo) = await editor(queue: queue)
        await model.rerun(RerunRequest(languageMode: .single(.english)))
        let job = try #require(model.rerunJob)
        #expect(model.isReadOnly && model.isRerunning)
        // The job writes its merged result, then finishes.
        var merged = model.segments
        merged[0].text = "merged by the job"
        try await repo.replaceSegments(merged, for: model.transcriptID)
        var done = job
        done.state = .completed
        done.warning = "Speakers could not be identified."
        await model.rerunJobUpdated(done)
        #expect(!model.isReadOnly && !model.isRerunning)
        #expect(model.segments[0].text == "merged by the job")
        #expect(model.rerunStatus == "Speakers could not be identified.")
        #expect(!model.canUndo, "stale undo steps are dropped")
    }

    @Test func aFailedRerunHandsTheEditorBack() async throws {
        let (model, _) = await editor()
        await model.rerun(RerunRequest())
        var failed = try #require(model.rerunJob)
        failed.state = .failed
        failed.failureReason = "boom"
        await model.rerunJobUpdated(failed)
        #expect(!model.isReadOnly && model.rerunStatus == "boom")
    }

    @Test func textSpeakerAndLanguageEditsMarkSegmentsAsUserEdited() async {
        let (model, _) = await Fixtures.model()
        let ids = model.segments.map(\.id)
        model.editText(ids[0], to: "hello brave world")
        model.setSpeaker(Fixtures.alice.id, for: [ids[1]])  // Bob -> Alice
        model.setLanguage("fr", for: [ids[2]])
        #expect(model.segments.map(\.isUserEdited) == [true, true, true])
        model.undo()
        #expect(model.segments[2].isUserEdited == false)
    }

    @Test func settingTheTranscriptLanguageRelabelsSegmentsAndSticks() async {
        let (model, repo) = await Fixtures.model()
        model.setTranscriptLanguages([.sinhala])
        #expect(model.transcript?.languages == [.sinhala])
        #expect(model.segments.allSatisfy { $0.languageCode == .sinhala })
        await model.flush()
        #expect(await repo.headers[model.transcriptID]?.languages == [.sinhala], "segment languages are not added back")
        model.setTranscriptLanguages([.english, "fr"])
        #expect(model.transcript?.languages == [.english, "fr"])
    }

    @Test func speakerRenamesReachTheTranscriptAndTheExportDocument() async {
        let (model, repo) = await Fixtures.model()
        model.renameSpeaker(Fixtures.alice.id, to: "Dr. Alice")
        await model.flush()
        #expect(await repo.headers[model.transcriptID]?.speakers.first { $0.id == Fixtures.alice.id }?.name == "Dr. Alice")
        let document = TranscriptDocument(transcript: model.transcript ?? Fixtures.transcript(), segments: model.segments)
        #expect(document.transcript.speakers.map(\.name).contains("Dr. Alice"))
        let first = model.segments[0]
        #expect(document.transcript.speakers.first { $0.id == first.speakerID }?.name == "Dr. Alice")
    }

    @Test func panelModelDefaultsFromTheTranscriptAndGreysOutModels() async {
        let (model, _) = await editor()
        model.setTranscriptLanguages([.sinhala])
        var services = AppServices.preview()
        services.models = MockModelManager(
            descriptors: [
                ModelDescriptor(
                    id: "whisper", displayName: "Whisper", kind: .asr, runtime: .coreML, languages: [.english], sizeBytes: 1,
                    license: LicenseInfo(spdx: "MIT"), capabilities: ModelCapabilities(file: true)),
                ModelDescriptor(
                    id: "qwen", displayName: "Qwen", kind: .asr, runtime: .mlx, languages: [.sinhala], sizeBytes: 1,
                    license: LicenseInfo(spdx: "MIT"), capabilities: ModelCapabilities(file: true)),
            ], installed: ["qwen"])
        model.models = services.models
        let panel = RerunPanelModel(editor: model)
        await panel.prepare()
        #expect(panel.kind == .single && panel.singleLanguage == .sinhala)
        #expect(panel.modelRows.first { $0.id == "whisper" }?.disabledReason?.contains("No si support") == true)
        panel.selectModel("whisper")
        panel.setSingleLanguage(.english)
        panel.setSingleLanguage(.sinhala)
        #expect(panel.modelID == nil, "a model that stops fitting falls back to Automatic")
        panel.replaceEverything = true
        #expect(panel.needsReplaceConfirmation && panel.request.replaceEverything)
        panel.transcribe = false
        #expect(!panel.needsReplaceConfirmation && !panel.request.replaceEverything)
    }
}

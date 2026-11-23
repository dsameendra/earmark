import AppCore
import AppCoreTesting
import FeatureSettings
import FeatureSupport
import Foundation
import Testing

// SCR-011 wave 2: Settings > Models recommendations, ordering, failed-state controls, disk refusal and consent hand-off.

private func descriptor(_ id: String, kind: ModelKind = .asr, caps: ModelCapabilities, size: Int64 = 1_000_000) -> ModelDescriptor {
    ModelDescriptor(
        id: ModelID(id), displayName: id, kind: kind, runtime: .coreML, languages: ["en"], sizeBytes: size,
        license: LicenseInfo(spdx: "MIT"), capabilities: caps)
}

@MainActor private func make(
    free: Int64 = .max, installed: Set<ModelID> = []
) async -> (ModelManagerModel, MockModelManager) {
    let catalog = [
        descriptor("other", caps: ModelCapabilities(file: true)),
        descriptor(
            "best",
            caps: ModelCapabilities(
                live: true, file: true, autoDetectLanguage: true,
                recommendedUse: [RecommendedUse(.file), RecommendedUse(.live), RecommendedUse(.dictation)])),
        descriptor("sd", kind: .diarization, caps: ModelCapabilities(speakerLabels: .offline)),
        descriptor("installed", caps: ModelCapabilities(file: true)),
    ]
    let mock = MockModelManager(descriptors: catalog, installed: installed)
    let model = ModelManagerModel(manager: mock, hardware: PlaceholderHardware(), store: InMemorySettingsStore(), freeDiskBytes: { free })
    await model.load()
    return (model, mock)
}

@Suite("Settings > Models page") @MainActor struct ModelsPageTests {
    @Test func marksTheRecommendedModelPerUseCaseWithAWhy() async {
        let (model, _) = await make()
        let recs = model.recommendations(for: "best")
        #expect(Set(recs.map(\.useCase)) == [.file, .live, .dictation])
        #expect(recs.allSatisfy { !$0.why.isEmpty })
        #expect(model.recommendations(for: "other").isEmpty)
        #expect(model.recommendations(for: "sd").isEmpty)
    }

    @Test func asrRowsAreOrderedRecommendedThenInstalledThenTheRest() async {
        let (model, _) = await make(installed: ["installed"])
        #expect(model.rows(of: .asr).map { $0.id.rawValue } == ["best", "installed", "other"])
        #expect(model.rows(of: .diarization).map { $0.id.rawValue } == ["sd"])
    }

    @Test func compactLandingPageKeepsRecommendationsAndInstalledModelsSeparate() async {
        let (model, _) = await make(installed: ["installed", "best"])
        #expect(model.recommendedRows.isEmpty)
        #expect(Set(model.managedRows.map(\.id)) == ["best", "installed"])
        #expect(model.browseRows(query: "English", kind: .asr).count == 3)
        #expect(model.browseRows(query: "other", kind: .asr).map(\.id) == ["other"])
        #expect(model.browseRows(query: "other", kind: .translation).isEmpty)
    }

    @Test func tooLittleDiskIsRefusedClearlyAndNeverStarts() async {
        let (model, mock) = await make(free: 10)
        let outcome = await model.download("best")
        guard case .failed(let reason) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(reason.contains("not enough free disk space"))
        #expect(model.errorMessage == reason)
        #expect(await mock.ensureAvailableCalls().isEmpty)
        #expect(model.row("best")?.state == .notInstalled)
    }

    @Test func confirmingRecordsConsentSoTheHookDoesNotAskAgain() async {
        let (model, mock) = await make()
        #expect(await model.download("best", confirmed: true) == .completed)
        #expect(await mock.consentedModels() == ["best"])
    }

    @Test func aFailedRowRetriesAndCancelDiscardsIt() async {
        let (model, mock) = await make()
        await mock.setState(.failed(reason: "offline"), for: "best")
        await model.load()
        #expect(model.row("best")?.state == .failed(reason: "offline"))
        #expect(await model.download("best") == .completed)  // Retry
        #expect(model.row("best")?.isInstalled == true)
        await mock.setState(.failed(reason: "offline"), for: "other")
        await model.load()
        await model.cancel("other")  // Cancel on a failed row goes to the manager, which discards partial data
        #expect(model.row("other") != nil)
    }

    @Test func downloadErrorsShowTheManagersWords() async {
        let (model, mock) = await make()
        await mock.setFailure(.modelDownloadFailed("best", reason: "The server returned 503."), for: "best")
        let outcome = await model.download("best")
        #expect(outcome == .failed("The server returned 503."))
        #expect(model.errorMessage == "The server returned 503.")
    }
}

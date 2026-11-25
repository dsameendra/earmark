import AppCore
import AppCoreTesting
import FeatureSettings
import FeatureSupport
import Foundation
import Testing

@Suite("Directional language-pack downloads") @MainActor
struct OPUSPairPackTests {
    private func make(free: Int64 = .max, installed: Set<ModelID> = []) async -> (ModelManagerModel, MockModelManager) {
        let descriptors = [("en", "de"), ("de", "en"), ("en", "fr")].map { source, target in
            ModelDescriptor(
                id: ModelID("opus/\(source)-\(target)"), displayName: "\(source) → \(target)", kind: .translation,
                runtime: .other, engine: "opus-mt", languages: [LanguageCode(source), LanguageCode(target)], sizeBytes: 100,
                license: LicenseInfo(spdx: "Apache-2.0"), capabilities: ModelCapabilities(
                    translation: true, translationPairs: [LanguagePair(source: LanguageCode(source), target: LanguageCode(target))],
                    translationLanguageMatching: .exact))
        }
        let manager = MockModelManager(descriptors: descriptors, installed: installed)
        let model = ModelManagerModel(manager: manager, hardware: PlaceholderHardware(), store: InMemorySettingsStore(), freeDiskBytes: { free })
        await model.load()
        return (model, manager)
    }

    @Test func combinedDiskRequirementRefusesBeforeEitherDownload() async {
        let (model, manager) = await make(free: 150) // enough for either pack separately, not both
        guard case .failed = await model.downloadPairPacks(source: "en", target: "de", bothDirections: true) else {
            Issue.record("Expected aggregate disk refusal"); return
        }
        #expect(await manager.ensureAvailableCalls().isEmpty)
        #expect(model.activePairPackIDs.isEmpty)
    }

    @Test func bothDirectionsAreSequentialAndAlreadyInstalledPacksAreSkipped() async {
        let (model, manager) = await make(free: 150, installed: ["opus/en-de"])
        #expect(await model.downloadPairPacks(source: "en", target: "de", bothDirections: true) == .completed)
        #expect(await manager.ensureAvailableCalls() == ["opus/de-en"])
        let installed = model.pairPacks(source: "en", target: "de", bothDirections: true).allSatisfy { $0.isInstalled }
        #expect(installed)
    }

    @Test func failureOrCancellationDoesNotStartReversePack() async {
        for error in [AppError.cancelled, .other("Offline")] {
            let (model, manager) = await make()
            await manager.setFailure(error, for: "opus/en-de")
            let result = await model.downloadPairPacks(source: "en", target: "de", bothDirections: true)
            #expect(result != .completed)
            #expect(await manager.ensureAvailableCalls() == ["opus/en-de"])
            #expect(model.activePairPackIDs.isEmpty)
        }
    }

    @Test func unsupportedReverseAndVariantsDoNotStartPartialSelections() async {
        let (model, manager) = await make()
        #expect(model.pairPacks(source: "en", target: "fr", bothDirections: true).isEmpty)
        #expect(model.pairPacks(source: "en-US", target: "de", bothDirections: false).isEmpty)
        guard case .failed = await model.downloadPairPacks(source: "en", target: "fr", bothDirections: true) else {
            Issue.record("Expected unsupported reverse refusal"); return
        }
        #expect(await manager.ensureAvailableCalls().isEmpty)
        #expect(await model.downloadPairPacks(source: "en", target: "fr", bothDirections: false) == .completed)
    }
}

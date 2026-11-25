import AppCore
import AppCoreTesting
import FeatureSettings
import FeatureSupport
import Testing

@Suite("Hugging Face preview and download handoff") @MainActor
struct HuggingFacePreviewTests {
    @Test func reviewDoesNotDownloadAndNormalConsentStillApplies() async throws {
        let descriptor = ModelDescriptor(id: "reviewed", displayName: "Reviewed", kind: .translation, runtime: .other,
                                         languages: ["en", "de"], sizeBytes: 100,
                                         license: LicenseInfo(spdx: "CC-BY-NC-4.0", isNonCommercial: true))
        let manager = MockModelManager(descriptors: [descriptor])
        let model = ModelManagerModel(manager: manager, hardware: PlaceholderHardware(), store: InMemorySettingsStore(),
                                      freeDiskBytes: { .max }, reviewedHuggingFaceModels: { _ in ["reviewed"] })
        await model.load()
        #expect(model.canBrowseHuggingFace)
        #expect(try model.previewHuggingFace("owner/model").map(\.id) == [descriptor.id])
        #expect(await manager.ensureAvailableCalls().isEmpty)
        #expect(await model.download(descriptor.id) == .needsConfirmation([.nonCommercial(spdx: "CC-BY-NC-4.0")]))
        #expect(await manager.ensureAvailableCalls().isEmpty)
        #expect(await model.download(descriptor.id, confirmed: true) == .completed)
        #expect(await manager.ensureAvailableCalls() == [descriptor.id])
    }

    @Test func staleRecipeCannotOfferAnUnavailableOrDisabledModel() async {
        let manager = MockModelManager(descriptors: [])
        let model = ModelManagerModel(manager: manager, hardware: PlaceholderHardware(), store: InMemorySettingsStore(),
                                      reviewedHuggingFaceModels: { _ in ["missing"] })
        await model.load()
        #expect(throws: AppError.self) { try model.previewHuggingFace("owner/model") }
        #expect(await manager.ensureAvailableCalls().isEmpty)
        let unavailable = ModelManagerModel(manager: manager, hardware: PlaceholderHardware(), store: InMemorySettingsStore())
        #expect(!unavailable.canBrowseHuggingFace)
        #expect(throws: AppError.self) { try unavailable.previewHuggingFace("owner/model") }
    }
}

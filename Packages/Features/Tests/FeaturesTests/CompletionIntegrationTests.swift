import AppCore
import AppCoreTesting
import FeatureHome
import FeatureSettings
import FeatureShell
import FeatureSupport
import Foundation
import Testing
import os

@Suite("Completion integration") @MainActor
struct CompletionIntegrationTests {
    @Test func preferredModelStatusFollowsTheChosenLanguageAndModel() async {
        let store = InMemorySettingsStore()
        let english = ModelDescriptor(
            id: "english", displayName: "English", kind: .asr, runtime: .coreML, languages: [.english], sizeBytes: 1,
            license: LicenseInfo(spdx: "MIT"))
        let sinhala = ModelDescriptor(
            id: "sinhala", displayName: "Sinhala", kind: .asr, runtime: .mlx, languages: [.sinhala], sizeBytes: 1,
            license: LicenseInfo(spdx: "MIT"), isExperimental: true)
        await store.set(LanguageMode.single(.sinhala), for: SettingsKey.languageMode)
        #expect(await PreferredModel.resolve(in: [english, sinhala], settings: store)?.id == sinhala.id)
        await store.set("english", for: SettingsKey.preferredModel)
        await store.set(LanguageMode.single(.english), for: SettingsKey.languageMode)
        #expect(await PreferredModel.resolve(in: [english, sinhala], settings: store)?.id == english.id)
        await store.set("removed-model", for: SettingsKey.preferredModel)
        #expect(await PreferredModel.resolve(in: [english, sinhala], settings: store)?.id == english.id)
    }

    @Test func homeMeetingAndLibraryEntryPointsNavigate() {
        let shell = ShellModel(services: .preview())
        shell.homeActions.captureMeeting()
        #expect(shell.selection == .meetings)
        shell.homeActions.openLibrary()
        #expect(shell.selection == .library)
    }

    @Test func microphoneTestIsExplicitStreamsLevelsAndStops() async {
        let probe = MeterProbe()
        let model = AudioSettingsModel(
            provider: PlaceholderAudioDevices(), store: InMemorySettingsStore(), microphonePreview: { _ in probe })
        await model.load()
        #expect(probe.starts == 0, "Loading Settings must not listen to the microphone")
        await model.startMicrophoneTest()
        #expect(probe.starts == 1 && model.isTestingMicrophone)
        probe.yield(0.7)
        #expect(await eventually { model.inputLevel == 0.7 })
        await model.stopMicrophoneTest()
        #expect(probe.stops == 1 && !model.isTestingMicrophone && model.inputLevel == 0)
    }
    @Test func microphoneFailureReleasesCaptureAndClearsTheMeter() async {
        let probe = MeterProbe()
        let model = AudioSettingsModel(
            provider: PlaceholderAudioDevices(), store: InMemorySettingsStore(), microphonePreview: { _ in probe },
            sourceErrors: { _ in probe.errors })
        await model.startMicrophoneTest()
        probe.yield(0.5)
        #expect(await eventually { model.inputLevel == 0.5 })
        probe.fail(.deviceUnavailable)
        #expect(await eventually { !model.isTestingMicrophone && model.meterError != nil && probe.stops == 1 })
        #expect(model.inputLevel == 0)
    }

    @Test func homeStatusObservesLanguageChangesFromSettings() async {
        let store = InMemorySettingsStore()
        let english = ModelDescriptor(
            id: "en", displayName: "English model", kind: .asr, runtime: .coreML, languages: [.english], sizeBytes: 1,
            license: LicenseInfo(spdx: "MIT"))
        let sinhala = ModelDescriptor(
            id: "si", displayName: "Sinhala model", kind: .asr, runtime: .mlx, languages: [.sinhala], sizeBytes: 1,
            license: LicenseInfo(spdx: "MIT"))
        var services = AppServices.preview()
        services.settings = store
        services.models = MockModelManager(descriptors: [english, sinhala])
        let model = HomeModel(services: services)
        let watching = Task { await model.run() }
        defer { watching.cancel() }
        #expect(await eventually { model.modelStatus?.name == "English model" })
        await store.set(LanguageMode.single(.sinhala), for: SettingsKey.languageMode)
        #expect(await eventually { model.modelStatus?.name == "Sinhala model" })
    }

}

private final class MeterProbe: AudioSource, Sendable {
    let tag = AudioSourceTag.mic(deviceUID: nil)
    let levels: AsyncStream<Float>
    let health = AsyncStream<AudioSourceHealth> { $0.finish() }
    let errors: AsyncStream<AppError>
    private let errorContinuation: AsyncStream<AppError>.Continuation
    private let chunks: AsyncStream<AudioChunk>
    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let levelContinuation: AsyncStream<Float>.Continuation
    private let counts = OSAllocatedUnfairLock(initialState: (starts: 0, stops: 0))
    var starts: Int { counts.withLock { $0.starts } }
    var stops: Int { counts.withLock { $0.stops } }

    init() {
        (levels, levelContinuation) = AsyncStream<Float>.makeStream()
        (errors, errorContinuation) = AsyncStream<AppError>.makeStream()
        (chunks, chunkContinuation) = AsyncStream<AudioChunk>.makeStream()
    }
    func yield(_ value: Float) { levelContinuation.yield(value) }
    func fail(_ error: AppError) { errorContinuation.yield(error) }
    func start() async throws -> AsyncStream<AudioChunk> {
        counts.withLock { $0.starts += 1 }
        return chunks
    }
    func stop() async {
        counts.withLock { $0.stops += 1 }
        levelContinuation.finish()
        errorContinuation.finish()
        chunkContinuation.finish()
    }
}

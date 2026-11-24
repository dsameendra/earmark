import AppCore
import AppCoreTesting
import FeatureOnboarding
import FeatureSettings
import FeatureSupport
import Foundation
import Synchronization
import Testing

private let enWhisper = ModelID("whisper.test")
private let enApple = ModelID("apple.test")
private let siQwen = ModelID("qwen.si.test")

private func descriptor(
    _ id: ModelID, _ name: String, languages: Set<LanguageCode>, mb: Int64, runtime: ModelRuntime = .coreML,
    experimental: Bool = false, minTier: HardwareTier = .tier8, capabilities: ModelCapabilities = .standard
) -> ModelDescriptor {
    ModelDescriptor(
        id: id, displayName: name, kind: .asr, runtime: runtime, languages: languages, sizeBytes: mb * 1_000_000,
        license: LicenseInfo(spdx: "MIT"), minTier: minTier, isExperimental: experimental, capabilities: capabilities)
}

private let testCatalog = [
    descriptor(enWhisper, "Whisper large-v3 turbo", languages: ["en", "ta"], mb: 1600),
    descriptor(enApple, "Apple Speech", languages: ["en"], mb: 0, runtime: .appleAsset),
    // Like the production specialist, Sinhala has an explicit recommendation rule.
    descriptor(siQwen, "Qwen3-ASR Sinhala", languages: ["si"], mb: 780, experimental: true,
               capabilities: ModelCapabilities(live: true, file: true, recommendedUse: [RecommendedUse(.file)])),
]

/// Picks Whisper for files, Apple Speech for live English, Qwen for Sinhala.
private struct FakeRouter: EngineRouter {
    func plan(for request: RoutingRequest) throws -> EnginePlan {
        guard case .single(let language) = request.languageMode else { throw AppError.other("single only") }
        switch (language, request.useCase) {
        case ("si", _): return EnginePlan(assignments: [EngineAssignment(language: language, engine: "qwen", model: siQwen)])
        case ("en", .live): return EnginePlan(assignments: [EngineAssignment(language: language, engine: "apple", model: enApple)])
        case ("en", _), ("ta", _): return EnginePlan(assignments: [EngineAssignment(language: language, engine: "whisper", model: enWhisper)])
        default: throw AppError.unsupportedLanguage(language)
        }
    }
}

/// Wraps the mock manager but keeps downloads open until cancelled, recording pause/resume/cancel.
private final class SlowModels: ModelManaging, Sendable {
    let inner = MockModelManager(descriptors: testCatalog)
    let calls = Mutex<[String]>([])
    func catalog() async -> [ModelDescriptor] { await inner.catalog() }
    func state(of model: ModelID) async -> ModelState { await inner.state(of: model) }
    func stateChanges() -> AsyncStream<(ModelID, ModelState)> { inner.stateChanges() }
    func installedModels() async -> Set<ModelID> { await inner.installedModels() }
    func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.progress(fraction: 0.4, bytesReceived: 40, bytesTotal: 100))
            continuation.onTermination = { _ in }
            // Stays open until `cancelDownload` finishes it.
            self.calls.withLock { $0.append("open:\(model.rawValue)") }
            Task {
                while !self.calls.withLock({ $0.contains("cancel:\(model.rawValue)") }) { try? await Task.sleep(for: .milliseconds(5)) }
                continuation.finish()
            }
        }
    }
    func pauseDownload(_ model: ModelID) async { calls.withLock { $0.append("pause:\(model.rawValue)") } }
    func resumeDownload(_ model: ModelID) async { calls.withLock { $0.append("resume:\(model.rawValue)") } }
    func cancelDownload(_ model: ModelID) async { calls.withLock { $0.append("cancel:\(model.rawValue)") } }
    func delete(_ model: ModelID) async throws {}
    func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) async throws -> ModelDescriptor {
        throw AppError.other("unused")
    }
    func diskUsage() async -> DiskUsage { await inner.diskUsage() }
    func location(of model: ModelID) async throws -> URL { try await inner.location(of: model) }
}

private struct FailingModels: ModelManaging {
    let inner = MockModelManager(descriptors: testCatalog)
    func catalog() async -> [ModelDescriptor] { await inner.catalog() }
    func state(of model: ModelID) async -> ModelState { .notInstalled }
    func stateChanges() -> AsyncStream<(ModelID, ModelState)> { AsyncStream { $0.finish() } }
    func installedModels() async -> Set<ModelID> { [] }
    func ensureAvailable(_ model: ModelID) -> AsyncThrowingStream<ModelDownloadEvent, any Error> {
        AsyncThrowingStream { $0.finish(throwing: AppError.other("network lost")) }
    }
    func pauseDownload(_ model: ModelID) async {}
    func resumeDownload(_ model: ModelID) async {}
    func cancelDownload(_ model: ModelID) async {}
    func delete(_ model: ModelID) async throws {}
    func importModel(folder: URL, displayName: String, languages: Set<LanguageCode>) async throws -> ModelDescriptor {
        throw AppError.other("unused")
    }
    func diskUsage() async -> DiskUsage { DiskUsage(totalBytes: 0, perModel: [:]) }
    func location(of model: ModelID) async throws -> URL { throw AppError.modelNotInstalled(model) }
}

/// Counts requests so tests can prove onboarding never prompts by itself.
private final class CountingPermissions: PermissionsServicing, Sendable {
    let status: PermissionStatus
    let requests = Mutex(0)
    init(status: PermissionStatus) { self.status = status }
    func status(_ kind: PermissionKind) async -> PermissionStatus { status }
    func request(_ kind: PermissionKind) async -> PermissionStatus {
        requests.withLock { $0 += 1 }
        return .granted
    }
    func settingsURL(for kind: PermissionKind) -> URL { URL(string: "x-apple.systempreferences:\(kind.rawValue)")! }
    func changes() -> AsyncStream<(PermissionKind, PermissionStatus)> { AsyncStream { _ in } }
}

@MainActor
private func makeModel(
    models: (any ModelManaging)? = nil, installed: Set<ModelID> = [], router: (any EngineRouter)? = FakeRouter(),
    store: InMemorySettingsStore = InMemorySettingsStore(), permissions: (any PermissionsServicing)? = nil, online: Bool = true,
    freeDisk: Int64? = nil
) -> OnboardingModel {
    var services = AppServices.preview()
    services.models = models ?? MockModelManager(descriptors: testCatalog, installed: installed)
    services.settings = store
    if let permissions { services.permissions = permissions }
    return OnboardingModel(services: services, router: router, isOnline: { online }, freeDiskBytes: { freeDisk })
}

@MainActor
@Suite("Onboarding flow")
struct OnboardingFlowTests {
    @Test func hasFiveStepsWithFlowCopy() {
        #expect(OnboardingStep.count == 5)
        #expect(OnboardingStep.allCases.map(\.number) == [1, 2, 3, 4, 5])
        #expect(OnboardingStep.welcome.title == "Your voice stays on your Mac")
        #expect(OnboardingStep.languages.progressText == "Step 2 of 5")
        #expect(OnboardingStep.welcome.primaryTitle == "Get started")
        #expect(OnboardingStep.ready.primaryTitle == "Open Earmark")
        #expect(OnboardingHighlight.welcome.map(\.id) == ["private", "fast", "languages"])
        #expect(OnboardingHighlight.welcome.allSatisfy { !$0.systemImage.isEmpty })
    }

    @Test func showsOnFirstLaunchAndNeverAgainAfterCompletion() async {
        let store = InMemorySettingsStore()
        #expect(await OnboardingModel.shouldPresent(store: store))  // ONB-AC-01
        let model = makeModel(store: store)
        await model.load()
        for _ in 0..<5 { await model.next() }
        #expect(model.isFinished)
        #expect(await OnboardingModel.shouldPresent(store: store) == false)
        #expect(await store.value(for: SettingsKey.onboardingStep, as: Int.self) == 0)
    }

    @Test func skipFromAnyStepCompletes() async {
        let store = InMemorySettingsStore()
        let model = makeModel(store: store)
        await model.load()
        await model.next()
        await model.skip()
        #expect(model.isFinished)
        #expect(await OnboardingModel.shouldPresent(store: store) == false)
    }

    @Test func welcomeAgainRearmsFromTheFirstStep() async {
        let store = InMemorySettingsStore()
        let first = makeModel(store: store)
        await first.load()
        await first.skip()
        await OnboardingModel.requestWelcomeAgain(store: store)
        #expect(await OnboardingModel.shouldPresent(store: store))
        let again = makeModel(store: store)
        await again.load()
        #expect(again.step == .welcome)
        #expect(again.isFinished == false)
    }

    @Test func quittingMidFlowResumesAtTheSameStep() async {
        let store = InMemorySettingsStore()
        let model = makeModel(store: store)
        await model.load()
        await model.next()
        await model.next()
        #expect(model.step == .permissions)
        let relaunched = makeModel(store: store)
        await relaunched.load()
        #expect(relaunched.step == .permissions)
    }

    @Test func backIsAvailableAfterTheFirstStepOnly() async {
        let model = makeModel()
        await model.load()
        #expect(!model.canGoBack)
        await model.back()
        #expect(model.step == .welcome)
        await model.next()
        #expect(model.canGoBack)
        await model.back()
        #expect(model.step == .welcome)
    }

    @Test func tourCoversCaptionsMeetingsAndDictationWithTheDefaultShortcut() async {
        let model = makeModel()
        await model.load()
        let ids = model.tourHighlights.map(\.id)
        #expect(ids.contains("liveCaptions") && ids.contains("meetings") && ids.contains("dictation") && ids.contains("menuBar"))
        let dictation = model.tourHighlights.first { $0.id == "dictation" }
        #expect(dictation?.detail.contains("Control-Option-D") == true)
        #expect(dictation?.detail.contains("Fn") == true)
    }

    @Test func tourUsesTheUsersDictationShortcut() async {
        let store = InMemorySettingsStore()
        await store.set(KeyCombo.functionKey, for: SettingsKey.shortcut("dictation"))
        let model = makeModel(store: store)
        await model.load()
        #expect(model.dictationShortcut == .functionKey)
        #expect(model.tourHighlights.first { $0.id == "dictation" }?.detail.hasPrefix("Press Fn,") == true)
        #expect(KeyCombo.defaultDictation.spokenDescription == "Control-Option-D")
    }

    @Test func consentIsAcknowledgedOnceAndPersisted() async {
        let store = InMemorySettingsStore()
        let skipper = makeModel(store: store)
        await skipper.load()
        await skipper.skip()
        // Not acknowledged: the Meetings notice must still show before the first capture (ONB-AC-08).
        #expect(await store.value(for: SettingsKey.meetingConsentNotice, as: Bool.self) == nil)
        let model = makeModel(store: store)
        await model.load()
        #expect(!model.consentAcknowledged)
        await model.acknowledgeConsent()
        #expect(model.consentAcknowledged)
        #expect(await store.value(for: SettingsKey.meetingConsentNotice, as: Bool.self) == false)
        let later = makeModel(store: store)
        await later.load()
        #expect(later.consentAcknowledged)
    }
}

@MainActor
@Suite("Onboarding languages and models")
struct OnboardingLanguageTests {
    @Test func englishIsPreselectedAndSinhalaIsExperimental() async {
        let model = makeModel()
        await model.load()
        let languages = model.languages
        #expect(languages.selected == [.english])  // ONB-AC-02
        #expect(languages.options.first?.code == .english)
        #expect(languages.options.first?.isDefault == true)
        let sinhala = languages.options.first { $0.code == .sinhala }
        #expect(sinhala?.isExperimental == true)
        #expect(sinhala?.label.hasSuffix("Sinhala") == true || sinhala?.label.contains("·") == true)
    }

    @Test func recommendsPerLanguageFromTheRouterWithSize() async {
        let model = makeModel()
        await model.load()
        let languages = model.languages
        // English: Whisper for files plus the Apple asset for live.
        #expect(languages.recommendations.map(\.id) == [enWhisper, enApple])  // ONB-AC-03
        #expect(languages.recommendations.first?.sizeText == "1.6 GB")
        #expect(languages.recommendations.last?.sizeText == "Managed by macOS")
        await languages.toggle(.sinhala)
        #expect(Set(languages.recommendations.map(\.id)) == [enWhisper, enApple, siQwen])
        #expect(languages.recommendations.first { $0.id == siQwen }?.isExperimental == true)
        #expect(languages.bytesToDownload == 2_380_000_000)
        #expect(languages.languageMode == .multilingual([.english, .sinhala]))
    }

    @Test func selectionPersistsAndNeverEmpties() async {
        let store = InMemorySettingsStore()
        let model = makeModel(store: store)
        await model.load()
        await model.languages.toggle(.english)  // only one selected: ignored
        #expect(model.languages.selected == [.english])
        await model.languages.toggle(.sinhala)
        #expect(await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) == .multilingual([.english, .sinhala]))
        await model.languages.toggle(.english)
        #expect(await store.value(for: SettingsKey.languageMode, as: LanguageMode.self) == .single(.sinhala))
    }

    @Test func fallsBackToTheCatalogByTierWithoutARouter() async {
        let model = makeModel(router: nil)
        await model.load()
        // Largest ASR model covering English that fits tier16.
        #expect(model.languages.recommendations.map(\.id) == [enWhisper])
        #expect(OnboardingLanguageModel.fallbackModel(
            for: .sinhala, in: LanguageCapabilityTable(models: testCatalog), tier: .tier8) == siQwen)
    }

    @Test func downloadReportsProgressAndInstalls() async {
        let model = makeModel()
        await model.load()
        await model.languages.startDownload()  // ONB-AC-04
        await model.languages.waitForDownload()
        let rec = model.languages.recommendations
        #expect(rec.allSatisfy { $0.isInstalled })
        #expect(model.languages.progress(for: enWhisper)?.phase == .completed)
        #expect(model.languages.hasPendingDownload == false)
    }

    @Test func skippingDownloadLeavesModelsUntouched() async {
        let store = InMemorySettingsStore()
        let model = makeModel(store: store)
        await model.load()
        await model.next()
        await model.next()
        #expect(model.languages.recommendations.allSatisfy { !$0.isInstalled })
        #expect(model.languages.isDownloading == false)
        #expect(model.languages.downloads.isEmpty)
    }

    @Test func pauseResumeAndCancelReachTheModelManager() async {
        let slow = SlowModels()
        let model = makeModel(models: slow, router: FakeRouter())
        await model.load()
        let languages = model.languages
        await languages.startDownload()
        #expect(await eventually { languages.progress(for: enWhisper)?.phase == .downloading })
        #expect(languages.isDownloading)
        await languages.pause()
        #expect(languages.isPaused)
        await languages.resume()
        #expect(!languages.isPaused)
        await languages.cancel()
        await languages.waitForDownload()
        #expect(languages.isDownloading == false)
        #expect(languages.progress(for: enWhisper)?.phase == .cancelled)
        let calls = slow.calls.withLock { $0 }
        #expect(calls.contains("pause:whisper.test") && calls.contains("resume:whisper.test") && calls.contains("cancel:whisper.test"))
    }

    @Test func offlineExplainsAndDoesNotDownload() async {
        let model = makeModel(online: false)
        await model.load()
        #expect(model.languages.isOffline)
        #expect(model.languages.offlineNotice == OnboardingLanguageModel.offlineNotice)  // ONB-AC-10
        await model.languages.startDownload()
        #expect(!model.languages.isDownloading)
        #expect(model.languages.downloads.isEmpty)
        // Continuing without a model is always possible.
        await model.next()
        #expect(model.step == .languages)
    }

    @Test func failedDownloadShowsReasonAndCanBeSkipped() async {
        let model = makeModel(models: FailingModels())
        await model.load()
        await model.languages.startDownload()
        await model.languages.waitForDownload()
        #expect(model.languages.errorMessage?.contains("Download failed") == true)
        #expect(model.languages.isDownloading == false)
    }

    @Test func lowDiskWarnsWithSizeNeededThenAllowsContinuing() async {
        let model = makeModel(freeDisk: 100_000_000)
        await model.load()
        await model.languages.startDownload()
        #expect(model.languages.diskWarning?.needed == 1_600_000_000)
        #expect(model.languages.diskWarning?.message.contains("1.6 GB") == true)
        #expect(!model.languages.isDownloading)
        await model.languages.startDownload(confirmLowDisk: true)
        await model.languages.waitForDownload()
        #expect(model.languages.diskWarning == nil)
        #expect(model.languages.allInstalled)
    }

    @Test func installedModelsNeedNoDownload() async {
        let model = makeModel(installed: [enWhisper, enApple])
        await model.load()
        #expect(model.languages.allInstalled)
        #expect(model.languages.hasPendingDownload == false)
        #expect(model.languages.bytesToDownload == 0)
    }
}

@MainActor
@Suite("Onboarding permissions")
struct OnboardingPermissionsTests {
    @Test func loadingAndNavigatingNeverRequestsAPermission() async {
        let permissions = CountingPermissions(status: .notDetermined)
        let model = makeModel(permissions: permissions)
        await model.load()
        for _ in 0..<5 { await model.next() }
        #expect(permissions.requests.withLock { $0 } == 0)  // ONB-AC-05
        let state = model.permissions.rowState(for: .microphone)
        #expect(state.context == .onboarding)
        #expect(state.chipLabel == "Ask later")
        #expect(state.action == .request)
    }

    @Test func requestHappensOnlyOnExplicitOptIn() async {
        let permissions = CountingPermissions(status: .notDetermined)
        let model = makeModel(permissions: permissions)
        await model.load()
        await model.permissions.request(.microphone)
        #expect(permissions.requests.withLock { $0 } == 1)
        #expect(model.permissions.rowState(for: .microphone).status == .granted)
    }

    @Test func denialShowsRecoveryWithDeepLinkAndNeverBlocks() async {
        let model = makeModel(permissions: CountingPermissions(status: .denied))
        await model.load()
        let state = model.permissions.rowState(for: .accessibility)
        #expect(state.recoveryNote?.contains("System Settings") == true)  // ONB-AC-06
        #expect(state.showsSettingsLink)
        #expect(model.permissions.settingsURL(for: .accessibility).absoluteString.contains("accessibility"))
        await model.next()
        await model.next()
        await model.next()
        #expect(model.step == .tour)
    }

    @Test func listsTheFlowBoardPermissions() {
        let kinds = OnboardingPermissionsModel.kinds
        #expect(Array(kinds.prefix(4)) == [.microphone, .systemAudioRecording, .accessibility, .notifications])
        #expect(kinds.contains(.screenRecording))
    }
}

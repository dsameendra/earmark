import AppCore
import AppCoreTesting
import FeatureSettings
import FeatureShell
import FeatureSupport
import Foundation
import Testing

// SCR-011 wave 2: per-use-case preferred models, the sidebar model picker, capability chips, recommendations, consent.

private let permissive = LicenseInfo(spdx: "MIT")

private func asr(
    _ id: String, _ languages: Set<LanguageCode>, size: Int64 = 600_000_000, caps: ModelCapabilities, license: LicenseInfo = permissive,
    minTier: HardwareTier = .tier8, runtime: ModelRuntime = .coreML, experimental: Bool = false
) -> ModelDescriptor {
    ModelDescriptor(
        id: ModelID(id), displayName: id, kind: .asr, runtime: runtime, languages: languages, sizeBytes: size, license: license,
        minTier: minTier, isExperimental: experimental, capabilities: caps)
}

/// A small catalog with the shapes that matter: a live-capable multilingual model, a file-only large model, a Sinhala-only model.
private func catalog() -> [ModelDescriptor] {
    [
        asr(
            "small", ["en", "de"], size: 200_000_000,
            caps: ModelCapabilities(
                live: true, file: true, wordTimestamps: true, autoDetectLanguage: true,
                recommendedUse: [RecommendedUse(.file, maxTier: .tier8), RecommendedUse(.live), RecommendedUse(.dictation)])),
        asr(
            "large", ["en", "de"], caps: ModelCapabilities(
                live: false, file: true, wordTimestamps: true, autoDetectLanguage: true, speed: .slow, memory: .heavy,
                recommendedUse: [RecommendedUse(.file, minTier: .tier16)])),
        asr(
            "sinhala", ["si"], size: 1_000_000_000, caps: ModelCapabilities(live: true, file: true, recommendedUse: [RecommendedUse(.file)]),
            license: LicenseInfo(spdx: "CC-BY-SA-4.0"), experimental: true),
        asr("heavy32", ["en"], caps: ModelCapabilities(file: true), minTier: .tier32Plus),
    ]
}

@MainActor private func makeServices(
    catalog: [ModelDescriptor] = catalog(), installed: Set<ModelID> = []
) -> (AppServices, MockModelManager, InMemorySettingsStore) {
    let mock = MockModelManager(descriptors: catalog, installed: installed)
    let store = InMemorySettingsStore()
    var services = AppServices.preview()
    services.models = mock
    services.settings = store
    return (services, mock, store)
}

@Suite("Preferred model per use case") struct PreferredModelPerUseCaseTests {
    @Test func keysAreDistinct() {
        let keys = UseCase.allCases.map { SettingsKey.preferredModelKey(for: $0) }
        #expect(Set(keys).count == 3)
        #expect(SettingsKey.preferredModelKey(for: .file) == SettingsKey.preferredModelFile)
        #expect(SettingsKey.preferredModelKey(for: .live) == SettingsKey.preferredModelLive)
        #expect(SettingsKey.preferredModelKey(for: .dictation) == SettingsKey.preferredModelDictation)
    }

    @Test func eachUseCaseReadsItsOwnKey() async {
        let store = InMemorySettingsStore()
        await PreferredModel.set("a", for: .file, settings: store)
        await PreferredModel.set("b", for: .live, settings: store)
        await PreferredModel.set("c", for: .dictation, settings: store)
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "a")
        #expect(await PreferredModel.explicitID(for: .live, settings: store) == "b")
        #expect(await PreferredModel.explicitID(for: .dictation, settings: store) == "c")
        await PreferredModel.set(nil, for: .live, settings: store)
        #expect(await PreferredModel.explicitID(for: .live, settings: store) == nil)
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "a")
    }

    @Test func legacySharedKeyMigratesToFileOnly() async {
        let store = InMemorySettingsStore()
        await store.set("whisper-large", for: SettingsKey.preferredModel)
        // Before the migration runs, file transcription still honours the old choice; live and dictation never did a split.
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "whisper-large")
        #expect(await PreferredModel.explicitID(for: .live, settings: store) == nil)
        await PreferredModel.migrateLegacy(settings: store)
        #expect(await store.value(for: SettingsKey.preferredModelFile, as: String.self) == "whisper-large")
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "whisper-large")
        #expect(await PreferredModel.explicitID(for: .live, settings: store) == nil)
        #expect(await PreferredModel.explicitID(for: .dictation, settings: store) == nil)
    }

    @Test func migrationIsIdempotentAndNeverOverwritesANewerChoice() async {
        let store = InMemorySettingsStore()
        await store.set("old", for: SettingsKey.preferredModel)
        await store.set("newer", for: SettingsKey.preferredModelFile)
        await PreferredModel.migrateLegacy(settings: store)
        await PreferredModel.migrateLegacy(settings: store)
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "newer")
        // Choosing Automatic afterwards must not resurrect the legacy value.
        await PreferredModel.set(nil, for: .file, settings: store)
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == nil)
    }

    @Test func fileJobsReadTheFileKeyNotTheLiveKey() async {
        let store = InMemorySettingsStore()
        let models = catalog()
        await PreferredModel.set("small", for: .live, settings: store)
        #expect(await FileJobSettings.load(from: store, catalog: models).modelID == nil)
        await PreferredModel.set("large", for: .file, settings: store)
        #expect(await FileJobSettings.load(from: store, catalog: models).modelID == "large")
    }

    @Test func quickLanguageChoiceClearsOnlyIncompatibleChoices() async {
        let store = InMemorySettingsStore()
        let models = catalog()
        await PreferredModel.set("small", for: .file, settings: store)
        await PreferredModel.set("sinhala", for: .live, settings: store)
        await TranscriptionLanguageChoice.english.persist(to: store, catalog: models)
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "small")
        #expect(await PreferredModel.explicitID(for: .live, settings: store) == nil)
    }
}

@Suite("Capability chips and recommendations") struct CapabilityPresentationTests {
    @Test func chipsListWhatAModelSupports() {
        let large = catalog()[1]
        let ids = ModelCapabilitySummary.chips(for: large).map(\.id)
        #expect(ids.contains("languages"))
        #expect(ids.contains("words") && ids.contains("detect"))
        #expect(ids.contains("fileOnly") && !ids.contains("live"))
        #expect(ids.contains("speed") && ids.contains("memory") && ids.contains("size") && ids.contains("license"))
        let small = ModelCapabilitySummary.chips(for: catalog()[0]).map(\.id)
        #expect(small.contains("live") && !small.contains("fileOnly"))
        #expect(!small.contains("speed"))  // unmeasured stays absent, nothing invented
    }

    @Test func systemTranslationUsesDynamicLanguagesAndSystemStorageLabels() {
        let model = ModelDescriptor(id: "apple/translation", displayName: "Apple Translation", kind: .translation,
                                    runtime: .appleAsset, engine: "apple.translation", languages: [], sizeBytes: 0,
                                    license: LicenseInfo(spdx: "LicenseRef-Apple-System"), capabilities: ModelCapabilities(translation: true))
        let chips = ModelCapabilitySummary.chips(for: model)
        #expect(!chips.contains { $0.id == "languages" })
        #expect(chips.first { $0.id == "size" }?.text == "System-managed")
    }

    @Test func licenceAndExperimentalWarningsAreExplicit() {
        let nonCommercial = asr(
            "nc", ["en"], caps: ModelCapabilities(), license: LicenseInfo(spdx: "CC-BY-NC-4.0", isNonCommercial: true))
        let chip = ModelCapabilitySummary.licenseChip(nonCommercial.license)
        #expect(chip.text.contains("non-commercial") && chip.tone == .warning)
        #expect(chip.spoken.contains("non-commercial"))
        #expect(ModelCapabilitySummary.licenseChip(LicenseInfo(spdx: "CC-BY-SA-4.0")).text.contains("share-alike"))
        let sinhala = ModelCapabilitySummary.chips(for: catalog()[2]).map(\.id)
        #expect(sinhala.contains("experimental"))
        #expect(ModelCapabilitySummary.chips(for: catalog()[3]).map(\.id).contains("tier"))
    }

    @Test func scriptChoicesAreVisibleAndCustomLicencesAreNeverCalledShareAlike() {
        let variants = asr("variants", ["zh-Hans", "zh-Hant", "en-US", "en-GB"], caps: ModelCapabilities())
        #expect(ModelCapabilitySummary.languageNames(variants).count == 4)
        #expect(ModelCapabilitySummary.languageCountLabel(variants) == "4 language options")
        #expect(ModelCapabilitySummary.languageNames(variants).contains(ModelCapabilitySummary.languageName("zh-Hant")))
        #expect(ModelCapabilitySummary.languageName("zh-Hant") != ModelCapabilitySummary.languageName("zh-Hans"))
        for identifier in ["LicenseRef-Gemma", "LicenseRef-OpenMDW", "NOASSERTION"] {
            let chip = ModelCapabilitySummary.licenseChip(LicenseInfo(spdx: identifier))
            #expect(!chip.text.contains("share-alike"))
            #expect(chip.spoken.contains("Review"))
        }
    }

    @Test func knownCustomLicencesUseReadableNamesAndUnknownOnesStayVisible() {
        #expect(ModelCapabilitySummary.licenseChip(LicenseInfo(spdx: "LicenseRef-NVIDIA-Open-Model-License")).text == "NVIDIA Open Model License · custom terms")
        #expect(ModelCapabilitySummary.licenseChip(LicenseInfo(spdx: "LicenseRef-Gemma")).text == "Gemma Terms of Use · custom terms")
        #expect(ModelCapabilitySummary.licenseChip(LicenseInfo(spdx: "LicenseRef-OpenMDW-1.1")).text == "OpenMDW 1.1 · custom terms")
        #expect(ModelCapabilitySummary.licenseChip(LicenseInfo(spdx: "LicenseRef-Other")).text == "LicenseRef-Other · custom terms")
    }

    @Test func languageSummaryListsFewAndCountsMany() {
        #expect(ModelCapabilitySummary.languageSummary(catalog()[2]) == ModelCapabilitySummary.languageName("si"))
        let many = asr("many", Set((0..<20).map { LanguageCode("x\($0)") }), caps: ModelCapabilities())
        #expect(ModelCapabilitySummary.languageSummary(many) == "20 languages")
    }

    @Test func recommendationsFollowTheOneRecommenderPerTier() {
        let models = catalog()
        func recommended(_ tier: HardwareTier, _ useCase: UseCase) -> [String] {
            ModelRecommendations.compute(catalog: models, tier: tier).filter { $0.useCase == useCase }.map(\.model.rawValue)
        }
        #expect(recommended(.tier8, .file).contains("small"))
        #expect(!recommended(.tier8, .file).contains("large"))
        #expect(recommended(.tier16, .file).contains("large"))
        #expect(recommended(.tier16, .live).contains("small"))
        #expect(!recommended(.tier16, .live).contains("large"))  // file-only models are never recommended for live
        // Sinhala is recommended for Sinhala only, with the language recorded.
        let sinhala = ModelRecommendations.compute(catalog: models, tier: .tier16).first { $0.model == "sinhala" && $0.useCase == .file }
        #expect(sinhala?.languages == ["si"])
        #expect(sinhala?.badgeText.contains("Sinhala") == true || sinhala?.badgeText.contains("si") == true)
        #expect(sinhala?.why.isEmpty == false)
    }

    @Test func nonCommercialModelsAreNeverRecommended() {
        let nc = asr(
            "nc", ["en"], caps: ModelCapabilities(live: true, file: true, recommendedUse: [RecommendedUse(.file)]),
            license: LicenseInfo(spdx: "CC-BY-NC-4.0", isNonCommercial: true))
        #expect(ModelRecommendations.compute(catalog: [nc], tier: .tier32Plus).isEmpty)
    }
}

@Suite("Picker entries") struct PickerEntryTests {
    @Test func greysUnusableRowsWithTheCompatibilityReason() {
        let entries = ModelPicker.entries(
            catalog: catalog(), states: [:], tier: .tier16, useCase: .live, mode: .single(.english), selected: nil)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id.rawValue, $0) })
        #expect(byID["small"]?.isDisabled == false)
        #expect(byID["large"]?.disabledReason == ModelIncompatibility.noLiveStreaming.message)
        #expect(byID["sinhala"]?.disabledReason?.contains("No en") == true)
        #expect(byID["heavy32"]?.disabledReason?.contains("32 GB") == true)
        #expect(byID["large"]?.accessibilityLabel.contains("Unavailable: No live streaming") == true)
        #expect(entries.last?.group == .unavailable)
    }

    @Test func fileUseCaseAllowsFileOnlyModelsAndMarksOneRecommended() {
        let entries = ModelPicker.entries(
            catalog: catalog(), states: [.init("large"): .installed(bytesOnDisk: 1)], tier: .tier16, useCase: .file,
            mode: .single(.english), selected: "large")
        let large = entries.first { $0.id == "large" }
        #expect(large?.isDisabled == false && large?.isSelected == true && large?.isRecommended == true)
        #expect(large?.group == .recommended)
        #expect(entries.filter(\.isRecommended).count == 1)
        #expect(entries.first?.id == "large")  // recommended sorts first
    }

    @Test func autoDetectGreysModelsThatCannotIdentifyTheLanguage() {
        let entries = ModelPicker.entries(
            catalog: catalog(), states: [:], tier: .tier16, useCase: .file, mode: .autoDetect, selected: nil)
        #expect(entries.first { $0.id == "sinhala" }?.disabledReason == ModelIncompatibility.noAutoDetect.message)
    }

    @Test func rowTextShowsSizeAndDownloadedState() {
        let entries = ModelPicker.entries(
            catalog: catalog(), states: [.init("small"): .installed(bytesOnDisk: 5)], tier: .tier16, useCase: .file,
            mode: .single(.english), selected: nil)
        #expect(entries.first { $0.id == "small" }?.stateText == "Downloaded")
        #expect(entries.first { $0.id == "large" }?.stateText == "Not downloaded")
        #expect(entries.first { $0.id == "large" }?.sizeText.isEmpty == false)
    }
}

@Suite("Model picker model") @MainActor struct ModelPickerModelTests {
    private func make(installed: Set<ModelID> = []) async -> (ModelPickerModel, MockModelManager, InMemorySettingsStore) {
        let (services, mock, store) = makeServices(installed: installed)
        await store.set(LanguageMode.single(.english), for: SettingsKey.languageMode)
        let picker = ModelPickerModel(services: services)
        await picker.reload()
        return (picker, mock, store)
    }

    @Test func installedSelectionPersistsPerUseCase() async {
        let (picker, _, store) = await make(installed: ["small", "large"])
        await picker.select("large")
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "large")
        #expect(picker.selected == "large")
        await picker.setUseCase(.live)
        #expect(picker.selected == nil)  // the live choice is separate
        await picker.select("small")
        #expect(await PreferredModel.explicitID(for: .live, settings: store) == "small")
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "large")
        await picker.setUseCase(.dictation)
        #expect(picker.selected == nil)
        #expect(await store.value(for: SettingsKey.preferredModel, as: String.self) == nil)  // legacy key never written
    }

    @Test func automaticClearsTheChoice() async {
        let (picker, _, store) = await make(installed: ["small"])
        await picker.select("small")
        await picker.select(nil)
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == nil)
        #expect(picker.isAutomaticSelected)
    }

    @Test func disabledRowsCannotBeSelected() async {
        let (picker, mock, store) = await make(installed: ["large"])
        await picker.setUseCase(.live)
        await picker.select("large")  // file-only
        #expect(await PreferredModel.explicitID(for: .live, settings: store) == nil)
        #expect(picker.pending == nil)
        #expect(await mock.ensureAvailableCalls().isEmpty)
    }

    @Test func undownloadedModelAsksBeforeDownloadingThenSelects() async {
        let (picker, mock, store) = await make()
        await mock.setPreflight(
            ModelPreflightResult(
                model: "large", displayName: "large", downloadBytes: 600_000_000, freeDiskBytes: 50_000_000_000,
                issues: [.licenseNotice(spdx: "CC-BY-SA-4.0", attribution: nil)]))
        await picker.select("large")
        let pending = picker.pending
        #expect(pending?.preflight.model == "large")
        #expect(pending?.text.message.contains("CC-BY-SA-4.0") == true)
        #expect(await mock.ensureAvailableCalls().isEmpty)  // nothing downloads before the user confirms
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == nil)
        await picker.confirmPending()
        #expect(picker.pending == nil)
        #expect(await mock.ensureAvailableCalls() == ["large"])
        #expect(await mock.consentedModels() == ["large"])  // recorded so the consent hook does not ask again
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == "large")
        #expect(picker.downloads.isEmpty)
        #expect(picker.entries.first { $0.id == "large" }?.isInstalled == true)
    }

    @Test func cancellingTheConfirmationDownloadsNothing() async {
        let (picker, mock, store) = await make()
        await picker.select("large")
        #expect(picker.pending != nil)
        picker.cancelPending()
        #expect(picker.pending == nil)
        #expect(await mock.ensureAvailableCalls().isEmpty)
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == nil)
    }

    @Test func insufficientDiskIsRefusedWithAClearMessage() async {
        let (picker, mock, _) = await make()
        await mock.setPreflight(
            ModelPreflightResult(
                model: "large", displayName: "large", downloadBytes: 600_000_000, freeDiskBytes: 1_000_000,
                issues: [.insufficientDisk(needed: 720_000_000, available: 1_000_000)]))
        await picker.select("large")
        #expect(picker.pending == nil)
        let message = picker.errorMessage ?? ""
        #expect(message.contains("not enough free disk space"))
        #expect(message.contains("Free up space"))
        #expect(await mock.ensureAvailableCalls().isEmpty)
    }

    @Test func aFailedDownloadShowsTheReasonAndDoesNotSelect() async {
        let (picker, mock, store) = await make()
        await mock.setFailure(.modelDownloadFailed("large", reason: "The server returned 503."), for: "large")
        await picker.select("large")
        await picker.confirmPending()
        #expect(picker.errorMessage == "The server returned 503.")
        #expect(await PreferredModel.explicitID(for: .file, settings: store) == nil)
        #expect(picker.downloads.isEmpty)
    }

    @Test func aDeclinedConsentIsNotAnError() async {
        let (picker, mock, _) = await make()
        await mock.setFailure(.cancelled, for: "large")
        await picker.select("large")
        await picker.confirmPending()
        #expect(picker.errorMessage == nil)
    }

    @Test func failedRowsOfferARetryThatConfirmsAgain() async {
        let (picker, mock, _) = await make()
        await mock.setState(.failed(reason: "offline"), for: "large")
        await picker.reload()
        await picker.select("large")
        #expect(picker.pending?.isRetry == true)
    }
}

@Suite("Consent hook") struct ConsentHookTests {
    final class Scripted: ModelConsentPresenting, @unchecked Sendable {
        let answer: Bool
        nonisolated(unsafe) var shown: [ModelConsentText] = []
        init(_ answer: Bool) { self.answer = answer }
        @MainActor func present(_ text: ModelConsentText) async -> Bool {
            shown.append(text)
            return answer
        }
    }

    private let preflight = ModelPreflightResult(
        model: "m", displayName: "Qwen Sinhala", downloadBytes: 1_100_000_000, freeDiskBytes: 40_000_000_000,
        issues: [
            .licenseNotice(spdx: "CC-BY-SA-4.0", attribution: "Attribution: the model authors."),
            .hardwareTier(required: .tier16, available: .tier8), .largeDownload(bytes: 1_100_000_000),
        ])

    @Test func dialogTextShowsSizeLicenceHardwareAndDisk() {
        let text = ModelConsentText.make(preflight)
        #expect(text.title == "Download Qwen Sinhala?")
        #expect(text.message.contains("Download size:"))
        #expect(text.message.contains("CC-BY-SA-4.0"))
        #expect(text.message.contains("Attribution: the model authors."))
        #expect(text.message.contains("16 GB"))
        #expect(text.message.contains("Free disk space:"))
        #expect(text.confirmTitle == "Download")
    }

    @Test func hookReturnsTheUsersAnswer() async {
        let yes = Scripted(true)
        let no = Scripted(false)
        #expect(await PromptingModelConsent(presenter: yes).confirmDownload(preflight))
        #expect(!(await PromptingModelConsent(presenter: no).confirmDownload(preflight)))
        #expect(await MainActor.run { yes.shown.count } == 1)
    }

    @Test func insufficientDiskTextNamesTheShortfall() {
        var refused = preflight
        refused.issues = [.insufficientDisk(needed: 1_320_000_000, available: 200_000_000)]
        let text = ModelConsentText.insufficientDisk(refused)
        #expect(text?.contains("not enough free disk space") == true)
        #expect(text?.contains("Qwen Sinhala") == true)
        #expect(ModelConsentText.insufficientDisk(preflight) == nil)
    }

    @Test func errorTextSurfacesTheManagersRefusal() {
        let error = AppError.modelDownloadFailed("m", reason: "Not enough free disk space: needs 1 GB, 2 MB available.")
        #expect(ModelDownloadErrorText.message(for: error, modelName: "M").contains("Not enough free disk space"))
        #expect(ModelDownloadErrorText.message(for: AppError.cancelled) == "The download was cancelled.")
    }
}

/// Every download goes through `ModelManaging.ensureAvailable`, where the manager runs the preflight and the consent hook.
/// This guard makes a new caller (or a direct download path) a reviewed decision, and the app must install the hook.
@Suite("Download consent guard") struct DownloadConsentGuardTests {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func sources(under roots: [String]) -> [(path: String, text: String)] {
        var out: [(String, String)] = []
        for root in roots {
            let base = repoRoot.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" && !url.path.contains("/Tests/") {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                out.append((String(url.path.dropFirst(repoRoot.path.count + 1)), text))
            }
        }
        return out
    }

    static var allSourceRoots: [String] {
        let packages = repoRoot.appendingPathComponent("Packages")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: packages.path)) ?? []
        return ["App"] + names.map { "Packages/\($0)/Sources" }
    }

    /// Callers of `ensureAvailable` / `retryDownload` outside the manager itself, each with the reason it is gated.
    static let knownCallers: [String: String] = [
        "Packages/Features/Sources/FeatureSettings/ModelManagerModel.swift": "Settings > Models and language downloads",
        "Packages/Features/Sources/FeatureShell/ModelPickerModel.swift": "sidebar model picker (preflight + confirmation first)",
        "Packages/Features/Sources/FeatureQueue/BatchSettingsModel.swift": "batch sheet model pick",
        "Packages/Features/Sources/FeatureHome/HomeModel.swift": "Home default model",
        "Packages/Features/Sources/FeatureOnboarding/OnboardingLanguageModel.swift": "onboarding language models",
        "Packages/Features/Sources/FeatureEditor/TranslatePanel.swift": "Translate panel (translation models)",
        "Packages/Jobs/Sources/Jobs/PersistentJobQueue+Run.swift": "queue auto-download for the routed model",
        "Packages/Meetings/Sources/Meetings/MeetingFinalizer.swift": "diarization and ASR models for meeting finalisation",
        "Packages/AppCore/Sources/AppCore/Models.swift": "protocol declaration and default",
        "Packages/AppCore/Sources/AppCoreTesting/Mocks.swift": "test double",
        "Packages/Features/Sources/FeatureSupport/Placeholders.swift": "preview double",
    ]

    @Test func everyDownloadCallerIsAKnownGatedEntryPoint() {
        var unknown: [String] = []
        for file in Self.sources(under: Self.allSourceRoots) {
            if file.path.hasPrefix("Packages/ModelStore/") { continue }
            let calls = file.text.contains(".ensureAvailable(") || file.text.contains(".retryDownload(")
            if calls, Self.knownCallers[file.path] == nil { unknown.append(file.path) }
        }
        #expect(unknown.isEmpty, "New download entry points must go through ModelManaging.ensureAvailable and be listed here: \(unknown)")
    }

    @Test func noFeatureOpensItsOwnModelDownload() {
        let offenders = Self.sources(under: Self.allSourceRoots).filter { file in
            !file.path.hasPrefix("Packages/ModelStore/") && file.text.contains("URLSessionDownloader")
        }.map(\.path)
        #expect(offenders.isEmpty, "Only ModelStore downloads models: \(offenders)")
    }

    @Test func theAppInstallsTheConsentHookOnTheModelManager() throws {
        let env = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/AppEnvironment.swift"), encoding: .utf8)
        let start = try #require(env.range(of: "let models = ModelManager("))
        let call = env[start.lowerBound...].prefix(400)
        #expect(call.contains("consent: PromptingModelConsent"), "ModelManager(...) must be created with the consent hook")
    }

    @Test func managerReferencesToLiveAndFileModelsAreSplit() throws {
        let env = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/AppEnvironment.swift"), encoding: .utf8)
        #expect(env.contains("explicitID(for: .live"))
        #expect(env.contains("explicitID(for: .file"))
        #expect(!env.contains("SettingsKey.preferredModel,"), "routing must not read the legacy shared key")
    }
}

import AppCore
import AppKit
import AudioCapture
import Diarization
import Dictation
import EarmarkTranslation
import FeatureMenuBar
import FeatureSettings
import FeatureShell
import FeatureSupport
import Foundation
import Jobs
import LiveCaptions
import Meetings
import ModelStore
import Permissions
import Persistence
import Processing
import QwenASR
import Transcription

#if DEBUG
    import AppCoreTesting
#endif

/// Composition root: builds the concrete services behind the AppCore protocols and the feature models that use them.
///
/// Real implementations are wired where they exist (`AppDatabase`, `ModelManager`, `SystemHardwareTierProvider`, the
/// `PersistentJobQueue` with its engines);
/// `Placeholder*` stand-ins cover protocols without a real implementation yet (meeting detector). Live captions
/// (`LiveSessionOrchestrator` and overlay) and dictation are wired here too. Debug builds launched with `-UseMocks` (or `EARMARK_USE_MOCKS=1`) use fully in-memory
/// services with sample data and the `AppCoreTesting` model manager.
@MainActor
final class AppEnvironment {
    let startupFailure: String?
    let updates = AppUpdateController()
    let services: AppServices
    /// Full wiring for the Settings scene (rules and presets persist through the database).
    let settingsDependencies: SettingsDependencies
    let shell: ShellModel
    let menuBar: MenuBarModel
    private let activation: ActivationPolicyController
    /// Live captions and dictation runtime (nil under `-UseMocks`); held here so they live as long as the app.
    private let live: LiveRuntime?
    private let dictation: DictationRuntime?
    private let meetings: MeetingRuntime?
    /// Host state for Apple language-pack installs (nil under `-UseMocks`); `TranslationPackHost` attaches it to a window.
    let translationPacks: ApplePackInstaller?
    /// The Apple-aware router, shared with onboarding so its model recommendations match what live and dictation will use.
    let engineRouter: any EngineRouter

    init() {
        let composition = Self.makeServices()
        let services = composition.services
        startupFailure = composition.startupFailure
        self.services = services
        var dependencies = composition.settingsDependencies
        dependencies.microphonePreviewErrors = { source in
            (source as? any ErrorReportingAudioSource)?.errors ?? AsyncStream { $0.finish() }
        }
        if updates.isConfigured {
            dependencies.checkForUpdates = { [updates] in updates.checkForUpdates() }
            dependencies.automaticUpdateChecks = { [updates] in updates.automaticallyChecks }
            dependencies.setAutomaticUpdateChecks = { [updates] in updates.setAutomaticallyChecks($0) }
        }
        settingsDependencies = dependencies
        live = composition.live
        dictation = composition.dictation
        meetings = composition.meetings
        translationPacks = composition.translationPacks
        engineRouter = composition.engineRouter ?? DefaultEngineRouter()
        shell = ShellModel(services: services)
        menuBar = MenuBarModel(services: services)
        activation = ActivationPolicyController(settings: services.settings)
        guard startupFailure == nil else { return }
        menuBar.start()
        // The single shared model key became one key per use case; copy the old choice to file transcription once.
        let settingsStore = services.settings
        Task { await PreferredModel.migrateLegacy(settings: settingsStore) }
        shell.startBackgroundWork()
        activation.start()
        live?.extras.start()
        if let dictation {
            let store = services.settings
            let controller = dictation.controller
            Task { await DictationSettingsBridge.run(store: store, controller: controller) }
        }
        // FILE-AC-08: jobs left running by a crash or quit continue from their last checkpoint.
        let queue = services.jobQueue
        Task { await queue.resumeInterrupted() }
        startMeetings(composition)
        followActivation()
    }

    /// Re-reads every permission when the app becomes active, so a switch changed in System Settings reaches the menu bar,
    /// onboarding, dictation and live without a relaunch. The OS state is exact for microphone and notifications.
    private func followActivation() {
        guard let permissions = services.permissions as? PermissionsService else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { await permissions.refresh() }
        }
    }

    /// Starts the meeting detector, recovers interrupted recordings, follows the consent switch and registers the bookmark
    /// hotkey (MTG-AC-01, -12, -11, -14).
    private func startMeetings(_ composition: Composition) {
        guard let meetings = composition.meetings else { return }
        let settings = services.settings
        let queue = services.jobQueue
        let repository = services.meetings
        let controller = meetings.controller
        // Ask for notification permission while the user is in Earmark, not mid-call when the dialog would hide behind Zoom.
        // Not before onboarding has finished: its own permission step asks, and a system dialog on the very first launch
        // would land on top of the welcome flow.
        if let prompter = services.meetingPrompts as? SystemMeetingPrompter {
            Task {
                guard await settings.value(for: SettingsKey.onboardingCompleted, as: Bool.self) == true else { return }
                await prompter.requestAuthorizationIfNeeded()
            }
        }
        // Quitting during a meeting stops and finalizes it (recorder closed, live transcript saved, finalization queued)
        // instead of leaving a half-written recording for the next launch to repair.
        AppDelegate.terminationWork = {
            guard await controller.currentSession != nil else { return }
            await controller.shutdown()
        }
        Task {
            // Recovery finishes before detection starts, so an auto-started recording can never be mistaken for a leftover.
            await MeetingRuntimeFactory.recover(
                root: await meetings.recordingsRoot(), meetings: repository, jobs: queue, controller: controller)
            await meetings.detector.start()
        }
        MeetingRuntimeFactory.followConsent(settings: settings)
        if let hotkeys = composition.dictation?.hotkeys {
            let capture = meetings.capture
            Task { await BookmarkHotkey.run(hotkeys: hotkeys, settings: settings) { await capture.addBookmark() } }
        }
    }

    /// `true` when the debug mock flag is set.
    static var usesMocks: Bool {
        #if DEBUG
            Bundle.main.bundleIdentifier == "lk.dumindu.earmark.uihost"
                || ProcessInfo.processInfo.arguments.contains("-UseMocks")
                || ProcessInfo.processInfo.environment["EARMARK_USE_MOCKS"] == "1"
        #else
            false
        #endif
    }

    /// Everything `init` needs from the composition.
    private struct Composition {
        var startupFailure: String?
        var services: AppServices
        var settingsDependencies: SettingsDependencies
        var live: LiveRuntime?
        var dictation: DictationRuntime?
        var meetings: MeetingRuntime?
        var translationPacks: ApplePackInstaller?
        var engineRouter: (any EngineRouter)?
    }

    struct LiveRuntime {
        let session: LiveSessionOrchestrator
        let overlay: CaptionOverlayController
        let extras: LiveExtrasService
    }

    struct DictationRuntime {
        let controller: DictationController
        let hud: DictationHUDController
        let hotkeys: GlobalHotkeyService
    }

    // Keep the composition root's service ownership and wiring in one place.
    // swiftlint:disable:next function_body_length
    private static func makeServices() -> Composition {
        #if DEBUG
            if usesMocks {
                let mocks = mockServices()
                var settings = SettingsDependencies.standalone(store: mocks.settings)
                settings.models = MockModelManager(descriptors: BuiltInCatalog.models, installed: [RoutingTargets.whisperSmall])
                settings.reviewedHuggingFaceModels = { try ReviewedHuggingFaceModels.resolve($0) }
                return Composition(services: mocks, settingsDependencies: settings)
            }
        #endif
        let database: AppDatabase
        do { database = try openDatabase() } catch {
            AppLog.logger("AppEnvironment").error("Library could not be opened: \(String(describing: error), privacy: .public)")
            let recoveryServices = AppServices.preview()
            return Composition(
                startupFailure:
                    "Earmark could not open its library. Your existing database has been left in place. "
                    + "No temporary library has been substituted.\n\n\(error.localizedDescription)",
                services: recoveryServices, settingsDependencies: .standalone(store: recoveryServices.settings))
        }
        let hardware = SystemHardwareTierProvider()
        // Apple's speech assets are system-managed; without this provider the Models screen reported them as "not available".
        let apple = AppleSpeechEngine()
        let appleReadiness = AppleSpeechReadiness()
        // Every download (batch sheet, queue, Home, onboarding, translation, diarization models) runs the manager's preflight;
        // when it needs consent (licence, under-spec hardware) this hook asks, and insufficient disk refuses it.
        let models = ModelManager(
            appleAssets: AppleSpeechAssetProvider(engine: apple, readiness: appleReadiness), hardware: hardware,
            consent: PromptingModelConsent(presenter: ModelConsentAlert()))
        let systemLanguage = LanguageCode(Locale.current.language.languageCode?.identifier ?? "en")
        Task { await appleReadiness.refresh(engine: apple, languages: [systemLanguage, .english]) }
        // One settings store instance: its change streams are tied to it, and the queue observes the same one.
        let settings = database.makeSettingsStore()
        Task {  // LIB-AC-13: playback resolves library-owned media against the chosen location.
            LibraryLocation.use(base: LibraryLocation.base(custom: await settings.value(for: SettingsKey.libraryLocation, as: String.self)))
        }
        let permissions = PermissionsService()
        let audioDevices = AudioDeviceProvider()
        // One engine instance each, shared by file jobs, live captions and dictation: WhisperKit holds a single resident model.
        let whisper = WhisperKitEngine(models: models, tokenizerFolder: models.tokenizerFolder)
        // Sinhala goes to Qwen3-ASR (MLX), never to stock Whisper (ADR-004). The model loads lazily on first use.
        let qwen = QwenSinhalaEngine(models: models)
        let parakeet = ParakeetEngine(models: models)
        let engines: [EngineID: any TranscriptionEngine] = [whisper.id: whisper, apple.id: apple, qwen.id: qwen, parakeet.id: parakeet]
        let translation = TranslationRuntime.make(models: models, settings: settings, nllbPython: nil)
        // Live and dictation leave Apple Speech for Whisper (with a notice) when it cannot be used on this Mac.
        let router = AppleAwareEngineRouter(readiness: appleReadiness, engine: apple)

        let live = makeLive(
            database: database, models: models, hardware: hardware, settings: settings, permissions: permissions,
            audioDevices: audioDevices, engines: engines, router: router, whisper: whisper, translation: translation.router)
        let dictation = makeDictation(
            database: database, models: models, hardware: hardware, settings: settings, permissions: permissions,
            engines: engines, router: router, translation: translation.router)
        let dictationControl = DictationMenuControl.make(controller: dictation.controller, settings: settings)

        // Meeting detection prompts (notification actions).
        let meetingPrompter = SystemMeetingPrompter()
        meetingPrompter.install()
        let diarizer = FluidAudioDiarizer(models: models)
        let embeddings = FluidSpeakerEmbeddingProvider(models: models)
        let finalization = MeetingFinalization(
            database: database, models: models, hardware: hardware, settings: settings, whisper: whisper, engines: engines,
            diarizer: diarizer, embeddings: embeddings, router: DefaultEngineRouter())
        let translationJob = TranslationJob(transcripts: database.transcripts, router: translation.router)
        let queue = makeJobQueue(
            database: database, models: models, hardware: hardware, settings: settings, whisper: whisper, engines: engines,
            diarizer: diarizer,
            handlers: [
                .finalizeMeeting: finalization.handler,
                .translate: { context in
                    guard let id = context.job.transcriptID, let target = context.job.settings.translateTo else {
                        throw AppError.other("The translation job has no transcript or target language.")
                    }
                    let outcome = try await translationJob.run(
                        transcriptID: id, target: target, progress: { await context.progress($0) })
                    if let message = outcome.skippedMessage { throw AppError.other(message) }
                    return JobHandlerResult(transcriptID: id, title: outcome.title)
                },
            ])
        let meetings = MeetingRuntimeFactory.make(
            database: database, settings: settings, permissions: permissions, jobs: queue, live: live.session, prompts: meetingPrompter)
        let explicitModel: @Sendable () async -> ModelID? = { await PreferredModel.explicitID(for: .file, settings: settings) }
        let services = AppServices(
            jobQueue: queue, transcripts: database.transcripts, meetings: database.meetings, models: models, live: live.session,
            meetingDetector: meetings.detector, hardware: hardware, permissions: permissions, audioDevices: audioDevices,
            settings: settings, media: database.media, presets: database.presets, liveExtras: live.extras, dictation: dictationControl,
            meetingCapture: meetings.capture, meetingPrompts: meetingPrompter, voiceProfiles: database.voiceProfiles,
            speakerEmbeddings: embeddings,
            segmentRetranscriber: SegmentRetranscriptionAdapter(
                router: DefaultEngineRouter(), hardware: hardware, models: models, engines: engines, explicitModel: explicitModel),
            translation: translation.service,
            mediaRoots: { [recordings = meetings.recordingsRoot] in [await recordings()] + MediaFiles.defaultRoots })
        var settingsDependencies = SettingsDependencies(
            store: settings, models: models, hardware: hardware, audioDevices: audioDevices, permissions: permissions,
            rules: database.rules, presets: database.presets, transcripts: database.transcripts,
            hotkeyDiagnostics: dictation.hotkeys,
            retryHotkeys: { [controller = dictation.controller] in await controller.retryHotkeyRegistration() },
            overlayPlacement: live.overlay, voiceProfiles: database.voiceProfiles,
            microphonePreview: { uid in MicrophoneSource(deviceUID: uid, permissions: permissions, deviceProvider: audioDevices) })
        settingsDependencies.mediaPurger = MediaPurger(
            transcripts: database.transcripts, media: database.media, meetings: database.meetings, roots: services.mediaRoots)
        settingsDependencies.reviewedHuggingFaceModels = { try ReviewedHuggingFaceModels.resolve($0) }
        settingsDependencies.meetingDiagnostics = MeetingDiagnosticsAdapter(detector: meetings.detector, prompter: meetingPrompter)
        return Composition(
            services: services, settingsDependencies: settingsDependencies, live: live, dictation: dictation, meetings: meetings,
            translationPacks: translation.packs, engineRouter: router)
    }

    /// Live captions: the orchestrator over the `AudioCapture` sources, the router-chosen engine, LS-EEND streaming
    /// diarization and the shared post-processing chain, plus the caption overlay.
    private static func makeLive(
        database: AppDatabase, models: ModelManager, hardware: any HardwareTierProviding, settings: any SettingsStore,
        permissions: any PermissionsServicing, audioDevices: AudioDeviceProvider, engines: [EngineID: any TranscriptionEngine],
        router: any EngineRouter, whisper: WhisperKitEngine, translation: any TranslationRouter
    ) -> LiveRuntime {
        let audio = LiveAudioProvider(permissions: permissions, settings: settings, deviceProvider: audioDevices)
        // Live captions have their own preferred model (a file-only model must never reach streaming).
        let explicitModel: @Sendable () async -> ModelID? = { await PreferredModel.explicitID(for: .live, settings: settings) }
        // Single languages and auto-detect use the router; a multilingual set of several languages code-switches through
        // `MultilingualEngine` (language ID on Whisper small, one engine per language).
        let provider = LiveLanguageEngineProvider(
            base: RouterEngineProvider(
                router: router, hardware: hardware, models: models, engine: { engines[$0] }, explicitModel: explicitModel),
            router: router, hardware: hardware, models: models, engines: engines,
            identifier: WhisperLanguageIdentifier(engine: whisper, model: RoutingTargets.whisperSmall), explicitModel: explicitModel)
        let rules = database.rules
        let session = LiveSessionOrchestrator(
            audio: audio, engines: provider, transcripts: database.transcripts, postProcessor: PostProcessingChain(),
            postProcessingContext: {
                let ignore = ((try? await rules.ignoreRules()) ?? []).filter { $0.isEnabled && $0.deletedAt == nil }
                let replace = ((try? await rules.replacementRules()) ?? []).filter { $0.isEnabled && $0.deletedAt == nil }
                return PostProcessingContext(
                    ignoreRules: ignore, replacementRules: replace,
                    applyReplacements: await settings.value(for: SettingsKey.applyReplacementsByDefault, as: Bool.self) ?? true,
                    enableHallucinationFilter: await settings.value(for: SettingsKey.hallucinationFilterEnabled, as: Bool.self) ?? true)
            },
            diarizer: LSEENDStreamingDiarizer(models: models), translation: translation)
        let overlay = CaptionOverlayController(settings: settings)
        let extras = LiveExtrasService(
            session: session, audio: audio, overlay: overlay,
            presetStore: CaptionPresetStore(repository: database.presets, settings: settings), settings: settings)
        return LiveRuntime(session: session, overlay: overlay, extras: extras)
    }

    /// Dictation: global hotkey (event tap with an `NSEvent` fallback), mic source, engine routed for `.dictation`,
    /// text insertion, HUD and history. The controller is started at launch; a missing permission only disables the hotkey.
    private static func makeDictation(
        database: AppDatabase, models: ModelManager, hardware: any HardwareTierProviding, settings: any SettingsStore,
        permissions: any PermissionsServicing, engines: [EngineID: any TranscriptionEngine], router: any EngineRouter,
        translation: any TranslationRouter
    ) -> DictationRuntime {
        let hud = DictationHUDController()
        let routed = RoutedEngineProvider(
            router: router, tier: { hardware.profile.tier }, installedModels: { await models.installedModels() },
            engines: engines)
        let hotkeys = GlobalHotkeyService(source: FallbackHotkeySource())
        let controller = DictationController(
            dependencies: DictationDependencies(
                hotkeys: hotkeys,
                makeAudioSource: { uid in MicrophoneSource(deviceUID: uid, permissions: permissions) },
                engineProvider: routed.provider,
                pipeline: DictationPipeline(
                    postProcessor: PostProcessingChain(), rules: database.rules,
                    // Translate before insert (TRN-AC-12): a slow or failing translation inserts the original text.
                    translation: TimeLimitedTranslationRouter(base: translation)),
                inserter: TextInserter.system(), history: DictationHistory(repository: database.dictationHistory),
                settings: settings, permissions: permissions, hud: hud, notifier: SystemDictationNotifier(),
                onboarding: AccessibilityOnboardingPresenter()))
        return DictationRuntime(controller: controller, hud: hud, hotkeys: hotkeys)
    }

    /// The real file-transcription queue: WhisperKit (tokenizer provisioned by the model manager, so no implicit network,
    /// ENG-AC-14) and Apple Speech engines behind the router, offline diarization, auto-export and notifications.
    private static func makeJobQueue(
        database: AppDatabase, models: ModelManager, hardware: any HardwareTierProviding, settings: any SettingsStore,
        whisper: WhisperKitEngine, engines: [EngineID: any TranscriptionEngine], diarizer: any Diarizer,
        handlers: [JobKind: JobHandler]
    ) -> any JobQueue {
        let decoder = AVFileDecoder()
        // Auto-detect may pick any language a catalogued ASR model covers, so Sinhala can be detected and routed to Qwen.
        var chunking = FileTranscriptionPipeline.Configuration()
        chunking.autoDetectCandidates = LanguageCapabilityTable(models: BuiltInCatalog.models).languages()
        let configuration = chunking
        let router = DefaultEngineRouter(catalog: BuiltInCatalog.models)
        // Language ID must use the model the plan routed to; a fixed model would swap WhisperKit's single resident model.
        let whisperID = whisper.id
        let pipeline: PipelineFactory = { plan in
            let model = plan.assignments.first { $0.engine == whisperID }?.model
            return FileTranscriptionPipeline(
                decoder: decoder, identifier: model.map { WhisperLanguageIdentifier(engine: whisper, model: $0) },
                configuration: configuration)
        }
        // Auto-detect and multilingual jobs resolve each detected language through the router; a single language keeps the plan.
        let resolver: FileEngineResolver = { plan, settings in
            switch settings.languageMode {
            case .single: return EngineBinding.resolver(plan: plan, engines: engines)
            case .autoDetect, .multilingual:
                return LanguageEngineResolver.make(
                    router: router, basePlan: plan, useCase: .file, tier: hardware.profile.tier, explicitModel: settings.modelID,
                    installed: { await models.installedModels() }, engines: engines)
            }
        }
        return PersistentJobQueue(
            services: JobQueueServices(
                jobs: database.jobs, transcripts: database.transcripts, media: database.media, rules: database.rules,
                settings: settings, models: models, hardware: hardware, engines: engines,
                pipeline: pipeline, decoder: decoder, diarizer: diarizer,
                autoExport: WatchFolderExport.provider(settings: settings, presets: database.presets),
                notifier: SystemJobNotifier(), handlers: handlers, engineResolver: resolver,
                libraryRoot: {
                    LibraryLocation.libraryRoot(
                        base: LibraryLocation.base(custom: await settings.value(for: SettingsKey.libraryLocation, as: String.self)))
                }))
    }

    private static func openDatabase() throws -> AppDatabase {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let support else { throw AppError.persistence(reason: "Application Support is unavailable.") }
        let url = support.appendingPathComponent("Earmark/earmark.sqlite")
        return try AppDatabase.open(at: url)
    }

    #if DEBUG
        private static func mockServices() -> AppServices {
            let sample = [
                Transcript(title: "Weekly sync", source: .meeting, duration: 1830, languages: ["en"]),
                Transcript(title: "Project notes", source: .file, duration: 412, languages: ["es"]),
            ]
            let model = ModelDescriptor(
                id: "mock/asr", displayName: "On-device speech", kind: .asr, runtime: .coreML, languages: [.english, "es", "fr", .sinhala],
                sizeBytes: 100,
                license: LicenseInfo(spdx: "MIT"))
            var services = AppServices.preview(transcripts: sample)
            let speakers = [Speaker(name: "Interviewer", colorHex: "1B7A74"), Speaker(name: "Nimali Perera", colorHex: "C44B16")]
            let lines = [
                "And when you look back at the early footage, what do you keep?",
                "I always keep the first take. The second one is for the editor, but the first one is for me.",
                "Even when the audio is rough?",
                "Rough is honest. C’est la première prise qui compte.",
                "Let's talk about how you earmark a moment worth coming back to.",
                "Usually it is a pause. Someone stops, and you can hear them deciding whether to say the true thing.",
            ]
            var transcript = sample[0]
            transcript.speakers = speakers
            transcript.languages = [.english, "fr"]
            if let asset = try? MockPlaybackMedia.makeAsset() {
                transcript.mediaAssetID = asset.id
                transcript.duration = asset.duration
                services.media = InMemoryMedia(items: [asset])
            }
            let segments = lines.enumerated().map { index, text in
                Segment(
                    start: Double(index * 12), end: Double(index * 12 + 10), text: text, speakerID: speakers[index % 2].id,
                    languageCode: index == 3 ? "fr" : .english)
            }
            services.transcripts = InMemoryTranscripts(items: [transcript, sample[1]], segments: [transcript.id: segments])
            services.models = MockModelManager(descriptors: [model])
            if UITestConfiguration.value("-EarmarkTestQueue") == "YES" {
                let states: [(String, JobState)] = [
                    ("Running interview.wav", .running), ("Paused notes.wav", .paused), ("Waiting clip.wav", .pending),
                    ("Finished conversation.wav", .completed), ("Stopped recording.wav", .cancelled), ("Failed import.wav", .failed),
                ]
                services.jobQueue = PlaceholderJobQueue(
                    seed: states.map { title, state in
                        Job(
                            kind: .transcribeFile, state: state, input: URL(fileURLWithPath: "/tmp/\(title)"),
                            transcriptID: state == .completed ? transcript.id : nil, progress: state == .completed ? 1 : 0.35)
                    })
            }
            return services
        }
    #endif
}

/// Applies the Dock-icon preference as the app's activation policy (MENU-AC-08) and follows changes.
@MainActor
final class ActivationPolicyController {
    private let settings: any SettingsStore
    private var task: Task<Void, Never>?

    init(settings: any SettingsStore) { self.settings = settings }

    func start() {
        guard task == nil else { return }
        let settings = settings
        task = Task { [weak self] in
            self?.apply(showDockIcon: await GeneralSettingsModel.loadShowDockIcon(from: settings))
            for await _ in settings.changes(for: SettingsKey.showDockIcon) {
                self?.apply(showDockIcon: await GeneralSettingsModel.loadShowDockIcon(from: settings))
            }
        }
    }

    private func apply(showDockIcon: Bool) {
        let policy: NSApplication.ActivationPolicy = showDockIcon ? .regular : .accessory
        guard NSApplication.shared.activationPolicy() != policy else { return }
        NSApplication.shared.setActivationPolicy(policy)
        if showDockIcon { NSApplication.shared.activate() }
    }
}
